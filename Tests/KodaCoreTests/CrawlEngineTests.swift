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
    // Real, parseable content — a 200 with an anchor the parser genuinely could follow.
    // Without this, a bodyless 404 fallback would fail `isHTML` and empty-body checks on
    // its own, so "no links, no facts" would hold even if checkOnly threading were broken
    // and this URL went down the ordinary full-crawl path. Giving it something to decline
    // to parse is what makes `externalLinksGetAStatusCheckButAreNotCrawled` meaningful.
    "https://external.test/x": (200, [:], html(title: "External", body: "<a href=\"/somewhere\">x</a>")),
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

@Test func externalLinksGetAStatusCheckButAreNotCrawled() async throws {
    let store = try await runCrawl()
    try await store.dbQueue.read { db in
        let external = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE host = 'external.test'")
        #expect(external == 1)
        // M3a: external links are fetched with a status-only HEAD (config.checkExternalLinks,
        // on by default) so a broken outbound link can be reported.
        let fetched = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.host = 'external.test'
            """)
        #expect(fetched == 1, "external URLs get a status check as of M3a")

        // ...but that status check must never turn into a crawl of the other site: no
        // outgoing links discovered from it, and no page facts extracted for it.
        let outgoingLinks = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM links l JOIN urls u ON u.id = l.from_url_id WHERE u.host = 'external.test'
            """)
        #expect(outgoingLinks == 0, "a status check must never crawl onwards from the external URL")
        let facts = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM page_facts f JOIN urls u ON u.id = f.url_id WHERE u.host = 'external.test'
            """)
        #expect(facts == 0, "a status check must never extract page facts for the external URL")
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

@Test func retainBodiesStopsPastRetainBodyURLLimit() async throws {
    // A tiny limit stands in for the real 50_000 default so the cutoff is reachable
    // in a fast test. workers = 1 with no crawl-delay makes claimNext process exactly
    // one URL per iteration, so `crawled` advances deterministically: seed then /a
    // are fetched while `crawled` is 0 then 1 (both < 2, so both retain their body);
    // /b and /c are fetched while `crawled` is 2 then 3 (both >= 2, so neither does).
    let pages: [String: (Int, [String: String], String)] = [
        "https://tiny.test/": (200, [:], html(title: "Home", body: """
            <a href="/a">A</a><a href="/b">B</a><a href="/c">C</a>
            """)),
        "https://tiny.test/a": (200, [:], html(title: "A", body: "<p>a</p>")),
        "https://tiny.test/b": (200, [:], html(title: "B", body: "<p>b</p>")),
        "https://tiny.test/c": (200, [:], html(title: "C", body: "<p>c</p>")),
    ]
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://tiny.test/")
    config.workers = 1
    config.retainBodyURLLimit = 2
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize(config.seedURL, relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    let engine = CrawlEngine(store: store, client: FixtureClient(pages: pages),
                             parser: SwiftSoupParser(), config: config)
    try await engine.run(onProgress: nil)

    let retained = try await store.dbQueue.read { db in
        try Int.fetchAll(db, sql: """
            SELECT (body_gz IS NOT NULL) FROM responses r JOIN urls u ON u.id = r.url_id
            ORDER BY u.depth ASC, u.id ASC
            """)
    }
    #expect(retained == [1, 1, 0, 0], "bodies retained for the first two crawled URLs, not the rest")
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

/// Tracks how many `fetch` calls are simultaneously in flight, for asserting on
/// whether crawl-delay actually serializes requests instead of just spacing batches.
private actor ConcurrencyTracker {
    private var current = 0
    private var maxObserved = 0

    func enter() {
        current += 1
        maxObserved = max(maxObserved, current)
    }

    func exit() {
        current -= 1
    }

    func maxConcurrency() -> Int { maxObserved }
}

/// Like `FixtureClient`, but holds each fetch open for `fetchDelay` and reports its
/// entry/exit to a `ConcurrencyTracker` so tests can observe overlap between requests.
private struct TrackingClient: HTTPClient {
    let pages: [String: (Int, [String: String], String)]
    let tracker: ConcurrencyTracker
    let fetchDelay: TimeInterval

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        await tracker.enter()
        try? await Task.sleep(nanoseconds: UInt64(fetchDelay * 1_000_000_000))
        let outcome: FetchOutcome
        if let (status, headers, body) = pages[url] {
            var merged = headers
            if merged["Content-Type"] == nil { merged["Content-Type"] = "text/html" }
            outcome = .response(HTTPResponse(status: status, headers: merged, body: Data(body.utf8), elapsedMs: 1))
        } else {
            outcome = .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        await tracker.exit()
        return outcome
    }
}

@Test func crawlDelaySerializesRequests() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 5
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize("https://site.test/", relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    let tracker = ConcurrencyTracker()
    let client = TrackingClient(pages: site, tracker: tracker, fetchDelay: 0.02)
    // A tiny crawl-delay keeps the suite fast while still requiring serialization.
    let robots = RobotsRules.parse("User-agent: *\nCrawl-delay: 0.01")
    let engine = CrawlEngine(store: store, client: client, parser: SwiftSoupParser(),
                             config: config, robots: robots)
    try await engine.run(onProgress: nil)

    let maxConcurrency = await tracker.maxConcurrency()
    #expect(maxConcurrency == 1, "crawl-delay must serialize requests, not fire a concurrent burst every interval")
}

@Test func noCrawlDelayAllowsConcurrentRequests() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 5
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize("https://site.test/", relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    let tracker = ConcurrencyTracker()
    let client = TrackingClient(pages: site, tracker: tracker, fetchDelay: 0.02)
    let engine = CrawlEngine(store: store, client: client, parser: SwiftSoupParser(), config: config)
    try await engine.run(onProgress: nil)

    let maxConcurrency = await tracker.maxConcurrency()
    #expect(maxConcurrency > 1, "without crawl-delay, workers should still fetch concurrently")
}
