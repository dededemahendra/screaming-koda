import Foundation
import GRDB

extension Store {
    /// Runs a report and returns its rows rendered as text, ready for a table or CSV.
    ///
    /// Paging is `LIMIT`/`OFFSET` on the definition's own query rather than sorting
    /// in Swift, so a report over a 500k-row crawl costs the same as one over 50.
    public func runReport(_ definition: ReportDefinition, limit: Int? = nil, offset: Int = 0) throws -> [[String?]] {
        var sql = definition.sql
        if let limit {
            sql += "\nLIMIT \(limit) OFFSET \(offset)"
        } else if offset > 0 {
            sql += "\nLIMIT -1 OFFSET \(offset)"
        }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: sql).map { row in
                (0..<row.count).map { Self.text(row[$0]) }
            }
        }
    }

    /// Row count for a report, for sidebar badges. Counting in SQL avoids
    /// materialising rows nobody is going to look at.
    public func reportCount(_ definition: ReportDefinition) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM (\(definition.sql))") ?? 0
        }
    }

    /// Counts for every report in one pass, keyed by report id.
    public func reportCounts(_ definitions: [ReportDefinition] = ReportCatalogue.all) throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try dbQueue.read { db in
            for definition in definitions {
                counts[definition.id] = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM (\(definition.sql))"
                ) ?? 0
            }
        }
        return counts
    }

    /// The column names the query actually produces, used to verify a definition's
    /// declared `columns` have not drifted from its SQL.
    public func reportColumnNames(_ definition: ReportDefinition) throws -> [String] {
        try dbQueue.read { db in
            let statement = try db.makeStatement(sql: "SELECT * FROM (\(definition.sql)) LIMIT 0")
            return statement.columnNames
        }
    }

    /// Renders a stored value for display. NULL stays nil so exporters can tell it
    /// apart from an empty string, and blobs are summarised rather than dumped.
    static func text(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .null: return nil
        case .string(let s): return s
        case .int64(let i): return String(i)
        case .double(let d):
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .blob(let data): return "<\(data.count) bytes>"
        }
    }
}
