import Foundation
import Testing
@testable import KodaCore
@testable import KodaUI

private struct ThreePageClient: HTTPClient {
    var robotsStatus: Int = 404
    var robotsBody: String = ""

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: robotsStatus, headers: ["Content-Type": "text/plain"],
                                          body: Data(robotsBody.utf8), elapsedMs: 1))
        }
        let body = url.hasSuffix("/")
            ? "<html><head><title>Home</title></head><body><a href=\"/a\">a</a><a href=\"/b\">b</a></body></html>"
            : "<html><head><title>Page</title></head><body>leaf</body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

/// Many linked pages and a small artificial delay per fetch, so the crawl
/// takes long enough (several batches, tens of milliseconds apart) that a
/// test can reliably observe `.running` and land a `pause()` in the middle —
/// `ThreePageClient`'s three pages complete in a single poll tick of
/// `waitUntil`, too fast to pause mid-crawl deterministically.
private struct SlowManyPageClient: HTTPClient {
    /// Far more pages than the one test using this needs to crawl, because that
    /// test pauses partway and then stops rather than finishing. The count is
    /// runway: at 20ms a page across the default workers, forty pages gave the
    /// crawl about 160ms of life, which scheduling jitter under parallel test
    /// execution routinely ate — the crawl finished before `pause()` landed and
    /// the test failed on `.finished` where it expected `.paused`.
    var pageCount = 200

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"],
                                          body: Data(), elapsedMs: 1))
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let body: String
        if url.hasSuffix("/") {
            let links = (0..<pageCount).map { "<a href=\"/p\($0)\">p\($0)</a>" }.joined()
            body = "<html><head><title>Home</title></head><body>\(links)</body></html>"
        } else {
            body = "<html><head><title>Page</title></head><body>leaf</body></html>"
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

private struct FailingClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        .failure(kind: "URLError.cannotFindHost")
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

@MainActor
@Test func startsIdle() {
    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPath: nil)
    #expect(c.state == .idle)
    #expect(c.rows == nil)
}

@MainActor
@Test func runningACrawlReachesFinishedAndPopulatesRows() async {
    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://three.test/"
    await c.start()

    #expect(await waitUntil { c.state == .finished }, "state was \(c.state)")
    c.rows?.refresh()
    #expect((c.rows?.count ?? 0) >= 3, "home plus two linked pages")
}

@MainActor
@Test func anInvalidSeedIsRefusedWithoutStartingACrawl() async {
    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "not a url"
    await c.start()

    #expect(c.state == .idle, "a refused start leaves the controller idle")
    #expect(c.notice != nil, "the user is told why")
    #expect(c.rows == nil, "no empty database is created")
}

