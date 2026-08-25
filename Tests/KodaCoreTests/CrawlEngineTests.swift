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

@Test func externalLinksAreStatusCheckedButNeverParsed() async throws {
    let store = try await runCrawl()
    try await store.dbQueue.read { db in
        let external = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE host = 'external.test'")
        #expect(external == 1)
        let checked = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.host = 'external.test'
            """)
        #expect(checked == 1, "external links get a status")
        let parsed = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM page_facts f JOIN urls u ON u.id = f.url_id WHERE u.host = 'external.test'
            """)
        #expect(parsed == 0, "but are never parsed, so they contribute no facts or links")
    }
}

@Test func externalCheckingCanBeTurnedOff() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.checkExternalLinks = false
    let store = try await runCrawl(config: config)
    let checked = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.is_internal = 0
            """) ?? 0
    }
    #expect(checked == 0)
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
    // The seed is the only page crawled. Its external link still gets a status:
    // depth limits govern how far the crawl walks, not whether a link it already
    // found is checked.
    let pages = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.is_internal = 1
            """) ?? 0
    }
    #expect(pages == 1, "only the seed is crawled at depth 0")
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

/// Records the high-water mark of simultaneous in-flight fetches.
private actor ConcurrencyProbe {
    private var inFlight = 0
    private(set) var peak = 0

    func enter() {
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func leave() { inFlight -= 1 }
}

private struct ProbingClient: HTTPClient {
    let probe: ConcurrencyProbe
    let pages: [String: (Int, [String: String], String)]

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        await probe.enter()
        // A real suspension, so genuinely concurrent fetches overlap observably.
        try? await Task.sleep(nanoseconds: 1_000_000)
        await probe.leave()

        guard let (status, headers, body) = pages[url] else {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        var merged = headers
        if merged["Content-Type"] == nil { merged["Content-Type"] = "text/html" }
        return .response(HTTPResponse(status: status, headers: merged, body: Data(body.utf8), elapsedMs: 1))
    }
}

private func peakConcurrency(robots: RobotsRules) async throws -> Int {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 5
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize("https://site.test/", relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    let probe = ConcurrencyProbe()
    let engine = CrawlEngine(store: store, client: ProbingClient(probe: probe, pages: site),
                             parser: SwiftSoupParser(), config: config, robots: robots)
    try await engine.run(onProgress: nil)
    return await probe.peak
}

@Test func crawlDelaySerializesRequests() async throws {
    // A crawl-delay bounds the interval between requests. Firing `workers` of them
    // at once and sleeping once per batch would be `workers` times too fast.
    let robots = RobotsRules.parse("User-agent: *\nCrawl-delay: 0.01")
    #expect(try await peakConcurrency(robots: robots) == 1)
}

@Test func withoutCrawlDelayRequestsRunConcurrently() async throws {
    // Control for the test above: proves the probe can observe concurrency at all.
    #expect(try await peakConcurrency(robots: .allowAll) > 1)
}

@Test func bodyRetentionStopsPastTheURLLimit() async throws {
    // Storing the HTML of half a million pages turns a database that fits on a
    // laptop into one that does not, which is what retainBodyURLLimit is for.
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 1
    config.retainBodyURLLimit = 3

    let store = try await runCrawl(config: config)
    let withBodies = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM responses WHERE body_gz IS NOT NULL") ?? 0
    }
    let total = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM responses WHERE status = 200") ?? 0
    }
    #expect(withBodies > 0, "early pages are retained")
    #expect(withBodies < total, "retention stops once the crawl grows past the limit")
}

@Test func retainBodiesOffStoresNothing() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.retainBodies = false
    let store = try await runCrawl(config: config)
    let withBodies = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM responses WHERE body_gz IS NOT NULL") ?? 0
    }
    #expect(withBodies == 0)
}

@Test func excludePatternsKeepURLsOutOfTheCrawl() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.exclude = ["/dupe"]
    let store = try await runCrawl(config: config)
    let paths = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id
            WHERE u.is_internal = 1 ORDER BY u.path
            """)
    }
    #expect(!paths.contains("/dupe"))
    #expect(paths.contains("/about"))
}

@Test func includePatternsRestrictTheCrawl() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.include = ["/about$"]
    let store = try await runCrawl(config: config)
    let paths = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id
            WHERE u.is_internal = 1 ORDER BY u.path
            """)
    }
    // The seed is always crawled; beyond it only matching URLs are enqueued.
    #expect(paths == ["/", "/about"])
}

/// Counts fast pages, and holds the slow one until they have all been served.
///
/// The gate is the point: a timing-based version of this test compares a 5ms
/// sleep against a 300ms one, and macOS coalesces short timers hard enough
/// under the test runner that the ratio does not survive. Ordering does.
private actor SlowPageProbe {
    private(set) var fastDone = 0
    private(set) var fastDoneBeforeSlow: Int?

    private let target: Int
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(target: Int) { self.target = target }

    func fastFinished() {
        fastDone += 1
        if fastDone >= target { open() }
    }

    func slowFinished() { fastDoneBeforeSlow = fastDone }

    /// Lets the slow page through regardless of how many fast ones have landed,
    /// so a design that starves the workers fails the test rather than hanging it.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        waiter?.resume()
        waiter = nil
    }

    func waitForFastPages() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// One page that waits for every other page, and ten that answer immediately.
