import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Slow enough that a reader gets many chances to look while the writer works.
private struct PacedSite: HTTPClient {
    static let pageCount = 60

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        try? await Task.sleep(nanoseconds: 4_000_000)
        let body: String
        if url == "https://live.test/" {
            let links = (0..<Self.pageCount).map { "<a href='/p\($0)'>p\($0)</a>" }.joined()
            body = "<html><head><title>Home</title></head><body><h1>H</h1>\(links)</body></html>"
        } else {
            body = "<html><head><title>P</title></head><body><h1>P</h1></body></html>"
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

/// The window browses results while the crawl is still writing. WAL is what makes
/// that safe, and this is the test that says so.
@Test func reportsAreReadableWhileACrawlIsWriting() async throws {
    let path = NSTemporaryDirectory() + "koda-live-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }

    var config = CrawlConfig(seedURL: "https://live.test/")
    config.workers = 2
    config.checkExternalLinks = false
    config.checkImages = false

    let crawl = Task {
        try await CrawlSession.start(dbPath: path, config: config, client: PacedSite(),
                                     parser: SwiftSoupParser(), onProgress: nil)
    }

    // A second connection to the same file, exactly as the app opens it.
    var reader: Store?
    let openDeadline = Date().addingTimeInterval(10)
    while reader == nil, Date() < openDeadline {
        if let candidate = try? Store(path: path), (try? candidate.urlTotal()) != nil {
            reader = candidate
        } else {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    let store = try #require(reader, "could not open a second connection while the crawl ran")

    var observed: [Int] = []
    var failures: [String] = []
    let readDeadline = Date().addingTimeInterval(20)
    while (observed.last ?? 0) < PacedSite.pageCount, Date() < readDeadline {
        do {
            observed.append(try store.reportCount(ReportCatalogue.report(id: "internal-all")!))
            _ = try store.rows(for: ReportQuery(definition: ReportCatalogue.report(id: "internal-all")!,
                                                sortColumn: 0), limit: 50)
            _ = try store.summary()
        } catch {
            failures.append(String(describing: error))
        }
        try await Task.sleep(nanoseconds: 3_000_000)
    }
    _ = try await crawl.value

    #expect(failures.isEmpty, "a reader must never be blocked or errored by the writer: \(failures.first ?? "")")
    #expect(observed.contains { $0 > 0 && $0 < PacedSite.pageCount + 1 },
            "the reader saw the crawl partway through, so this really was concurrent")

    let final = try store.reportCount(ReportCatalogue.report(id: "internal-all")!)
    #expect(final == PacedSite.pageCount + 1, "and sees everything once the writer finishes")
}
