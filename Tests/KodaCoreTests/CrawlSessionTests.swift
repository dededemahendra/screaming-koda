import Foundation
import Testing
@testable import KodaCore

private struct RobotsClient: HTTPClient {
    let robotsStatus: Int
    let robotsBody: String

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: robotsStatus, headers: ["Content-Type": "text/plain"],
                                          body: Data(robotsBody.utf8), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data("<html><head><title>P</title></head><body></body></html>".utf8),
                                      elapsedMs: 1))
    }
}

@Test func fetchesAndParsesRobots() async {
    let seed = URLNormalizer.normalize("https://site.test/some/page", relativeTo: nil)!
    let client = RobotsClient(robotsStatus: 200, robotsBody: "User-agent: *\nDisallow: /blocked")
    let rules = await CrawlSession.fetchRobots(for: seed, client: client, config: CrawlConfig(seedURL: seed.absoluteString))
    #expect(!rules.isAllowed(path: "/blocked", userAgent: "ScreamingKoda/0.1"))
    #expect(rules.isAllowed(path: "/allowed", userAgent: "ScreamingKoda/0.1"))
}

@Test func missingRobotsMeansAllowAll() async {
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    let client = RobotsClient(robotsStatus: 404, robotsBody: "")
    let rules = await CrawlSession.fetchRobots(for: seed, client: client, config: CrawlConfig(seedURL: seed.absoluteString))
    #expect(rules.isAllowed(path: "/anything", userAgent: "ScreamingKoda/0.1"))
}

@Test func robotsDisabledSkipsFetchEntirely() async {
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    var config = CrawlConfig(seedURL: seed.absoluteString)
    config.respectRobots = false
    let client = RobotsClient(robotsStatus: 200, robotsBody: "User-agent: *\nDisallow: /")
    let rules = await CrawlSession.fetchRobots(for: seed, client: client, config: config)
    #expect(rules.isAllowed(path: "/anything", userAgent: "ScreamingKoda/0.1"))
}

@Test func startSeedsFrontierAndCrawls() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 1
    let store = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: RobotsClient(robotsStatus: 404, robotsBody: ""),
        parser: SwiftSoupParser(), onProgress: nil
    )
    let counts = try store.urlCounts()
    #expect(counts.done >= 1)
    #expect(counts.queued == 0)
}

@Test func startRejectsInvalidSeed() async {
    let config = CrawlConfig(seedURL: "not a url")
    await #expect(throws: (any Error).self) {
        _ = try await CrawlSession.start(dbPath: nil, config: config,
                                         client: RobotsClient(robotsStatus: 404, robotsBody: ""),
                                         parser: SwiftSoupParser(), onProgress: nil)
    }
}
