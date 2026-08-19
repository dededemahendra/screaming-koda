import Foundation
import GRDB
import Testing
@testable import KodaCore

private struct TinyClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        let body = "<html><head><title>Only</title></head><body>hi</body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

@Test func prepareReturnsAnEngineThatHasNotRunYet() async throws {
    let config = CrawlConfig(seedURL: "https://tiny.test/")
    let (engine, store, outcome) = try await CrawlSession.prepare(
        dbPath: nil, config: config, client: TinyClient(), parser: SwiftSoupParser()
    )

    #expect(await engine.state == .idle)
    #expect(outcome == .absent)
    #expect(try store.urlCounts().queued == 1, "the seed is enqueued but nothing has been fetched")

    let responses = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM responses") ?? 0
    }
    #expect(responses == 0)
}

@Test func prepareGivesARunnableEngine() async throws {
    let config = CrawlConfig(seedURL: "https://tiny.test/")
    let (engine, store, _) = try await CrawlSession.prepare(
        dbPath: nil, config: config, client: TinyClient(), parser: SwiftSoupParser()
    )
    try await engine.run(onProgress: nil)

    #expect(await engine.state == .finished)
    #expect(try store.urlCounts().done == 1)
}

@Test func prepareRejectsAnInvalidSeed() async {
    let config = CrawlConfig(seedURL: "not a url")
    await #expect(throws: CrawlSessionError.self) {
        _ = try await CrawlSession.prepare(dbPath: nil, config: config,
                                           client: TinyClient(), parser: SwiftSoupParser())
    }
}

@Test func startStillRunsToCompletion() async throws {
    let config = CrawlConfig(seedURL: "https://tiny.test/")
    let (store, outcome) = try await CrawlSession.start(
        dbPath: nil, config: config, client: TinyClient(),
        parser: SwiftSoupParser(), onProgress: nil
    )
    #expect(outcome == .absent)
    #expect(try store.urlCounts().done == 1)
    #expect(try store.urlCounts().queued == 0)
}
