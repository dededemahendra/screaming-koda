import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaUI

/// Four URLs with deliberately non-aligned orderings so a wrong sort column
/// cannot accidentally produce the right answer.
@MainActor
private func seeded() throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://s.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state) VALUES
              ('https://s.test/d', x'01', 's.test', '/d', 3, 1, 0, 2),
              ('https://s.test/a', x'02', 's.test', '/a', 1, 1, 0, 2),
              ('https://s.test/c', x'03', 's.test', '/c', 0, 1, 0, 2),
              ('https://s.test/b', x'04', 's.test', '/b', 2, 1, 0, 2)
            """)
        try db.execute(sql: """
            INSERT INTO responses (url_id, status, fetched_at) VALUES
              (1, 500, 0), (2, 200, 0), (3, 404, 0), (4, 301, 0)
            """)
        try db.execute(sql: """
            INSERT INTO page_facts (url_id, title) VALUES
              (1, 'Zebra'), (2, 'Apple'), (3, 'Mango'), (4, 'Banana')
            """)
    }
    return store
}

/// The unfiltered Internal report, which is what these tests exercise: the
/// table's default view. Report-specific behaviour lives in ReportSelectionTests.
@MainActor
private func rebuild(_ index: RowIndex, sortColumnID: String? = nil, ascending: Bool = true) {
    index.rebuild(report: Reports.internalURLs,
                  filter: Reports.internalURLs.defaultFilter,
                  sortColumnID: sortColumnID, ascending: ascending)
}

@MainActor
private func urls(_ store: Store, _ index: RowIndex) throws -> [String] {
    try store.dbQueue.read { db in
        try index.ids.map { id in
            try String.fetchOne(db, sql: "SELECT url FROM urls WHERE id = ?", arguments: [id]) ?? "?"
        }
    }
}

@MainActor
@Test func sortsByAddressAscending() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "address", ascending: true)
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["a", "b", "c", "d"])
}

@MainActor
@Test func sortsByAddressDescending() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "address", ascending: false)
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["d", "c", "b", "a"])
}

@MainActor
@Test func sortsByStatus() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "status", ascending: true)
    // 200, 301, 404, 500 → /a, /b, /c, /d
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["a", "b", "c", "d"])
}

@MainActor
@Test func sortsByTitle() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "title", ascending: true)
    // Apple, Banana, Mango, Zebra → /a, /b, /c, /d
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["a", "b", "c", "d"])
}

@MainActor
@Test func sortsByDepth() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "depth", ascending: true)
    // depths 0,1,2,3 → /c, /a, /b, /d
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["c", "a", "b", "d"])
}

@MainActor
@Test func nullsSortLastAscending() throws {
    let store = try seeded()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/queued', x'05', 's.test', '/queued', 9, 1, 0, 0)
            """)
        // No responses row, so status is null.
        try db.execute(sql: "INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position) VALUES (1,5,'q',NULL,1,0)")
    }
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "status", ascending: true)
    #expect(try urls(store, index).last == "https://s.test/queued")
}

@MainActor
@Test func nullsSortLastDescendingToo() throws {
    let store = try seeded()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/queued', x'05', 's.test', '/queued', 9, 1, 0, 0)
            """)
        try db.execute(sql: "INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position) VALUES (1,5,'q',NULL,1,0)")
    }
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "status", ascending: false)
    #expect(try urls(store, index).last == "https://s.test/queued",
            "a table sorted either way should open on real values, not blanks")
}

@MainActor
@Test func idAtBoundsIsSafe() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "address", ascending: true)
    #expect(index.count == 4)
    #expect(index.id(at: 0) != nil)
    #expect(index.id(at: 3) != nil)
    #expect(index.id(at: 4) == nil)
    #expect(index.id(at: -1) == nil)
}

@MainActor
@Test func excludesImageOnlyURLs() throws {
    let store = try seeded()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/pic.png', x'06', 's.test', '/pic.png', 1, 1, 0, 2)
            """)
        try db.execute(sql: "INSERT INTO images (url_id, src_url_id, alt) VALUES (1,5,'a')")
        try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (5,200,0)")
    }
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "address", ascending: true)
    #expect(index.count == 4, "a fetched image is still not a row in the URL table")
}

@MainActor
@Test func appendNewIdsPicksUpRowsAddedMidCrawl() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, ascending: true)
    #expect(index.count == 4)

    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/e', x'07', 's.test', '/e', 4, 1, 0, 2)
            """)
        try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (5,200,0)")
    }

    let grew = index.appendNewIds()
    #expect(grew)
    #expect(index.count == 5)
}

@MainActor
@Test func appendNewIdsRefusesUnderANonDefaultSort() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "status", ascending: true)
    let grew = index.appendNewIds()
    #expect(!grew, "appending only makes sense in discovery order; other sorts must rebuild")
}

/// Appending can only ever add. On a filtered report a row can stop matching —
/// a page missing a title gains one and leaves Titles → Missing — and no append
/// will ever remove it, so filtered views must rebuild instead.
@MainActor
@Test func appendNewIdsRefusesOnAFilteredReport() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    let missing = Reports.titles.filters.first { $0.id == "missing" }!
    index.rebuild(report: Reports.titles, filter: missing, sortColumnID: nil, ascending: true)
    #expect(!index.appendNewIds())
}

/// Descending discovery order is not id order either.
@MainActor
@Test func appendNewIdsRefusesWhenDescending() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, ascending: false)
    #expect(!index.appendNewIds())
}

@MainActor
@Test func appendNewIdsRefusesUnderAddressSort() throws {
    // Address order is NOT id order, so a newly discovered URL could belong
    // anywhere in the list — appending it would look plausible and be wrong.
    let store = try seeded()
    let index = RowIndex(store: store)
    rebuild(index, sortColumnID: "address", ascending: true)
    #expect(!index.appendNewIds())
}

@MainActor
@Test func discoveryOrderIsTheDefaultBeforeAnyRebuild() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    #expect(index.sortColumnID == nil)
    #expect(index.report.id == Reports.internalURLs.id)
    #expect(index.filter.id == Reports.internalURLs.defaultFilter.id)
}
