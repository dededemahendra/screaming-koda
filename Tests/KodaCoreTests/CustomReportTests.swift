import Foundation
import GRDB
import Testing
@testable import KodaCore

@MainActor
private func matches(_ store: Store, _ custom: CustomReport) throws -> Set<String> {
    guard let report = CustomReports.compile(custom) else { return [] }
    let filter = report.filters.first { $0.id == CustomReports.defaultFilterID }!
    let ids = try store.ids(for: report, filter: filter, sortBy: nil, ascending: true)
    return try ReportFixture.paths(store, ids)
}

private func condition(_ field: String, _ comparison: Comparison,
                       _ value: String = "") -> CustomReport {
    CustomReport(id: "t", name: "Test",
                 conditions: [CustomCondition(field: field, comparison: comparison, value: value)])
}

@MainActor
@Test func aTextConditionFindsMatchingPages() throws {
    let store = try ReportFixture.make()
    #expect(try matches(store, condition("path", .equals, "/no-title")) == ["/no-title"])
    // Matching is case-insensitive, so /social-full — "A shared title matching
    // the page title" — is a genuine hit and not a bug.
    #expect(try matches(store, condition("title", .contains, "Shared title"))
            == ["/dupe-a", "/dupe-b", "/social-full"])
}

@MainActor
@Test func aNumericConditionComparesAsANumber() throws {
    let store = try ReportFixture.make()
    // Textual comparison would put "9" above "404"; this must not.
    let deep = try matches(store, condition("depth", .greaterThan, "3"))
    #expect(deep.contains("/deep/four"))
    #expect(!deep.contains("/"))
}

@MainActor
@Test func emptyAndNotEmptyWorkWithoutAValue() throws {
    let store = try ReportFixture.make()
    #expect(try matches(store, condition("title", .isEmpty)).contains("/no-title"))
    #expect(try !matches(store, condition("title", .isNotEmpty)).contains("/no-title"))
}

/// `NULL != 'x'` is NULL in SQL rather than true, so a page with no title would
/// be missed by a naive "is not" — which is exactly when someone is looking for
/// it.
@MainActor
@Test func isNotAlsoMatchesRowsWithNoValueAtAll() throws {
    let store = try ReportFixture.make()
    #expect(try matches(store, condition("title", .notEquals, "Home")).contains("/no-title"))
}

@MainActor
@Test func conditionsCombineWithAnd() throws {
    let store = try ReportFixture.make()
    let untitled = try matches(store, condition("title", .isEmpty))
    // A custom report's base is every internal page URL, crawled or not, so a
    // URL with no page_facts row at all genuinely has no title. That is why the
    // second condition below is what narrows it.
    #expect(untitled.contains("/no-title"))
    #expect(untitled.contains("/queued"), "never fetched, so it has no title either")

    let both = CustomReport(id: "t", name: "Untitled but crawled", conditions: [
        CustomCondition(field: "title", comparison: .isEmpty),
        CustomCondition(field: "status", comparison: .equals, value: "200"),
    ])
    #expect(try matches(store, both) == ["/no-title"])
}

/// A custom report is about pages, not about images, stylesheets or other
/// people's sites.
@MainActor
@Test func aCustomReportCoversInternalPagesOnly() throws {
    let store = try ReportFixture.make()
    let everything = try matches(store, condition("address", .contains, "test"))
    #expect(!everything.contains { $0.hasPrefix("https://ext.test") })
    #expect(!everything.contains("/img/big.png"))
    #expect(everything.contains("/"))
}

// MARK: - Safety

/// The safety story in one test. The field and the comparison come from fixed
/// sets; only the value is a person's text, and it is bound rather than
/// interpolated. A report builder taking raw SQL would hand anyone who opens a
/// shared configuration the ability to drop the crawl.
@MainActor
@Test func aValueThatLooksLikeSQLIsTreatedAsText() throws {
    let store = try ReportFixture.make()
    let nasty = "'; DROP TABLE urls; --"
    #expect(try matches(store, condition("title", .equals, nasty)).isEmpty)
    #expect(try matches(store, condition("title", .contains, nasty)).isEmpty)

    // The crawl is still there.
    let remaining = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
    }
    #expect(remaining > 0)
}

@MainActor
@Test func anUnknownFieldIsIgnoredRatherThanInterpolated() {
    #expect(CustomReports.compile(condition("u.url); DROP TABLE urls; --", .equals, "x")) == nil)
    #expect(CustomReports.compile(condition("nonexistent", .equals, "x")) == nil)
}

