import Foundation
import KodaCore
import Testing
@testable import KodaUI

private let internalAll = ReportCatalogue.report(id: "internal-all")!

@Test func cacheCountsRowsUpFront() async throws {
    let store = try await fixtureStore()
    let cache = try RowWindowCache(store: store, query: ReportQuery(definition: internalAll))
    #expect(cache.count == FixtureSite.pageCount + 2, "the seed, 25 pages, and the image")
}

@Test func rowsMatchTheUnpagedQuery() async throws {
    let store = try await fixtureStore()
    let query = ReportQuery(definition: internalAll, sortColumn: 0)
    let expected = try store.rows(for: query)
    let cache = try RowWindowCache(store: store, query: query, windowSize: 4, maxWindows: 2)

    for index in expected.indices {
        #expect(try cache.row(at: index)?[0] == expected[index][0], "row \(index)")
    }
}

@Test func oneWindowServesEveryRowInIt() async throws {
    let store = try await fixtureStore()
    let cache = try RowWindowCache(store: store, query: ReportQuery(definition: internalAll, sortColumn: 0),
                                   windowSize: 10, maxWindows: 4)
    for index in 0..<10 { _ = try cache.row(at: index) }
    #expect(cache.loadCount == 1, "ten rows in one window must be one query, not ten")
}

@Test func lruEvictsSoTheFullSetIsNeverResident() async throws {
    let store = try await fixtureStore()
    let cache = try RowWindowCache(store: store, query: ReportQuery(definition: internalAll, sortColumn: 0),
                                   windowSize: 2, maxWindows: 3)
    for index in 0..<cache.count { _ = try cache.row(at: index) }
    #expect(cache.residentWindows <= 3)
    #expect(cache.loadCount >= 10, "scrolling the whole report really did page")
}

@Test func revisitingAnEvictedWindowReloadsIt() async throws {
    let store = try await fixtureStore()
    let cache = try RowWindowCache(store: store, query: ReportQuery(definition: internalAll, sortColumn: 0),
                                   windowSize: 2, maxWindows: 2)
    let first = try cache.row(at: 0)?[0]
    for index in 0..<cache.count { _ = try cache.row(at: index) }
    let loadsBefore = cache.loadCount

    #expect(try cache.row(at: 0)?[0] == first, "an evicted row still reads correctly")
    #expect(cache.loadCount == loadsBefore + 1)
}

@Test func recentlyUsedWindowsSurviveEviction() async throws {
    let store = try await fixtureStore()
    let cache = try RowWindowCache(store: store, query: ReportQuery(definition: internalAll, sortColumn: 0),
                                   windowSize: 2, maxWindows: 2)
    _ = try cache.row(at: 0)
    _ = try cache.row(at: 2)
    _ = try cache.row(at: 0)   // window 0 is now the most recent
    _ = try cache.row(at: 4)   // evicts window 1, not window 0
    let loads = cache.loadCount
    _ = try cache.row(at: 0)
    #expect(cache.loadCount == loads, "the most recently used window was kept")
}

@Test func outOfRangeIndicesReturnNil() async throws {
    let store = try await fixtureStore()
    let cache = try RowWindowCache(store: store, query: ReportQuery(definition: internalAll))
    #expect(try cache.row(at: -1) == nil)
    #expect(try cache.row(at: cache.count) == nil)
    #expect(try cache.row(at: 10_000) == nil)
}

@Test func changingTheQueryInvalidatesEverything() async throws {
    let store = try await fixtureStore()
    let cache = try RowWindowCache(store: store, query: ReportQuery(definition: internalAll, sortColumn: 0),
                                   windowSize: 4, maxWindows: 4)
    _ = try cache.row(at: 0)
    #expect(cache.residentWindows == 1)

    var narrowed = ReportQuery(definition: internalAll, sortColumn: 0)
    narrowed.filter = "p1"
    try cache.setQuery(narrowed)

    #expect(cache.residentWindows == 0, "row indices mean something different now")
    #expect(cache.count < FixtureSite.pageCount)
    #expect(cache.count > 0)
}

@Test func reloadPicksUpRowsWrittenSince() async throws {
    // What the refresh timer relies on while a crawl writes underneath.
    let store = try emptyStore()
    let cache = try RowWindowCache(store: store, query: ReportQuery(definition: internalAll))
    #expect(cache.count == 0)

    let crawled = try await fixtureStore()
    let other = try RowWindowCache(store: crawled, query: ReportQuery(definition: internalAll))
    try other.reload()
    #expect(other.count > 0)
}

@Test func anEmptyDatabaseIsNotAnError() throws {
    let store = try emptyStore()
    for definition in ReportCatalogue.all {
        let cache = try RowWindowCache(store: store, query: ReportQuery(definition: definition))
        #expect(cache.count == 0)
        #expect(try cache.row(at: 0) == nil)
    }
}
