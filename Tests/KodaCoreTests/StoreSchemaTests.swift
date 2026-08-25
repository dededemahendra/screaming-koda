import Foundation
import GRDB
import Testing
@testable import KodaCore

@Test func migrationCreatesAllTables() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let tables = try store.dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    }
    for expected in ["crawl_meta", "hreflang", "images", "links", "page_facts", "responses", "urls"] {
        #expect(tables.contains(expected), "missing table \(expected)")
    }
}

@Test func migrationIsIdempotent() throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.migrate()
    let count = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table'") ?? 0
    }
    #expect(count > 0)
}

@Test func configRoundTrips() throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://example.com/")
    config.workers = 9
    config.respectRobots = false
    try store.initializeCrawl(config: config, startedAt: Date(timeIntervalSince1970: 1000))
    let loaded = try store.loadConfig()
    #expect(loaded?.workers == 9)
    #expect(loaded?.respectRobots == false)
    #expect(loaded?.seedURL == "https://example.com/")
}

@Test func urlHashIsUnique() throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        let hash = Data(repeating: 1, count: 32)
        try db.execute(
            sql: "INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state) VALUES (?,?,?,?,?,?,?,?)",
            arguments: ["http://a/", hash, "a", "/", 0, 1, 0.0, 0]
        )
        var threw = false
        do {
            try db.execute(
                sql: "INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state) VALUES (?,?,?,?,?,?,?,?)",
                arguments: ["http://a/dup", hash, "a", "/dup", 0, 1, 0.0, 0]
            )
        } catch { threw = true }
        #expect(threw, "duplicate url_hash must be rejected")
    }
}

@Test func removingADatabaseTakesItsWriteAheadLogWithIt() async throws {
    let path = NSTemporaryDirectory() + "koda-remove-\(UUID().uuidString).koda"
    defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

    let store = try Store(path: path)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://rm.test/"), startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize("https://rm.test/", relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())
    #expect(FileManager.default.fileExists(atPath: path))

    try Store.removeDatabase(at: path)
    for suffix in ["", "-wal", "-shm"] {
        #expect(!FileManager.default.fileExists(atPath: path + suffix), "\(suffix) survived")
    }
    // And removing one that is not there is not an error, because the caller
    // has usually just checked and does not need to check twice.
    try Store.removeDatabase(at: path)
}

// MARK: - Somebody else's file

/// `--db` is one typo away from an ordinary file, and both the crawl path and
/// the read-only commands used to write to whatever it named: a crawl deleted it
/// outright, and `summary` migrated eight tables into it. A tool that can eat a
/// database it did not create is a tool nobody should run in their home
/// directory.

private func temporaryPath(_ suffix: String) -> String {
    NSTemporaryDirectory() + "koda-foreign-\(UUID().uuidString)\(suffix)"
}

private func makeForeignDatabase(at path: String) throws {
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute(sql: "INSERT INTO customers (name) VALUES ('Ada')")
    }
}

@Test func migratingSomebodyElsesDatabaseIsRefused() throws {
    let path = temporaryPath(".sqlite")
    defer { try? FileManager.default.removeItem(atPath: path) }
    try makeForeignDatabase(at: path)

    #expect(throws: StoreError.self) {
        let store = try Store(path: path)
        try store.migrate()
    }

    let tables = try DatabaseQueue(path: path).read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    }
    #expect(tables == ["customers"], "the file is left exactly as it was found")
}

@Test func removingSomebodyElsesDatabaseIsRefused() throws {
    let path = temporaryPath(".sqlite")
    defer { try? FileManager.default.removeItem(atPath: path) }
    try makeForeignDatabase(at: path)

    #expect(throws: StoreError.self) { try Store.removeDatabase(at: path) }
    #expect(FileManager.default.fileExists(atPath: path), "the file survives")
}

@Test func removingAFileThatIsNotADatabaseAtAllIsRefused() throws {
    let path = temporaryPath(".koda")
    defer { try? FileManager.default.removeItem(atPath: path) }
    try "notes, not a crawl".write(toFile: path, atomically: true, encoding: .utf8)

    #expect(throws: StoreError.self) { try Store.removeDatabase(at: path) }
    #expect(FileManager.default.fileExists(atPath: path))
}

