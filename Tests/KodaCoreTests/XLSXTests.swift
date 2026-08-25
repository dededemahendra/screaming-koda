import Foundation
import Testing
@testable import KodaCore

/// Runs a command and returns its standard output, for shelling out to `unzip`.
/// A hand-written zip is exactly the kind of thing that looks right and is not,
/// so the tests read it back with a reader nobody here wrote.
private func run(_ launchPath: String, _ arguments: [String]) throws -> (status: Int32, output: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, output)
}

private func writeTemp(_ data: Data) throws -> String {
    let path = NSTemporaryDirectory() + "koda-\(UUID().uuidString).xlsx"
    try data.write(to: URL(fileURLWithPath: path))
    return path
}

// MARK: - The archive

@Test func theWorkbookIsAZipThatUnzipAccepts() throws {
    let book = XLSXWriter.workbook(sheets: [
        .init(name: "One", columns: ["URL", "Status"], rows: [["https://x.test/", "200"]])
    ])
    let path = try writeTemp(book)
    defer { try? FileManager.default.removeItem(atPath: path) }

    // -t verifies every entry's CRC against its decompressed bytes, which is the
    // half of a zip that is easy to get subtly wrong.
    let tested = try run("/usr/bin/unzip", ["-t", path])
    #expect(tested.status == 0, "\(String(decoding: tested.output, as: UTF8.self))")

    let listed = String(decoding: try run("/usr/bin/unzip", ["-Z1", path]).output, as: UTF8.self)
    for part in ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml",
                 "xl/_rels/workbook.xml.rels", "xl/worksheets/sheet1.xml"] {
        #expect(listed.contains(part), "missing \(part)")
    }
}

@Test func exportingTheSameCrawlTwiceGivesTheSameBytes() throws {
    let sheets: [XLSXWriter.Sheet] = [.init(name: "S", columns: ["A"], rows: [["1"], ["2"]])]
    #expect(XLSXWriter.workbook(sheets: sheets) == XLSXWriter.workbook(sheets: sheets))
}

@Test func crc32MatchesTheKnownValueForCheck() {
    // The standard CRC-32 check value for the nine bytes "123456789".
    #expect(ZIPArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
}

// MARK: - The sheet

@Test func cellsCarryTheirValuesAndNullsAreAbsent() throws {
    let book = XLSXWriter.workbook(sheets: [
        .init(name: "One", columns: ["URL", "Title", "Status"],
              rows: [["https://x.test/a", nil, "404"]])
    ])
    let path = try writeTemp(book)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let sheet = String(decoding: try run("/usr/bin/unzip", ["-p", path, "xl/worksheets/sheet1.xml"]).output,
                       as: UTF8.self)
    #expect(sheet.contains("https://x.test/a"))
    // A status is a number so it sorts as one; a NULL is no cell at all, which is
    // how a spreadsheet spells "nothing here".
    #expect(sheet.contains("<c r=\"C2\"><v>404</v></c>"))
    #expect(!sheet.contains("r=\"B2\""))
    #expect(sheet.contains("autoFilter"))
}

@Test func headersAreAlwaysTextEvenWhenTheyLookNumeric() throws {
    let book = XLSXWriter.workbook(sheets: [.init(name: "S", columns: ["2024"], rows: [["2024"]])])
    let path = try writeTemp(book)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let sheet = String(decoding: try run("/usr/bin/unzip", ["-p", path, "xl/worksheets/sheet1.xml"]).output,
                       as: UTF8.self)
    #expect(sheet.contains("<c r=\"A1\" t=\"inlineStr\""))
    #expect(sheet.contains("<c r=\"A2\"><v>2024</v></c>"))
}

@Test func onlyRoundTrippableDigitsBecomeNumbers() {
    #expect(XLSXWriter.numeric("404") == "404")
    #expect(XLSXWriter.numeric("-3") == "-3")
    #expect(XLSXWriter.numeric("1.5") == "1.5")
    // Leading zeros and trailing zeros are meaningful in the text they came from.
    #expect(XLSXWriter.numeric("007") == nil)
    #expect(XLSXWriter.numeric("1.10") == nil)
    #expect(XLSXWriter.numeric("") == nil)
    #expect(XLSXWriter.numeric("nan") == nil)
    #expect(XLSXWriter.numeric("inf") == nil)
    #expect(XLSXWriter.numeric("1e400") == nil)
}

