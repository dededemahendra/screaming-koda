import Foundation
import GRDB
import Testing
@testable import KodaCore

@MainActor
private func siteStore(_ pages: [(String, Int, Bool)]) throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        for (path, status, noindex) in pages {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,?,1,0,2)
                    """,
                arguments: ["https://s.test\(path)", Data(path.utf8), "s.test", path,
                            path.split(separator: "/").count])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO responses (url_id, status, content_type, fetched_at)
                    VALUES (?,?, 'text/html; charset=utf-8', 0)
                    """, arguments: [id, status])
            try db.execute(
                sql: "INSERT INTO page_facts (url_id, title, meta_robots) VALUES (?,?,?)",
                arguments: [id, "T", noindex ? "noindex" : nil])
        }
    }
    return store
}

private let site: [(String, Int, Bool)] = [
    ("/", 200, false),
    ("/blog", 200, false),
    ("/blog/one", 200, false),
    ("/blog/two", 200, true),          // noindex
    ("/blog/archive/old", 404, false), // a folder with no page of its own
    ("/about", 200, false),
]

// MARK: - Tree

@MainActor
@Test func theTreeFollowsTheURLPathHierarchy() throws {
    let store = try siteStore(site)
    let root = try store.siteTree()
    #expect(root.children.map(\.name) == ["about", "blog"], "sorted, not in crawl order")

    let blog = try #require(root.children.first { $0.name == "blog" })
    #expect(blog.children.map(\.name) == ["archive", "one", "two"])
}

/// A folder that is not itself a page still has to exist, or its children have
/// nowhere to hang.
@MainActor
@Test func aFolderWithNoPageOfItsOwnStillAppears() throws {
    let store = try siteStore(site)
    let blog = try #require(try store.siteTree().children.first { $0.name == "blog" })
    let archive = try #require(blog.children.first { $0.name == "archive" })
    #expect(archive.urlID == nil, "nothing was crawled at /blog/archive itself")
    #expect(archive.children.map(\.name) == ["old"])
}

/// A folder's weight has to be visible without opening it, or the tree is just
/// a slower list.
@MainActor
@Test func countsRollUpThroughTheTree() throws {
    let store = try siteStore(site)
    let root = try store.siteTree()
    #expect(root.pageCount == site.count)

    let blog = try #require(root.children.first { $0.name == "blog" })
    #expect(blog.pageCount == 4, "/blog plus its three descendants")
    // /blog/two is noindex and /blog/archive/old is a 404, both non-indexable.
    #expect(blog.issueCount == 2)
    #expect(root.issueCount == 2)
}

@MainActor
@Test func aPageThatIsAlsoAFolderIsBoth() throws {
    let store = try siteStore(site)
    let blog = try #require(try store.siteTree().children.first { $0.name == "blog" })
    #expect(blog.urlID != nil, "/blog is a real page")
    #expect(blog.isFolder, "and it has children")
}

@MainActor
@Test func anEmptyCrawlHasAnEmptyTree() throws {
    let store = try siteStore([])
    let root = try store.siteTree()
    #expect(root.children.isEmpty)
    #expect(root.pageCount == 0)
}

// MARK: - Graph

@MainActor
@Test func theGraphKeepsOnlyEdgesBetweenDrawnNodes() throws {
    let store = try siteStore(site)
    try store.dbQueue.write { db in
        // / links to /blog and /about; /blog links to /blog/one.
        for (from, to) in [(1, 2), (1, 6), (2, 3)] {
            try db.execute(
                sql: """
                    INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position)
                    VALUES (?,?,'x',NULL,1,0)
                    """, arguments: [from, to])
        }
    }
    let graph = try store.linkGraph(limit: 100)
    #expect(graph.nodes.count == site.count)
    #expect(graph.edges.count == 3)
    #expect(!graph.isTruncated)

    // Now cap it hard: the edges to nodes that were dropped must go too, or the
    // diagram draws lines to nowhere.
    let small = try store.linkGraph(limit: 2)
    #expect(small.nodes.count == 2)
    #expect(small.isTruncated)
    let kept = Set(small.nodes.map(\.id))
    #expect(small.edges.allSatisfy { kept.contains($0.from) && kept.contains($0.to) })
}

/// The cap keeps the most-linked pages, because those are what the structure is
/// about — and the true total is reported so a capped diagram cannot read as a
/// complete one.
@MainActor
@Test func theGraphKeepsTheMostLinkedPagesAndSaysWhatItDropped() throws {
    let store = try siteStore(site)
    try store.dbQueue.write { db in
        for from in [1, 2, 3, 4] {
            try db.execute(
                sql: """
                    INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position)
                    VALUES (?,6,'x',NULL,1,0)
                    """, arguments: [from])
        }
    }
    let graph = try store.linkGraph(limit: 1)
    #expect(graph.nodes.first?.url.hasSuffix("/about") == true, "four inlinks, the most of any")
    #expect(graph.totalNodes == site.count)
    #expect(graph.isTruncated)
}

@MainActor
@Test func graphNodesCarryWhatADiagramNeeds() throws {
    let store = try siteStore(site)
    let graph = try store.linkGraph()
    let noindexed = try #require(graph.nodes.first { $0.url.hasSuffix("/blog/two") })
    #expect(!noindexed.indexable)
    #expect(noindexed.label == "two", "the last segment, not the whole path")
    #expect(graph.maxDepth >= 2)

    let home = try #require(graph.nodes.first { $0.url == "https://s.test/" })
    #expect(home.label == "/")
}

@MainActor
@Test func anEmptyCrawlHasAnEmptyGraph() throws {
    let store = try siteStore([])
    let graph = try store.linkGraph()
    #expect(graph.nodes.isEmpty)
    #expect(graph.edges.isEmpty)
    #expect(!graph.isTruncated)
}
