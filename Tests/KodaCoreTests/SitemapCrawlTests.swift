import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Serves a sitemap index, two child sitemaps, and a small site. One sitemap
/// URL is deliberately linked from nowhere, which is the orphan.
private struct SitemapSite: HTTPClient {
    var indexBody: String = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://sm.test/sitemap-a.xml</loc></sitemap>
          <sitemap><loc>https://sm.test/sitemap-b.xml</loc></sitemap>
        </sitemapindex>
        """
    var robotsBody: String = "User-agent: *\nSitemap: https://sm.test/sitemap.xml"

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        func xml(_ body: String) -> FetchOutcome {
            .response(HTTPResponse(status: 200, headers: ["Content-Type": "application/xml"],
                                   body: Data(body.utf8), elapsedMs: 1))
        }
        func html(_ body: String) -> FetchOutcome {
            .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                   body: Data(body.utf8), elapsedMs: 1))
        }
        switch url {
        case "https://sm.test/robots.txt":
            return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/plain"],
                                          body: Data(robotsBody.utf8), elapsedMs: 1))
        case "https://sm.test/sitemap.xml":
            return xml(indexBody)
        case "https://sm.test/sitemap-a.xml":
            return xml("""
                <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
                  <url><loc>https://sm.test/</loc></url>
                  <url><loc>https://sm.test/linked</loc></url>
                </urlset>
                """)
        case "https://sm.test/sitemap-b.xml":
            return xml("""
                <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
                  <url><loc>https://sm.test/orphan</loc></url>
                </urlset>
                """)
        case "https://sm.test/":
            return html("<html><head><title>Home</title></head><body>"
                        + "<a href=\"/linked\">Linked</a><a href=\"/unlisted\">Unlisted</a></body></html>")
        default:
            return html("<html><head><title>Leaf</title></head><body>a leaf</body></html>")
        }
    }
}

@MainActor
private func crawlWithSitemaps(_ client: SitemapSite = SitemapSite(),
                               configure: (inout CrawlConfig) -> Void = { _ in })
    async throws -> (Store, SitemapOutcome) {
    var config = CrawlConfig(seedURL: "https://sm.test/")
    config.workers = 1
    configure(&config)
    let (engine, store, _, sitemap) = try await CrawlSession.prepare(
        dbPath: nil, config: config, client: client, parser: SwiftSoupParser())
    try await engine.run(onProgress: nil)
    return (store, sitemap)
}

@MainActor
@Test func sitemapsAreDiscoveredThroughRobots() async throws {
    let (store, outcome) = try await crawlWithSitemaps()
    #expect(outcome.fetched == 3, "the index plus its two children")
    #expect(outcome.urls == 3)
    #expect(try store.sitemapCount() == 3)
}

@MainActor
@Test func sitemapDiscoveryCanBeTurnedOff() async throws {
    let (store, outcome) = try await crawlWithSitemaps { $0.discoverSitemaps = false }
    #expect(outcome.fetched == 0)
    #expect(try store.sitemapCount() == 0)
}

@MainActor
@Test func anExplicitlyConfiguredSitemapIsUsed() async throws {
    let (store, outcome) = try await crawlWithSitemaps {
        $0.discoverSitemaps = false
        $0.sitemapURLs = ["https://sm.test/sitemap-b.xml"]
    }
    #expect(outcome.fetched == 1)
    #expect(try store.sitemapCount() == 1)
}

/// The whole point: a URL the sitemap declares and nothing links to is an
/// orphan, which a crawl alone can never find.
@MainActor
@Test func anOrphanIsAURLInTheSitemapThatNothingLinksTo() async throws {
    let (store, _) = try await crawlWithSitemaps()
    let orphans = try store.ids(for: Reports.sitemap,
                                filter: Reports.sitemap.filters.first { $0.id == "orphans" }!,
                                sortBy: nil, ascending: true)
    let paths = try await store.dbQueue.read { db in
        Set(try String.fetchAll(db, sql: """
            SELECT path FROM urls WHERE id IN (\(orphans.map(String.init).joined(separator: ",")))
            """))
    }
    #expect(paths == ["/orphan"])
}

/// The page a crawl starts from has no inlinks in its own crawl unless something
/// links back to it. Reporting that as unreachable is the opposite of true.
@MainActor
@Test func theCrawlsStartingPageIsNeverAnOrphan() async throws {
    let (store, _) = try await crawlWithSitemaps()
    let inlinks = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM links l JOIN urls u ON u.id = l.to_url_id WHERE u.path = '/'
            """) ?? 0
    }
    #expect(inlinks == 0, "nothing links to the home page in this fixture")

    let orphans = try store.ids(for: Reports.sitemap,
                                filter: Reports.sitemap.filters.first { $0.id == "orphans" }!,
                                sortBy: nil, ascending: true)
    let paths = try await store.dbQueue.read { db in
        Set(try String.fetchAll(db, sql: """
            SELECT path FROM urls WHERE id IN (\(orphans.map(String.init).joined(separator: ",")))
            """))
    }
    #expect(!paths.contains("/"), "the entry point is not an orphan")
}