@MainActor
@Test func unreachableRobotsIsSurfacedToTheUser() async {
    let c = CrawlController(client: ThreePageClient(robotsStatus: 503), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://three.test/"
    await c.start()

    #expect(await waitUntil { c.state == .finished })
    let notice = c.notice ?? ""
    #expect(notice.lowercased().contains("robots"), "a restricted crawl must explain itself; got: \(notice)")
}

@MainActor
@Test func robotsDisallowingEverythingExplainsTheEmptyTable() async {
    let client = ThreePageClient(robotsStatus: 200, robotsBody: "User-agent: *\nDisallow: /")
    let c = CrawlController(client: client, parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://three.test/"
    await c.start()

    #expect(await waitUntil { c.state == .finished })
    let notice = c.notice ?? ""
    #expect(notice.lowercased().contains("robots"), "an empty table must say why; got: \(notice)")
}

@MainActor
@Test func stopEndsAnActiveCrawl() async {
    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://three.test/"
    await c.start()
    await c.stop()

    #expect(await waitUntil { c.state == .cancelled || c.state == .finished },
            "a stopped crawl settles; got \(c.state)")
}

@MainActor
@Test func progressIsReported() async {
    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://three.test/"
    await c.start()

    #expect(await waitUntil { (c.progress?.crawled ?? 0) > 0 }, "progress reaches the controller")
}

/// `rate` is documented as nil when not measuring, but `startTicking()` guards
/// on `state.isActive`, which is true for `.paused` too — so before this fix,
/// `refreshCounts` kept calling `rate.observe` on every tick during a pause.
/// After `pause()`'s `reset()`, the next tick set a fresh baseline and the one
/// after computed a zero delta against the unchanged count, so `perSecond`
/// settled at 0.0 rather than staying nil. `refreshCounts(force:now:)` is
/// internal with an injectable clock precisely so this can be driven directly,
/// without waiting on the real 500ms ticker.
@MainActor
@Test func rateStaysAbsentThroughoutAPause() async {
    let c = CrawlController(client: SlowManyPageClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://slow.test/"
    await c.start()
    #expect(c.state == .running, "beginCrawl sets .running synchronously, before start() returns")
    // `pause()` only takes effect against the engine's own state, which only
    // becomes `.running` once its `run()` loop actually starts — waiting for
    // real progress is what makes the pause below land between batches
    // rather than racing a `run()` task that has not started yet.
    #expect(await waitUntil { (c.progress?.crawled ?? 0) > 0 },
            "the crawl must be genuinely under way before it can be paused")

    let t0 = Date()
    c.refreshCounts(force: true, now: t0)
    c.refreshCounts(force: true, now: t0.addingTimeInterval(1))

    await c.pause()
    #expect(c.state == .paused)
    #expect(c.rate.perSecond == nil, "pause() resets the rate directly")

    // Two ticks, not one: the bug needs a first paused tick to set a baseline
    // and a second to compute the zero delta against it.
    c.refreshCounts(force: true, now: t0.addingTimeInterval(2))
    c.refreshCounts(force: true, now: t0.addingTimeInterval(3))

    #expect(c.rate.perSecond == nil, "a paused crawl must not resume measuring a rate")

    // Stopped rather than resumed to completion. This test needs a crawl that is
    // still going when `pause()` lands, and nothing else; making it also wait for
    // that same crawl to finish would make it pay for the race twice, and under
    // parallel execution the finish is what used to win.
    await c.stop()
}

/// Split from the pause test above rather than tacked onto its end: depth is
/// recorded by the same tick that observes the rate, but asserting it needs a
/// crawl that *finished*, which is the opposite of what a pause needs. Sharing
/// one crawl between the two made whichever assertion ran second depend on a
/// race it had no reason to care about.
@MainActor
@Test func aFinishedCrawlRecordsTheDepthItReached() async {
    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://three.test/"
    await c.start()
    #expect(await waitUntil { c.state == .finished })

    c.refreshCounts(force: true)
    #expect(c.depthReached != nil, "the finished crawl's depth is recorded")
}

/// Item 1 of the M2 final review: the shipped app must write a real file, not an
/// in-memory database, and `CrawlController` is where that resolution has to happen
/// (the host isn't known until the user has typed a seed URL). `crawlsDirectory` is
/// the injection point the app composes through (see `KodaApp.init`); this test
/// exercises it exactly the same way, but pointed at a scratch directory instead of
/// the user's real Application Support folder.
@MainActor
@Test func aControllerWithCrawlsDirectoryWritesARealFileOnDisk() async {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(),
                             crawlsDirectory: { CrawlDatabaseLocation.crawlsDirectory(appSupport: tempRoot) })
    c.seedURL = "https://three.test/"
    await c.start()
    #expect(await waitUntil { c.state == .finished })

    let expected = CrawlDatabaseLocation.path(
        forHost: "three.test", in: CrawlDatabaseLocation.crawlsDirectory(appSupport: tempRoot)
    )
    #expect(FileManager.default.fileExists(atPath: expected.path),
            "a real .koda file must exist on disk once the crawl finishes")
    #expect(c.notice == nil, "the first crawl of a host must not claim anything was replaced")
    #expect(c.pendingExistingCrawl == nil, "there was nothing to ask about the first time around")
}

