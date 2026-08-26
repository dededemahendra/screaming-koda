import KodaCore

public struct SidebarItem: Identifiable, Equatable, Sendable {
    public let reportID: String
    public let filterID: String
    public let reportName: String
    public let filterName: String
    /// nil before the crawl has counted this filter. Distinct from 0, which is
    /// a measurement: "we checked and found none".
    public let count: Int?
    public let severity: Severity?

    public var id: String { "\(reportID).\(filterID)" }
}

public struct SidebarBand: Identifiable, Equatable, Sendable {
    public let severity: Severity
    public let items: [SidebarItem]

    public var id: String { severity.rawValue }
    public var total: Int { items.reduce(0) { $0 + ($1.count ?? 0) } }
}

public struct SidebarSection: Identifiable, Equatable, Sendable {
    public let reportID: String
    public let reportName: String
    public let items: [SidebarItem]

    public var id: String { reportID }
}

/// What the sidebar shows, decided without drawing anything.
///
/// Both halves narrow from one search field, so the same matching rule has to
/// serve them: it matches the filter's name or its report's name, because
/// typing "canonical" should find the Canonicals tab as well as the canonical
/// findings scattered through other reports.
public enum SidebarModel {

    public static func bands(reports: [Report], counts: [String: Int],
                             search: String = "") -> [SidebarBand] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return Severity.allCases.compactMap { severity in
            var items: [SidebarItem] = []
            for report in reports {
                for filter in report.filters where filter.severity == severity {
                    guard matches(query, report: report, filter: filter) else { continue }
                    // A finding that found nothing is not a finding. The clean
                    // case is stated once, in the finished-crawl state, rather
                    // than as a hundred rows of zero above the ones that matter.
                    guard let count = counts["\(report.id).\(filter.id)"], count > 0
                    else { continue }
                    items.append(item(report, filter, count))
                }
            }
            guard !items.isEmpty else { return nil }
            return SidebarBand(severity: severity, items: items.sorted(by: worstFirst))
        }
    }

    public static func sections(reports: [Report], counts: [String: Int],
                                search: String = "") -> [SidebarSection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return reports.compactMap { report in
            let items = report.filters
                .filter { matches(query, report: report, filter: $0) }
                .map { item(report, $0, counts["\(report.id).\($0.id)"]) }
            guard !items.isEmpty else { return nil }
            return SidebarSection(reportID: report.id, reportName: report.name, items: items)
        }
    }

    /// Findings, not pages: one page failing three checks is three findings.
    /// Two reports asking the same question count twice — Not HTTPS appears
    /// under both URL Structure and Security — which is right for "how much is
    /// there to look at" and wrong for "how many pages are broken". The header
    /// that shows this says findings.
    public static func findingTotal(reports: [Report], counts: [String: Int]) -> Int {
        var total = 0
        for report in reports {
            for filter in report.filters where filter.severity != nil {
                total += counts["\(report.id).\(filter.id)"] ?? 0
            }
        }
        return total
    }

    /// The sidebar header's second line.
    ///
    /// Formatting goes through `.formatted()` so the grouping separator is the
    /// reader's, not the author's. This is worth stating because it looked like
    /// a bug during design: the URL cap read "500.000", which is correct
    /// grouping in en_ID and reads as five hundred to anyone expecting en_AU.
    /// Hand-rolling a separator would make it genuinely wrong everywhere else.
    public static func findingSummary(_ total: Int) -> String {
        switch total {
        case 0: return "No findings"
        case 1: return "1 finding"
        default: return "\(total.formatted()) findings"
        }
    }

    private static func item(_ report: Report, _ filter: ReportFilter,
                             _ count: Int?) -> SidebarItem {
        SidebarItem(reportID: report.id, filterID: filter.id,
                    reportName: report.name, filterName: filter.name,
                    count: count, severity: filter.severity)
    }

    /// Count descending, then by name. The tiebreak is not cosmetic: without
    /// it, two filters on the same count swap places between reloads as the
    /// counts dictionary re-enumerates, and a list that reorders itself twice a
    /// second during a crawl cannot be read.
    private static func worstFirst(_ a: SidebarItem, _ b: SidebarItem) -> Bool {
        let left = a.count ?? 0, right = b.count ?? 0
        if left != right { return left > right }
        if a.reportName != b.reportName { return a.reportName < b.reportName }
        return a.filterName < b.filterName
    }

    private static func matches(_ query: String, report: Report,
                                filter: ReportFilter) -> Bool {
        guard !query.isEmpty else { return true }
        return filter.name.localizedStandardContains(query)
            || report.name.localizedStandardContains(query)
    }
}
