import Foundation

/// How a column's text sits in its cell. Deliberately not `NSTextAlignment`:
/// `KodaCore` builds and tests headless, and a report definition is the wrong
/// place to acquire an AppKit dependency.
public enum ColumnAlignment: Sendable {
    case leading, trailing
}

public struct ReportColumn: Sendable, Identifiable, Equatable {
    /// Stable key, also the SQL alias and the `NSTableColumn` identifier. Must be
    /// unique within its report — two columns sharing an id would shadow each
    /// other in the SELECT and silently show the same value twice.
    public let id: String
    public let header: String
    /// SQL, evaluated against `ReportSQL.from`. Always a literal in `Reports.all`,
    /// never anything derived from user input.
    public let expression: String
    public let width: Double
    public let alignment: ColumnAlignment
    public let sortable: Bool

    public init(
        id: String, header: String, expression: String, width: Double,
        alignment: ColumnAlignment = .leading, sortable: Bool = true
    ) {
        self.id = id
        self.header = header
        self.expression = expression
        self.width = width
        self.alignment = alignment
        self.sortable = sortable
    }
}

public struct ReportFilter: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    /// ANDed with the report's own predicate. `"1"` for an unfiltered view.
    ///
    /// Built-in filters are compile-time constants. A user-defined one carries
    /// `?` placeholders and supplies `arguments` for them, so nothing a person
    /// typed is ever interpolated into SQL.
    public let predicate: String
    /// Values bound to the placeholders in `predicate`, in order.
    public let arguments: [String]
    /// Which band this finding belongs to, or nil when the filter is not a
    /// finding at all. "All" and "Success (2xx)" are navigation aids.
    ///
    /// An optional rather than a `Bool` plus a band: the two could contradict
    /// each other, and a filter that claimed to be an issue with no band would
    /// have nowhere to appear in the sidebar.
    public let severity: Severity?

    public init(id: String, name: String, predicate: String,
                arguments: [String] = [], severity: Severity? = nil) {
        self.id = id
        self.name = name
        self.predicate = predicate
        self.arguments = arguments
        self.severity = severity
    }

    /// Whether this filter describes a problem at all.
    public var isFinding: Bool { severity != nil }
}

public struct Report: Sendable, Identifiable, Equatable {
    public let id: String
    /// The tab label.
    public let name: String
    /// What belongs in this tab at all, before any filter narrows it.
    public let predicate: String
    public let columns: [ReportColumn]
    /// The first entry is the default and is expected to be the unfiltered one.
    public let filters: [ReportFilter]

    public init(id: String, name: String, predicate: String,
                columns: [ReportColumn], filters: [ReportFilter]) {
        self.id = id
        self.name = name
        self.predicate = predicate
        self.columns = columns
        self.filters = filters
    }

    /// Resolving a sort key by lookup is what keeps user input out of SQL: a
    /// header click yields a column id, and an id this report does not declare
    /// has no expression to interpolate, so it simply does not sort.
    public func column(id: String) -> ReportColumn? {
        columns.first { $0.id == id }
    }

    public var defaultFilter: ReportFilter {
        filters[0]
    }
}

public enum ReportSQL {
    /// The one join every report reads from. Reports needing more — inlink
    /// counts, image alt aggregates — use a correlated subquery in a column
    /// expression rather than extending this, so all eleven share a query plan.
    public static let from = """
        FROM urls u
        LEFT JOIN responses r ON r.url_id = u.id
        LEFT JOIN page_facts f ON f.url_id = u.id
        """
}
