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
/// draw, and an indexed page fetch is sub-millisecond. Known limitation:
/// `OFFSET` is O(offset), so scrolling near the end of a very large crawl
/// gets sluggish. Keyset pagination fixes it but needs a stable sort key,
/// which only matters once M3 adds sortable columns.
@MainActor
public final class RowStore {
    private let store: Store
    private let pageSize: Int
    private let maxPages: Int

    private var pages: [Int: [CrawlRow]] = [:]
    private var lru: [Int] = []
    private var cachedCount = 0

    /// Counts actual `loadPage` executions (cache misses), so tests can prove a
    /// hit was served from the cache without a redundant SQL round trip. Not
    /// public — this is a test seam, not part of the component's contract.
    var loadCount = 0

    public init(store: Store, pageSize: Int = 200, maxPages: Int = 20) {
        self.store = store
        self.pageSize = max(pageSize, 1)
        self.maxPages = max(maxPages, 1)
    }

    public var count: Int { cachedCount }

    /// Re-reads the row count and drops cached pages. Called on the UI's tick
    /// while a crawl is running.
    public func refresh() {
        // If the read fails, `cachedCount` is left as-is (stale) and the cache is
        // intentionally left alone too: invalidating on a transient failure would
        // throw away perfectly good pages for no benefit, since we have nothing
        // newer to replace them with.
        guard let freshCount = try? store.dbQueue.read({ db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM urls u WHERE \(Store.visibleURLsFilter)") ?? 0
        }) else {
            return
        }
        cachedCount = freshCount
        invalidate()
    }

    public func invalidate() {
        pages.removeAll()
        lru.removeAll()
    }

    public func row(at index: Int) -> CrawlRow? {
        guard index >= 0, index < cachedCount else { return nil }
        let pageIndex = index / pageSize
        let page: [CrawlRow]
        if let cached = pages[pageIndex] {
            touch(pageIndex)
            page = cached
        } else {
            page = loadPage(pageIndex)
        }
        let offset = index - pageIndex * pageSize
        guard offset >= 0, offset < page.count else { return nil }
        return page[offset]
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
        let rows: [CrawlRow] = (try? store.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.id AS id, u.url AS url, r.status AS status, f.title AS title, u.depth AS depth
                FROM urls u
                LEFT JOIN responses r ON r.url_id = u.id
                LEFT JOIN page_facts f ON f.url_id = u.id
                WHERE \(Store.visibleURLsFilter)
                ORDER BY u.id
                LIMIT ? OFFSET ?
                """, arguments: [pageSize, pageIndex * pageSize])
            .map { row in
                CrawlRow(id: row["id"], address: row["url"], status: row["status"],
                         title: row["title"], depth: row["depth"])
            }
        }) ?? []

        pages[pageIndex] = rows
        touch(pageIndex)
        while lru.count > maxPages, let oldest = lru.first {
            lru.removeFirst()
            pages.removeValue(forKey: oldest)
        }
        return rows
    }
}
