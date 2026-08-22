import Foundation
import GRDB
import Testing
@testable import KodaCore

private actor FetchLog {
    private(set) var pages: [String] = []
    func record(_ url: String) { pages.append(url) }
}

/// A three-page site that records every page fetch, so a resumed crawl can be
/// distinguished from a restarted one by what it asks for over the wire.
private struct CountingClient: HTTPClient {
    let log: FetchLog

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        await log.record(url)

        let body: String
        switch url {
        case "https://resume.test/":
            body = "<html><head><title>Home</title></head><body><a href='/a'>a</a><a href='/b'>b</a></body></html>"
        case "https://resume.test/a":
            body = "<html><head><title>A</title></head><body></body></html>"
        case "https://resume.test/b":
            body = "<html><head><title>B</title></head><body></body></html>"
        default:
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

private func config() -> CrawlConfig {
    var c = CrawlConfig(seedURL: "https://resume.test/")
    c.workers = 2
    return c
}

@Test func crawlingTwiceProducesTheSameURLCount() async throws {
    let first = try await CrawlSession.start(dbPath: nil, config: config(), client: CountingClient(log: FetchLog()),
                                             parser: SwiftSoupParser(), onProgress: nil)
    let second = try await CrawlSession.start(dbPath: nil, config: config(), client: CountingClient(log: FetchLog()),
                                              parser: SwiftSoupParser(), onProgress: nil)
    #expect(try first.urlCounts().total == second.urlCounts().total)
    #expect(try first.summary().crawledURLs == second.summary().crawledURLs)
}

@Test func rerunningAFinishedCrawlRefetchesNothing() async throws {
    let path = NSTemporaryDirectory() + "koda-resume-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let firstLog = FetchLog()
    _ = try await CrawlSession.start(dbPath: path, config: config(), client: CountingClient(log: firstLog),
                                     parser: SwiftSoupParser(), onProgress: nil)
    #expect(await firstLog.pages.count == 3)

    // Same database, same seed: the frontier is drained, so there is nothing to do.
    let secondLog = FetchLog()
    let store = try await CrawlSession.start(dbPath: path, config: config(), client: CountingClient(log: secondLog),
                                             parser: SwiftSoupParser(), onProgress: nil)
    #expect(await secondLog.pages.isEmpty, "a completed crawl must not be redone")
    #expect(try store.urlCounts().done == 3)
}

@Test func inFlightURLsAreRequeuedOnTheNextRun() async throws {
    let path = NSTemporaryDirectory() + "koda-resume-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let firstLog = FetchLog()
    let first = try await CrawlSession.start(dbPath: path, config: config(), client: CountingClient(log: firstLog),
                                             parser: SwiftSoupParser(), onProgress: nil)

    // State 1 is exactly what a killed process leaves behind: claimed, never finished.
    try await first.dbQueue.write { db in
        try db.execute(sql: "UPDATE urls SET state = 1 WHERE path = '/a'")
    }

    let secondLog = FetchLog()
    let store = try await CrawlSession.start(dbPath: path, config: config(), client: CountingClient(log: secondLog),
                                             parser: SwiftSoupParser(), onProgress: nil)

    #expect(await secondLog.pages == ["https://resume.test/a"], "only the interrupted URL is redone")
    #expect(try store.urlCounts().inFlight == 0)
    #expect(try store.urlCounts().done == 3)
}