@Test func columnReferencesRollOverPastZ() {
    #expect(XLSXWriter.column(0) == "A")
    #expect(XLSXWriter.column(25) == "Z")
    #expect(XLSXWriter.column(26) == "AA")
    #expect(XLSXWriter.column(27) == "AB")
    #expect(XLSXWriter.column(51) == "AZ")
    #expect(XLSXWriter.column(52) == "BA")
    #expect(XLSXWriter.column(701) == "ZZ")
    #expect(XLSXWriter.column(702) == "AAA")
}

@Test func markupInACrawledTitleCannotBreakTheSheet() throws {
    // A title is whatever the site put in it. This one would produce a file that
    // does not open if it went in raw.
    let nasty = "A & B <script>\"x\" 'y'\u{0007}\u{001B}"
    let book = XLSXWriter.workbook(sheets: [.init(name: "S", columns: ["Title"], rows: [[nasty]])])
    let path = try writeTemp(book)
    defer { try? FileManager.default.removeItem(atPath: path) }

    let data = try run("/usr/bin/unzip", ["-p", path, "xl/worksheets/sheet1.xml"]).output
    #expect(try XMLDocument(data: data, options: []).rootElement() != nil, "the part must still parse")
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("&amp;") && text.contains("&lt;script&gt;"))
    #expect(!text.contains("\u{0007}"), "XML 1.0 cannot represent a bell, even as an entity")
}

@Test func sheetNamesAreTrimmedAndDeduplicated() {
    let named = XLSXWriter.namedUniquely([
        .init(name: "Reports/2024", columns: [], rows: []),
        .init(name: String(repeating: "x", count: 40), columns: [], rows: []),
        .init(name: String(repeating: "x", count: 40), columns: [], rows: []),
    ]).map(\.name)

    #expect(named[0] == "Reports-2024", "Excel rejects a slash in a sheet name")
    #expect(named[1].count == 31)
    #expect(named[2].count == 31)
    #expect(named[1] != named[2], "Excel rejects a workbook with two sheets of one name")
}

// MARK: - Over a real crawl

/// A small site with duplicate titles and a 404, so the workbook has something
/// to put in tabs and something to leave out.
private struct ExportSite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        func page(_ status: Int, _ body: String) -> FetchOutcome {
            .response(HTTPResponse(status: status, headers: ["Content-Type": "text/html"],
                                   body: Data(body.utf8), elapsedMs: 1))
        }
        switch url {
        case "https://site.test/":
            return page(200, """
                <html><head><title>Shared</title></head><body><h1>H</h1>
                <a href="/dupe">Dupe</a><a href="/gone">Gone</a></body></html>
                """)
        case "https://site.test/dupe":
            return page(200, "<html><head><title>Shared</title></head><body><h1>H</h1></body></html>")
        default:
            return page(404, "")
        }
    }
}

@Test func aCrawlExportsToAWorkbookOfItsNonEmptyReports() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 2
    let store = try await CrawlSession.start(dbPath: nil, config: config, client: ExportSite(),
                                             parser: SwiftSoupParser(), onProgress: nil)
    let path = try writeTemp(try store.xlsx())
    defer { try? FileManager.default.removeItem(atPath: path) }

    #expect(try run("/usr/bin/unzip", ["-t", path]).status == 0)

    let workbook = String(decoding: try run("/usr/bin/unzip", ["-p", path, "xl/workbook.xml"]).output,
                          as: UTF8.self)
    #expect(workbook.contains("name=\"Overview\""))
    #expect(workbook.contains("name=\"titles-duplicate\""))
    #expect(!workbook.contains("name=\"response-5xx\""), "an empty report gets no tab")

    let overview = String(decoding: try run("/usr/bin/unzip", ["-p", path, "xl/worksheets/sheet1.xml"]).output,
                          as: UTF8.self)
    #expect(overview.contains("Discovered"))
    #expect(overview.contains("https://site.test/"))
}
