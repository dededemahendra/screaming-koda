import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Builds a crawl on disk with the given pages, so comparison is exercised
/// across two real files exactly as a user would have them.
@MainActor
private func crawlFile(_ pages: [(path: String, status: Int, title: String?,
                                  desc: String?, h1: String?, robots: String?)]) throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmp-\(UUID().uuidString).koda").path
    let store = try Store(path: path)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://c.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        for page in pages {
            let url = "https://c.test\(page.path)"
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,1,1,0,2)
                    """,
                arguments: [url, Data(page.path.utf8), "c.test", page.path])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO responses (url_id, status, content_type, fetched_at)
                    VALUES (?,?, 'text/html; charset=utf-8', 0)
                    """,
                arguments: [id, page.status])
            try db.execute(
                sql: """
                    INSERT INTO page_facts (url_id, title, meta_description, h1, meta_robots, word_count)
                    VALUES (?,?,?,?,?,100)
                    """,
                arguments: [id, page.title, page.desc, page.h1, page.robots])
        }
    }
    return path
}

private typealias Page = (path: String, status: Int, title: String?,
                          desc: String?, h1: String?, robots: String?)

private let before: [Page] = [
    ("/", 200, "Home", "Home description", "Welcome", nil),
    ("/about", 200, "About us", "About description", "About", nil),
    ("/gone-later", 200, "Doomed", "Doomed description", "Doomed", nil),
    ("/untitled", 200, nil, "No title yet", "Untitled", nil),
]

private let after: [Page] = [
    ("/", 200, "Home", "Home description", "Welcome", nil),                    // unchanged
    ("/about", 200, "About the company", "About description", "About", nil),   // title changed
    ("/untitled", 200, "Now it has one", "No title yet", "Untitled", nil),     // nil -> value
    ("/brand-new", 200, "New page", "New description", "New", nil),            // added
    ("/noindexed", 200, "Blocked", "Blocked", "Blocked", "noindex"),           // added, non-indexable
]

@MainActor
@Test func comparisonFindsAddedAndRemovedPages() throws {
    let old = try crawlFile(before)
    let new = try crawlFile(after)
    defer { try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.removeItem(atPath: new) }

    let store = try Store(path: new)
    try store.migrate()
    let diff = try store.compare(against: old)

    #expect(Set(diff.added) == ["https://c.test/brand-new", "https://c.test/noindexed"])
    #expect(Set(diff.removed) == ["https://c.test/gone-later"])
    #expect(diff.addedTotal == 2)
    #expect(diff.removedTotal == 1)
}

@MainActor
@Test func comparisonFindsChangedFields() throws {
    let old = try crawlFile(before)
    let new = try crawlFile(after)
    defer { try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.removeItem(atPath: new) }

    let store = try Store(path: new)
    try store.migrate()
    let diff = try store.compare(against: old)

    let byURL = Dictionary(grouping: diff.changes, by: \.url)
    let about = byURL["https://c.test/about"] ?? []
    #expect(about.count == 1)
    #expect(about.first?.field == "Title")
    #expect(about.first?.before == "About us")
    #expect(about.first?.after == "About the company")

    #expect(byURL["https://c.test/"] == nil, "an unchanged page produces no rows")
}

/// In SQL, `NULL != 'x'` is NULL rather than true, so a title appearing where
/// there was none — one of the most useful things a comparison can report —
/// would be silently missed by `!=`.
@MainActor
@Test func aValueAppearingWhereThereWasNoneIsAChange() throws {
    let old = try crawlFile(before)
    let new = try crawlFile(after)
    defer { try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.removeItem(atPath: new) }

    let store = try Store(path: new)
    try store.migrate()
    let diff = try store.compare(against: old)

    let change = try #require(diff.changes.first { $0.url == "https://c.test/untitled" })
    #expect(change.field == "Title")
    #expect(change.before == nil)
    #expect(change.after == "Now it has one")
}

/// A page that changed in several ways produces one row per field, because a
/// single row saying "changed" is not something anyone can act on.
@MainActor
@Test func aPageChangedInSeveralWaysProducesARowPerField() throws {
    let old = try crawlFile([("/x", 200, "Old title", "Old desc", "Old h1", nil)])
    let new = try crawlFile([("/x", 404, "New title", "New desc", "New h1", nil)])
    defer { try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.removeItem(atPath: new) }

    let store = try Store(path: new)
    try store.migrate()
    let diff = try store.compare(against: old)

    let fields = Set(diff.changes.map(\.field))
    #expect(fields.isSuperset(of: ["Status", "Title", "Meta Description", "H1", "Indexability"]))
    let indexability = try #require(diff.changes.first { $0.field == "Indexability" })
    #expect(indexability.before == Indexability.indexable)
    #expect(indexability.after == Indexability.clientError)
}

