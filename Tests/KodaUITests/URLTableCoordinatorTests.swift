import AppKit
import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaUI

private let internalReport = Reports.internalURLs

/// Cell lookup is positional against the report's column list, so tests name the
/// column and resolve its index the same way the coordinator does.
private func col(_ id: String) -> Int {
    internalReport.columns.firstIndex { $0.id == id }!
}

@MainActor
private func rebuilt(_ store: Store) -> RowStore {
    let index = RowIndex(store: store, report: internalReport)
    index.rebuild(report: internalReport, filter: internalReport.defaultFilter,
                  sortColumnID: nil, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()
    return rows
}

@MainActor
private func seededRows(pages: Int) throws -> RowStore {
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://t.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        for i in 0..<pages {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, redirect_hops)
                    VALUES (?,?,?,?,?,1,0,2,0)
                    """,
                arguments: ["https://t.test/\(i)", Data("h\(i)".utf8), "t.test", "/\(i)", i]
            )
            let id = db.lastInsertedRowID
            try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (?,?,0)",
                           arguments: [id, 200 + i])
            try db.execute(sql: "INSERT INTO page_facts (url_id, title) VALUES (?,?)",
                           arguments: [id, "Title \(i)"])
        }
    }
    return rebuilt(store)
}

@MainActor
private func queuedOnlyRows() throws -> RowStore {
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://t.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, redirect_hops)
                VALUES (?,?,?,?,0,1,0,0,0)
                """,
            arguments: ["https://t.test/queued", Data("hq".utf8), "t.test", "/queued"]
        )
    }
    return rebuilt(store)
}

@MainActor
@Test func reportsTheRowCount() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 12), report: internalReport)
    #expect(coordinator.numberOfRows(in: NSTableView()) == 12)
}

@MainActor
@Test func reportsZeroRowsWithoutAStore() {
    let coordinator = URLTableCoordinator(rows: nil, report: internalReport)
    #expect(coordinator.numberOfRows(in: NSTableView()) == 0)
}

@MainActor
@Test func cellsComeFromTheReportsColumnOrder() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 3), report: internalReport)
    #expect(coordinator.value(columnIndex: col("address"), row: 1) == "https://t.test/1")
    #expect(coordinator.value(columnIndex: col("status"), row: 1) == "201")
    #expect(coordinator.value(columnIndex: col("title"), row: 1) == "Title 1")
    #expect(coordinator.value(columnIndex: col("depth"), row: 1) == "1")
}

/// A derived column has to survive the round trip too — `indexability` is a
/// CASE expression, not a stored value.
@MainActor
@Test func aDerivedColumnRendersItsComputedValue() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 1), report: internalReport)
    #expect(coordinator.value(columnIndex: col("indexability"), row: 0) == Indexability.indexable)
}

@MainActor
@Test func rendersMissingValuesAsEmptyRatherThanCrashing() throws {
    let coordinator = URLTableCoordinator(rows: try queuedOnlyRows(), report: internalReport)
    #expect(coordinator.value(columnIndex: col("status"), row: 0) == "",
            "an unfetched URL has no status")
    #expect(coordinator.value(columnIndex: col("title"), row: 0) == "")
    #expect(coordinator.value(columnIndex: col("address"), row: 0) == "https://t.test/queued")
}

@MainActor
@Test func outOfRangeRowsAndColumnsRenderEmptyRatherThanCrashing() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 2), report: internalReport)
    #expect(coordinator.value(columnIndex: col("address"), row: 99) == "")
    #expect(coordinator.value(columnIndex: col("status"), row: -1) == "")
    #expect(coordinator.value(columnIndex: 999, row: 0) == "")
    #expect(coordinator.value(columnIndex: -1, row: 0) == "")
}

@MainActor
@Test func theInternalReportLeadsWithTheColumnsAUserExpects() {
    #expect(internalReport.columns.prefix(4).map(\.id)
            == ["address", "status", "contentType", "indexability"])
    #expect(internalReport.columns.map(\.header).allSatisfy { !$0.isEmpty })
}

// MARK: - tableView(_:viewFor:row:)
//
// `numberOfRows`/`value(columnIndex:row:)` above cover the data layer; these
// cover the delegate method that actually builds the `NSTableCellView` AppKit
// draws, including the cell-reuse branch and the unknown-column/out-of-range
// guards. Everything here runs against a bare `NSTableView()` with no
// `NSApplication` running, the same way `reportsTheRowCount` already
// constructs one — no SwiftUI hosting is required for any of this.

