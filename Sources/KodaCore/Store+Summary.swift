import Foundation
import GRDB

public struct CrawlSummary: Sendable {
    public let totalURLs: Int
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

            // See `Store.visibleURLsFilter` for the rationale. `imagesMissingAlt` below
            // queries the `images` table directly and is unaffected by this filter.
            let notImageOnly = Store.visibleURLsFilter
            return CrawlSummary(
                totalURLs: try count("SELECT count(*) FROM urls u WHERE \(notImageOnly)"),
                internalURLs: try count("SELECT count(*) FROM urls u WHERE u.is_internal = 1 AND \(notImageOnly)"),
                externalURLs: try count("SELECT count(*) FROM urls u WHERE u.is_internal = 0 AND \(notImageOnly)"),
                byStatusClass: byClass,
                transportErrors: try count("SELECT count(*) FROM responses WHERE status = 0"),
                missingTitles: try count("""
                    SELECT count(*) FROM page_facts f JOIN responses r ON r.url_id = f.url_id
                    WHERE (f.title IS NULL OR f.title = '') AND r.status = 200
                    """),
                // Must match the sibling queries above and stay restricted to status = 200:
                // `CrawlEngine.process` writes a `page_facts` row for ANY status as long as
                // the content type is HTML and the body is non-empty, so custom error-page
                // templates (very commonly sharing one title across every 404/500) get a
                // `page_facts` row too. Without the status filter, those collide and get
                // counted as "duplicate titles" even though they're not indexable pages.
                duplicateTitles: try count("""
                    SELECT coalesce(sum(n), 0) FROM (
                      SELECT count(*) AS n FROM page_facts f JOIN responses r ON r.url_id = f.url_id
                      WHERE f.title IS NOT NULL AND f.title != '' AND r.status = 200
                      GROUP BY f.title HAVING count(*) > 1
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
                maxDepth: try count("SELECT coalesce(max(u.depth), 0) FROM urls u JOIN responses r ON r.url_id = u.id")
            )
        }
    }
}
