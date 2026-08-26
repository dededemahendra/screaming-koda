import Foundation

/// A field a custom report can filter or display.
///
/// A closed catalogue, not free SQL. That is the whole safety story: the field
/// and the comparison are chosen from fixed sets, and only the value a person
/// types is variable — and that is bound as a parameter, never interpolated. A
/// report builder that took raw SQL would be handing anyone who opens a shared
/// configuration the ability to run `DROP TABLE` against the crawl.
public struct QueryField: Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public let expression: String
    public let kind: Kind

    public enum Kind: Sendable, Equatable { case text, number }

    public init(id: String, label: String, expression: String, kind: Kind) {
        self.id = id
        self.label = label
        self.expression = expression
        self.kind = kind
    }
}

public enum Comparison: String, Codable, Sendable, CaseIterable {
    case equals, notEquals, contains, notContains, startsWith, endsWith
    case greaterThan, lessThan, isEmpty, isNotEmpty

    public var label: String {
        switch self {
        case .equals: return "is"
        case .notEquals: return "is not"
        case .contains: return "contains"
        case .notContains: return "does not contain"
        case .startsWith: return "starts with"
        case .endsWith: return "ends with"
        case .greaterThan: return "is greater than"
        case .lessThan: return "is less than"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        }
    }

    /// Whether the comparison needs a value at all.
    public var needsValue: Bool {
        self != .isEmpty && self != .isNotEmpty
    }

    /// Which field kinds it makes sense on. "Contains" on a number, or
    /// "greater than" on a title, are offered by nobody sensible.
    public func suits(_ kind: QueryField.Kind) -> Bool {
        switch self {
        case .greaterThan, .lessThan: return kind == .number
        case .contains, .notContains, .startsWith, .endsWith: return kind == .text
        default: return true
        }
    }
}

public struct CustomCondition: Codable, Sendable, Equatable {
    public var field: String
    public var comparison: Comparison
    public var value: String

    public init(field: String, comparison: Comparison, value: String = "") {
        self.field = field
        self.comparison = comparison
        self.value = value
    }
}

/// A report someone defined themselves.
public struct CustomReport: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// ANDed together. Deliberately not a full boolean expression tree: nested
    /// AND/OR is a query language, and someone who needs one has SQL and the
    /// `.koda` file.
    public var conditions: [CustomCondition]
    /// Field ids to show. Empty means a sensible default set.
    public var columns: [String]

    public init(id: String = UUID().uuidString, name: String,
                conditions: [CustomCondition] = [], columns: [String] = []) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.columns = columns
    }
}

public enum CustomReports {
    /// Everything a custom report can ask about.
    public static let fields: [QueryField] = [
        .init(id: "address", label: "Address", expression: "u.url", kind: .text),
        .init(id: "path", label: "Path", expression: "u.path", kind: .text),
        .init(id: "status", label: "Status code", expression: "r.status", kind: .number),
        .init(id: "contentType", label: "Content type", expression: "r.content_type", kind: .text),
        .init(id: "indexability", label: "Indexability",
              expression: "(\(Indexability.expression))", kind: .text),
        .init(id: "title", label: "Title", expression: "f.title", kind: .text),
        .init(id: "titleLength", label: "Title length", expression: "f.title_length", kind: .number),
        .init(id: "titlePixels", label: "Title width", expression: "f.title_pixels", kind: .number),
        .init(id: "description", label: "Meta description",
              expression: "f.meta_description", kind: .text),
        .init(id: "descriptionLength", label: "Description length",
              expression: "f.meta_description_length", kind: .number),
        .init(id: "h1", label: "H1", expression: "f.h1", kind: .text),
        .init(id: "h2", label: "H2", expression: "f.h2", kind: .text),
        .init(id: "wordCount", label: "Word count", expression: "f.word_count", kind: .number),
        .init(id: "textLength", label: "Text length", expression: "f.text_length", kind: .number),
        .init(id: "depth", label: "Crawl depth", expression: "u.depth", kind: .number),
        .init(id: "inlinks", label: "Inlinks",
              expression: "(SELECT count(DISTINCT from_url_id) FROM links WHERE to_url_id = u.id)",
              kind: .number),
        .init(id: "size", label: "Size in bytes", expression: "r.content_length", kind: .number),
        .init(id: "responseTime", label: "Response time",
              expression: "r.response_time_ms", kind: .number),
        .init(id: "canonical", label: "Canonical",
              expression: "(SELECT cu.url FROM urls cu WHERE cu.id = f.canonical_id)", kind: .text),
        .init(id: "metaRobots", label: "Meta robots", expression: "f.meta_robots", kind: .text),
        .init(id: "lang", label: "Language", expression: "f.lang", kind: .text),
        .init(id: "analytics", label: "Tracking", expression: "f.analytics", kind: .text),
        .init(id: "ogTitle", label: "og:title", expression: "f.og_title", kind: .text),
        .init(id: "inSitemap", label: "In sitemap", expression: "u.in_sitemap", kind: .number),
        .init(id: "renderedWords", label: "Rendered words",
              expression: "r.rendered_words", kind: .number),
        .init(id: "clicks", label: "Clicks (Search Console)",
              expression: """
                  (SELECT m.value FROM external_metrics m
                   WHERE m.url_id = u.id AND m.source = 'gsc' AND m.metric = 'Clicks')
                  """, kind: .number),
        .init(id: "sessions", label: "Sessions (Analytics)",
              expression: """
                  (SELECT m.value FROM external_metrics m
                   WHERE m.url_id = u.id AND m.source = 'ga4' AND m.metric = 'Sessions')
                  """, kind: .number),
    ]