/// A report whose every condition was discarded must not silently become "show
/// me everything" — that would look like a working filter finding a great deal.
@MainActor
@Test func aReportWithNoUsableConditionsCompilesToNothing() {
    #expect(CustomReports.compile(CustomReport(id: "t", name: "Empty")) == nil)
    #expect(CustomReports.compile(condition("title", .equals, "   ")) == nil,
            "a blank value is not a condition")
    #expect(CustomReports.compile(condition("wordCount", .greaterThan, "not a number")) == nil)
}

/// "Contains" on a number and "greater than" on a title are offered by nobody
/// sensible, and a stored definition could still name one.
@MainActor
@Test func aComparisonThatDoesNotSuitTheFieldIsDropped() {
    #expect(CustomReports.compile(condition("wordCount", .contains, "5")) == nil)
    #expect(CustomReports.compile(condition("title", .greaterThan, "5")) == nil)
}

// MARK: - Behaving like a real report

@MainActor
@Test func aCustomReportSortsAndCountsLikeAnyOther() throws {
    let store = try ReportFixture.make()
    let custom = CustomReport(
        id: "t", name: "Everything indexable",
        conditions: [CustomCondition(field: "depth", comparison: .greaterThan, value: "0")],
        columns: ["address", "depth"])
    let report = try #require(CustomReports.compile(custom))

    let filter = report.filters.first { $0.id == "matching" }!
    let ascending = try store.ids(for: report, filter: filter,
                                  sortBy: report.column(id: "depth"), ascending: true)
    let descending = try store.ids(for: report, filter: filter,
                                   sortBy: report.column(id: "depth"), ascending: false)
    // Compared by the sort key rather than by row identity: many pages share a
    // depth, and among ties both directions fall back to ascending id — so the
    // first ascending row is not the last descending one, and asserting that it
    // is would be testing the tie-break rather than the sort.
    #expect(ascending.count == descending.count)
    func depths(_ ids: [Int64]) throws -> [Int] {
        try store.dbQueue.read { db in
            try ids.compactMap { id in
                try Int.fetchOne(db, sql: "SELECT depth FROM urls WHERE id = ?", arguments: [id])
            }
        }
    }
    #expect(try depths(ascending) == depths(ascending).sorted())
    #expect(try depths(descending) == depths(descending).sorted(by: >))

    // And the one-pass count agrees with running it directly, which is what
    // proves the bound arguments survive the union.
    let counts = try store.counts(for: [report])
    #expect(counts["\(report.id).matching"] == ascending.count)
}

/// Arguments are concatenated across a union of predicates, so their order has
/// to line up with the placeholders. Several custom reports at once is where
/// that goes wrong if it is going to.
@MainActor
@Test func severalCustomReportsCountCorrectlyTogether() throws {
    let store = try ReportFixture.make()
    let reports = [
        CustomReport(id: "a", name: "A", conditions: [
            CustomCondition(field: "title", comparison: .contains, value: "Shared title")]),
        CustomReport(id: "b", name: "B", conditions: [
            CustomCondition(field: "path", comparison: .equals, value: "/no-title")]),
        CustomReport(id: "c", name: "C", conditions: [
            CustomCondition(field: "depth", comparison: .greaterThan, value: "3")]),
    ].compactMap(CustomReports.compile)
    #expect(reports.count == 3)

    let counts = try store.counts(for: reports)
    for report in reports {
        let filter = report.filters.first { $0.id == "matching" }!
        let direct = try store.ids(for: report, filter: filter,
                                   sortBy: nil, ascending: true).count
        #expect(counts["\(report.id).matching"] == direct, "\(report.name) disagrees")
    }
}

@MainActor
@Test func customReportsRoundTripAsJSON() throws {
    let custom = CustomReport(name: "Thin pages with traffic", conditions: [
        CustomCondition(field: "wordCount", comparison: .lessThan, value: "200"),
        CustomCondition(field: "clicks", comparison: .greaterThan, value: "0"),
    ], columns: ["address", "wordCount", "clicks"])
    let data = try JSONEncoder().encode([custom])
    let back = try JSONDecoder().decode([CustomReport].self, from: data)
    #expect(back == [custom])
    #expect(CustomReports.compile(back[0]) != nil)
}
