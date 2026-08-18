import Foundation
import Testing
@testable import KodaCore

private struct SummaryClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        let pages: [String: (Int, String)] = [
            "https://sum.test/": (200, "<html><head><title>Dup</title></head><body><h1>H</h1><a href='/a'>a</a><a href='/b'>b</a><a href='/c'>c</a></body></html>"),
            "https://sum.test/a": (200, "<html><head><title>Dup</title><meta name='description' content='d'></head><body><h1>H</h1><img src='/i.png'></body></html>"),
            "https://sum.test/b": (200, "<html><head></head><body><p>no title no h1</p></body></html>"),
            "https://sum.test/c": (404, ""),
        ]
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        guard let (status, body) = pages[url] else {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: status, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

private func summarizedCrawl() async throws -> CrawlSummary {
    var config = CrawlConfig(seedURL: "https://sum.test/")
    config.workers = 2
    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: SummaryClient(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    return try store.summary()
}

@Test func countsInternalURLs() async throws {
    let s = try await summarizedCrawl()
    #expect(s.internalURLs == 4)
}

@Test func groupsStatusCodes() async throws {
    let s = try await summarizedCrawl()
    #expect(s.byStatusClass["2xx"] == 3)
    #expect(s.byStatusClass["4xx"] == 1)
}

@Test func countsMissingTitles() async throws {
    let s = try await summarizedCrawl()
    #expect(s.missingTitles == 1, "/b has no title; /c is a 404 with no facts")
}

@Test func countsDuplicateTitles() async throws {
    let s = try await summarizedCrawl()
    #expect(s.duplicateTitles == 2, "'Dup' appears on / and /a")
}

@Test func countsMissingDescriptionsAndH1() async throws {
    let s = try await summarizedCrawl()
    #expect(s.missingDescriptions == 2, "/ and /b lack descriptions")
    #expect(s.missingH1 == 1, "/b lacks an h1")
}

@Test func countsImagesMissingAlt() async throws {
    let s = try await summarizedCrawl()
    #expect(s.imagesMissingAlt == 1)
}

@Test func reportsMaxDepth() async throws {
    let s = try await summarizedCrawl()
    #expect(s.maxDepth == 1)
}

// MARK: - Fix-round regression tests (review findings on the first cut of Task 11)

/// Finding 1: a non-empty-body 404 (a custom error-page template, extremely common in the
/// wild) still gets a `page_facts` row — `CrawlEngine.process` builds facts for any status
/// as long as the content type is HTML and the body is non-empty, not just for 200s. The
/// original `duplicateTitles` query had no status filter (unlike its siblings
/// `missingTitles`/`missingDescriptions`/`missingH1`), so an error template sharing a title
/// with a real page was wrongly counted as a duplicate. The brief's own fixture never
/// exercised this because its 404 returns an EMPTY body, so no facts row was ever created.
private struct NonEmpty404Client: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://dup404.test/" {
            return .response(HTTPResponse(
                status: 200, headers: ["Content-Type": "text/html"],
                body: Data("<html><head><title>Site</title></head><body><a href='/missing'>x</a></body></html>".utf8),
                elapsedMs: 1))
        }
        // Every other path 404s with a non-empty HTML body sharing the seed's title — a
        // stand-in for a custom error-page template.
        return .response(HTTPResponse(
            status: 404, headers: ["Content-Type": "text/html"],
            body: Data("<html><head><title>Site</title></head><body>Not found</body></html>".utf8),
            elapsedMs: 1))
    }
}

@Test func duplicateTitlesExcludesNon200Pages() async throws {
    var config = CrawlConfig(seedURL: "https://dup404.test/")
    config.workers = 1
    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: NonEmpty404Client(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    let s = try store.summary()
    #expect(s.duplicateTitles == 0, "the 404's title collides with the seed's, but a non-200 page isn't a real duplicate-title issue")
}

/// Finding 2: `urls` is deduplicated by `url_hash`, so a URL that is BOTH a normal link
/// target AND an `<img src>` reference collapses to a single row. The original exclusion
/// (`u.id NOT IN (SELECT src_url_id FROM images)`) excluded that row entirely, even though
/// it's a real page that was actually fetched — excluding by identity is wrong; only URLs
/// that exist *solely* as image sources should be excluded.
private struct LinkedAndEmbeddedClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://linkimg.test/" {
            return .response(HTTPResponse(
                status: 200, headers: ["Content-Type": "text/html"],
                body: Data("<html><head><title>Seed</title></head><body><a href='/b'>b</a><img src='/b'></body></html>".utf8),
                elapsedMs: 1))
        }
        if url == "https://linkimg.test/b" {
            return .response(HTTPResponse(
                status: 200, headers: ["Content-Type": "text/html"],
                body: Data("<html><head><title>B</title></head><body></body></html>".utf8),
                elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
    }
}

@Test func internalURLsKeepsPagesThatAreAlsoImageSources() async throws {
    var config = CrawlConfig(seedURL: "https://linkimg.test/")
    config.workers = 1
    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: LinkedAndEmbeddedClient(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    let s = try store.summary()
    #expect(s.internalURLs == 2, "/b is a real fetched page even though it's also embedded as an <img src>")
}
