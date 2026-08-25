import Foundation
import GRDB
import Testing
@testable import KodaCore

/// A wide site: enough URLs that a stop lands mid-crawl rather than at the end.
private struct WideSite: HTTPClient {
    let onFetch: @Sendable (String) async -> Void

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        await onFetch(url)
        let body: String
        if url == "https://wide.test/" {
            let links = (0..<40).map { "<a href='/p\($0)'>p\($0)</a>" }.joined()
            body = "<html><head><title>Home</title></head><body><h1>H</h1>\(links)</body></html>"
        } else {
            body = "<html><head><title>Page</title></head><body><h1>P</h1></body></html>"
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

private func seededStore() throws -> (Store, CrawlConfig) {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://wide.test/")
    config.workers = 2
    config.checkExternalLinks = false
    config.checkImages = false
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize(config.seedURL, relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())
    return (store, config)
}

@Test func stopLeavesTheFrontierResumable() async throws {
    let (store, config) = try seededStore()
    let box = EngineBox()
    // Stop the moment the first page beyond the seed is fetched, so the crawl is
    // interrupted with the seed's forty links already queued.
    let client = WideSite(onFetch: { url in
        if url != "https://wide.test/" { await box.engine?.requestStop() }
    })
    let engine = CrawlEngine(store: store, client: client, parser: SwiftSoupParser(), config: config)
    await box.set(engine)

    let finished = try await engine.run(onProgress: nil)

    #expect(finished == false, "a stopped crawl does not report completion")
    let counts = try store.urlCounts()
    #expect(counts.inFlight == 0, "nothing is left claimed")
    #expect(counts.queued >= 1, "the frontier still holds work")
}

@Test func aStoppedCrawlFinishesOnASecondRun() async throws {
    let (store, config) = try seededStore()

    let first = CrawlEngine(store: store, client: WideSite(onFetch: { _ in }),
                            parser: SwiftSoupParser(), config: config)
    await first.requestStop()
    #expect(try await first.run(onProgress: nil) == false)
    #expect(try store.urlCounts().done == 0, "stopping before the first chunk crawls nothing")

    let second = CrawlEngine(store: store, client: WideSite(onFetch: { _ in }),
                             parser: SwiftSoupParser(), config: config)
    #expect(try await second.run(onProgress: nil) == true)
    #expect(try store.urlCounts().queued == 0)
    #expect(try store.urlCounts().done == 41, "the seed plus all forty pages")
}

@Test func stoppingMidCrawlKeepsWhatWasAlreadyDone() async throws {
    let (store, config) = try seededStore()

    // Stop once a handful of pages are in, so the crawl is genuinely partial.
    actor Counter {
        var seen = 0
        func bump() -> Int { seen += 1; return seen }
    }
    let counter = Counter()
    let box = EngineBox()
    let client = WideSite(onFetch: { _ in
        if await counter.bump() >= 5 { await box.engine?.requestStop() }
    })
    let engine = CrawlEngine(store: store, client: client, parser: SwiftSoupParser(), config: config)
    await box.set(engine)

    let finished = try await engine.run(onProgress: nil)
    #expect(finished == false)

    let partial = try store.urlCounts()
    #expect(partial.done > 0, "work already completed is kept")
    #expect(partial.done < 41, "but the crawl really did stop early")
    #expect(partial.inFlight == 0)

    // Resuming completes it without redoing what was finished.
    let resumed = CrawlEngine(store: store, client: WideSite(onFetch: { _ in }),
                              parser: SwiftSoupParser(), config: config)
    #expect(try await resumed.run(onProgress: nil) == true)
    #expect(try store.urlCounts().done == 41)
}

@Test func aFinishedCrawlIsMarkedFinishedAndAStoppedOneIsNot() async throws {
    let (store, config) = try seededStore()

    let stopped = CrawlEngine(store: store, client: WideSite(onFetch: { _ in }),
                              parser: SwiftSoupParser(), config: config)
    await stopped.requestStop()
    _ = try await stopped.run(onProgress: nil)
    let afterStop = try await store.dbQueue.read { db in
        try Double.fetchOne(db, sql: "SELECT finished_at FROM crawl_meta WHERE id = 1")
    }
    #expect(afterStop == nil, "a stopped crawl must not look complete")

    let completing = CrawlEngine(store: store, client: WideSite(onFetch: { _ in }),
                                 parser: SwiftSoupParser(), config: config)
    _ = try await completing.run(onProgress: nil)
    let afterFinish = try await store.dbQueue.read { db in
        try Double.fetchOne(db, sql: "SELECT finished_at FROM crawl_meta WHERE id = 1")
    }
    #expect(afterFinish != nil)
}

/// Lets the stub client reach the engine that owns it.
private actor EngineBox {
    private(set) var engine: CrawlEngine?
    func set(_ engine: CrawlEngine) { self.engine = engine }
}

@Test func resumingClearsTheFinishedMarkSoAStopCannotLookDone() async throws {
    let (store, config) = try seededStore()
    let engine = CrawlEngine(store: store, client: WideSite(onFetch: { _ in }),
                             parser: SwiftSoupParser(), config: config)
    _ = try await engine.run(onProgress: nil)
    let finished = try #require(try store.crawlMeta())
    #expect(finished.isFinished)
    #expect(finished.seedURL == "https://wide.test/")

    // Starting again over the same database is a resume, and a resumed crawl is
    // running. Leaving the old finish time in place would let a crawl that was
    // stopped halfway through report itself as complete.
    try store.initializeCrawl(config: config, startedAt: Date())
    let reopened = try #require(try store.crawlMeta())
    #expect(reopened.isFinished == false)
    #expect(reopened.startedAt == finished.startedAt, "the crawl still started when it started")
}

@Test func anUnfinishedCrawlHasNoDurationRatherThanAGrowingOne() {
    let started = Date(timeIntervalSince1970: 1_700_000_000)

    let done = CrawlMeta(seedURL: "https://x.test/", startedAt: started,
                         finishedAt: started.addingTimeInterval(42))
    #expect(done.duration == 42)

    // The database records when a crawl started and when it finished, and
    // nothing else. Measuring an unfinished crawl against the clock says a run
    // that was stopped last week took a week, which is a number about the
    // calendar rather than the crawl.
    #expect(CrawlMeta(seedURL: "https://x.test/", startedAt: started, finishedAt: nil).duration == nil)
}

/// A site whose one external link is slow to answer, so a stop can land while
/// the status-check phase has it claimed.
private struct ExternalSite: HTTPClient {
    let onExternal: @Sendable () async -> Void

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url.hasPrefix("https://away.test/") {
            await onExternal()
            return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                          body: Data("<html><body><a href='/deep'>Deep</a></body></html>".utf8),
                                          elapsedMs: 1))
        }
        let links = (0..<6).map { "<a href='https://away.test/e\($0)'>e\($0)</a>" }.joined()
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data("<html><head><title>H</title></head><body><h1>H</h1>\(links)</body></html>".utf8),
                                      elapsedMs: 1))
    }
}

