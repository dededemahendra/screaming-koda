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
    return (0..<rows.count).compactMap { rows.row(at: $0)?.address }
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
