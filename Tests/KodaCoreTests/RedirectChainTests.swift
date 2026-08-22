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

    let store = try await CrawlSession.start(dbPath: nil, config: config,
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

    let store = try await CrawlSession.start(dbPath: nil, config: config,
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

    let store = try await CrawlSession.start(dbPath: nil, config: config, client: ShortChain(),
                                             parser: SwiftSoupParser(), onProgress: nil)
    let title = try await store.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT title FROM page_facts") }
    #expect(title == "End")
}

@Test func redirectsDoNotConsumeDepthBudget() async throws {
    struct RedirectThenLink: HTTPClient {
        func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
            switch url {
            case "https://hop.test/a":
                return .response(HTTPResponse(status: 301, headers: ["Location": "https://hop.test/b"],
                                              body: Data(), elapsedMs: 1))
            case "https://hop.test/b":
                return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                              body: Data("<html><head><title>B</title></head><body><a href='/c'>c</a></body></html>".utf8),
                                              elapsedMs: 1))
            case "https://hop.test/c":
                return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                              body: Data("<html><head><title>C</title></head><body></body></html>".utf8),
                                              elapsedMs: 1))
            default:
                return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
            }
        }
    }
    // A redirect is the same page at a new address, not a child of it. With
    // maxDepth 1 the hop must not eat the single level available to /c.
    var config = CrawlConfig(seedURL: "https://hop.test/a")
    config.workers = 1
    config.maxDepth = 1

    let store = try await CrawlSession.start(dbPath: nil, config: config, client: RedirectThenLink(),
                                             parser: SwiftSoupParser(), onProgress: nil)
    let paths = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id ORDER BY u.path
            """)
    }
    #expect(paths == ["/a", "/b", "/c"])
}

@Test func canonicalTargetIsNotTreatedAsARedirectHop() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://canon.test/")
    config.maxRedirects = 0
    try store.initializeCrawl(config: config, startedAt: Date())
    let url = URLNormalizer.normalize("https://canon.test/", relativeTo: nil)!
    let id = try store.insertURLIfNew(url, depth: 0, isInternal: true, discoveredAt: Date())

    var facts = PageFacts()
    facts.canonical = "https://canon.test/preferred"
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                             contentType: "text/html", contentLength: 10, responseTimeMs: 1,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)
    _ = try store.write(results: [result], config: config, now: Date())

    // maxRedirects is 0, so if a canonical counted as a hop the target would be
    // recorded as skipped and never crawled.
    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: "SELECT redirect_hops, state FROM urls WHERE path = '/preferred'")
    }
    #expect(row?["redirect_hops"] == 0)
    #expect(row?["state"] == 0, "the canonical target is queued, not abandoned")
}
