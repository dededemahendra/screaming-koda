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
/// this test (see task-6-report.md's fix-round sections): even with a real
/// `NSWindow`/`NSScrollView` hierarchy, forced layout, and `scrollRowToVisible`
/// past the row that was first drawn, `makeView(withIdentifier:owner:)`
/// returned `nil` rather than handing back the earlier cell. So this cannot
/// assert object identity across a reuse cycle, and under `swift test` every
/// call here takes the freshly-created-cell path in `viewFor` — the reuse
/// branch is never actually executed.
///
/// This test only covers wiring: that `viewFor`, called repeatedly through
/// the same table view and column, always hands back the requested row's own
/// value rather than a value left over from an earlier call. It does NOT, by
/// itself, guard against a `stringValue` assignment sliding into only one of
/// `viewFor`'s two branches — under `makeView` always returning nil here,
/// that mutation would be invisible to this test no matter how the rows are
/// sequenced. What actually closes that gap is that `viewFor` no longer has
/// two assignment sites to slide into: both branches call the single
/// `configure(_:column:row:)` method below, and `configure` is tested
/// directly, against a cell that already carries the wrong text, further
/// down this file.
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

// MARK: - configure(_:column:row:)
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
    let coordinator = URLTableCoordinator(rows: try seededRows(pages: 5))
    let cell = staleCell()

    coordinator.configure(cell, column: .address, row: 3)

    #expect(cell.textField?.stringValue == "https://t.test/3")
}

@MainActor
@Test func configureOverwritesStaleTextWithEmptyWhenTheRowHasNoValue() throws {
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
    let cell = staleCell()

    coordinator.configure(cell, column: .status, row: 0)

    #expect(
        cell.textField?.stringValue == "",
        "a stale value must not survive when the new value is empty"
    )
}
