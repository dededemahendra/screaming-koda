import Foundation
import GRDB
import Testing
@testable import KodaCore

/// A site that 401s everything without the right credentials — including
/// robots.txt, which is how a real protected staging environment behaves.
private final class ProtectedSite: HTTPClient, @unchecked Sendable {
    let expected: String
    /// A serial queue rather than NSLock: `lock()` is unavailable from an async
    /// context under Swift 6, and this recorder is written from inside `fetch`.
    private let queue = DispatchQueue(label: "protected-site.seen")
    private var seen: [String: [String: String]] = [:]

    init(expected: String) { self.expected = expected }

    func headers(for url: String) -> [String: String] {
        queue.sync { seen[url] ?? [:] }
    }

    private func record(_ url: String, _ headers: [String: String]) {
        queue.sync { seen[url] = headers }
    }

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        await fetch(url: url, method: method, userAgent: userAgent, timeout: timeout, headers: [:])
    }

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval,
               headers: [String: String]) async -> FetchOutcome {
        record(url, headers)

        guard headers["Authorization"] == expected || headers["X-Staging-Bypass"] == "let-me-in" else {
            return .response(HTTPResponse(status: 401, headers: [:], body: nil, elapsedMs: 1))
        }
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data("<html><head><title>Protected</title></head><body>ok</body></html>".utf8),
                                      elapsedMs: 1))
    }
}

private let credential = "Basic " + Data("admin:hunter2".utf8).base64EncodedString()

@Test func basicCredentialsBecomeAnAuthorizationHeader() {
    var config = CrawlConfig(seedURL: "https://p.test/")
    config.basicAuthUser = "admin"
    config.basicAuthPassword = "hunter2"
    #expect(config.requestHeaders["Authorization"] == credential)
    #expect(config.hasCredentials)
}

@Test func noCredentialsMeansNoAuthorizationHeader() {
    let config = CrawlConfig(seedURL: "https://p.test/")
    #expect(config.requestHeaders.isEmpty)
    #expect(!config.hasCredentials)
}

@Test func extraHeadersAreCarriedAlongsideCredentials() {
    var config = CrawlConfig(seedURL: "https://p.test/")
    config.basicAuthUser = "admin"
    config.extraHeaders = ["X-Staging-Bypass": "let-me-in"]
    #expect(config.requestHeaders["X-Staging-Bypass"] == "let-me-in")
    #expect(config.requestHeaders["Authorization"] != nil)
}

@MainActor
@Test func aProtectedSiteIsUnreachableWithoutCredentials() async throws {
    var config = CrawlConfig(seedURL: "https://p.test/")
    config.workers = 1
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: ProtectedSite(expected: credential),
        parser: SwiftSoupParser(), onProgress: nil)
    let status = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT status FROM responses LIMIT 1")
    }
    #expect(status == 401)
}

@MainActor
@Test func credentialsUnlockAProtectedSite() async throws {
    var config = CrawlConfig(seedURL: "https://p.test/")
    config.workers = 1
    config.basicAuthUser = "admin"
    config.basicAuthPassword = "hunter2"
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: ProtectedSite(expected: credential),
        parser: SwiftSoupParser(), onProgress: nil)
    let title = try await store.dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT title FROM page_facts LIMIT 1")
    }
    #expect(title == "Protected")
}

/// The one that actually matters. robots.txt is fetched before anything else,
/// and an unreachable robots.txt means disallow-all — so a crawl that
/// authenticates its pages but not its robots.txt produces nothing at all and
/// looks like a broken tool.
@MainActor
@Test func robotsAndSitemapFetchesCarryTheCredentialsToo() async throws {
    let client = ProtectedSite(expected: credential)
    var config = CrawlConfig(seedURL: "https://p.test/")
    config.workers = 1
    config.basicAuthUser = "admin"
    config.basicAuthPassword = "hunter2"
    config.sitemapURLs = ["https://p.test/sitemap.xml"]

    _ = try await CrawlSession.start(dbPath: nil, config: config, client: client,
                                     parser: SwiftSoupParser(), onProgress: nil)

    #expect(client.headers(for: "https://p.test/robots.txt")["Authorization"] == credential)
    #expect(client.headers(for: "https://p.test/sitemap.xml")["Authorization"] == credential)
}

@MainActor
@Test func anExtraHeaderAloneIsEnoughForAStagingBypass() async throws {
    var config = CrawlConfig(seedURL: "https://p.test/")
    config.workers = 1
    config.extraHeaders = ["X-Staging-Bypass": "let-me-in"]
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: ProtectedSite(expected: credential),
        parser: SwiftSoupParser(), onProgress: nil)
    let status = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT status FROM responses LIMIT 1")
    }
    #expect(status == 200)
}

@Test func credentialsRoundTripThroughTheStoredConfig() throws {
    var config = CrawlConfig(seedURL: "https://p.test/")
    config.basicAuthUser = "admin"
    config.basicAuthPassword = "hunter2"
    config.extraHeaders = ["X-Token": "abc"]
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: config, startedAt: Date())

    let reloaded = try #require(try store.loadConfig())
    #expect(reloaded.basicAuthUser == "admin")
    #expect(reloaded.extraHeaders == ["X-Token": "abc"])
}