@MainActor
@Test func aPageCrawledButAbsentFromTheSitemapIsFlagged() async throws {
    let (store, _) = try await crawlWithSitemaps()
    let ids = try store.ids(for: Reports.sitemap,
                            filter: Reports.sitemap.filters.first { $0.id == "notInSitemap" }!,
                            sortBy: nil, ascending: true)
    let paths = try await store.dbQueue.read { db in
        Set(try String.fetchAll(db, sql: """
            SELECT path FROM urls WHERE id IN (\(ids.map(String.init).joined(separator: ",")))
            """))
    }
    #expect(paths == ["/unlisted"])
}

/// A sitemap URL is crawled, not merely recorded — otherwise the orphan would
/// have no status and could not be judged.
@MainActor
@Test func sitemapURLsAreActuallyCrawled() async throws {
    let (store, _) = try await crawlWithSitemaps()
    let status = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT r.status FROM urls u JOIN responses r ON r.url_id = u.id WHERE u.path = '/orphan'
            """)
    }
    #expect(status == 200)
}

/// A sitemap index pointing at itself must terminate rather than loop.
@MainActor
@Test func aSelfReferencingSitemapIndexTerminates() async throws {
    var client = SitemapSite()
    client.indexBody = """
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://sm.test/sitemap.xml</loc></sitemap>
          <sitemap><loc>https://sm.test/sitemap-b.xml</loc></sitemap>
        </sitemapindex>
        """
    let (_, outcome) = try await crawlWithSitemaps(client)
    #expect(outcome.fetched == 2, "the index once, then the child; the self-reference is skipped")
}

@MainActor
@Test func anUnreachableSitemapIsReportedNotSwallowed() async throws {
    let (_, outcome) = try await crawlWithSitemaps {
        $0.discoverSitemaps = false
        $0.sitemapURLs = ["https://sm.test/does-not-exist.xml"]
    }
    #expect(outcome.failed == ["https://sm.test/does-not-exist.xml"])
    #expect(outcome.urls == 0)
}

// MARK: - List mode

@MainActor
@Test func listModeCrawlsTheListWithoutFollowingLinks() async throws {
    let (store, _) = try await crawlWithSitemaps {
        $0.listModeOnly = true
        $0.discoverSitemaps = false
        $0.seedList = ["https://sm.test/listed"]
    }
    let paths = try await store.dbQueue.read { db in
        Set(try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id
            """))
    }
    #expect(paths == ["/", "/listed"], "the seed and the listed URL, and nothing they link to")
}

/// Links are still recorded in list mode — they are just not followed — so the
/// inlink and anchor reports still work on the listed set.
@MainActor
@Test func listModeStillRecordsTheLinksItFinds() async throws {
    let (store, _) = try await crawlWithSitemaps {
        $0.listModeOnly = true
        $0.discoverSitemaps = false
    }
    let links = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM links") ?? 0
    }
    #expect(links == 2, "the home page's two links are recorded but not followed")
}

@MainActor
@Test func sitemapURLsFeedListModeToo() async throws {
    let (store, _) = try await crawlWithSitemaps { $0.listModeOnly = true }
    let crawled = try await store.dbQueue.read { db in
        Set(try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id
            """))
    }
    #expect(crawled == ["/", "/linked", "/orphan"], "everything the sitemap declared, nothing else")
}
