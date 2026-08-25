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