@MainActor
@Test func twoIdenticalCrawlsDifferInNoWay() throws {
    let old = try crawlFile(before)
    let new = try crawlFile(before)
    defer { try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.removeItem(atPath: new) }

    let store = try Store(path: new)
    try store.migrate()
    let diff = try store.compare(against: old)
    #expect(diff.isEmpty)
    #expect(diff.changes.isEmpty)
}

@MainActor
@Test func aMissingOrUnrelatedFileIsRefusedClearly() throws {
    let store = try Store(path: nil)
    try store.migrate()
    #expect(throws: CompareError.self) { _ = try store.compare(against: "/no/such/file.koda") }

    let notACrawl = FileManager.default.temporaryDirectory
        .appendingPathComponent("empty-\(UUID().uuidString).db").path
    let other = try Store(path: notACrawl)
    try other.dbQueue.write { db in try db.execute(sql: "CREATE TABLE unrelated (x INTEGER)") }
    defer { try? FileManager.default.removeItem(atPath: notACrawl) }
    #expect(throws: CompareError.self) { _ = try store.compare(against: notACrawl) }
}

/// The counts are the true totals even when the lists are capped, so a
/// comparison never quietly claims fewer changes than there were.
@MainActor
@Test func cappedListsStillReportTheTrueTotals() throws {
    let many: [Page] = (0..<12).map { ("/p\($0)", 200, "Title \($0)", "d", "h", nil) }
    let changed: [Page] = (0..<12).map { ("/p\($0)", 200, "Changed \($0)", "d", "h", nil) }
    let old = try crawlFile(many)
    let new = try crawlFile(changed)
    defer { try? FileManager.default.removeItem(atPath: old)
            try? FileManager.default.removeItem(atPath: new) }

    let store = try Store(path: new)
    try store.migrate()
    let diff = try store.compare(against: old, limit: 5)
    #expect(diff.changes.count == 5)
    #expect(diff.changesTotal == 12)
}

/// A URL that was queued but never fetched is not a page that existed, so it
/// must not read as "removed" when the next crawl does not queue it.
@MainActor
@Test func anUncrawledURLIsNotCountedAsPresent() throws {
    let old = try crawlFile([("/", 200, "Home", "d", "h", nil)])
    defer { try? FileManager.default.removeItem(atPath: old) }
    let oldStore = try Store(path: old)
    try oldStore.migrate()
    try oldStore.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://c.test/queued', x'AA', 'c.test', '/queued', 1, 1, 0, 0)
            """)
    }
    let new = try crawlFile([("/", 200, "Home", "d", "h", nil)])
    defer { try? FileManager.default.removeItem(atPath: new) }

    let store = try Store(path: new)
    try store.migrate()
    #expect(try store.compare(against: old).removed.isEmpty)
}

/// The whole reason comparison is restricted to v1 fields: a `.koda` file
/// written by an older build genuinely lacks the later columns, ATTACH does not
/// migrate it, and migrating someone's previous crawl in order to read it would
/// be a rude thing for a comparison to do.
///
/// Built by running only the first migration, so this is a real v1 database
/// rather than a modern one with columns pretended away.
@MainActor
@Test func aCrawlFromTheOriginalSchemaCanStillBeCompared() throws {
    let oldPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("v1-\(UUID().uuidString).koda").path
    defer { try? FileManager.default.removeItem(atPath: oldPath) }

    let old = try Store(path: oldPath)
    try Store.migrator.migrate(old.dbQueue, upTo: "v1")
    try old.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO crawl_meta (id, seed_url, started_at, config_json, schema_version)
            VALUES (1, 'https://c.test/', 0, '{}', 1);
            -- The hash must match how crawlFile builds it, or the two crawls
            -- share no URLs and the comparison has nothing to join on. x'2F' is
            -- the single byte "/".
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://c.test/', x'2F', 'c.test', '/', 0, 1, 0, 2);
            INSERT INTO responses (url_id, status, content_type, fetched_at)
            VALUES (1, 200, 'text/html', 0);
            INSERT INTO page_facts (url_id, title) VALUES (1, 'The old title');
            """)
    }

    // It really is a v1 database: none of the later columns exist.
    let columns = try old.dbQueue.read { db in
        Set(try db.columns(in: "responses").map(\.name))
    }
    #expect(!columns.contains("rendered"), "v9")
    #expect(!columns.contains("headers_json"), "v5")

    let new = try crawlFile([("/", 200, "The new title", nil, nil, nil)])
    defer { try? FileManager.default.removeItem(atPath: new) }
    let store = try Store(path: new)
    try store.migrate()

    let diff = try store.compare(against: oldPath)
    let change = try #require(diff.changes.first { $0.field == "Title" })
    #expect(change.before == "The old title")
    #expect(change.after == "The new title")
    #expect(diff.added.isEmpty)
    #expect(diff.removed.isEmpty)
}
