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
