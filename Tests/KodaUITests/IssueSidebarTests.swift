import SwiftUI
import Testing
@testable import KodaCore
@testable import KodaUI

/// Grouping separators come from the locale, which is why this asserts the
/// count is formatted at all rather than asserting a particular separator. A
/// hand-rolled separator would be wrong on every machine but the author's —
/// "500.000" is correct in en_ID and would look like a bug to anyone reading
/// it as en_AU.
@Test func theFindingSummaryReadsAsEnglishAndGroupsItsDigits() {
    #expect(SidebarModel.findingSummary(0) == "No findings")
    #expect(SidebarModel.findingSummary(1) == "1 finding")
    #expect(SidebarModel.findingSummary(2) == "2 findings")
    #expect(SidebarModel.findingSummary(1204) == "\(1204.formatted()) findings")
}

@MainActor
@Test func theSidebarDrawsItsBandsAndSections() {
    let counts = ["responseCodes.clientError": 12, "titles.missing": 4,
                  "urls.underscore": 30, "internal.all": 500]
    let sidebar = IssueSidebar(reports: Reports.all, counts: counts,
                               crawlName: "example.com",
                               selectedReportID: "internal", selectedFilterID: "all",
                               onSelect: { _, _ in })
    ViewCapture.expectNotBlank(sidebar.frame(width: 260, height: 700),
                               size: CGSize(width: 260, height: 700),
                               "the issue sidebar with findings")
}

/// A crawl that found nothing must still draw a usable sidebar, not an empty
/// column — the report sections are what is left to browse.
@MainActor
@Test func theSidebarDrawsWithNoFindingsAtAll() {
    let sidebar = IssueSidebar(reports: Reports.all, counts: ["internal.all": 40],
                               crawlName: "example.com",
                               selectedReportID: "internal", selectedFilterID: "all",
                               onSelect: { _, _ in })
    ViewCapture.expectNotBlank(sidebar.frame(width: 260, height: 700),
                               size: CGSize(width: 260, height: 700),
                               "the issue sidebar with a clean crawl")
}

@MainActor
@Test func theSidebarDrawsBeforeAnyCrawlHasCounted() {
    let sidebar = IssueSidebar(reports: Reports.all, counts: [:], crawlName: nil,
                               selectedReportID: "internal", selectedFilterID: "all",
                               onSelect: { _, _ in })
    ViewCapture.expectNotBlank(sidebar.frame(width: 260, height: 700),
                               size: CGSize(width: 260, height: 700),
                               "the issue sidebar before a crawl")
}
