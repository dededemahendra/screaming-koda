import Testing
@testable import KodaCore
@testable import KodaUI

private let internalReport = Reports.all.first { $0.id == "internal" }!

@Test func addressAbsorbsWhateverIsLeftOver() {
    // Derived rather than hard-coded: Internal's eleven fixed columns already
    // total more than the minimum window width, which is the bug below.
    let fixed = internalReport.columns.dropFirst().reduce(0) { $0 + $1.width }
    let pane = fixed + 600
    let widths = ColumnLayout.widths(for: internalReport, paneWidth: pane)
    #expect(widths.reduce(0, +) == pane)
    #expect(widths[0] == 600)
    // Every column but the first keeps the width its definition asked for.
    #expect(Array(widths.dropFirst())
            == internalReport.columns.dropFirst().map(\.width))
}

/// The bug this task exists for: at 1100pt, twelve columns with a fixed 340pt
/// address ran off the right edge. `widths.count == columns.count` and
/// `allSatisfy { $0 > 0 }` cannot fail for any implementation, since `widths`
/// is `[max(minimumFirstColumn, …)] + rest.map(\.width)` and every declared
/// width is a positive constant — so the real property is that nothing is
/// left over and nothing is invented: whenever the pane is wide enough for
/// the fixed columns plus the minimum address width, the widths sum exactly
/// to the pane width.
@Test func noColumnFallsOffTheRightEdgeAtTheMinimumWindowWidth() {
    let minimumFirstColumn = 220.0
    for pane in stride(from: 640.0, through: 2400.0, by: 40.0) {
        for report in Reports.all {
            let fixed = report.columns.dropFirst().reduce(0) { $0 + $1.width }
            let widths = ColumnLayout.widths(for: report, paneWidth: pane)
            #expect(widths.count == report.columns.count)
            if pane >= fixed + minimumFirstColumn {
                #expect(widths.reduce(0, +) == pane,
                        "\(report.id) at pane width \(pane) left space unfilled or overflowed")
            }
        }
    }
}

/// Below the point where the address would become unreadable, nothing shrinks
/// and the table scrolls instead. Squeezing a URL to 40pt helps nobody.
@Test func theAddressStopsShrinkingRatherThanBecomingUnreadable() {
    let narrow = ColumnLayout.widths(for: internalReport, paneWidth: 300)
    #expect(narrow[0] == 220)
    #expect(narrow.reduce(0, +) > 300)
}

@Test func aReportWithOneColumnGivesItTheWholePane() {
    let single = Report(id: "one", name: "One", predicate: "1",
                        columns: [ReportColumn(id: "address", header: "Address",
                                               expression: "u.url", width: 340)],
                        filters: [ReportFilter(id: "all", name: "All", predicate: "1")])
    #expect(ColumnLayout.widths(for: single, paneWidth: 900) == [900])
}

@Test func theStatusAndIndexabilityColumnsDeclareWhatTheyMean() {
    #expect(internalReport.column(id: "status")?.semantic == .status)
    #expect(internalReport.column(id: "indexability")?.semantic == .indexability)
    #expect(internalReport.column(id: "title")?.semantic == nil)
}

@MainActor
@Test func aStatusCellTakesItsInkFromTheCode() {
    #expect(URLTableCoordinator.ink(for: "404", semantic: .status) == Theme.Ink.critical)
    #expect(URLTableCoordinator.ink(for: "301", semantic: .status) == Theme.Ink.warning)
    #expect(URLTableCoordinator.ink(for: "200", semantic: .status) == nil)
    #expect(URLTableCoordinator.ink(for: "", semantic: .status) == nil)
    #expect(URLTableCoordinator.ink(for: Indexability.indexable, semantic: .indexability) == nil)
    #expect(URLTableCoordinator.ink(for: "Noindex", semantic: .indexability)
            == Theme.Ink.critical)
    #expect(URLTableCoordinator.ink(for: "Home", semantic: nil) == nil)
}
