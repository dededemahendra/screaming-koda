import Foundation
import GRDB

/// One labelled field of the Details pane. Kept as label/value pairs rather than
/// a twenty-property struct so the view stays a loop and every field is
/// assertable by name in a test.
public struct DetailField: Sendable, Identifiable, Equatable {
    public let label: String
    public let value: String?
    public var id: String { label }

    public init(label: String, value: String?) {
        self.label = label
        self.value = value
    }
}

public struct URLDetail: Sendable, Equatable {
    public let id: Int64
    public let url: String
    public let fields: [DetailField]

    public func value(_ label: String) -> String? {
        fields.first { $0.label == label }?.value
    }
}

public struct LinkRow: Sendable, Identifiable, Equatable {
    /// Position in the result, not a database id: a page can link to the same
    /// target twice with different anchor text, and both rows are real.
    public let id: Int
    public let urlID: Int64
    public let url: String
    public let anchor: String?
    public let rel: String?
    public let status: Int?
}

public struct ImageRow: Sendable, Identifiable, Equatable {
    public let id: Int
    public let urlID: Int64
    public let url: String
    public let alt: String?
    public let status: Int?
    public let bytes: Int?
}

/// A capped result plus the true total, so the pane can say "showing 1,000 of
/// 4,213" instead of silently truncating.
public struct InspectorRows<Element: Sendable & Equatable>: Sendable, Equatable {
    public let items: [Element]
    public let total: Int
    public var isTruncated: Bool { items.count < total }

    public init(items: [Element], total: Int) {
        self.items = items
        self.total = total
    }
}

extension Store {
    /// Paging the inspector is not worth it in M3b. A page with more than a
    /// thousand inlinks exists; the cap is surfaced rather than hidden.
    public static let inspectorLimit = 1000

    public func detail(id: Int64) throws -> URLDetail? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT u.url AS url, u.host AS host, u.depth AS depth,
                       u.is_internal AS is_internal, u.redirect_hops AS hops,
                       u.check_only AS check_only, u.state AS state,
                       r.status AS status, r.error_kind AS error_kind,
                       r.content_type AS content_type, r.content_length AS content_length,
                       r.response_time_ms AS ms,
                       (SELECT ru.url FROM urls ru WHERE ru.id = r.redirect_target_id) AS redirect_to,
                       f.title AS title, f.title_length AS title_length, f.title_count AS title_count,
                       f.meta_description AS descr, f.meta_description_length AS descr_length,
                       f.meta_description_count AS descr_count,
                       f.h1 AS h1, f.h1_count AS h1_count, f.h2_count AS h2_count,
                       (SELECT cu.url FROM urls cu WHERE cu.id = f.canonical_id) AS canonical,
                       f.meta_robots AS meta_robots, f.x_robots_tag AS x_robots,
                       f.lang AS lang, f.word_count AS word_count,
                       \(Indexability.expression) AS indexability,
                       (SELECT count(DISTINCT from_url_id) FROM links WHERE to_url_id = u.id) AS inlinks,
                       (SELECT count(*) FROM links WHERE from_url_id = u.id) AS outlinks,
                       (SELECT count(*) FROM images WHERE url_id = u.id) AS image_count
                \(ReportSQL.from)
                WHERE u.id = ?
                """, arguments: [id])
            else { return nil }

            func text(_ key: String) -> String? { Self.display(row[key]) }
            let fields: [DetailField] = [
                .init(label: "Address", value: text("url")),
                .init(label: "Host", value: text("host")),
                .init(label: "Indexability", value: text("indexability")),
                .init(label: "Status", value: text("status")),
                .init(label: "Error", value: text("error_kind")),
                .init(label: "Content Type", value: text("content_type")),
                .init(label: "Size (bytes)", value: text("content_length")),
                .init(label: "Response Time (ms)", value: text("ms")),
                .init(label: "Redirects To", value: text("redirect_to")),
                .init(label: "Redirect Hops", value: text("hops")),
                .init(label: "Depth", value: text("depth")),
                .init(label: "Internal", value: (row["is_internal"] as Int? ?? 0) == 1 ? "Yes" : "No"),
                .init(label: "Title", value: text("title")),
                .init(label: "Title Length", value: text("title_length")),
                .init(label: "Titles Found", value: text("title_count")),
                .init(label: "Meta Description", value: text("descr")),
                .init(label: "Meta Description Length", value: text("descr_length")),
                .init(label: "Meta Descriptions Found", value: text("descr_count")),
                .init(label: "H1", value: text("h1")),
                .init(label: "H1s Found", value: text("h1_count")),
                .init(label: "H2s Found", value: text("h2_count")),
                .init(label: "Canonical", value: text("canonical")),
                .init(label: "Meta Robots", value: text("meta_robots")),
                .init(label: "X-Robots-Tag", value: text("x_robots")),
                .init(label: "Language", value: text("lang")),
                .init(label: "Word Count", value: text("word_count")),
                .init(label: "Inlinks", value: text("inlinks")),
                .init(label: "Outlinks", value: text("outlinks")),
                .init(label: "Images", value: text("image_count")),
            ]
            return URLDetail(id: id, url: row["url"], fields: fields)
        }
    }

    public func inlinks(id: Int64, limit: Int = Store.inspectorLimit) throws -> InspectorRows<LinkRow> {
        try links(id: id, limit: limit, incoming: true)
    }

    public func outlinks(id: Int64, limit: Int = Store.inspectorLimit) throws -> InspectorRows<LinkRow> {
        try links(id: id, limit: limit, incoming: false)
    }

    private func links(id: Int64, limit: Int, incoming: Bool) throws -> InspectorRows<LinkRow> {
        // The row shows the *other* end of the link: inlinks list who points
        // here, outlinks list what this page points at.
        let match = incoming ? "l.to_url_id" : "l.from_url_id"
        let other = incoming ? "l.from_url_id" : "l.to_url_id"
        return try dbQueue.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM links l WHERE \(match) = ?",
                                         arguments: [id]) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT o.id AS url_id, o.url AS url, l.anchor_text AS anchor, l.rel AS rel,
                       r.status AS status
                FROM links l
                JOIN urls o ON o.id = \(other)
                LEFT JOIN responses r ON r.url_id = o.id
                WHERE \(match) = ?
                ORDER BY l.position ASC, o.id ASC
                LIMIT ?
                """, arguments: [id, limit])
            return InspectorRows(
                items: rows.enumerated().map { index, row in
                    LinkRow(id: index, urlID: row["url_id"], url: row["url"],
                            anchor: row["anchor"], rel: row["rel"], status: row["status"])
                },
                total: total)
        }
    }

    public func imageRows(id: Int64, limit: Int = Store.inspectorLimit) throws -> InspectorRows<ImageRow> {
        try dbQueue.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM images WHERE url_id = ?",
                                         arguments: [id]) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id AS url_id, s.url AS url, i.alt AS alt,
                       r.status AS status, r.content_length AS bytes
                FROM images i
                JOIN urls s ON s.id = i.src_url_id
                LEFT JOIN responses r ON r.url_id = s.id
                WHERE i.url_id = ?
                ORDER BY s.id ASC
                LIMIT ?
                """, arguments: [id, limit])
            return InspectorRows(
                items: rows.enumerated().map { index, row in
                    ImageRow(id: index, urlID: row["url_id"], url: row["url"], alt: row["alt"],
                             status: row["status"], bytes: row["bytes"])
                },
                total: total)
        }
    }
}
