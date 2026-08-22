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
    let store = try await CrawlSession.start(dbPath: nil, config: config, client: SummaryClient(),
                                             parser: SwiftSoupParser(), onProgress: nil)
    return try store.summary()
}

@Test func countsInternalURLs() async throws {
    let s = try await summarizedCrawl()
    // Four pages plus /i.png. An image on the seed host is an internal URL even
    // though M1 never fetches it, which is why internal != crawled below.
    #expect(s.internalURLs == 5)
    #expect(s.externalURLs == 0)
    #expect(s.totalURLs == 5)
}

@Test func countsCrawledURLsSeparatelyFromDiscovered() async throws {
    let s = try await summarizedCrawl()
    #expect(s.crawledURLs == 4, "the image is discovered but never fetched")
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
