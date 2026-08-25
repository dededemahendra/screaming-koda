import Foundation
import GRDB

public struct CrawlSummary: Sendable {
    public let totalURLs: Int
    /// URLs that actually got a response row. Always <= `totalURLs`: external
    /// links, images, and filtered or capped URLs are recorded but never fetched.
    public let crawledURLs: Int
    public let internalURLs: Int
    public let externalURLs: Int
    public let byStatusClass: [String: Int]
    public let transportErrors: Int
    public let missingTitles: Int
    public let duplicateTitles: Int
    public let missingDescriptions: Int
    public let missingH1: Int
    public let imagesMissingAlt: Int
    public let maxDepth: Int
}

extension Store {
    public func summary() throws -> CrawlSummary {
        try dbQueue.read { db in
            func count(_ sql: String) throws -> Int {
                try Int.fetchOne(db, sql: sql) ?? 0
            }

            var byClass: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT (status / 100) AS class, count(*) AS n FROM responses WHERE status > 0 GROUP BY class
                """) {
                let cls: Int = row["class"]
                byClass["\(cls)xx"] = row["n"]
            }

            return CrawlSummary(
                totalURLs: try count("SELECT count(*) FROM urls"),
                crawledURLs: try count("SELECT count(*) FROM responses"),
                internalURLs: try count("SELECT count(*) FROM urls WHERE is_internal = 1"),
                externalURLs: try count("SELECT count(*) FROM urls WHERE is_internal = 0"),
                byStatusClass: byClass,
                transportErrors: try count("SELECT count(*) FROM responses WHERE status = 0"),
                missingTitles: try count("""
                    SELECT count(*) FROM page_facts f JOIN responses r ON r.url_id = f.url_id
                    WHERE (f.title IS NULL OR f.title = '') AND r.status = 200
                    """),
                duplicateTitles: try count("""
                    SELECT coalesce(sum(n), 0) FROM (
                      SELECT count(*) AS n FROM page_facts WHERE title IS NOT NULL AND title != ''
                      GROUP BY title HAVING count(*) > 1
                    )
                    """),
                missingDescriptions: try count("""
                    SELECT count(*) FROM page_facts f JOIN responses r ON r.url_id = f.url_id
                    WHERE (f.meta_description IS NULL OR f.meta_description = '') AND r.status = 200
                    """),
                missingH1: try count("""
                    SELECT count(*) FROM page_facts f JOIN responses r ON r.url_id = f.url_id
                    WHERE (f.h1 IS NULL OR f.h1 = '') AND r.status = 200
                    """),
                imagesMissingAlt: try count("SELECT count(*) FROM images WHERE alt IS NULL OR alt = ''"),
                // Joined against page_facts, not responses: only parsed HTML pages
                // count. Images and other assets are fetched now, and letting an
                // asset one level below a page inflate "max depth" would misreport
                // how deep the site actually is.
                maxDepth: try count("SELECT coalesce(max(u.depth), 0) FROM urls u JOIN page_facts f ON f.url_id = u.id")
            )
        }
    }
}

/// Everything the window shows about a crawl, gathered in one go.
public struct CrawlSnapshot: Sendable {
    public let urlCounts: (queued: Int, inFlight: Int, done: Int, total: Int)
    public let reportCounts: [String: Int]
    public let summary: CrawlSummary
    public let meta: CrawlMeta?
}

extension Store {
    /// The whole window's worth of counts, off the calling thread.
    ///
    /// Sixty-odd aggregate queries, and a UI that wants them twice a second while
    /// a crawl writes underneath. Run where the caller is, that is the main
    /// thread stalling for as long as the crawl is large; run here, it is
    /// GRDB's own queue, which is where database work belongs. The caller waits
    /// without blocking anything.
    public func snapshot() async throws -> CrawlSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                continuation.resume(with: Result {
                    CrawlSnapshot(
                        urlCounts: try self.urlCounts(),
                        reportCounts: try self.reportCounts(),
                        summary: try self.summary(),
                        meta: try self.crawlMeta()
                    )
                })
            }
        }
    }
}