/// Task 8: re-crawling a host that already has a database no longer auto-replaces
/// it. `start()` instead publishes `pendingExistingCrawl` and waits — the tests
/// below exercise each of the three answers the sheet in `ContentView` offers
/// (Replace, Resume, Cancel), driven directly through the controller's API.
///
/// Each of these tests opens two `CrawlController`s on the same `.koda` file
/// within a single test — `first` finishes and is left to be released by ARC,
/// then `second` opens that same file to resume or replace it. That is why
/// this file must be run with `swift test --no-parallel` rather than plain
/// `swift test`: `first`'s GRDB connection is closed only when ARC gets
/// around to deallocating it, not synchronously when the test moves on, so
/// under parallel test execution `second`'s open can race that deallocation
/// and hit `SQLite error 5: database is locked`. This is a known
/// test-isolation defect, not a product defect — see the README — and is not
/// something to fix here.
@MainActor
private func directoryProvider(_ tempRoot: URL) -> @MainActor @Sendable () -> URL {
    { CrawlDatabaseLocation.crawlsDirectory(appSupport: tempRoot) }
}

@MainActor
@Test func reCrawlingTheSameHostOffersAPendingChoiceInsteadOfReplacingImmediately() async {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let directory = directoryProvider(tempRoot)

    let first = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), crawlsDirectory: directory)
    first.seedURL = "https://three.test/"
    await first.start()
    #expect(await waitUntil { first.state == .finished })

    // A brand new controller, standing in for the user quitting and relaunching the
    // app, then crawling the same host again.
    let second = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), crawlsDirectory: directory)
    second.seedURL = "https://three.test/"
    await second.start()

    #expect(second.state == .idle, "nothing runs until the user answers")
    #expect(second.pendingExistingCrawl?.host == "three.test")
    #expect((second.pendingExistingCrawl?.urlCount ?? 0) >= 3, "the prior crawl's own pages must be counted")
}

@MainActor
@Test func replacingAPendingCrawlDeletesTheOldDatabaseAndStartsFresh() async {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let directory = directoryProvider(tempRoot)

    let first = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), crawlsDirectory: directory)
    first.seedURL = "https://three.test/"
    await first.start()
    #expect(await waitUntil { first.state == .finished })

    let second = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), crawlsDirectory: directory)
    second.seedURL = "https://three.test/"
    await second.start()
    #expect(second.pendingExistingCrawl != nil)

    await second.replacePending()
    #expect(await waitUntil { second.state == .finished })
    #expect(second.pendingExistingCrawl == nil)
    #expect((second.rows?.count ?? 0) >= 3, "the new crawl's own rows must still show up")
}

@MainActor
@Test func resumingAPendingCrawlContinuesTheExistingDatabaseRatherThanReplacingIt() async {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let directory = directoryProvider(tempRoot)

    let first = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), crawlsDirectory: directory)
    first.seedURL = "https://three.test/"
    await first.start()
    #expect(await waitUntil { first.state == .finished })

    let second = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), crawlsDirectory: directory)
    second.seedURL = "https://three.test/"
    await second.start()
    #expect(second.pendingExistingCrawl != nil)

    await second.resumePending()
    #expect(await waitUntil { second.state == .finished })
    #expect(second.pendingExistingCrawl == nil)
    #expect((second.rows?.count ?? 0) >= 3, "resuming a finished crawl opens and displays its existing rows")
    #expect(second.notice == nil, "resuming must not claim anything was replaced")
}

@MainActor
@Test func cancellingAPendingCrawlLeavesTheExistingDatabaseUntouched() async {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let directory = directoryProvider(tempRoot)

    let first = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), crawlsDirectory: directory)
    first.seedURL = "https://three.test/"
    await first.start()
    #expect(await waitUntil { first.state == .finished })

    let second = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), crawlsDirectory: directory)
    second.seedURL = "https://three.test/"
    await second.start()
    guard let pending = second.pendingExistingCrawl else {
        Issue.record("expected a pending existing crawl")
        return
    }

    second.cancelPending()
    #expect(second.pendingExistingCrawl == nil)
    #expect(second.state == .idle)
    #expect(FileManager.default.fileExists(atPath: pending.path.path),
            "Cancel must leave the existing database exactly as it was")
}

