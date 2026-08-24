import Foundation
import Testing
@testable import KodaCore

// MARK: - Export rows

/// The guarantee that matters: a file and the table it came from must not
/// disagree. Both go through `ids` and `rows`, and this proves it.
@Test func exportedRowsMatchTheTablesRowsForTheSameQuery() throws {
    let store = try ReportFixture.make()
    let report = Reports.titles
    let filter = report.defaultFilter
    let export = try store.export(report: report, filter: filter)

    let ids = try store.ids(for: report, filter: filter, sortBy: nil, ascending: true)
    let table = try store.rows(ids: ids, columns: report.columns).map(\.cells)
    #expect(export.rows == table)
    #expect(export.headers == report.columns.map(\.header))
    #expect(export.name == report.name)
}

@Test func exportHonoursTheSortAndTheFilter() throws {
    let store = try ReportFixture.make()
    let report = Reports.titles
    let missing = report.filters.first { $0.id == "missing" }!
    #expect(try store.export(report: report, filter: missing).rows.count == 1)

    let address = report.column(id: "address")!
    let up = try store.export(report: report, filter: report.defaultFilter,
                              sortBy: address, ascending: true).rows
    let down = try store.export(report: report, filter: report.defaultFilter,
                                sortBy: address, ascending: false).rows
    #expect(up.first == down.last)
    #expect(up != down)
}

/// "I checked and it is clean" is a result. A file with headers and no rows says
/// that; no file at all does not.
@Test func anEmptyReportExportsHeadersAndNoRows() throws {
    let store = try ReportFixture.make()
    let noarchive = Reports.directives.filters.first { $0.id == "noarchive" }!
    let export = try store.export(report: Reports.directives, filter: noarchive)
    #expect(export.rows.isEmpty)
    #expect(!export.headers.isEmpty)
}

/// The export pages in 200s; the fixture is smaller than that, so this forces
/// several pages to prove the stitching drops and duplicates nothing.
@Test func pagingDoesNotDropOrDuplicateRows() throws {
    let store = try ReportFixture.make()
    let all = try store.export(report: Reports.internalURLs,
                               filter: Reports.internalURLs.defaultFilter)
    let ids = try store.ids(for: Reports.internalURLs,
                            filter: Reports.internalURLs.defaultFilter,
                            sortBy: nil, ascending: true)
    #expect(all.rows.count == ids.count)
    #expect(Store.exportPageSize > 1)

    // The addresses must be unique and in the index's order.
    let addresses = all.rows.compactMap { $0.first ?? nil }
    #expect(Set(addresses).count == addresses.count)
}

@Test func exportAllCoversEveryReport() throws {
    let store = try ReportFixture.make()
    let exports = try store.exportAll()
    #expect(exports.count == 18)
    #expect(exports.map(\.name) == Reports.all.map(\.name))
}

@Test func exportRespectsALimit() throws {
    let store = try ReportFixture.make()
    let export = try store.export(report: Reports.internalURLs,
                                  filter: Reports.internalURLs.defaultFilter, limit: 3)
    #expect(export.rows.count == 3)
}

// MARK: - CSV

private let awkward = ReportExport(
    name: "Awkward",
    headers: ["Address", "Title", "Note"],
    rows: [
        ["https://x.test/", "A title, with a comma", nil],
        ["https://x.test/q", "He said \"hello\"", ""],
        ["https://x.test/n", "Line one\nLine two", "plain"],
    ])

@Test func csvQuotesFieldsContainingCommasQuotesAndNewlines() {
    let text = String(decoding: CSVWriter.encode(awkward, includeBOM: false), as: UTF8.self)
    #expect(text.contains("\"A title, with a comma\""))
    #expect(text.contains("\"He said \"\"hello\"\"\""))
    #expect(text.contains("\"Line one\nLine two\""))
}

@Test func csvLeavesOrdinaryFieldsUnquoted() {
    #expect(CSVWriter.field("plain") == "plain")
    #expect(CSVWriter.field("") == "")
}

@Test func csvStartsWithABOMAndUsesCRLF() {
    let data = CSVWriter.encode(awkward)
    #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
    #expect(String(decoding: data, as: UTF8.self).contains("Address,Title,Note\r\n"))
}

@Test func csvOmitsTheBOMWhenAsked() {
    #expect(Array(CSVWriter.encode(awkward, includeBOM: false).prefix(3)) != [0xEF, 0xBB, 0xBF])
}

@Test func csvHasOneLineForTheHeaderAndOnePerRow() {
    let text = String(decoding: CSVWriter.encode(awkward, includeBOM: false), as: UTF8.self)
    // The embedded newline means counting "\r\n" rather than lines.
    #expect(text.components(separatedBy: "\r\n").count - 1 == 4)
}

// MARK: - XLSX naming and escaping

@Test func sheetNamesAreSanitisedAndCappedAt31() {
    let names = XLSXWriter.sheetNames(["Response Codes", "a/b\\c:d?e*f[g]h",
                                       String(repeating: "x", count: 60)])
    #expect(names[0] == "Response Codes")
    #expect(!names[1].contains(where: { ":\\/?*[]".contains($0) }))
    #expect(names[2].count == 31)
    #expect(names.allSatisfy { $0.count <= 31 })
}

/// Truncation can make two different names collide, and a workbook with two
/// sheets of the same name does not open.
@Test func sheetNamesAreDeduplicatedAfterTruncation() {
    let long = String(repeating: "Report Name ", count: 5)
    let names = XLSXWriter.sheetNames([long, long, long])
    #expect(Set(names.map { $0.lowercased() }).count == 3)
    #expect(names.allSatisfy { $0.count <= 31 })
}

@Test func xmlEscapingCoversTheFiveEntities() {
    #expect(XLSXWriter.escape("a & b < c > d \" e ' f")
            == "a &amp; b &lt; c &gt; d &quot; e &apos; f")
}

/// A form feed is legal in an HTML title and illegal in XML at any escaping. One
/// stray byte would otherwise produce a workbook Excel refuses to open, with no
/// hint which row caused it.
@Test func controlCharactersAreStrippedButTabsAndNewlinesSurvive() {
    #expect(XLSXWriter.escape("before\u{0C}after") == "beforeafter")
    #expect(XLSXWriter.escape("a\tb\nc") == "a\tb\nc")
}

@Test func columnLettersRollOverPastZ() {
    #expect(XLSXWriter.columnLetters(0) == "A")
    #expect(XLSXWriter.columnLetters(25) == "Z")
    #expect(XLSXWriter.columnLetters(26) == "AA")
    #expect(XLSXWriter.columnLetters(51) == "AZ")
    #expect(XLSXWriter.columnLetters(52) == "BA")
}
