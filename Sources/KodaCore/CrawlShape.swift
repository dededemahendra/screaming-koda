import Foundation
import GRDB

/// One node of the site's path hierarchy.
public struct SiteTreeNode: Identifiable, Sendable, Equatable {
    /// The full path prefix, which is unique and stable.
    public let id: String
    /// Just this segment, for display.
    public let name: String
    /// Set when this node is itself a crawled page rather than only a folder.
    public let urlID: Int64?
    public let status: Int?
    /// Pages at or below this node, so a folder's weight is visible without
    /// opening it.
    public let pageCount: Int
    /// Non-indexable pages at or below, which is what makes a branch worth
    /// opening.
    public let issueCount: Int
    public var children: [SiteTreeNode]

    public var isFolder: Bool { !children.isEmpty }
}

public struct GraphNode: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let url: String
    public let label: String
    public let depth: Int
    public let indexable: Bool
    public let inlinks: Int
}

public struct GraphEdge: Sendable, Equatable, Hashable {
    public let from: Int64
    public let to: Int64
}

/// The link graph, bounded.
///
/// A 500,000-node diagram is not a visualisation, it is a grey rectangle. The
/// most-linked pages are kept, since they are the ones the structure is about,
/// and the count of what was left out is reported rather than hidden.
public struct CrawlGraph: Sendable, Equatable {
    public let nodes: [GraphNode]
    public let edges: [GraphEdge]
    public let totalNodes: Int

    public var isTruncated: Bool { nodes.count < totalNodes }
    public var maxDepth: Int { nodes.map(\.depth).max() ?? 0 }
}

extension Store {
    /// The site as a path hierarchy.
    ///
    /// Built from `urls.path` rather than from the link graph: people think
    /// about a site as folders, and a link-derived tree would put a page under
    /// whichever page happened to link to it first, which is an accident of
    /// crawl order rather than a fact about the site.
    public func siteTree() throws -> SiteTreeNode {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.id AS id, u.path AS path, r.status AS status,
                       (\(Indexability.isNonIndexable)) AS bad
                \(ReportSQL.from)
                WHERE u.is_internal = 1 AND u.check_only = 0 AND \(Store.visibleURLsFilter)
                ORDER BY u.path
                """)
        }

        var root = Builder(name: "/", id: "/")
        for row in rows {
            let path: String = row["path"]
            let segments = path.split(separator: "/").map(String.init)
            root.insert(segments: segments, urlID: row["id"], status: row["status"],
                        bad: (row["bad"] as Int? ?? 0) == 1, prefix: "")
        }
        return root.build()
    }

    /// A private mutable shape while the tree is assembled; the public node is
    /// immutable.
    private final class Builder {
        let name: String
        let id: String
        var urlID: Int64?
        var status: Int?
        var isBad = false
        var children: [String: Builder] = [:]

        init(name: String, id: String) {
            self.name = name
            self.id = id
        }

        func insert(segments: [String], urlID: Int64, status: Int?, bad: Bool, prefix: String) {
            guard let first = segments.first else {
                // The path ended here, so this node is a page and not only a folder.
                self.urlID = urlID
                self.status = status
                self.isBad = bad
                return
            }
            let childID = prefix + "/" + first
            let child = children[first] ?? Builder(name: first, id: childID)
            children[first] = child
            child.insert(segments: Array(segments.dropFirst()), urlID: urlID,
                         status: status, bad: bad, prefix: childID)
        }

        func build() -> SiteTreeNode {
            let built = children.values
                .map { $0.build() }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return SiteTreeNode(
                id: id, name: name, urlID: urlID, status: status,
                pageCount: (urlID == nil ? 0 : 1) + built.reduce(0) { $0 + $1.pageCount },
                issueCount: (isBad ? 1 : 0) + built.reduce(0) { $0 + $1.issueCount },
                children: built)
        }
    }

    /// The internal link graph, capped at `limit` of the most-linked pages.
    public func linkGraph(limit: Int = 300) throws -> CrawlGraph {
        try dbQueue.read { db in
            let total = try Int.fetchOne(db, sql: """
                SELECT count(*) \(ReportSQL.from)
                WHERE u.is_internal = 1 AND r.status IS NOT NULL AND \(Reports.pageRows)
                """) ?? 0

            let rows = try Row.fetchAll(db, sql: """
                SELECT u.id AS id, u.url AS url, u.path AS path, u.depth AS depth,
                       (\(Indexability.isNonIndexable)) AS bad,
                       (SELECT count(DISTINCT from_url_id) FROM links WHERE to_url_id = u.id) AS inlinks
                \(ReportSQL.from)
                WHERE u.is_internal = 1 AND r.status IS NOT NULL AND \(Reports.pageRows)
                ORDER BY inlinks DESC, u.depth ASC, u.id ASC
                LIMIT \(max(limit, 0))
                """)

            let nodes = rows.map { row in
                let path: String = row["path"]
                return GraphNode(id: row["id"], url: row["url"],
                                 label: path == "/" ? "/" : (path.split(separator: "/").last
                                                             .map(String.init) ?? path),
                                 depth: row["depth"],
                                 indexable: (row["bad"] as Int? ?? 0) == 0,
                                 inlinks: row["inlinks"] ?? 0)
            }
            guard !nodes.isEmpty else { return CrawlGraph(nodes: [], edges: [], totalNodes: total) }

            // Only edges between pages that made the cut: an edge to a node that
            // is not drawn is a line to nowhere.
            let kept = Set(nodes.map(\.id))
            let placeholders = Array(repeating: "?", count: kept.count).joined(separator: ",")
            let ids = Array(kept)
            let edgeRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT from_url_id AS a, to_url_id AS b FROM links
                WHERE from_url_id IN (\(placeholders)) AND to_url_id IN (\(placeholders))
                  AND from_url_id != to_url_id
                """, arguments: StatementArguments(ids + ids))

            return CrawlGraph(nodes: nodes,
                              edges: edgeRows.map { GraphEdge(from: $0["a"], to: $0["b"]) },
                              totalNodes: total)
        }
    }
}
