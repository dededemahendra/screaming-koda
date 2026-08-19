import AppKit
import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaUI

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
    let rows = RowStore(store: store)
    rows.refresh()
    return rows
}

@MainActor
@Test func reportsTheRowCount() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 12))
    #expect(coordinator.numberOfRows(in: NSTableView()) == 12)
}

@MainActor
@Test func reportsZeroRowsWithoutAStore() {
    let coordinator = URLTableCoordinator(rows: nil)
    #expect(coordinator.numberOfRows(in: NSTableView()) == 0)
}

@MainActor
@Test func rendersEachColumn() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 3))
    #expect(coordinator.value(for: .address, row: 1) == "https://t.test/1")
    #expect(coordinator.value(for: .status, row: 1) == "201")
    #expect(coordinator.value(for: .title, row: 1) == "Title 1")
    #expect(coordinator.value(for: .depth, row: 1) == "1")
}

@MainActor
@Test func rendersMissingValuesAsEmptyRatherThanCrashing() throws {
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
    let rows = RowStore(store: store)
    rows.refresh()
    let coordinator = URLTableCoordinator(rows: rows)

    #expect(coordinator.value(for: .status, row: 0) == "", "an unfetched URL has no status")
    #expect(coordinator.value(for: .title, row: 0) == "")
    #expect(coordinator.value(for: .address, row: 0) == "https://t.test/queued")
}

@MainActor
@Test func outOfRangeRowsRenderEmptyRatherThanCrashing() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 2))
    #expect(coordinator.value(for: .address, row: 99) == "")
    #expect(coordinator.value(for: .status, row: -1) == "")
}

@MainActor
@Test func columnsCoverTheSpecifiedSet() {
    #expect(URLTableColumn.allCases.map(\.rawValue) == ["address", "status", "title", "depth"])
}

@MainActor
@Test func columnTitlesAreHumanReadable() {
    #expect(URLTableColumn.address.title == "Address")
    #expect(URLTableColumn.status.title == "Status")
    #expect(URLTableColumn.title.title == "Title")
    #expect(URLTableColumn.depth.title == "Depth")
}

// MARK: - tableView(_:viewFor:row:)
//
// `numberOfRows`/`value(for:row:)` above cover the data layer; these cover the
// delegate method that actually builds the `NSTableCellView` AppKit draws,
// including the cell-reuse branch and the unknown-column/out-of-range guards.
// Everything here runs against a bare `NSTableView()` with no `NSApplication`
// running, the same way the existing `reportsTheRowCount` test already
// constructs one — no SwiftUI hosting is required for any of this.

@MainActor
@Test func viewForRendersCellWithExpectedText() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 3))
    let table = NSTableView()
    let column = NSTableColumn(identifier: .init(URLTableColumn.address.rawValue))
    table.addTableColumn(column)

    let view = try #require(coordinator.tableView(table, viewFor: column, row: 1) as? NSTableCellView)
    #expect(view.textField?.stringValue == "https://t.test/1")
}

/// AppKit's real reuse pool is populated by internal view teardown during
/// actual on-screen scrolling/display, which never fires without a running
/// `NSApplication` and a live window — confirmed empirically while writing
/// this test (see task-6-report.md's fix-round section): even with a real
/// `NSWindow`/`NSScrollView` hierarchy, forced layout, and `scrollRowToVisible`
/// past the row that was first drawn, `makeView(withIdentifier:owner:)`
/// returned `nil` rather than handing back the earlier cell. So this cannot
/// assert object identity across a reuse cycle. Instead it asserts the
/// property that actually guards against the regression the review is
/// worried about — the `stringValue` assignment sliding from after the
/// reuse/create branches merge into only one of them: a cell requested for
/// row N, through the same table view and column, always carries row N's own
/// value, never a value left over from a different row requested earlier in
/// the same sequence.
@MainActor
@Test func viewForNeverCarriesAStaleNeighboursText() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 5))
    let table = NSTableView()
    let column = NSTableColumn(identifier: .init(URLTableColumn.address.rawValue))
    table.addTableColumn(column)

    for row in [0, 3, 1, 4, 2] {
        let view = try #require(coordinator.tableView(table, viewFor: column, row: row) as? NSTableCellView)
        #expect(view.textField?.stringValue == "https://t.test/\(row)")
    }
}

@MainActor
@Test func viewForReturnsNilForAnUnknownColumn() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 2))
    let table = NSTableView()
    let unknownColumn = NSTableColumn(identifier: .init("bogus"))
    table.addTableColumn(unknownColumn)

    #expect(coordinator.tableView(table, viewFor: unknownColumn, row: 0) == nil)
}

@MainActor
@Test func viewForRendersEmptyForARowBeyondTheRowCount() throws {
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 2))
    let table = NSTableView()
    let column = NSTableColumn(identifier: .init(URLTableColumn.address.rawValue))
    table.addTableColumn(column)

    let view = try #require(coordinator.tableView(table, viewFor: column, row: 99) as? NSTableCellView)
    #expect(view.textField?.stringValue == "")
}
