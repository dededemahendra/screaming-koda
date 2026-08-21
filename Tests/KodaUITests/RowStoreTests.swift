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
    let store = try seededStore(pages: 37)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()
    #expect(rows.count == 37)
}

@MainActor
@Test func countAgreesWithSummaryTotalURLs() throws {
    let store = try seededStore(pages: 25)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()
    let totalURLs = try store.summary().totalURLs
    #expect(rows.count == totalURLs,
            "RowStore must not invent a third meaning of 'total URLs'")
}

@MainActor
@Test func returnsTheCorrectRowAtEachIndex() throws {
    let store = try seededStore(pages: 10)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
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
    let store = try seededStore(pages: 23)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index, pageSize: 5, maxPages: 10)
    rows.refresh()
    for i in 0..<23 {
        #expect(rows.row(at: i)?.title == "T\(i)", "wrong row at index \(i)")
    }
}

@MainActor
@Test func survivesCacheEviction() throws {
    // 40 rows over 4-row pages with only 2 pages resident forces eviction.
    let store = try seededStore(pages: 40)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index, pageSize: 4, maxPages: 2)
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
    let store = try seededStore(pages: 3)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()
    #expect(rows.row(at: 3) == nil)
    #expect(rows.row(at: 999) == nil)
    #expect(rows.row(at: -1) == nil)
}

@MainActor
@Test func refreshPicksUpRowsAddedAfterwards() throws {
    let store = try seededStore(pages: 5)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
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

    // Membership now lives in RowIndex, not RowStore: RowStore.refresh() only
    // drops cached pages, it cannot see a row the index has never heard of.
    // A live crawl exercises both steps -- refresh the index, then the store
    // -- so the test does the same rather than asserting a guarantee
    // RowStore no longer owns alone.
    index.appendNewIds()
    rows.refresh()
    #expect(rows.count == 6, "a live crawl adds rows; the index picks them up and the store shows them")
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
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()
    #expect(rows.row(at: 2)?.status == nil, "a queued-but-unfetched URL has no status yet")
}

@MainActor
@Test func lruEvictsTheLeastRecentlyUsedPageNotTheOldestLoaded() throws {
    // pageSize 4, maxPages 2, 12 rows -> pages 0, 1, 2. Load page 0 and page 1, then
    // keep re-reading page 0 so it becomes "hot", then load a third page. A true LRU
    // cache evicts page 1 (untouched since it loaded); a cache that only updates
    // eviction order on misses (FIFO wearing an LRU label) would instead evict page 0
    // -- the page just read ten times -- because a hit never moves it in the queue.
    // `loadCount` (an internal test seam, not part of the public API) lets the test
    // tell a cache hit from a reload without reaching into private state.
    let store = try seededStore(pages: 12)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index, pageSize: 4, maxPages: 2)
    rows.refresh()

    _ = rows.row(at: 0) // loads page 0
    _ = rows.row(at: 4) // loads page 1
    #expect(rows.loadCount == 2)

    for _ in 0..<10 {
        _ = rows.row(at: 0) // repeated hits on page 0; must not evict it
    }
    #expect(rows.loadCount == 2, "cache hits must not trigger a reload")

    _ = rows.row(at: 8) // loads page 2, forcing an eviction under maxPages == 2
    #expect(rows.loadCount == 3)

    let countBeforeRereadingPage0 = rows.loadCount
    #expect(rows.row(at: 0)?.title == "T0", "page 0 was hot; it must still be cached")
    #expect(rows.loadCount == countBeforeRereadingPage0,
            "re-reading the recently-hit page must be a cache hit, not a reload")

    let countBeforeRereadingPage1 = rows.loadCount
    #expect(rows.row(at: 4)?.title == "T4", "page 1 was cold; it must have been evicted")
    #expect(rows.loadCount == countBeforeRereadingPage1 + 1,
            "re-reading the untouched page must require a reload")
}

@MainActor
@Test func rowsComeBackInTheIndexsOrderNotTheDatabasesOrder() throws {
    let store = try seededStore(pages: 10)
    let index = RowIndex(store: store)
    index.rebuild(sort: .address, ascending: false)   // reverse alphabetical
    let rows = RowStore(store: store, index: index)
    rows.refresh()

    let addresses = (0..<rows.count).compactMap { rows.row(at: $0)?.address }
    #expect(addresses == addresses.sorted(by: >),
            "SQL `IN` does not preserve order; RowStore must reorder to match the index")
}

@MainActor
@Test func countComesFromTheIndex() throws {
    let store = try seededStore(pages: 7)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()
    #expect(rows.count == 7)
    #expect(rows.count == index.count)
}

@MainActor
@Test func aRowDeepInALargeCrawlIsFetchedDirectly() throws {
    // The point of the index: row 4,999 costs the same as row 0.
    let store = try seededStore(pages: 5_000)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()

    #expect(rows.row(at: 4_999)?.title == "T4999")
    #expect(rows.row(at: 0)?.title == "T0")
}

@MainActor
@Test func changingTheSortChangesWhatRowZeroIs() throws {
    let store = try seededStore(pages: 5)
    let index = RowIndex(store: store)
    let rows = RowStore(store: store, index: index)

    index.rebuild(sort: .address, ascending: true)
    rows.refresh()
    let ascendingFirst = rows.row(at: 0)?.address

    index.rebuild(sort: .address, ascending: false)
    rows.refresh()
    let descendingFirst = rows.row(at: 0)?.address

    #expect(ascendingFirst != descendingFirst)
}
