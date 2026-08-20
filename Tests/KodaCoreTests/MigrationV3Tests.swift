import Foundation
import GRDB
import Testing
@testable import KodaCore

@Test func checkOnlyColumnExistsAndDefaultsToZero() throws {
    let store = try Store(path: nil)
    try store.migrate()

    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                VALUES (?,?,?,?,0,1,0,0)
                """,
            arguments: ["https://m3.test/", Data("h".utf8), "m3.test", "/"]
        )
        let value = try Int.fetchOne(db, sql: "SELECT check_only FROM urls WHERE url = 'https://m3.test/'")
        #expect(value == 0, "an existing-style insert must still work and default to 0")
    }
}

@Test func sortIndexesExist() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let indexes = try store.dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
    }
    #expect(indexes.contains("idx_urls_depth"))
    #expect(indexes.contains("idx_urls_url"))
}

@Test func migrationIsIdempotentAcrossAllVersions() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let before = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") ?? 0
    }
    try store.migrate()
    let after = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") ?? 0
    }
    #expect(before == after, "re-migrating must not add or drop schema objects")
}