@MainActor
@Test func viewForRendersCellWithExpectedText() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 3), report: internalReport)
    let table = NSTableView()
    let column = NSTableColumn(identifier: .init("address"))
    table.addTableColumn(column)

    let view = try #require(coordinator.tableView(table, viewFor: column, row: 1) as? NSTableCellView)
    #expect(view.textField?.stringValue == "https://t.test/1")
}

/// AppKit's real reuse pool is populated by internal view teardown during
/// actual on-screen scrolling/display, which never fires without a running
/// `NSApplication` and a live window — confirmed empirically: even with a real
/// `NSWindow`/`NSScrollView` hierarchy, forced layout, and `scrollRowToVisible`
/// past the row that was first drawn, `makeView(withIdentifier:owner:)`
/// returned `nil` rather than handing back the earlier cell. So this cannot
/// assert object identity across a reuse cycle, and under `swift test` every
/// call here takes the freshly-created-cell path in `viewFor` — the reuse
/// branch is never actually executed.
///
/// This test only covers wiring: that `viewFor`, called repeatedly through
/// the same table view and column, always hands back the requested row's own
/// value rather than one left over from an earlier call. What actually closes
/// the reuse gap is that `viewFor` has no second assignment site to slide
/// into: both branches call `configure(_:columnIndex:row:)`, which is tested
/// directly further down this file.
@MainActor
@Test func viewForNeverCarriesAStaleNeighboursText() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 5), report: internalReport)
    let table = NSTableView()
    let column = NSTableColumn(identifier: .init("address"))
    table.addTableColumn(column)

    for row in [0, 3, 1, 4, 2] {
        let view = try #require(coordinator.tableView(table, viewFor: column, row: row) as? NSTableCellView)
        #expect(view.textField?.stringValue == "https://t.test/\(row)")
    }
}

@MainActor
@Test func viewForReturnsNilForAColumnTheReportDoesNotDeclare() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 2), report: internalReport)
    let table = NSTableView()
    // "canonical" is a real column — of the Canonicals report, not this one.
    for identifier in ["bogus", "canonical"] {
        let column = NSTableColumn(identifier: .init(identifier))
        table.addTableColumn(column)
        #expect(coordinator.tableView(table, viewFor: column, row: 0) == nil)
    }
}

@MainActor
@Test func viewForRendersEmptyForARowBeyondTheRowCount() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 2), report: internalReport)
    let table = NSTableView()
    let column = NSTableColumn(identifier: .init("address"))
    table.addTableColumn(column)

    let view = try #require(coordinator.tableView(table, viewFor: column, row: 99) as? NSTableCellView)
    #expect(view.textField?.stringValue == "")
}

/// Switching tab replaces the columns wholesale. Without this the table would
/// keep the previous report's headers while rendering the new report's cells.
@MainActor
@Test func installColumnsReplacesTheWholeSetAndClearsStaleSortDescriptors() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 2), report: internalReport)
    let table = NSTableView()
    coordinator.installColumns(on: table)
    #expect(table.tableColumns.map(\.identifier.rawValue) == internalReport.columns.map(\.id))

    table.sortDescriptors = [NSSortDescriptor(key: "status", ascending: true)]
    coordinator.report = Reports.canonicals
    coordinator.installColumns(on: table)
    #expect(table.tableColumns.map(\.identifier.rawValue) == Reports.canonicals.columns.map(\.id))
    #expect(table.sortDescriptors.isEmpty, "a sort from the previous tab must not persist")
}

// MARK: - configure(_:columnIndex:row:)
//
// `viewFor`'s reuse and create branches both funnel into this one method, so
// there is exactly one place a cell's text gets set. These tests target that
// method head-on, by handing it a cell that already carries the wrong text —
// exactly the shape a real reused `NSTableCellView` would have — without
// needing AppKit to ever actually reuse one.

@MainActor
private func staleCell() -> NSTableCellView {
    let cell = NSTableCellView()
    let field = NSTextField(labelWithString: "STALE FROM ANOTHER ROW")
    cell.textField = field
    return cell
}

@MainActor
@Test func configureOverwritesStaleTextWithTheRowsOwnValue() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 5), report: internalReport)
    let cell = staleCell()

    coordinator.configure(cell, columnIndex: col("address"), row: 3)

    #expect(cell.textField?.stringValue == "https://t.test/3")
}

@MainActor
@Test func configureOverwritesStaleTextWithEmptyWhenTheRowHasNoValue() throws {
    let coordinator = URLTableCoordinator(rows: try queuedOnlyRows(), report: internalReport)
    let cell = staleCell()

    coordinator.configure(cell, columnIndex: col("status"), row: 0)

    #expect(
        cell.textField?.stringValue == "",
        "a stale value must not survive when the new value is empty"
    )
}