    public static func field(_ id: String) -> QueryField? {
        fields.first { $0.id == id }
    }

    static let defaultColumns = ["address", "status", "indexability", "title", "wordCount"]

    /// Turns a definition into a real `Report`, which then works everywhere a
    /// built-in one does — the table, sorting, the sidebar, the exports.
    ///
    /// Returns nil when nothing survives validation: a report whose every
    /// condition names a field that no longer exists would otherwise silently
    /// become "show me everything".
    public static func compile(_ custom: CustomReport) -> Report? {
        var clauses: [String] = []
        var arguments: [String] = []

        for condition in custom.conditions {
            guard let field = field(condition.field),
                  condition.comparison.suits(field.kind) else { continue }
            let expression = field.expression

            switch condition.comparison {
            case .isEmpty:
                clauses.append("(\(expression) IS NULL OR trim(CAST(\(expression) AS TEXT)) = '')")
                continue
            case .isNotEmpty:
                clauses.append("(\(expression) IS NOT NULL AND trim(CAST(\(expression) AS TEXT)) != '')")
                continue
            default:
                break
            }

            let value = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }

            switch condition.comparison {
            case .equals:
                clauses.append("\(expression) = ?"); arguments.append(value)
            case .notEquals:
                // IS NOT, so a row whose value is NULL still counts as "not X".
                clauses.append("\(expression) IS NOT ?"); arguments.append(value)
            case .contains:
                clauses.append("lower(CAST(\(expression) AS TEXT)) LIKE ?")
                arguments.append("%\(value.lowercased())%")
            case .notContains:
                clauses.append("coalesce(lower(CAST(\(expression) AS TEXT)) LIKE ?, 0) = 0")
                arguments.append("%\(value.lowercased())%")
            case .startsWith:
                clauses.append("lower(CAST(\(expression) AS TEXT)) LIKE ?")
                arguments.append("\(value.lowercased())%")
            case .endsWith:
                clauses.append("lower(CAST(\(expression) AS TEXT)) LIKE ?")
                arguments.append("%\(value.lowercased())")
            case .greaterThan:
                guard Double(value) != nil else { continue }
                clauses.append("\(expression) > CAST(? AS REAL)"); arguments.append(value)
            case .lessThan:
                guard Double(value) != nil else { continue }
                clauses.append("\(expression) < CAST(? AS REAL)"); arguments.append(value)
            case .isEmpty, .isNotEmpty:
                break
            }
        }

        guard !clauses.isEmpty else { return nil }

        let chosen = custom.columns.isEmpty ? defaultColumns : custom.columns
        let columns = chosen.compactMap(field).map {
            ReportColumn(id: $0.id, header: $0.label, expression: $0.expression,
                         width: $0.kind == .number ? 90 : 240,
                         alignment: $0.kind == .number ? .trailing : .leading)
        }
        guard !columns.isEmpty else { return nil }

        return Report(
            id: "custom_\(custom.id)",
            name: custom.name.isEmpty ? "Custom" : custom.name,
            // Internal page URLs, crawled or not. Deliberately not restricted to
            // HTML 200s the way the content reports are: a custom report asking
            // "status is 404" or "was never crawled" is a perfectly reasonable
            // thing to want, and a base that excluded those would make those
            // questions unanswerable. `status` is one of the fields, so anyone
            // who wants only live pages can say so.
            predicate: "u.is_internal = 1 AND \(Reports.pageRows)",
            columns: columns,
            filters: [
                ReportFilter(id: "all", name: "All", predicate: "1"),
                ReportFilter(id: "matching", name: custom.name.isEmpty ? "Matching" : custom.name,
                             predicate: clauses.joined(separator: " AND "),
                             arguments: arguments, severity: .hygiene),
            ])
    }

    /// A custom report opens on its own condition rather than on "All": someone
    /// who defined a filter wants to see what it found.
    public static let defaultFilterID = "matching"
}
