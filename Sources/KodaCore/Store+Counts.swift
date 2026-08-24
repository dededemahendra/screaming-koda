import Foundation
import GRDB

extension Store {
    /// Row counts for every report and filter, keyed `"reportID.filterID"`.
    ///
    /// Fifty-three separate `COUNT(*)` queries at a live crawl's refresh cadence
    /// is not viable, so this is one conditional-aggregation pass over the shared
    /// join instead: one scan, all counts.
    public func counts(for reports: [Report]) throws -> [String: Int] {
        let pairs = reports.flatMap { report in
            report.filters.map { filter in
                (key: "\(report.id).\(filter.id)",
                 sql: "(\(report.predicate)) AND (\(filter.predicate))",
                 arguments: filter.arguments)
            }
        }
        guard !pairs.isEmpty else { return [:] }

        var out: [String: Int] = [:]
        try dbQueue.read { db in
            // Chunked so this can never quietly hit SQLite's per-statement column
            // limit as reports are added. The limit is far above 53 today; a
            // silent truncation at the boundary would be very hard to notice.
            for chunk in stride(from: 0, to: pairs.count, by: Self.countsPerStatement) {
                let slice = pairs[chunk..<min(chunk + Self.countsPerStatement, pairs.count)]
                // Aliases are positional rather than derived from ids, so a report
                // id containing a character SQLite dislikes cannot break the query.
                let selected = slice.enumerated()
                    .map { "coalesce(sum(CASE WHEN \($1.sql) THEN 1 ELSE 0 END), 0) AS n\($0)" }
                    .joined(separator: ", ")
                // Arguments concatenate in the order their predicates appear in
                // the SELECT, which is the order the placeholders are bound in.
                let arguments = slice.flatMap(\.arguments)
                guard let row = try Row.fetchOne(db, sql: "SELECT \(selected) \(ReportSQL.from)",
                                                 arguments: StatementArguments(arguments))
                else { continue }
                for (offset, pair) in slice.enumerated() {
                    out[pair.key] = row["n\(offset)"] ?? 0
                }
            }
        }
        return out
    }

    static let countsPerStatement = 200
}
