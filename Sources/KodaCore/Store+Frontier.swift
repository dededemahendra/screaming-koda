import Foundation
import GRDB

public struct FrontierItem: Sendable {
    public let id: Int64
    public let url: NormalizedURL
    public let depth: Int
    /// True when this URL is only to be status-checked (HEAD), never parsed —
    /// an external link or an image source.
    public let checkOnly: Bool
}

extension Store {
    /// Inserts the URL if unseen; returns the row id either way.
    public func insertURLIfNew(
        _ url: NormalizedURL,
        depth: Int,
        isInternal: Bool,
        discoveredAt: Date
    ) throws -> Int64 {
        try dbQueue.write { db in
            try Self.insertURL(db, url, depth: depth, isInternal: isInternal, discoveredAt: discoveredAt)
        }
    }

    /// Same as `insertURLIfNew` but inside a caller-managed transaction.
    static func insertURL(
        _ db: Database,
        _ url: NormalizedURL,
        depth: Int,
        isInternal: Bool,
        discoveredAt: Date
    ) throws -> Int64 {
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url_hash = ?", arguments: [url.sha256]) {
            return existing
        }
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                VALUES (?,?,?,?,?,?,?,0)
                """,
            arguments: [url.absoluteString, url.sha256, url.host, url.path, depth, isInternal ? 1 : 0,
                        discoveredAt.timeIntervalSince1970]
        )
        return db.lastInsertedRowID
    }

    /// Claims up to `limit` queued URLs, shallowest first, marking them in-flight.
    ///
    /// A claimed row whose stored `url` string can no longer be re-normalized (e.g. a
    /// future normalizer change, or corrupt data) is marked skipped rather than left
    /// in-flight forever — otherwise it would silently strand the frontier: nothing
    /// else moves a row out of the in-flight state, and `claimNext` only ever selects
    /// queued rows, so the row would never be crawled and never complete.
    public func claimNext(limit: Int, maxPerHost: Int) throws -> [FrontierItem] {
        try dbQueue.write { db in
            // ROW_NUMBER() partitions the queue by host so one crowded host cannot
            // fill a batch. Requires SQLite 3.25+; macOS 14 ships 3.43+ and this
            // machine has 3.51.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, url, depth, check_only FROM (
                      SELECT id, url, depth, check_only, host,
                             ROW_NUMBER() OVER (PARTITION BY host ORDER BY depth ASC, id ASC) AS rn
                      FROM urls WHERE state = 0
                    )
                    WHERE rn <= ?
                    ORDER BY depth ASC, id ASC
                    LIMIT ?
                    """,
                arguments: [max(maxPerHost, 1), limit]
            )
            guard !rows.isEmpty else { return [] }
            let ids = rows.map { $0["id"] as Int64 }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(
                sql: "UPDATE urls SET state = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            var items: [FrontierItem] = []
            items.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["id"]
                if let normalized = URLNormalizer.normalize(row["url"], relativeTo: nil) {
                    items.append(FrontierItem(id: id, url: normalized, depth: row["depth"],
                                              checkOnly: (row["check_only"] as Int) != 0))
                } else {
                    try Self.setState(db, id: id, state: 3)
                }
            }
            return items
        }
    }

    public func markDone(_ id: Int64) throws {
        try dbQueue.write { db in try Self.setState(db, id: id, state: 2) }
    }

    /// - Parameter reason: why, so the Crawlability report can say something
    ///   more useful than "not crawled".
    public func markSkipped(_ id: Int64, reason: String = "blocked by robots.txt") throws {
        try dbQueue.write { db in
            try Self.setState(db, id: id, state: 3)
            try db.execute(sql: "UPDATE urls SET skip_reason = ? WHERE id = ?",
                           arguments: [reason, id])
        }
    }

    static func setState(_ db: Database, id: Int64, state: Int) throws {
        try db.execute(sql: "UPDATE urls SET state = ? WHERE id = ?", arguments: [state, id])
    }

    /// Requeues URLs left in-flight by a crash or quit. Returns how many were reset.
    @discardableResult
    public func resetInFlight() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE urls SET state = 0 WHERE state = 1")
            return db.changesCount
        }
    }

    /// `total` counts every row in `urls`, including image-only rows (an `<img src>`
    /// target that is never a link or crawl target in its own right) — unlike
    /// `Store.summary().totalURLs`, which excludes those. The two numbers will
    /// legitimately differ on any page with images.
    public func urlCounts() throws -> (queued: Int, inFlight: Int, done: Int, total: Int) {
        try dbQueue.read { db in
            func count(_ state: Int) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE state = ?", arguments: [state]) ?? 0
            }
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
            return (try count(0), try count(1), try count(2), total)
        }
    }
}

extension Store {
    /// Seeds the frontier from a sitemap, marking each URL as sitemap-declared.
    ///
    /// A URL already discovered by crawling is marked rather than re-inserted,
    /// and one already crawled is not re-queued — so running a sitemap seed over
    /// an existing crawl annotates it instead of restarting it.
    ///
    /// Returns how many URLs were newly queued.
    @discardableResult
    public func seedFromSitemap(_ urls: [NormalizedURL], config: CrawlConfig,
                                now: Date) throws -> Int {
        guard !urls.isEmpty else { return 0 }
        let seedHost = config.seedHost
        var queued = 0
        try dbQueue.write { db in
            for url in urls {
                let isInternal = Self.isInternal(url, seedHost: seedHost, config: config)
                // A sitemap listing another site's URLs is a mistake worth
                // recording — not just that the URL was skipped, but why — even
                // though the URL itself is not worth crawling.
                let existing = try Int64.fetchOne(
                    db, sql: "SELECT id FROM urls WHERE url_hash = ?", arguments: [url.sha256])
                if let existing {
                    try db.execute(sql: "UPDATE urls SET in_sitemap = 1 WHERE id = ?",
                                   arguments: [existing])
                    continue
                }
                let shouldQueue = isInternal && Self.passesFilters(url, config: config)
                // Same wording as discover()'s skip reasons — the Crawlability
                // report shows both side by side and they must read as one system.
                let skipReason: String? = shouldQueue ? nil : (isInternal ? "excluded by URL filters" : "external")
                try db.execute(
                    sql: """
                        INSERT INTO urls (url, url_hash, host, path, depth, is_internal,
                                          discovered_at, state, in_sitemap, skip_reason)
                        VALUES (?,?,?,?,0,?,?,?,1,?)
                        """,
                    arguments: [url.absoluteString, url.sha256, url.host, url.path,
                                isInternal ? 1 : 0, now.timeIntervalSince1970,
                                shouldQueue ? 0 : 3, skipReason])
                if shouldQueue { queued += 1 }
            }
        }
        return queued
    }

    /// How many URLs a sitemap declared, for the crawl summary and the UI.
    public func sitemapCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE in_sitemap = 1") ?? 0
        }
    }
}
