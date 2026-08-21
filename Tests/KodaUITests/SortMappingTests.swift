import AppKit
import Testing
@testable import KodaCore
@testable import KodaUI

@MainActor
private func coordinator(_ report: Report) -> URLTableCoordinator {
    URLTableCoordinator(rows: nil, report: report)
}

@MainActor
@Test func aSortDescriptorMapsToAColumnAndDirection() {
    let resolved = coordinator(Reports.internalURLs)
        .sort(from: NSSortDescriptor(key: "status", ascending: false))
    #expect(resolved?.columnID == "status")
    #expect(resolved?.ascending == false)
}

@MainActor
@Test func anUnknownSortDescriptorResolvesToNil() {
    #expect(coordinator(Reports.internalURLs)
        .sort(from: NSSortDescriptor(key: "nonsense", ascending: true)) == nil)
}

/// The allow-list in practice. A descriptor left over from another tab names a
/// column this report does not declare, so it resolves to nil instead of
/// interpolating an expression that report never offered.
@MainActor
@Test func aColumnFromAnotherReportResolvesToNil() {
    #expect(Reports.internalURLs.column(id: "canonical") == nil)
    #expect(coordinator(Reports.internalURLs)
        .sort(from: NSSortDescriptor(key: "canonical", ascending: true)) == nil)
    #expect(coordinator(Reports.canonicals)
        .sort(from: NSSortDescriptor(key: "canonical", ascending: true))?.columnID == "canonical")
}

/// Nothing user-typed can reach the ORDER BY: resolution is a lookup, and there
/// is no expression to interpolate for an id no report declares.
@MainActor
@Test func aSQLInjectionAttemptInASortKeyResolvesToNil() {
    let nasty = NSSortDescriptor(key: "u.url; DROP TABLE urls; --", ascending: true)
    for report in Reports.all {
        #expect(coordinator(report).sort(from: nasty) == nil, "\(report.id) accepted it")
    }
}

@MainActor
@Test func everyReportOffersAtLeastOneSortableColumn() {
    for report in Reports.all {
        let sortable = report.columns.filter { $0.sortable }
        #expect(!sortable.isEmpty, "\(report.id) has nothing to sort by")
    }
}
