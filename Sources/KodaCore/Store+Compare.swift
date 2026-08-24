import Foundation
import GRDB

/// One field that differs between two crawls of the same URL.
public struct CrawlChange: Sendable, Identifiable, Equatable {
    public let id: Int
    public let url: String
    /// A human name for what changed, e.g. "Status" or "Title".
    public let field: String
    public let before: String?
    public let after: String?
}

/// What changed between two crawls.
///
/// Counts are the true totals; the arrays are capped, so a comparison of two
/// large crawls stays readable without quietly claiming fewer changes than
/// there were.
public struct CrawlDiff: Sendable, Equatable {
    public let added: [String]
    public let removed: [String]
    public let changes: [CrawlChange]
    public let addedTotal: Int
    public let removedTotal: Int
    public let changesTotal: Int

    public var isEmpty: Bool { addedTotal == 0 && removedTotal == 0 && changesTotal == 0 }

    public init(added: [String], removed: [String], changes: [CrawlChange],
                addedTotal: Int, removedTotal: Int, changesTotal: Int) {
        self.added = added
        self.removed = removed
        self.changes = changes
        self.addedTotal = addedTotal
        self.removedTotal = removedTotal
        self.changesTotal = changesTotal
    }
}

public enum CompareError: Error, CustomStringConvertible {
    case notFound(String)
    case notACrawlDatabase(String)

    public var description: String {
        switch self {
        case .notFound(let path):
            return "No crawl database at \(path)"
        case .notACrawlDatabase(let path):
            return "\(path) is not a crawl database — it has no urls table."
        }
    }
}

extension Store {
    /// Compares this crawl against an earlier one on disk.
    ///
    /// Identity is `url_hash`, the SHA-256 of the normalised URL, so a URL is
    /// the same URL across crawls regardless of discovery order or row id.
    ///
    /// **Only fields that have existed since the first schema version are
    /// compared.** An older `.koda` file genuinely lacks the later columns —
    /// ATTACH does not migrate it, and migrating someone's previous crawl in
    /// order to read it would be a rude thing for a comparison to do. Restricting
    /// the comparison to v1 fields means any crawl this tool has ever written can
    /// be compared against any other. It happens to cost nothing: status, title,
    /// description, H1, canonical, word count and the whole indexability ladder
    /// are all v1.
    public func compare(against path: String, limit: Int = 500) throws -> CrawlDiff {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CompareError.notFound(path)
        }
        return try dbQueue.write { db in
            try db.execute(sql: "ATTACH DATABASE ? AS prev", arguments: [path])
            defer { try? db.execute(sql: "DETACH DATABASE prev") }

            let hasURLs = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM prev.sqlite_master WHERE type='table' AND name='urls'") ?? 0
            guard hasURLs > 0 else { throw CompareError.notACrawlDatabase(path) }

            // Only URLs that were actually fetched count as present in a crawl:
            // a queued-but-never-reached URL is not a page that existed.
            let present = "EXISTS (SELECT 1 FROM %@responses rr WHERE rr.url_id = %@urls.id)"

            func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }

            let addedSQL = """
                SELECT url FROM urls
                WHERE \(String(format: present, "", "")) 
                  AND url_hash NOT IN (SELECT url_hash FROM prev.urls)
                ORDER BY url
                """
            let removedSQL = """
                SELECT url FROM prev.urls
                WHERE \(String(format: present, "prev.", "prev."))
                  AND url_hash NOT IN (SELECT url_hash FROM urls)
                ORDER BY url
                """

            let added = try String.fetchAll(db, sql: addedSQL + " LIMIT \(limit)")
            let removed = try String.fetchAll(db, sql: removedSQL + " LIMIT \(limit)")
            let addedTotal = try count("SELECT count(*) FROM (\(addedSQL))")
            let removedTotal = try count("SELECT count(*) FROM (\(removedSQL))")

            let changesSQL = Self.changesSQL
            let rows = try Row.fetchAll(db, sql: changesSQL + " LIMIT \(limit)")
            let changesTotal = try count("SELECT count(*) FROM (\(changesSQL))")

            let changes = rows.enumerated().map { index, row in
                CrawlChange(id: index, url: row["url"], field: row["field"],
                            before: Self.display(row["before"]),
                            after: Self.display(row["after"]))
            }
            return CrawlDiff(added: added, removed: removed, changes: changes,
                             addedTotal: addedTotal, removedTotal: removedTotal,
                             changesTotal: changesTotal)
        }
    }

    /// One row per changed field, built as a UNION so a page that changed in
    /// three ways produces three rows rather than one row nobody can read.
    ///
    /// `IS NOT` rather than `!=`: in SQL, `NULL != 'x'` is NULL, not true, so a
    /// title appearing where there was none — one of the most useful things a
    /// comparison can tell you — would be silently missed by `!=`.
    static let changesSQL: String = {
        let joins = """
            FROM urls u
            JOIN prev.urls pu ON pu.url_hash = u.url_hash
            LEFT JOIN responses r ON r.url_id = u.id
            LEFT JOIN prev.responses pr ON pr.url_id = pu.id
            LEFT JOIN page_facts f ON f.url_id = u.id
            LEFT JOIN prev.page_facts pf ON pf.url_id = pu.id
            """
        func clause(_ name: String, _ now: String, _ then: String) -> String {
            """
            SELECT u.url AS url, '\(name)' AS field, \(then) AS before, \(now) AS after
            \(joins)
            WHERE (r.url_id IS NOT NULL OR pr.url_id IS NOT NULL) AND (\(now)) IS NOT (\(then))
            """
        }
        let indexNow = Indexability.expression
        // The same ladder, over the attached crawl's aliases.
        let indexThen = Indexability.expression
            .replacingOccurrences(of: "r.status", with: "pr.status")
            .replacingOccurrences(of: "f.meta_robots", with: "pf.meta_robots")
            .replacingOccurrences(of: "f.x_robots_tag", with: "pf.x_robots_tag")
            .replacingOccurrences(of: "f.canonical_id", with: "pf.canonical_id")
            .replacingOccurrences(of: "u.id", with: "pu.id")

        return [
            clause("Status", "r.status", "pr.status"),
            clause("Title", "f.title", "pf.title"),
            clause("Meta Description", "f.meta_description", "pf.meta_description"),
            clause("H1", "f.h1", "pf.h1"),
            clause("Indexability", "(\(indexNow))", "(\(indexThen))"),
            clause("Canonical",
                   "(SELECT cu.url FROM urls cu WHERE cu.id = f.canonical_id)",
                   "(SELECT cu.url FROM prev.urls cu WHERE cu.id = pf.canonical_id)"),
        ].joined(separator: "\nUNION ALL\n") + "\nORDER BY url, field"
    }()
}
