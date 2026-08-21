import Foundation
import GRDB
import KodaCore

public struct CrawlRow: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let address: String
    public let status: Int?
    public let title: String?
    public let depth: Int
}

/// Pages rows out of SQLite so the table never holds the whole crawl in memory.
///
/// Reads are synchronous because `NSTableView` asks for cell values during
/// draw, and an indexed page fetch is sub-millisecond. Row order and count
/// come from `RowIndex`, which owns both the sort and `Store.visibleURLsFilter`
/// — `RowStore`'s job is only to fetch the contents of a slice of ids, by
/// primary key, at O(1) cost regardless of how deep into the crawl that slice
/// falls.
@MainActor
public final class RowStore {
    private let store: Store
    private let index: RowIndex
    private let pageSize: Int
    private let maxPages: Int

    private var pages: [Int: [CrawlRow]] = [:]
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

    public func row(at rowIndex: Int) -> CrawlRow? {
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

    private func loadPage(_ pageIndex: Int) -> [CrawlRow] {
        loadCount += 1
        let start = pageIndex * pageSize
        let end = min(start + pageSize, index.count)
        guard start < end else { return [] }
        let wanted: [Int64] = (start..<end).compactMap { index.id(at: $0) }
        guard !wanted.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: wanted.count).joined(separator: ",")
        let fetched: [Int64: CrawlRow] = (try? store.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.id AS id, u.url AS url, r.status AS status, f.title AS title, u.depth AS depth
                FROM urls u
                LEFT JOIN responses r ON r.url_id = u.id
                LEFT JOIN page_facts f ON f.url_id = u.id
                WHERE u.id IN (\(placeholders))
                """, arguments: StatementArguments(wanted))
            .reduce(into: [Int64: CrawlRow]()) { acc, row in
                let id: Int64 = row["id"]
                acc[id] = CrawlRow(id: id, address: row["url"], status: row["status"],
                                   title: row["title"], depth: row["depth"])
            }
        }) ?? [:]

        // `IN` returns rows in whatever order SQLite likes, so reorder to match
        // the index. Without this the table would show correct rows in the wrong
        // places — which looks like data corruption rather than a sorting bug.
        let rows = wanted.compactMap { fetched[$0] }

        pages[pageIndex] = rows
        touch(pageIndex)
        while lru.count > maxPages, let oldest = lru.first {
            lru.removeFirst()
            pages.removeValue(forKey: oldest)
        }
        return rows
    }
}