@MainActor
private func visibleAddresses(_ c: CrawlController) -> [String] {
    guard let rows = c.rows else { return [] }
    // Address is the Internal report's first column.
    return (0..<rows.count).compactMap { rows.row(at: $0)?.cells.first ?? nil }
}

/// The correctness fix Task 7 owns: `RowIndex.appendNewIds()` advances a
/// watermark from the largest id it holds and only ever fetches ids above it.
/// A URL that was hidden by `Store.visibleURLsFilter` when first discovered —
/// an image-only URL — and later becomes visible because a real link to it
/// appears has an id *below* that watermark, so a pure append can never find
/// it. `CrawlController.refreshRowIndexForLiveCrawl` must periodically do a
/// full rebuild under the default sort so a URL like this is not silently
/// missing from the crawl forever. `now` is injected so this test can
/// simulate the throttle interval elapsing without sleeping for real.
@MainActor
@Test func aLateRevealedImageOnlyURLEventuallyAppearsAfterTheAppendWatermarkPassesIt() async throws {
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).koda")
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPath: tempFile.path)
    c.seedURL = "https://three.test/"
    await c.start()
    #expect(await waitUntil { c.state == .finished })

    // A second handle onto the same on-disk database, standing in for direct
    // seeding of rows the crawler itself did not (yet) produce.
    let store = try Store(path: tempFile.path)
    let existingPageId = try await store.dbQueue.read { db in
        try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM urls") ?? 0
    }
    #expect(existingPageId > 0)

    // A URL discovered only as an image source — hidden by the visibility
    // filter — immediately followed by a normal, visible page with a higher
    // id. `RowIndex.appendNewIds()`'s watermark is the *last id it actually
    // appended*, not "the largest id it has ever seen" — so the image being
    // skipped over here, while the normal page right after it is appended,
    // is exactly what leaves the image permanently below the watermark.
    try await store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state) VALUES
              ('https://three.test/pic.png', ?, 'three.test', '/pic.png', 1, 1, 0, 2),
              ('https://three.test/later', ?, 'three.test', '/later', 1, 1, 0, 2)
            """, arguments: [Data([0xAB, 0xCD, 0xEF, 0x01]), Data([0xAB, 0xCD, 0xEF, 0x02])])
        try db.execute(sql: """
            INSERT INTO images (url_id, src_url_id, alt)
            VALUES (?, (SELECT id FROM urls WHERE url = 'https://three.test/pic.png'), 'a')
            """, arguments: [existingPageId])
    }
    let imageId = try await store.dbQueue.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url = 'https://three.test/pic.png'")!
    }

    // Advance the append watermark past the image's id: /later is picked up,
    // pic.png correctly stays hidden.
    let t0 = Date()
    c.refreshRowIndexForLiveCrawl(now: t0)
    #expect(visibleAddresses(c).contains("https://three.test/later"),
            "the normal page above the image must show up")
    #expect(!visibleAddresses(c).contains("https://three.test/pic.png"),
            "an image-only URL is not a row in the URL table")

    // A real link to the image now appears, flipping it visible per
    // Store.visibleURLsFilter — but its id is below the watermark that was
    // just advanced past it (to /later's id), so appendNewIds() alone can
    // never see it again.
    try await store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position)
            VALUES (?, ?, 'pic', NULL, 1, 0)
            """, arguments: [existingPageId, imageId])
    }

    c.refreshRowIndexForLiveCrawl(now: t0.addingTimeInterval(1))
    #expect(!visibleAddresses(c).contains("https://three.test/pic.png"),
            "append alone must not find it — its id is below the watermark")

    // Once the full-rebuild interval elapses, the periodic rebuild recovers it.
    c.refreshRowIndexForLiveCrawl(now: t0.addingTimeInterval(CrawlController.liveFullRebuildInterval + 1))
    #expect(visibleAddresses(c).contains("https://three.test/pic.png"),
            "a URL revealed after the watermark passed it must eventually appear")
}
