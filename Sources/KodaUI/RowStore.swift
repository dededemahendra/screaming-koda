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

    public init(store: Store, pageSize: Int = 200, maxPages: Int = 20) {
        self.store = store
        self.pageSize = max(pageSize, 1)
        self.maxPages = max(maxPages, 1)
    }

    public var count: Int { cachedCount }

    /// Re-reads the row count and drops cached pages. Called on the UI's tick
    /// while a crawl is running.
    public func refresh() {
        cachedCount = (try? store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM urls u WHERE \(Store.visibleURLsFilter)") ?? 0
        }) ?? cachedCount
        invalidate()
    }

    public func invalidate() {
        pages.removeAll()
        lru.removeAll()
    }

    public func row(at index: Int) -> CrawlRow? {
        guard index >= 0, index < cachedCount else { return nil }
        let pageIndex = index / pageSize
        let page = pages[pageIndex] ?? loadPage(pageIndex)
        let offset = index - pageIndex * pageSize
        guard offset >= 0, offset < page.count else { return nil }
        return page[offset]
    }

    private func loadPage(_ pageIndex: Int) -> [CrawlRow] {
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
        lru.removeAll { $0 == pageIndex }
        lru.append(pageIndex)
        while lru.count > maxPages, let oldest = lru.first {
            lru.removeFirst()
            pages.removeValue(forKey: oldest)
        }
        return rows
    }
}
