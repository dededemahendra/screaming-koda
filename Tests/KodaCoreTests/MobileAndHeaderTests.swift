import Foundation
import GRDB
import Testing
@testable import KodaCore

// MARK: - Mobile

/// A site that serves different markup to phones is otherwise crawled as the
/// desktop version only.
@Test func crawlingAsAPhoneSendsAMobileUserAgent() {
    var config = CrawlConfig(seedURL: "https://m.test/")
    #expect(config.effectiveUserAgent == KodaCoreInfo.userAgent)

    config.mobile = true
    #expect(config.effectiveUserAgent.contains("iPhone"))
    #expect(config.effectiveUserAgent.contains("Mobile"),
            "mobile markup is usually chosen on this token")
}

/// A user agent the person set themselves wins over the mobile preset, because
/// they set it on purpose.
@Test func anExplicitUserAgentSurvivesMobileMode() {
    var config = CrawlConfig(seedURL: "https://m.test/")
    config.mobile = true
    config.userAgent = "MyBot/1.0"
    #expect(config.effectiveUserAgent == "MyBot/1.0")
}

private struct AgentRecorder: HTTPClient, @unchecked Sendable {
    let seen = Box()
    final class Box: @unchecked Sendable {
        private let queue = DispatchQueue(label: "agent")
        private var value: String?
        var agent: String? {
            get { queue.sync { value } }
            set { queue.sync { value = newValue } }
        }
    }

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        seen.agent = userAgent
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200,
                                      headers: ["Content-Type": "text/html", "X-Served-By": "edge-7"],
                                      body: Data("<html><head><title>M</title></head><body>x</body></html>".utf8),
                                      elapsedMs: 1))
    }
}

@MainActor
@Test func theMobileAgentReachesTheActualRequest() async throws {
    var config = CrawlConfig(seedURL: "https://m.test/")
    config.workers = 1
    config.mobile = true
    let client = AgentRecorder()
    _ = try await CrawlSession.start(dbPath: nil, config: config, client: client,
                                     parser: SwiftSoupParser(), onProgress: nil)
    #expect(client.seen.agent?.contains("iPhone") == true)
}

// MARK: - Header extraction

@MainActor
@Test func anamedHeaderIsPulledIntoTheExtractionTab() async throws {
    var config = CrawlConfig(seedURL: "https://m.test/")
    config.workers = 1
    config.headerExtractions = ["X-Served-By"]

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: AgentRecorder(),
        parser: SwiftSoupParser(), onProgress: nil)

    let rows = try await store.dbQueue.read { db in
        try Row.fetchAll(db, sql: "SELECT name, value FROM extractions")
    }
    #expect(rows.count == 1)
    #expect(rows.first?["name"] == "X-Served-By")
    #expect(rows.first?["value"] == "edge-7")
}

/// Header names are not case-sensitive, and servers are inconsistent about
/// them, so a rule written one way must match a header sent another.
@MainActor
@Test func headerExtractionIsCaseInsensitive() async throws {
    var config = CrawlConfig(seedURL: "https://m.test/")
    config.workers = 1
    config.headerExtractions = ["x-served-by"]

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: AgentRecorder(),
        parser: SwiftSoupParser(), onProgress: nil)
    let value = try await store.dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM extractions")
    }
    #expect(value == "edge-7")
}

@MainActor
@Test func aHeaderThatIsNotSentProducesNoRow() async throws {
    var config = CrawlConfig(seedURL: "https://m.test/")
    config.workers = 1
    config.headerExtractions = ["X-Not-Present"]

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: AgentRecorder(),
        parser: SwiftSoupParser(), onProgress: nil)
    let count = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM extractions") ?? 0
    }
    #expect(count == 0, "absent, not an empty value")
}
