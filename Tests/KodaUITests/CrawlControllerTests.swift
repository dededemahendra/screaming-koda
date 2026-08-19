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
/// (the host isn't known until the user has typed a seed URL). `dbPathForHost` is the
/// injection point the app composes through; these tests exercise it exactly the way
/// `KodaApp.resolveDBPath` does, but pointed at a scratch directory instead of the
/// user's real Application Support folder.
@MainActor
@Test func aControllerWithDBPathForHostWritesARealFileOnDisk() async {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let c = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPathForHost: { host in
        let result = try CrawlDatabaseLocation.prepare(forHost: host, appSupport: tempRoot)
        return (result.path, result.outcome == .replacedExisting)
    })
    c.seedURL = "https://three.test/"
    await c.start()
    #expect(await waitUntil { c.state == .finished })

    let expected = CrawlDatabaseLocation.path(
        forHost: "three.test", in: CrawlDatabaseLocation.crawlsDirectory(appSupport: tempRoot)
    )
    #expect(FileManager.default.fileExists(atPath: expected.path),
            "a real .koda file must exist on disk once the crawl finishes")
    #expect(c.notice == nil, "the first crawl of a host must not claim anything was replaced")
}

@MainActor
@Test func reCrawlingTheSameHostReplacesTheOldDatabaseAndSaysSo() async {
    let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let resolver: @MainActor @Sendable (String) throws -> (path: String, replacedExisting: Bool) = { host in
        let result = try CrawlDatabaseLocation.prepare(forHost: host, appSupport: tempRoot)
        return (result.path, result.outcome == .replacedExisting)
    }

    let first = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPathForHost: resolver)
    first.seedURL = "https://three.test/"
    await first.start()
    #expect(await waitUntil { first.state == .finished })

    // A brand new controller, standing in for the user quitting and relaunching the
    // app, then crawling the same host again.
    let second = CrawlController(client: ThreePageClient(), parser: SwiftSoupParser(), dbPathForHost: resolver)
    second.seedURL = "https://three.test/"
    await second.start()
    #expect(await waitUntil { second.state == .finished })

    let notice = second.notice ?? ""
    #expect(notice.lowercased().contains("replaced"),
            "re-crawling the same host must say the old database was replaced; got: \(notice)")
    #expect((second.rows?.count ?? 0) >= 3, "the new crawl's own rows must still show up")
}
