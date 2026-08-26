import Testing
@testable import KodaCore
@testable import KodaUI

private let sample: [Report] = [
    Report(id: "codes", name: "Response Codes", predicate: "1",
           columns: [ReportColumn(id: "a", header: "A", expression: "u.url", width: 100)],
           filters: [
               ReportFilter(id: "all", name: "All", predicate: "1"),
               ReportFilter(id: "gone", name: "Client error (4xx)",
                            predicate: "1", severity: .breaksIndexing),
               ReportFilter(id: "server", name: "Server error (5xx)",
                            predicate: "1", severity: .breaksIndexing),
           ]),
    Report(id: "titles", name: "Titles", predicate: "1",
           columns: [ReportColumn(id: "a", header: "A", expression: "u.url", width: 100)],
           filters: [
               ReportFilter(id: "all", name: "All", predicate: "1"),
               ReportFilter(id: "missing", name: "Missing", predicate: "1",
                            severity: .costsClicks),
           ]),
    Report(id: "urls", name: "URL Structure", predicate: "1",
           columns: [ReportColumn(id: "a", header: "A", expression: "u.url", width: 100)],
           filters: [
               ReportFilter(id: "all", name: "All", predicate: "1"),
               ReportFilter(id: "underscore", name: "Underscores in path",
                            predicate: "1", severity: .hygiene),
           ]),
]

private let counts = [
    "codes.all": 100, "codes.gone": 4, "codes.server": 9,
    "titles.all": 80, "titles.missing": 12,
    "urls.all": 80, "urls.underscore": 3,
]

@Test func bandsComeBackInWorkingOrder() {
    let bands = SidebarModel.bands(reports: sample, counts: counts)
    #expect(bands.map(\.severity) == [.breaksIndexing, .costsClicks, .hygiene])
}

@Test func theWorstFindingInABandIsListedFirst() {
    let bands = SidebarModel.bands(reports: sample, counts: counts)
    #expect(bands[0].items.map(\.filterID) == ["server", "gone"])
    #expect(bands[0].total == 13)
}

/// A tie must not reorder between two runs of the same crawl. Sorting by count
/// alone leaves equal counts in whatever order the dictionary produced them.
@Test func tiedCountsFallBackToNames() {
    let tied = ["codes.gone": 5, "codes.server": 5, "titles.missing": 1]
    let bands = SidebarModel.bands(reports: sample, counts: tied)
    #expect(bands[0].items.map(\.filterName) == ["Client error (4xx)", "Server error (5xx)"])
}

/// "We checked and it's clean" belongs in the finished-crawl state, not as 112
/// rows of zero above the three findings that matter.
@Test func findingsThatFoundNothingAreNotListed() {
    let bands = SidebarModel.bands(reports: sample,
                                   counts: ["codes.gone": 0, "titles.missing": 2])
    #expect(bands.map(\.severity) == [.costsClicks])
}

@Test func anEmptyBandIsAbsentRatherThanAnEmptyHeading() {
    let bands = SidebarModel.bands(reports: sample, counts: ["titles.missing": 2])
    #expect(bands.count == 1)
    #expect(bands[0].severity == .costsClicks)
}

@Test func navigationFiltersNeverAppearInABand() {
    let bands = SidebarModel.bands(reports: sample, counts: counts)
    #expect(!bands.flatMap(\.items).contains { $0.filterID == "all" })
}

@Test func searchMatchesAFilterName() {
    let bands = SidebarModel.bands(reports: sample, counts: counts, search: "server")
    #expect(bands.flatMap(\.items).map(\.filterID) == ["server"])
}

/// Typing a report name has to find that report's findings, or searching
/// "canonical" would miss the Canonicals tab entirely.
@Test func searchMatchesAReportName() {
    let bands = SidebarModel.bands(reports: sample, counts: counts, search: "titles")
    #expect(bands.flatMap(\.items).map(\.filterID) == ["missing"])
}

@Test func searchIgnoresCase() {
    let bands = SidebarModel.bands(reports: sample, counts: counts, search: "SERVER ERROR")
    #expect(bands.flatMap(\.items).map(\.filterID) == ["server"])
}

@Test func sectionsListEveryFilterIncludingTheNavigationOnes() {
    let sections = SidebarModel.sections(reports: sample, counts: counts)
    #expect(sections.map(\.reportID) == ["codes", "titles", "urls"])
    #expect(sections[0].items.map(\.filterID) == ["all", "gone", "server"])
}

/// Report order is the order `Reports.all` declares, not the count order the
/// bands use: browsing is a stable list you learn the shape of.
@Test func sectionsKeepDeclarationOrder() {
    let sections = SidebarModel.sections(reports: sample, counts: counts, search: "")
    #expect(sections.map(\.reportName) == ["Response Codes", "Titles", "URL Structure"])
}

@Test func searchNarrowsSectionsToo() {
    let sections = SidebarModel.sections(reports: sample, counts: counts, search: "underscore")
    #expect(sections.map(\.reportID) == ["urls"])
    #expect(sections[0].items.map(\.filterID) == ["underscore"])
}

/// A report whose own name matches keeps all of its filters, so searching
/// "titles" gives you the tab rather than one row out of it.
@Test func aReportMatchedByNameKeepsAllItsFilters() {
    let sections = SidebarModel.sections(reports: sample, counts: counts, search: "titles")
    #expect(sections.map(\.reportID) == ["titles"])
    #expect(sections[0].items.map(\.filterID) == ["all", "missing"])
}

@Test func sectionsWithNoMatchAreAbsent() {
    let sections = SidebarModel.sections(reports: sample, counts: counts, search: "zzz")
    #expect(sections.isEmpty)
}

@Test func aFilterWithNoCountYetShowsAsUnknownRatherThanZero() {
    let sections = SidebarModel.sections(reports: sample, counts: [:])
    #expect(sections[0].items.allSatisfy { $0.count == nil })
}

@Test func theFindingTotalSumsEveryFinding() {
    #expect(SidebarModel.findingTotal(reports: sample, counts: counts) == 28)
}

@Test func theFindingTotalIgnoresNavigationFilters() {
    #expect(SidebarModel.findingTotal(reports: sample, counts: ["codes.all": 999]) == 0)
}
