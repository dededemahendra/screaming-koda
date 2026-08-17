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
