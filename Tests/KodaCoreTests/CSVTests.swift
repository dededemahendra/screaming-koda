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

// MARK: - Streaming

/// A crawl big enough that one report spans several chunks.
private func streamingFixture() async throws -> Store {
    var config = CrawlConfig(seedURL: "https://csv.test/")
    config.checkExternalLinks = false
    config.checkImages = false
    return try await CrawlSession.start(dbPath: nil, config: config, client: WideCSVSite(),
                                        parser: SwiftSoupParser(), onProgress: nil)
}

private struct WideCSVSite: HTTPClient {
    static let pageCount = 60

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        let body: String
        if url == "https://csv.test/" {
            body = (0..<Self.pageCount).map { "<a href='/p\($0)'>Page \($0)</a>" }.joined()
        } else {
            body = "<p>A page with a reasonable amount of text on it, as pages have.</p>"
        }
        return .response(HTTPResponse(
            status: 200, headers: ["Content-Type": "text/html"],
            body: Data("<html><head><title>A title long enough to be ordinary</title></head><body>\(body)</body></html>".utf8),
            elapsedMs: 1))
    }
}

@Test func streamingAReportGivesExactlyWhatRenderingItGives() async throws {
    let store = try await streamingFixture()
    let definition = ReportCatalogue.report(id: "internal-all")!

    var streamed = Data()
    let rows = try store.streamCSV(for: definition) { streamed.append($0) }

    let rendered = try store.csv(for: definition)
    let expectedRows = try store.reportCount(definition)
    #expect(String(decoding: streamed, as: UTF8.self) == rendered)
    #expect(rows == expectedRows)
}

@Test func streamingHandsOverTheReportInPiecesRatherThanAllAtOnce() async throws {
    let store = try await streamingFixture()
    var chunks = 0
    var largest = 0
    let rows = try store.streamCSV(for: ReportCatalogue.report(id: "internal-all")!,
                                   chunkBytes: 1024) { chunk in
        chunks += 1
        largest = max(largest, chunk.count)
    }
    #expect(rows > WideCSVSite.pageCount)
    #expect(chunks > 1, "a report this size must not arrive as one buffer")
    // The whole point is that peak memory is a chunk, not a report. The handoff
    // happens as soon as the buffer passes the threshold, so a chunk overshoots
    // by at most one row.
    #expect(largest < 1024 * 2)
}

@Test func aFailedExportLeavesThePreviousOneAlone() async throws {
    let store = try await streamingFixture()
    let path = NSTemporaryDirectory() + "koda-csv-\(UUID().uuidString).csv"
    defer { try? FileManager.default.removeItem(atPath: path) }

    try "the export from yesterday".write(toFile: path, atomically: true, encoding: .utf8)
    // A report whose SQL cannot run, to make the write fail part way.
    let broken = ReportDefinition(id: "broken", group: "X", name: "Broken", summary: "",
                                  columns: ["URL"], sql: "SELECT nope FROM nowhere")
    #expect(throws: (any Error).self) { try store.writeCSV(for: broken, to: path) }
    let survived = try String(contentsOfFile: path, encoding: .utf8)
    #expect(survived == "the export from yesterday")

    // And no debris beside it.
    let directory = (path as NSString).deletingLastPathComponent
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasSuffix(".partial") }
    #expect(leftovers.isEmpty)
}
