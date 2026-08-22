import Foundation
import Testing
@testable import KodaCore

@Test func plainFieldsAreNotQuoted() {
    #expect(CSVWriter.field("hello") == "hello")
    #expect(CSVWriter.field("https://example.com/a?b=1") == "https://example.com/a?b=1")
}

@Test func nilBecomesAnEmptyField() {
    #expect(CSVWriter.field(nil) == "")
    #expect(CSVWriter.row([nil, "a", nil]) == ",a,")
}

@Test func emptyStringAndNilAreIndistinguishableInCSV() {
    // Worth stating explicitly: CSV has no way to tell them apart, so callers who
    // need the distinction must not round-trip through this exporter.
    #expect(CSVWriter.field("") == CSVWriter.field(nil))
}

@Test func fieldsWithSeparatorsAreQuoted() {
    #expect(CSVWriter.field("a,b") == "\"a,b\"")
    #expect(CSVWriter.field("line\nbreak") == "\"line\nbreak\"")
    #expect(CSVWriter.field("carriage\rreturn") == "\"carriage\rreturn\"")
}

@Test func quotesAreDoubled() {
    #expect(CSVWriter.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
}

@Test func leadingAndTrailingSpacesAreQuoted() {
    // Unquoted surrounding whitespace is silently trimmed by many readers.
    #expect(CSVWriter.field(" padded ") == "\" padded \"")
}

@Test func documentUsesCRLFAndEndsWithOne() {
    let csv = CSVWriter.document(columns: ["A", "B"], rows: [["1", "2"], ["3", nil]])
    #expect(csv == "A,B\r\n1,2\r\n3,\r\n")
}

@Test func documentWithNoRowsIsJustAHeader() {
    #expect(CSVWriter.document(columns: ["A", "B"], rows: []) == "A,B\r\n")
}

// MARK: - Golden file

private struct GoldenSite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        func page(_ body: String) -> FetchOutcome {
            .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                   body: Data(body.utf8), elapsedMs: 1))
        }
        switch url {
        case "https://gold.test/":
            return page("""
                <html><head><title>Same, with a comma</title></head>
                <body><h1>H</h1><a href="/two">Two</a></body></html>
                """)
        case "https://gold.test/two":
            return page("""
                <html><head><title>Same, with a comma</title></head>
                <body><h1>H</h1></body></html>
                """)
        default:
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
    }
}

@Test func duplicateTitlesExportMatchesTheGoldenFile() async throws {
    var config = CrawlConfig(seedURL: "https://gold.test/")
    config.workers = 1
    let store = try await CrawlSession.start(dbPath: nil, config: config, client: GoldenSite(),
                                             parser: SwiftSoupParser(), onProgress: nil)

    let csv = try store.csv(for: ReportCatalogue.report(id: "titles-duplicate")!)
    let expected = """
        URL,Title,Length\r
        https://gold.test/,"Same, with a comma",18\r
        https://gold.test/two,"Same, with a comma",18\r

        """
    #expect(csv == expected)
}

@Test func writeAllCSVsSkipsEmptyReports() async throws {
    var config = CrawlConfig(seedURL: "https://gold.test/")
    config.workers = 1
    let store = try await CrawlSession.start(dbPath: nil, config: config, client: GoldenSite(),
                                             parser: SwiftSoupParser(), onProgress: nil)

    let directory = NSTemporaryDirectory() + "koda-csv-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }

    let written = try store.writeAllCSVs(to: directory)
    #expect(!written.isEmpty)
    #expect(written.count < ReportCatalogue.all.count, "reports with no findings are skipped")
    #expect(written.contains { $0.hasSuffix("titles-duplicate.csv") })
    #expect(!written.contains { $0.hasSuffix("response-5xx.csv") })

    let onDisk = try String(contentsOfFile: directory + "/titles-duplicate.csv", encoding: .utf8)
    let inMemory = try store.csv(for: ReportCatalogue.report(id: "titles-duplicate")!)
    #expect(onDisk == inMemory)
}
