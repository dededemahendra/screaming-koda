import Foundation
import GRDB

/// A report plus the table's current sort and filter.
///
/// Sorting and filtering wrap the report's own SQL in an outer SELECT, so no
/// report definition has to know either exists, and adding a report stays a
/// matter of writing one query.
public struct ReportQuery: Sendable, Hashable {
    public enum Direction: String, Sendable, Hashable {
        case ascending = "ASC"
        case descending = "DESC"

        public var reversed: Direction { self == .ascending ? .descending : .ascending }
    }

    public let definition: ReportDefinition
    /// Index into `definition.columns`. Nil keeps the report's own ordering.
    public var sortColumn: Int?
    public var direction: Direction
    /// Free text matched against every column. Empty means no filter.
    public var filter: String

    public init(definition: ReportDefinition, sortColumn: Int? = nil,
                direction: Direction = .ascending, filter: String = "") {
        self.definition = definition
        self.sortColumn = sortColumn
        self.direction = direction
        self.filter = filter
    }

    /// A column identifier is only ever taken from the definition by index, never
    /// from anything the user typed, so a sort cannot become an injection. The
    /// quoting below is belt and braces on top of that.
    var sortColumnName: String? {
        guard let sortColumn, definition.columns.indices.contains(sortColumn) else { return nil }
        return definition.columns[sortColumn]
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// SQL plus its arguments. Filter text is bound, never interpolated.
    func sql(limit: Int?, offset: Int) -> (String, StatementArguments) {
        var arguments: [DatabaseValueConvertible] = []
        var sql = "SELECT * FROM (\(definition.sql))"

        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            // ESCAPE makes %, _ and the escape character itself literal. Without it
            // a user searching for "50%" would match every row.
            let pattern = "%" + trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            let clauses = definition.columns.map {
                "coalesce(\(Self.quoted($0)), '') LIKE ? ESCAPE '\\'"
            }
            sql += " WHERE (" + clauses.joined(separator: " OR ") + ")"
            arguments.append(contentsOf: Array(repeating: pattern, count: definition.columns.count))
        }

        if let sortColumnName {
            sql += " ORDER BY \(Self.quoted(sortColumnName)) \(direction.rawValue)"
        }
        if let limit {
            sql += " LIMIT \(limit) OFFSET \(offset)"
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET \(offset)"
        }
        return (sql, StatementArguments(arguments))
    }
}

extension Store {
    /// One window of a report, rendered as text.
    public func rows(for query: ReportQuery, limit: Int? = nil, offset: Int = 0) throws -> [[String?]] {
        let (sql, arguments) = query.sql(limit: limit, offset: offset)
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                (0..<row.count).map { Self.text(row[$0]) }
            }
        }
    }

    /// Row count after filtering, for the scrollbar and the row-count label.
    public func count(for query: ReportQuery) throws -> Int {
        var stripped = query
        stripped.sortColumn = nil
        let (sql, arguments) = stripped.sql(limit: nil, offset: 0)
        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM (\(sql))", arguments: arguments) ?? 0
        }
    }
}
