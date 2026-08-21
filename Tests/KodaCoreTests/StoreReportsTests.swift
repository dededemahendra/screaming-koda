import Foundation
import GRDB
import Testing
@testable import KodaCore

private let addressColumn = ReportColumn(id: "address", header: "Address",
                                         expression: "u.url", width: 380)
private let statusColumn = ReportColumn(id: "status", header: "Status",
                                        expression: "r.status", width: 70, alignment: .trailing)
private let titleColumn = ReportColumn(id: "title", header: "Title",
                                       expression: "f.title", width: 300)

private let internalPages = Report(
    id: "t", name: "T", predicate: "u.is_internal = 1 AND u.check_only = 0",
    columns: [addressColumn, statusColumn, titleColumn],
    filters: [
        ReportFilter(id: "all", name: "All", predicate: "1"),
        ReportFilter(id: "gone", name: "404", predicate: "r.status = 404", isIssue: true),
    ]
)

private func ids(_ store: Store, _ filter: String = "all",
                 sortBy: ReportColumn? = nil, ascending: Bool = true) throws -> [Int64] {
    let f = internalPages.filters.first { $0.id == filter }!
    return try store.ids(for: internalPages, filter: f, sortBy: sortBy, ascending: ascending)
}

@Test func idsRespectTheReportAndFilterPredicates() throws {
    let store = try ReportFixture.make()
    #expect(try ReportFixture.paths(store, ids(store, "gone")) == ["/gone"])

    // The report predicate applies on its own too: external URLs and images are
    // check_only, so neither reaches this report even under "All".
    let all = try ReportFixture.paths(store, ids(store))
    #expect(!all.contains("https://ext.test/broken"))
    #expect(!all.contains("/img/big.png"))
    #expect(all.contains("/gone"))
}

@Test func idsSortAscendingAndDescending() throws {
    let store = try ReportFixture.make()
    let up = try ids(store, sortBy: addressColumn, ascending: true)
    let down = try ids(store, sortBy: addressColumn, ascending: false)
    #expect(up.count == down.count)
    #expect(up.first == down.last)
    #expect(up != down)
}

/// M3a's rule, preserved: a table sorted by status opens on real statuses
/// whichever way the arrow points. `/queued` has no response row at all.
@Test func idsPutNullsLastInBothDirections() throws {
    let store = try ReportFixture.make()
    for ascending in [true, false] {
        let sorted = try ids(store, sortBy: statusColumn, ascending: ascending)
        let last = try ReportFixture.paths(store, [sorted.last!])
        #expect(last == ["/queued"], "nulls should be last when ascending == \(ascending)")
    }
}

@Test func idsWithNoSortAreInDiscoveryOrder() throws {
    let store = try ReportFixture.make()
    let discovered = try ids(store)
    #expect(discovered == discovered.sorted(), "discovery order is ascending id")
}

/// SQLite returns `IN (...)` rows in whatever order it likes, so the fetch has
/// to restore the order the ids were asked for. Without this the table shows
/// correct rows in the wrong places, which reads as data corruption.
@Test func rowsComeBackInTheOrderOfTheIdsGiven() throws {
    let store = try ReportFixture.make()
    let ordered = try ids(store, sortBy: addressColumn, ascending: true)
    let scrambled = Array(ordered.reversed().prefix(10))
    let rows = try store.rows(ids: scrambled, columns: internalPages.columns)
    #expect(rows.map(\.id) == scrambled)
}

@Test func rowsRenderCellsInColumnOrder() throws {
    let store = try ReportFixture.make()
    let gone = try ids(store, "gone")
    let row = try store.rows(ids: gone, columns: internalPages.columns)[0]
    #expect(row.cells.count == 3)
    #expect(row.cells[0] == "https://fx.test/gone")
    #expect(row.cells[1] == "404")
}

/// nil and "" must stay distinguishable: the table renders a genuine NULL
/// differently from an empty string, and collapsing them would hide the
/// difference between "no title" and "an empty title".
@Test func rowsRenderNullAsNilNotEmptyString() throws {
    let store = try ReportFixture.make()
    let noTitle = try store.ids(
        for: internalPages,
        filter: ReportFilter(id: "x", name: "x", predicate: "u.path = '/no-title'"),
        sortBy: nil, ascending: true)
    let row = try store.rows(ids: noTitle, columns: internalPages.columns)[0]
    #expect(row.cells[2] == nil)
}

@Test func rowsForAnEmptyIdListIsEmpty() throws {
    let store = try ReportFixture.make()
    #expect(try store.rows(ids: [], columns: internalPages.columns).isEmpty)
}

/// A sortable column the report does not declare must never reach the SQL. The
/// caller resolves ids through `Report.column(id:)`, so this asserts the
/// resolution rather than trusting the query builder to sanitise anything.
@Test func anUndeclaredSortColumnCannotBeResolved() throws {
    #expect(internalPages.column(id: "wordCount") == nil)
}
