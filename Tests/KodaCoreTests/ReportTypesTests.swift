import Foundation
import Testing
@testable import KodaCore

private let sample = Report(
    id: "titles",
    name: "Titles",
    predicate: "u.is_internal = 1",
    columns: [
        ReportColumn(id: "address", header: "Address", expression: "u.url", width: 380),
        ReportColumn(id: "titleLength", header: "Length", expression: "f.title_length",
                     width: 70, alignment: .trailing),
        ReportColumn(id: "note", header: "Note", expression: "'x'", width: 80, sortable: false),
    ],
    filters: [
        ReportFilter(id: "all", name: "All", predicate: "1"),
        ReportFilter(id: "missing", name: "Missing", predicate: "f.title IS NULL", severity: .breaksIndexing),
    ]
)

@Test func columnLookupFindsADeclaredColumn() {
    #expect(sample.column(id: "titleLength")?.expression == "f.title_length")
}

/// The allow-list is the lookup itself: a sort key that names a column this
/// report does not declare cannot reach SQL, because there is no expression to
/// reach it with.
@Test func columnLookupRejectsAnUndeclaredColumn() {
    #expect(sample.column(id: "wordCount") == nil)
    #expect(sample.column(id: "'; DROP TABLE urls; --") == nil)
}

@Test func defaultFilterIsTheFirstOne() {
    #expect(sample.defaultFilter.id == "all")
}

@Test func aColumnIsSortableByDefaultAndCanOptOut() {
    #expect(sample.column(id: "address")?.sortable == true)
    #expect(sample.column(id: "note")?.sortable == false)
}

@Test func onlyIssueFiltersAreMarkedAsSuch() {
    #expect(sample.filters.filter(\.isFinding).map(\.id) == ["missing"])
}

@Test func theSharedFromJoinsResponsesAndPageFactsLeft() {
    // LEFT, not INNER: a URL discovered but not yet fetched still has to appear
    // in the table during a live crawl.
    #expect(ReportSQL.from.contains("LEFT JOIN responses"))
    #expect(ReportSQL.from.contains("LEFT JOIN page_facts"))
    #expect(!ReportSQL.from.contains("INNER JOIN"))
}
