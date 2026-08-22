import Foundation

/// Whether a report is an inventory of what exists or a list of things to fix.
/// A crawl summary that reports "4 internal URLs" as a finding trains people to
/// ignore the findings list, so the two are kept apart.
public enum ReportKind: String, Sendable, Hashable {
    case inventory
    case issue
}

/// A report is a name, a SQL query, and a column list. Adding one is a new value
/// in `ReportCatalogue.all`, not new code — which is what keeps the eventual UI
/// from having to know anything about SEO rules.
public struct ReportDefinition: Sendable, Identifiable, Hashable {
    /// Stable slug. Used by the CLI and, later, by saved UI state.
    public let id: String
    /// The tab this belongs under.
    public let group: String
    /// The filter name within its group.
    public let name: String
    /// Inventory or issue. Only issues are surfaced as findings.
    public let kind: ReportKind
    /// One line explaining what the rule actually means.
    public let summary: String
    /// Display titles, in order. These must match the query's result columns;
    /// `reportColumnsMatchTheirQueries` in the test suite enforces it.
    public let columns: [String]
    /// A complete SELECT, ordered, with no trailing semicolon and no LIMIT.
    public let sql: String

    public init(
        id: String, group: String, name: String, kind: ReportKind = .issue,
        summary: String, columns: [String], sql: String
    ) {
        self.id = id
        self.group = group
        self.name = name
        self.kind = kind
        self.summary = summary
        self.columns = columns
        self.sql = sql
    }

    /// "Titles / Duplicate", for display and CLI output.
    public var qualifiedName: String { "\(group) / \(name)" }
}