private struct StallingSite: HTTPClient {
    let probe: SlowPageProbe

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        func page(_ body: String) -> FetchOutcome {
            .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                   body: Data(body.utf8), elapsedMs: 1))
        }
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://stall.test/" {
            let links = ["<a href='/slow'>slow</a>"]
                + (0..<10).map { "<a href='/f\($0)'>f\($0)</a>" }
            return page("<html><head><title>T</title></head><body><h1>H</h1>\(links.joined())</body></html>")
        }
        if url == "https://stall.test/slow" {
            await probe.waitForFastPages()
            await probe.slowFinished()
            return page("<html><head><title>Slow</title></head><body><h1>S</h1></body></html>")
        }
        await probe.fastFinished()
        return page("<html><head><title>Fast</title></head><body><h1>F</h1></body></html>")
    }
}

@Test func oneSlowURLDoesNotStallTheOtherWorkers() async throws {
    // The frontier claims /slow first, so a design that waits for a whole round
    // to finish before starting the next would leave workers idle behind it.
    let probe = SlowPageProbe(target: 10)
    var config = CrawlConfig(seedURL: "https://stall.test/")
    config.workers = 3

    // Bounded, so a regression reports "4 of 10" instead of wedging the suite.
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        await probe.open()
    }
    defer { watchdog.cancel() }

    _ = try await CrawlSession.start(dbPath: nil, config: config, client: StallingSite(probe: probe),
                                     parser: SwiftSoupParser(), onProgress: nil)

    let before = await probe.fastDoneBeforeSlow
    #expect(before != nil, "the slow page was crawled")
    #expect(before == 10, "fast pages must keep flowing while one URL hangs, got \(before ?? -1)")
}

/// A site whose hub page carries a page-level nofollow directive.
private struct NofollowSite: HTTPClient {
    /// Where the directive lives: a meta tag, or the X-Robots-Tag header.
    let inHeader: Bool
    let directive: String

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        var headers = ["Content-Type": "text/html"]
        var meta = ""
        if url == "https://nf.test/hub" {
            if inHeader { headers["X-Robots-Tag"] = directive } else {
                meta = "<meta name=\"robots\" content=\"\(directive)\">"
            }
        }
        let body = url == "https://nf.test/"
            ? "<html><head><title>H</title></head><body><h1>H</h1><a href='/hub'>Hub</a></body></html>"
            : "<html><head><title>P</title>\(meta)</head><body><h1>P</h1><a href='/deep'>Deep</a></body></html>"
        return .response(HTTPResponse(status: 200, headers: headers, body: Data(body.utf8), elapsedMs: 1))
    }
}

private func nofollowPaths(inHeader: Bool, directive: String, follow: Bool = false) async throws -> [String] {
    var config = CrawlConfig(seedURL: "https://nf.test/")
    config.workers = 2
    config.followInternalNofollow = follow
    config.checkExternalLinks = false
    config.checkImages = false
    let store = try await CrawlSession.start(
        dbPath: nil, config: config, client: NofollowSite(inHeader: inHeader, directive: directive),
        parser: SwiftSoupParser(), onProgress: nil
    )
    return try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id ORDER BY u.path
            """)
    }
}

@Test func aPageLevelNofollowStopsTheCrawlAtThatPage() async throws {
    // rel=nofollow on a link and nofollow on the page are the same directive,
    // written in two places. Honouring one and not the other means a crawl that
    // says it respects nofollow and does not.
    #expect(try await nofollowPaths(inHeader: false, directive: "nofollow") == ["/", "/hub"])
    #expect(try await nofollowPaths(inHeader: false, directive: "noindex, nofollow") == ["/", "/hub"])
    #expect(try await nofollowPaths(inHeader: false, directive: "none") == ["/", "/hub"],
            "none is the shorthand for noindex plus nofollow")
    #expect(try await nofollowPaths(inHeader: true, directive: "nofollow") == ["/", "/hub"],
            "X-Robots-Tag says the same thing in a header")

    #expect(try await nofollowPaths(inHeader: false, directive: "noindex") == ["/", "/deep", "/hub"],
            "noindex is about indexing, not crawling")
    #expect(try await nofollowPaths(inHeader: false, directive: "nofollow", follow: true)
        == ["/", "/deep", "/hub"], "--follow-nofollow governs both forms")
}

@Test func aNofollowPageStillContributesToTheLinkGraph() async throws {
    var config = CrawlConfig(seedURL: "https://nf.test/")
    config.workers = 2
    config.checkExternalLinks = false
    config.checkImages = false
    let store = try await CrawlSession.start(
        dbPath: nil, config: config, client: NofollowSite(inHeader: false, directive: "nofollow"),
        parser: SwiftSoupParser(), onProgress: nil
    )
    let targets = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT dst.path FROM links l JOIN urls dst ON dst.id = l.to_url_id
            JOIN urls src ON src.id = l.from_url_id WHERE src.path = '/hub'
            """)
    }
    // Not crawling it is not the same as not knowing about it: the inspector's
    // outlinks pane and the broken-link report both read this table.
    #expect(targets == ["/deep"])
}
