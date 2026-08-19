import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaUI

/// Builds a store with `n` fetched pages, titled "T0", "T1", … at increasing depth.
@MainActor
private func seededStore(pages: Int) throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    let config = CrawlConfig(seedURL: "https://rows.test/p/0")
    try store.initializeCrawl(config: config, startedAt: Date())

    try store.dbQueue.write { db in
        for i in 0..<pages {
            let url = "https://rows.test/p/\(i)"
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, redirect_hops)
                    VALUES (?,?,?,?,?,1,?,2,0)
                    """,
                arguments: [url, Data("h\(i)".utf8), "rows.test", "/p/\(i)", i % 4, 0.0]
            )
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (?,?,0)",
                arguments: [id, 200]
            )
            try db.execute(
                sql: "INSERT INTO page_facts (url_id, title) VALUES (?,?)",
                arguments: [id, "T\(i)"]
            )
        }
    }
    return store
}

@MainActor
@Test func countMatchesTheNumberOfRows() throws {
    let rows = RowStore(store: try seededStore(pages: 37))
    rows.refresh()
    #expect(rows.count == 37)
}

@MainActor
@Test func countAgreesWithSummaryTotalURLs() throws {
    let store = try seededStore(pages: 25)
    let rows = RowStore(store: store)
    rows.refresh()
    let totalURLs = try store.summary().totalURLs
    #expect(rows.count == totalURLs,
            "RowStore must not invent a third meaning of 'total URLs'")
}

@MainActor
@Test func returnsTheCorrectRowAtEachIndex() throws {
    let rows = RowStore(store: try seededStore(pages: 10))
    rows.refresh()
    #expect(rows.row(at: 0)?.title == "T0")
    #expect(rows.row(at: 4)?.title == "T4")
    #expect(rows.row(at: 9)?.title == "T9")
    #expect(rows.row(at: 0)?.address == "https://rows.test/p/0")
    #expect(rows.row(at: 3)?.status == 200)
    #expect(rows.row(at: 6)?.depth == 6 % 4)
}

@MainActor
@Test func crossesPageBoundariesCorrectly() throws {
    // pageSize 5 means indices 4/5 and 9/10 straddle page edges.
    let rows = RowStore(store: try seededStore(pages: 23), pageSize: 5, maxPages: 10)
    rows.refresh()
    for i in 0..<23 {
        #expect(rows.row(at: i)?.title == "T\(i)", "wrong row at index \(i)")
    }
}

@MainActor
@Test func survivesCacheEviction() throws {
    // 40 rows over 4-row pages with only 2 pages resident forces eviction.
    let rows = RowStore(store: try seededStore(pages: 40), pageSize: 4, maxPages: 2)
    rows.refresh()
    for i in stride(from: 0, to: 40, by: 1) {
        #expect(rows.row(at: i)?.title == "T\(i)")
    }
    // Re-read an early page that must have been evicted.
    #expect(rows.row(at: 0)?.title == "T0")
    #expect(rows.row(at: 39)?.title == "T39")
}

@MainActor
@Test func outOfRangeIndexesReturnNil() throws {
    let rows = RowStore(store: try seededStore(pages: 3))
    rows.refresh()
    #expect(rows.row(at: 3) == nil)
    #expect(rows.row(at: 999) == nil)
    #expect(rows.row(at: -1) == nil)
}

@MainActor
@Test func refreshPicksUpRowsAddedAfterwards() throws {
    let store = try seededStore(pages: 5)
    let rows = RowStore(store: store)
    rows.refresh()
    #expect(rows.count == 5)

    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, redirect_hops)
                VALUES (?,?,?,?,0,1,0,2,0)
                """,
            arguments: ["https://rows.test/p/99", Data("h99".utf8), "rows.test", "/p/99"]
        )
        let id = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (?,200,0)", arguments: [id])
        try db.execute(sql: "INSERT INTO page_facts (url_id, title) VALUES (?,?)", arguments: [id, "T99"])
    }

    rows.refresh()
    #expect(rows.count == 6, "a live crawl adds rows; refresh must see them")
    #expect(rows.row(at: 5)?.title == "T99")
}

@MainActor
@Test func rowsWithoutAResponseShowNoStatus() throws {
    let store = try seededStore(pages: 2)
    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, redirect_hops)
                VALUES (?,?,?,?,1,1,0,0,0)
                """,
            arguments: ["https://rows.test/queued", Data("hq".utf8), "rows.test", "/queued"]
        )
        let id = db.lastInsertedRowID
        try db.execute(sql: "INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position) VALUES (1,?,'q',NULL,1,0)", arguments: [id])
    }
    let rows = RowStore(store: store)
    rows.refresh()
    #expect(rows.row(at: 2)?.status == nil, "a queued-but-unfetched URL has no status yet")
}
