import Foundation
import Testing
@testable import KodaCore
@testable import KodaUI

private let stamp = Date(timeIntervalSince1970: 1_787_000_000)   // 2026-08-21 UTC

@Test func theSuggestedFilenameNamesTheHostReportAndDate() {
    let name = ExportCommands.suggestedFilename(host: "example.com", reportName: "Response Codes",
                                                format: .csv, date: stamp)
    #expect(name.hasPrefix("example-com-response-codes-2026-"))
    #expect(name.hasSuffix(".csv"))
}

@Test func aFilenameIsSafeForTheFilesystem() {
    let name = ExportCommands.suggestedFilename(host: "a/b:c.test", reportName: "Meta Description",
                                                format: .xlsx, date: stamp)
    #expect(!name.contains("/"))
    #expect(!name.contains(":"))
    #expect(name.hasSuffix(".xlsx"))
}

@Test func aWholeCrawlExportOmitsTheReportName() {
    let name = ExportCommands.suggestedFilename(host: "example.com", reportName: nil,
                                                format: .xlsx, date: stamp)
    #expect(name.hasPrefix("example-com-2026-"))
    #expect(!name.contains("--"), "a missing part must not leave a double hyphen")
}

@Test func anUnknownHostStillProducesAUsableName() {
    let name = ExportCommands.suggestedFilename(host: nil, reportName: nil,
                                                format: .csv, date: stamp)
    #expect(name.hasSuffix(".csv"))
    #expect(name.count > 4)
}

// MARK: - Writing

/// A small store built here rather than reusing KodaCoreTests' `ReportFixture`,
/// which is private to that target. These tests are about writing files, not
/// about covering every issue class, so three rows is enough.
@MainActor
private func smallStore() throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        let pages = [("/", 200), ("/missing", 404), ("/boom", 500)]
        for (path, status) in pages {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,1,1,0,2)
                    """,
                arguments: ["https://fx.test\(path)", Data(path.utf8), "fx.test", path])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO responses (url_id, status, content_type, fetched_at)
                    VALUES (?,?,'text/html; charset=utf-8',0)
                    """,
                arguments: [id, status])
            try db.execute(sql: "INSERT INTO page_facts (url_id, title) VALUES (?,?)",
                           arguments: [id, "Title for \(path)"])
        }
    }
    return store
}

@MainActor
private func scratchDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("export-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
@Test func exportingOneReportAsCSVWritesThatOneFile() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try smallStore()
    let export = try store.export(report: Reports.titles, filter: Reports.titles.defaultFilter)

    let target = directory.appendingPathComponent("titles.csv")
    let written = try ExportCommands.write([export], format: .csv, to: target,
                                           host: "fx.test", date: stamp)
    #expect(written == [target])
    let text = try String(contentsOf: target, encoding: .utf8)
    #expect(text.contains("Address"))
    #expect(text.contains("https://fx.test/"))
}

/// CSV has no notion of sheets, so exporting everything means one file per
/// report rather than one file with eleven sections.
@MainActor
@Test func exportingAllReportsAsCSVWritesOneFilePerReport() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try smallStore()

    let written = try ExportCommands.write(try store.exportAll(), format: .csv,
                                           to: directory.appendingPathComponent("out"),
                                           host: "fx.test", date: stamp)
    #expect(written.count == 23)
    let names = written.map { $0.lastPathComponent }
    #expect(Set(names).count == 23, "no two reports collide on a filename")
    for url in written {
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
@Test func exportingAllReportsAsXLSXWritesOneWorkbook() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try smallStore()

    let target = directory.appendingPathComponent("crawl.xlsx")
    let written = try ExportCommands.write(try store.exportAll(), format: .xlsx, to: target,
                                           host: "fx.test", date: stamp)
    #expect(written == [target])
    let size = try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int ?? 0
    #expect(size > 1000)
}

/// The file on disk must hold the same rows the table would show. Reads the CSV
/// back rather than trusting the encoder.
@MainActor
@Test func theWrittenFileContainsTheSameRowsAsTheTable() throws {
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try smallStore()
    let report = Reports.responseCodes
    let filter = report.filters.first { $0.id == "clientError" }!

    let target = directory.appendingPathComponent("codes.csv")
    try ExportCommands.write([try store.export(report: report, filter: filter)],
                             format: .csv, to: target, host: "fx.test", date: stamp)

    let text = try String(contentsOf: target, encoding: .utf8)
    let dataLines = text.components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty }
    let ids = try store.ids(for: report, filter: filter, sortBy: nil, ascending: true)
    #expect(dataLines.count == ids.count)
    #expect(dataLines.count == 1)
    #expect(text.contains("/missing"))
}