@Test func stoppingDuringTheStatusCheckDoesNotTurnExternalURLsIntoCrawlTargets() async throws {
    // External URLs are recorded as skipped and only ever HEAD-checked. If a stop
    // handed them back to the frontier as queued, resuming would GET and parse
    // third-party pages and follow their links — the crawl would leave the site.
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://ext.test/")
    config.workers = 2
    config.checkImages = false
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize(config.seedURL, relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    let box = EngineBox()
    let engine = CrawlEngine(
        store: store,
        client: ExternalSite(onExternal: { await box.engine?.requestStop() }),
        parser: SwiftSoupParser(), config: config
    )
    await box.set(engine)
    _ = try await engine.run(onProgress: nil)

    let queuedExternal = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE is_internal = 0 AND state = 0") ?? 0
    }
    #expect(queuedExternal == 0, "a stopped status check must not queue external URLs for crawling")

    // And resuming must not fetch one as a page.
    let resumed = CrawlEngine(store: store, client: ExternalSite(onExternal: {}),
                              parser: SwiftSoupParser(), config: config)
    _ = try await resumed.run(onProgress: nil)
    let externalWithFacts = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM page_facts f JOIN urls u ON u.id = f.url_id WHERE u.is_internal = 0
            """) ?? 0
    }
    #expect(externalWithFacts == 0, "an external page is status-checked, never parsed")
}
