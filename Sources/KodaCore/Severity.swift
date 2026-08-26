/// How much a finding costs, in the order a person would work through them.
///
/// Lives in `KodaCore` rather than in the sidebar that ranks by it: the window,
/// the export and the CLI all list findings, and severity held in a view would
/// let them disagree about what matters. The crawl summary and the reports
/// already diverged once for exactly that reason.
public enum Severity: String, Sendable, CaseIterable, Comparable {
    /// The page cannot rank, or the crawler could not reach it.
    case breaksIndexing
    /// The page is indexed but underperforms in results.
    case costsClicks
    /// Worth fixing, not costing traffic today.
    case hygiene

    public var title: String {
        switch self {
        case .breaksIndexing: return "Breaks indexing"
        case .costsClicks: return "Costs clicks"
        case .hygiene: return "Hygiene"
        }
    }

    /// Declaration order is the working order, and `<` follows it, so sorting a
    /// collection of bands yields the order they should be read in.
    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs)
        else { return false }
        return left < right
    }
}
