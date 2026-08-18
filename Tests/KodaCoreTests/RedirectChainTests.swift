import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Redirects forever, with a new URL each hop, so dedup can never stop it.
private struct InfiniteRedirectClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        let next = (Int(url.components(separatedBy: "?n=").last ?? "0") ?? 0) + 1
        return .response(HTTPResponse(status: 301,
                                      headers: ["Location": "https://loop.test/a?n=\(next)"],
                                      body: Data(), elapsedMs: 1))
    }
}

@Test func redirectHopsIncrementAlongChain() async throws {
    var config = CrawlConfig(seedURL: "https://loop.test/a?n=0")
    config.workers = 1
    config.maxRedirects = 3

    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config,
                                                   client: InfiniteRedirectClient(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    let maxHops = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT max(redirect_hops) FROM urls") ?? 0
    }
    #expect(maxHops == config.maxRedirects + 1, "the chain stops one past the limit")
}

@Test func chainBeyondLimitIsRecordedButNotCrawled() async throws {
    var config = CrawlConfig(seedURL: "https://loop.test/a?n=0")
    config.workers = 1
    config.maxRedirects = 3

    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config,
                                                   client: InfiniteRedirectClient(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    let fetched = try await store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM responses") ?? 0 }
    let recorded = try await store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0 }

    #expect(fetched == config.maxRedirects + 1, "hops 0 through maxRedirects are followed")
    #expect(recorded == config.maxRedirects + 2, "the abandoned target is still recorded")
    #expect(try store.urlCounts().queued == 0, "the crawl terminates")
}

@Test func shortChainCompletesNormally() async throws {
    struct ShortChain: HTTPClient {
        func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
            switch url {
            case "https://short.test/a":
                return .response(HTTPResponse(status: 301, headers: ["Location": "https://short.test/b"],
                                              body: Data(), elapsedMs: 1))
            case "https://short.test/b":
                return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                              body: Data("<html><head><title>End</title></head><body></body></html>".utf8),
                                              elapsedMs: 1))
            default:
                return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
            }
        }
    }
    var config = CrawlConfig(seedURL: "https://short.test/a")
    config.workers = 1

    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: ShortChain(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    let title = try await store.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT title FROM page_facts") }
    #expect(title == "End")
}
