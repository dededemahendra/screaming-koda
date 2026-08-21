import Foundation
import GRDB
import KodaCore

/// Pages rows out of SQLite so the table never holds the whole crawl in memory.
///
/// Reads are synchronous because `NSTableView` asks for cell values during
/// draw, and an indexed page fetch is sub-millisecond. Row order, count, and
/// which report's columns to fetch all come from `RowIndex` — `RowStore`'s job
/// is only to fetch the contents of a slice of ids, by primary key, at O(1)
/// cost regardless of how deep into the crawl that slice falls.
@MainActor
public final class RowStore {
    private let store: Store
    private let index: RowIndex
    private let pageSize: Int
    private let maxPages: Int

    private var pages: [Int: [ReportRow]] = [:]
    private var lru: [Int] = []

    /// Counts actual `loadPage` executions (cache misses), so tests can prove a
    /// hit was served from the cache without a redundant SQL round trip. Not
    /// public — this is a test seam, not part of the component's contract.
    var loadCount = 0

    public init(store: Store, index: RowIndex, pageSize: Int = 200, maxPages: Int = 20) {
        self.store = store
        self.index = index
        self.pageSize = max(pageSize, 1)
        self.maxPages = max(maxPages, 1)
    }

    /// The index decides how many rows there are and in what order; RowStore only
    /// fetches their contents. One place owns the filter and the ordering.
    public var count: Int { index.count }

    /// Re-reads the row count and drops cached pages. Called on the UI's tick
    /// while a crawl is running.
    public func refresh() {
        invalidate()
    }

    public func invalidate() {
        pages.removeAll()
        lru.removeAll()
    }

    /// The value of a named column for a row. Cells are positional, so this is
    /// the one place that translates a column id into an offset — call sites
    /// that hard-code an index go stale the moment a report's columns change.
    ///
    /// Returns nil both for a row that is out of range and for a genuine SQL
    /// NULL; callers that need to tell those apart check `row(at:)` first.
    public func value(_ columnID: String, at rowIndex: Int) -> String? {
        guard let position = index.report.columns.firstIndex(where: { $0.id == columnID }),
              let row = row(at: rowIndex), position < row.cells.count
        else { return nil }
        return row.cells[position]
    }

    public func row(at rowIndex: Int) -> ReportRow? {
        guard rowIndex >= 0, rowIndex < index.count else { return nil }
        let pageIndex = rowIndex / pageSize
        if let cached = pages[pageIndex] {
            touch(pageIndex)
            let offset = rowIndex - pageIndex * pageSize
            return offset < cached.count ? cached[offset] : nil
        }
        let page = loadPage(pageIndex)
        let offset = rowIndex - pageIndex * pageSize
        return offset < page.count ? page[offset] : nil
    }

    /// Marks `pageIndex` as most-recently-used, moving it to the end of the
    /// eviction queue. Called on both cache hits (from `row(at:)`) and misses
    /// (from `loadPage`) — without the hit-path call, this degrades to FIFO,
    /// which evicts a page a user is actively scrolling across just as readily
    /// as one they've long since scrolled past.
    private func touch(_ pageIndex: Int) {
        lru.removeAll { $0 == pageIndex }
        lru.append(pageIndex)
    }

    private func loadPage(_ pageIndex: Int) -> [ReportRow] {
        loadCount += 1
        let start = pageIndex * pageSize
        let end = min(start + pageSize, index.count)
        guard start < end else { return [] }
        let wanted: [Int64] = (start..<end).compactMap { index.id(at: $0) }
        guard !wanted.isEmpty else { return [] }

        // The report owns both which columns to select and the order they come
        // back in; the store restores the order of `wanted`, since `IN` does not
        // preserve it. Without that the table would show correct rows in the
        // wrong places, which reads as data corruption rather than a sort bug.
        let rows = (try? store.rows(ids: wanted, columns: index.report.columns)) ?? []

        pages[pageIndex] = rows
        touch(pageIndex)
        while lru.count > maxPages, let oldest = lru.first {
            lru.removeFirst()
            pages.removeValue(forKey: oldest)
        }
        return rows
    }
}