@Test func aFileThatIsNotADatabaseSaysSoRatherThanQuotingSQLite() throws {
    let path = temporaryPath(".koda")
    defer { try? FileManager.default.removeItem(atPath: path) }
    try "notes, not a crawl".write(toFile: path, atomically: true, encoding: .utf8)

    // "SQLite error 26: file is not a database - while executing `PRAGMA
    // journal_mode=WAL`" is a true sentence about the wrong subject.
    do {
        let store = try Store(path: path)
        try store.migrate()
        Issue.record("expected opening a text file to fail")
    } catch let error as StoreError {
        #expect(String(describing: error).contains(path))
        #expect(String(describing: error).lowercased().contains("crawl"))
    }
}

@Test func aCrawlOfOurOwnIsStillMigratedAndRemoved() throws {
    let path = temporaryPath(".koda")
    defer { try? Store.removeDatabase(at: path) }

    let store = try Store(path: path)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://ours.test/"), startedAt: Date())

    // Reopening runs the migrator again, which is how an older crawl file gets
    // upgraded. The guard must not stand in the way of that.
    let reopened = try Store(path: path)
    try reopened.migrate()
    #expect(try reopened.crawlMeta()?.seedURL == "https://ours.test/")

    try Store.removeDatabase(at: path)
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func aPathWithNothingAtItIsFreeToBecomeACrawl() throws {
    let path = temporaryPath(".koda")
    defer { try? Store.removeDatabase(at: path) }
    let store = try Store(path: path)
    try store.migrate()
    #expect(try store.crawlMeta() == nil)
    // Removing what is not there stays a no-op: the caller has usually just
    // checked and should not have to check twice.
    try Store.removeDatabase(at: temporaryPath(".koda"))
}

// MARK: - Making the reports affordable

/// A count over `links` is the most expensive thing the sidebar does, and the
/// sidebar does it every half second while a crawl runs. Two things keep it
/// affordable: an index the count can be answered from without touching the
/// table, and statistics, without which SQLite guesses that a join over the
/// largest table is as cheap as one over the smallest.

@Test func theInlinkIndexCoversTheInternalFlag() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let columns = try store.dbQueue.read { db in
        try Row.fetchAll(db, sql: "PRAGMA index_info(idx_links_to)").map { $0["name"] as String }
    }
    #expect(columns == ["to_url_id", "is_internal"],
            "counting internal inlinks must not have to visit the table")
}

@Test func anOlderCrawlIsUpgradedWithoutLosingAnything() throws {
    let path = NSTemporaryDirectory() + "koda-v1-\(UUID().uuidString).koda"
    defer { try? Store.removeDatabase(at: path) }

    // A database as an earlier version left it: the narrow index, no v4.
    let old = try Store(path: path)
    try old.migrate()
    try old.initializeCrawl(config: CrawlConfig(seedURL: "https://old.test/"), startedAt: Date())
    try old.dbQueue.write { db in
        try db.execute(sql: "DROP INDEX idx_links_to; CREATE INDEX idx_links_to ON links(to_url_id)")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4-inlink-index'")
    }

    let reopened = try Store(path: path)
    try reopened.migrate()
    let columns = try reopened.dbQueue.read { db in
        try Row.fetchAll(db, sql: "PRAGMA index_info(idx_links_to)").map { $0["name"] as String }
    }
    #expect(columns == ["to_url_id", "is_internal"])
    #expect(try reopened.crawlMeta()?.seedURL == "https://old.test/", "the crawl itself survives")
}

@Test func aFinishedCrawlLeavesStatisticsBehind() async throws {
    var config = CrawlConfig(seedURL: "https://stats.test/")
    config.checkExternalLinks = false
    config.checkImages = false
    let store = try await CrawlSession.start(dbPath: nil, config: config, client: StatsSite(),
                                             parser: SwiftSoupParser(), onProgress: nil)

    let analysed = try await store.dbQueue.read { db in
        try Bool.fetchOne(db, sql: """
            SELECT count(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_stat1'
            """) ?? false
    }
    #expect(analysed, "without statistics every report query plans as if links were small")
}

private struct StatsSite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        let body = url.hasSuffix("/") ? "<a href='/a'>A</a><a href='/b'>B</a>" : "<p>Leaf</p>"
        return .response(HTTPResponse(
            status: 200, headers: ["Content-Type": "text/html"],
            body: Data("<html><head><title>T</title></head><body>\(body)</body></html>".utf8), elapsedMs: 1))
    }
}
