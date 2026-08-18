import Foundation
import Testing
@testable import KodaCore

/// Records every URL `fetch` was called with, so tests can assert a fetch never happened
/// (not just that its result was ignored).
private final class CallRecorder: @unchecked Sendable {
    private var urls: [String] = []
    func record(_ url: String) { urls.append(url) }
    var count: Int { urls.count }
}

private struct RobotsClient: HTTPClient {
    let robotsStatus: Int
    let robotsBody: String
    var transportFailure: String? = nil
    var recorder: CallRecorder? = nil

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        recorder?.record(url)
        if url.hasSuffix("/robots.txt") {
            if let transportFailure {
                return .failure(kind: transportFailure)
            }
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
    let result = await CrawlSession.fetchRobots(for: seed, client: client, config: CrawlConfig(seedURL: seed.absoluteString))
    #expect(!result.rules.isAllowed(path: "/blocked", userAgent: "ScreamingKoda/0.1"))
    #expect(result.rules.isAllowed(path: "/allowed", userAgent: "ScreamingKoda/0.1"))
    #expect(result.outcome == .parsed)
}

@Test func missingRobotsMeansAllowAll() async {
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    let client = RobotsClient(robotsStatus: 404, robotsBody: "")
    let result = await CrawlSession.fetchRobots(for: seed, client: client, config: CrawlConfig(seedURL: seed.absoluteString))
    #expect(result.rules.isAllowed(path: "/anything", userAgent: "ScreamingKoda/0.1"))
}

@Test func robotsDisabledSkipsFetchEntirely() async {
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    var config = CrawlConfig(seedURL: seed.absoluteString)
    config.respectRobots = false
    let recorder = CallRecorder()
    let client = RobotsClient(robotsStatus: 200, robotsBody: "User-agent: *\nDisallow: /", recorder: recorder)
    let result = await CrawlSession.fetchRobots(for: seed, client: client, config: config)
    #expect(result.rules.isAllowed(path: "/anything", userAgent: "ScreamingKoda/0.1"))
    // The test's name promises no fetch happened at all, not merely that the result was
    // discarded — assert on the call count, not just the resulting rules.
    #expect(recorder.count == 0)
}

@Test func serverErrorRobotsMeansDisallowAll() async {
    // A 5xx means the server is unhealthy, not that it granted permission — this must not
    // be treated the same as a 404 (which genuinely means "no robots.txt exists").
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    let client = RobotsClient(robotsStatus: 503, robotsBody: "")
    let result = await CrawlSession.fetchRobots(for: seed, client: client, config: CrawlConfig(seedURL: seed.absoluteString))
    #expect(!result.rules.isAllowed(path: "/anything", userAgent: "ScreamingKoda/0.1"))
    #expect(result.outcome == .unreachable(reason: "http 503"))
}

@Test func transportFailureRobotsMeansDisallowAll() async {
    // A timeout / DNS failure / connection refused is equally not consent to crawl.
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    let client = RobotsClient(robotsStatus: 200, robotsBody: "", transportFailure: "timedOut")
    let result = await CrawlSession.fetchRobots(for: seed, client: client, config: CrawlConfig(seedURL: seed.absoluteString))
    #expect(!result.rules.isAllowed(path: "/anything", userAgent: "ScreamingKoda/0.1"))
    #expect(result.outcome == .unreachable(reason: "timedOut"))
}

@Test func outcomeDistinguishesAbsentFromUnreachableFromParsed() async {
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    let config = CrawlConfig(seedURL: seed.absoluteString)

    let missing = await CrawlSession.fetchRobots(
        for: seed, client: RobotsClient(robotsStatus: 404, robotsBody: ""), config: config)
    #expect(missing.outcome == .absent)

    let broken = await CrawlSession.fetchRobots(
        for: seed, client: RobotsClient(robotsStatus: 500, robotsBody: ""), config: config)
    #expect(broken.outcome == .unreachable(reason: "http 500"))

    let ok = await CrawlSession.fetchRobots(
        for: seed, client: RobotsClient(robotsStatus: 200, robotsBody: "User-agent: *\nDisallow: /x"), config: config)
    #expect(ok.outcome == .parsed)
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
    await #expect(throws: CrawlSessionError.self) {
        _ = try await CrawlSession.start(dbPath: nil, config: config,
                                         client: RobotsClient(robotsStatus: 404, robotsBody: ""),
                                         parser: SwiftSoupParser(), onProgress: nil)
    }
}
