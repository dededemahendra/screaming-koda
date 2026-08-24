import Foundation
import KodaCore

/// Row access for a table over a report, backed by paged SQL behind an LRU of
/// row windows.
///
/// A crawl can hold half a million rows. Materialising a report to feed a table
/// would cost more memory than the crawl itself, so the table asks for rows by
/// index and this loads the window containing that index, keeping only a handful
/// of windows resident.
///
/// Main-thread only, like the table it feeds. Reads are synchronous because a
/// window is one indexed SQLite query, and an asynchronous data source would mean
/// the table drawing blank rows and then flickering as they filled in.
public final class RowWindowCache {
    public let windowSize: Int
    public let maxWindows: Int

    private let store: Store
    private var query: ReportQuery
    private var windows: [Int: [[String?]]] = [:]
    /// Window indices, least recently used first.
    private var usage: [Int] = []

    public private(set) var count: Int
    /// Windows loaded since the last reset. Lets tests assert that scrolling
    /// re-reads rather than silently holding everything.
    public private(set) var loadCount = 0

    public init(store: Store, query: ReportQuery, windowSize: Int = 200, maxWindows: Int = 8) throws {
        precondition(windowSize > 0 && maxWindows > 0)
        self.store = store
        self.query = query
        self.windowSize = windowSize
        self.maxWindows = maxWindows
        self.count = try store.count(for: query)
    }

    public var currentQuery: ReportQuery { query }
    public var residentWindows: Int { windows.count }

    /// Nil when the index is out of range, which happens routinely while a crawl
    /// is running and the table has a stale row count.
    public func row(at index: Int) throws -> [String?]? {
        guard index >= 0, index < count else { return nil }
        let windowIndex = index / windowSize

        if let window = windows[windowIndex] {
            touch(windowIndex)
            let offset = index - windowIndex * windowSize
            return offset < window.count ? window[offset] : nil
        }

        let rows = try store.rows(for: query, limit: windowSize, offset: windowIndex * windowSize)
        loadCount += 1
        windows[windowIndex] = rows
        touch(windowIndex)
        evictIfNeeded()

        let offset = index - windowIndex * windowSize
        return offset < rows.count ? rows[offset] : nil
    }

    /// Changing sort or filter changes what every row index means, so nothing
    /// already loaded can be reused.
    public func setQuery(_ newQuery: ReportQuery) throws {
        query = newQuery
        try reload()
    }

    /// Re-counts and drops the cache. Called on the refresh timer while a crawl
    /// writes underneath us.
    public func reload() throws {
        windows.removeAll()
        usage.removeAll()
        count = try store.count(for: query)
    }

    private func touch(_ windowIndex: Int) {
        usage.removeAll { $0 == windowIndex }
        usage.append(windowIndex)
    }

    private func evictIfNeeded() {
        while usage.count > maxWindows {
            let oldest = usage.removeFirst()
            windows[oldest] = nil
        }
    }
}
