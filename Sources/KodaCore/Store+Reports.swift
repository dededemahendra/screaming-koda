import Foundation
import GRDB

/// One row of a report, already rendered for display.
///
/// Cells are positional, matching the report's `columns`. A `nil` cell is a
/// genuine SQL NULL and stays distinct from `""`: "this page has no title" and
/// "this page's title is empty" are different findings.
public struct ReportRow: Sendable, Identifiable, Equatable {
    public let id: Int64
    public let cells: [String?]

    public init(id: Int64, cells: [String?]) {
        self.id = id
        self.cells = cells
    }
}

extension Store {
    /// The ordered ids of every row matching `report` narrowed by `filter`.
    ///
    /// Holding the ids, rather than paging with `LIMIT`/`OFFSET`, is what makes
    /// row 400,000 as cheap to reach as row 1 — see `RowIndex`.
    public func ids(for report: Report, filter: ReportFilter,
                    sortBy: ReportColumn?, ascending: Bool) throws -> [Int64] {
        try dbQueue.read { db in
            try Int64.fetchAll(db,
                sql: Self.idsSQL(report: report, filter: filter,
                                 sortBy: sortBy, ascending: ascending),
                arguments: StatementArguments(filter.arguments))
        }
    }

    /// Split out so the "every filter is valid SQL" test can prepare the exact
    /// statement that would run, without needing rows to match it.
    static func idsSQL(report: Report, filter: ReportFilter,
                       sortBy: ReportColumn?, ascending: Bool) -> String {
        let direction = ascending ? "ASC" : "DESC"
        // Nulls last in BOTH directions, per M3a: a table sorted by status should
        // open on real statuses whichever way the arrow points.
        let order: String
        if let sortBy {
            order = "(\(sortBy.expression)) IS NULL ASC, (\(sortBy.expression)) \(direction), u.id ASC"
        } else {
            order = "u.id \(direction)"
        }
        return """
            SELECT u.id
            \(ReportSQL.from)
            WHERE (\(report.predicate)) AND (\(filter.predicate))
            ORDER BY \(order)
            """
    }

    /// Fetches the contents of a slice of ids by primary key, with no predicate,
    /// so the cost is O(slice) however deep into the crawl the slice falls.
    public func rows(ids: [Int64], columns: [ReportColumn]) throws -> [ReportRow] {
        guard !ids.isEmpty, !columns.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let selected = columns.enumerated()
            .map { "(\($1.expression)) AS c\($0)" }
            .joined(separator: ", ")

        let fetched: [Int64: ReportRow] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.id AS row_id, \(selected)
                \(ReportSQL.from)
                WHERE u.id IN (\(placeholders))
                """, arguments: StatementArguments(ids))
            .reduce(into: [:]) { acc, row in
                let id: Int64 = row["row_id"]
                let cells = (0..<columns.count).map { Self.display(row["c\($0)"]) }
                acc[id] = ReportRow(id: id, cells: cells)
            }
        }
        // `IN` returns rows in whatever order SQLite likes, so restore the order
        // that was asked for. Without this the table shows correct rows in the
        // wrong places, which looks like corruption rather than a sorting bug.
        return ids.compactMap { fetched[$0] }
    }

    /// The single place a database value becomes display text, so every report
    /// renders the same type the same way.
    static func display(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .null:
            return nil
        case .int64(let i):
            return String(i)
        case .double(let d):
            // Whole doubles read badly as "404.0" in a status column.
            return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .string(let s):
            return s
        case .blob(let data):
            // Content hashes are the only blobs a report can surface; a short
            // prefix is enough to compare two rows by eye.
            return data.prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }
}
