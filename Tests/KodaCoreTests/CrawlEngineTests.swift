import Foundation
import GRDB
import Testing
@testable import KodaCore

/// A fixture site with a known shape: a redirect chain, a 404, duplicate titles, a noindex page.
private struct FixtureClient: HTTPClient {
    let pages: [String: (Int, [String: String], String)]

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        guard let (status, headers, body) = pages[url] else {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        var merged = headers
        if merged["Content-Type"] == nil { merged["Content-Type"] = "text/html" }
        return .response(HTTPResponse(status: status, headers: merged, body: Data(body.utf8), elapsedMs: 1))
    }
}

private func html(title: String, body: String) -> String {
    "<html><head><title>\(title)</title></head><body>\(body)</body></html>"
}

private let site: [String: (Int, [String: String], String)] = [
    "https://site.test/": (200, [:], html(title: "Home", body: """
        <a href="/about">About</a><a href="/old">Old</a><a href="/gone">Gone</a>
        <a href="/dupe">Dupe</a><a href="https://external.test/x">Ext</a>
        """)),
    "https://site.test/about": (200, [:], html(title: "About", body: "<p>About us</p>")),
    "https://site.test/old": (301, ["Location": "https://site.test/new"], ""),
    "https://site.test/new": (200, [:], html(title: "New", body: "<p>Moved here</p>")),
    "https://site.test/gone": (404, [:], ""),
    "https://site.test/dupe": (200, [:], html(title: "About", body: "<p>Duplicate title</p>")),
]

private func runCrawl(config: CrawlConfig? = nil) async throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    var cfg = config ?? CrawlConfig(seedURL: "https://site.test/")
    cfg.workers = 2
    try store.initializeCrawl(config: cfg, startedAt: Date())
    let seed = URLNormalizer.normalize(cfg.seedURL, relativeTo: nil)!
    _ = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())

    let engine = CrawlEngine(store: store, client: FixtureClient(pages: site),
                             parser: SwiftSoupParser(), config: cfg)
    try await engine.run(onProgress: nil)
    return store
}

@Test func crawlsEveryInternalPage() async throws {
    let store = try await runCrawl()
    let crawled = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id
            WHERE u.is_internal = 1 ORDER BY u.path
            """)
    }
    #expect(crawled == ["/", "/about", "/dupe", "/gone", "/new", "/old"])
}

@Test func recordsRedirectChain() async throws {
    let store = try await runCrawl()
    try await store.dbQueue.read { db in
        let row = try Row.fetchOne(db, sql: """
            SELECT r.status, t.url AS target FROM responses r
            JOIN urls u ON u.id = r.url_id
            LEFT JOIN urls t ON t.id = r.redirect_target_id
            WHERE u.path = '/old'
            """)
        #expect(row?["status"] == 301)
        #expect(row?["target"] == "https://site.test/new")
    }
}

@Test func recordsNotFound() async throws {
    let store = try await runCrawl()
    let status = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT r.status FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/gone'")
    }
    #expect(status == 404)
}

@Test func externalLinksAreRecordedButNotCrawled() async throws {
    let store = try await runCrawl()
    try await store.dbQueue.read { db in
        let external = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE host = 'external.test'")
        #expect(external == 1)
        let fetched = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.host = 'external.test'
            """)
        #expect(fetched == 0, "external URLs are not fetched in M1")
    }
}

@Test func duplicateTitlesAreQueryable() async throws {
    let store = try await runCrawl()
    let dupes = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM (SELECT title FROM page_facts WHERE title IS NOT NULL
                                  GROUP BY title HAVING count(*) > 1)
            """)
    }
    #expect(dupes == 1, "About appears twice")
}

@Test func terminatesAndMarksNothingInFlight() async throws {
    let store = try await runCrawl()
    let counts = try store.urlCounts()
    #expect(counts.queued == 0)
    #expect(counts.inFlight == 0)
}

@Test func respectsURLCap() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.urlCap = 2
    let store = try await runCrawl(config: config)
    #expect(try store.urlCounts().done <= 3, "cap limits how much gets queued")
}

@Test func respectsMaxDepth() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.maxDepth = 0
    let store = try await runCrawl(config: config)
    let fetched = try await store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM responses") ?? 0 }
    #expect(fetched == 1, "only the seed is crawled at depth 0")
}

@Test func robotsDisallowSkipsURL() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 1
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize("https://site.test/", relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    let robots = RobotsRules.parse("User-agent: *\nDisallow: /about")
    let engine = CrawlEngine(store: store, client: FixtureClient(pages: site),
                             parser: SwiftSoupParser(), config: config, robots: robots)
    try await engine.run(onProgress: nil)

    let aboutFetched = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/about'
            """) ?? 0
    }
    #expect(aboutFetched == 0)
}

@Test func reportsProgress() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 1
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize("https://site.test/", relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    final class Box: @unchecked Sendable { var updates: [CrawlProgress] = [] }
    let box = Box()
    let engine = CrawlEngine(store: store, client: FixtureClient(pages: site),
                             parser: SwiftSoupParser(), config: config)
    try await engine.run(onProgress: { box.updates.append($0) })

    #expect(!box.updates.isEmpty)
    #expect(box.updates.last!.crawled >= 6)
}
