import Foundation
import GRDB
import Testing
@testable import KodaCore

private let page = """
    <html><head>
      <link rel="stylesheet" href="/css/site.css">
      <link rel="stylesheet" href="https://cdn.test/vendor.css">
      <link rel="preload" href="/css/not-a-stylesheet.css">
      <script src="/js/app.js"></script>
      <script>var inline = 1;</script>
    </head><body><h1>Page</h1></body></html>
    """

@Test func stylesheetsAndScriptsAreFound() throws {
    let facts = try SwiftSoupParser().parse(html: page)
    #expect(facts.resources.map(\.src) == ["/css/site.css", "https://cdn.test/vendor.css", "/js/app.js"])
    #expect(facts.resources.map(\.kind) == ["css", "css", "js"])
}

/// `rel=preload` is not a stylesheet, and an inline script has no URL to check.
@Test func onlyRealStylesheetsAndExternalScriptsCount() throws {
    let facts = try SwiftSoupParser().parse(html: page)
    #expect(!facts.resources.contains { $0.src.contains("not-a-stylesheet") })
    #expect(facts.resources.count == 3, "the inline script has nothing to fetch")
}

private struct ResourceSite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url.hasSuffix(".css") {
            return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/css"],
                                          body: nil, elapsedMs: 1))
        }
        if url.hasSuffix(".js") {
            // A broken script is the finding this whole tab exists for.
            return .response(HTTPResponse(status: 404, headers: [:], body: nil, elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(page.utf8), elapsedMs: 1))
    }
}

@MainActor
private func crawl(checkResources: Bool) async throws -> Store {
    var config = CrawlConfig(seedURL: "https://res.test/")
    config.workers = 1
    config.checkResources = checkResources
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: ResourceSite(),
        parser: SwiftSoupParser(), onProgress: nil)
    return store
}

@MainActor
@Test func resourcesAreRecordedEvenWhenNotFetched() async throws {
    let store = try await crawl(checkResources: false)
    let count = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM resources") ?? 0
    }
    #expect(count == 3, "the relationship is recorded regardless; only fetching is optional")
}

@MainActor
@Test func abrokenScriptIsFoundWhenResourceCheckingIsOn() async throws {
    let store = try await crawl(checkResources: true)
    let ids = try store.ids(for: Reports.resources,
                            filter: Reports.resources.filters.first { $0.id == "broken" }!,
                            sortBy: nil, ascending: true)
    let urls = try await store.dbQueue.read { db in
        Set(try String.fetchAll(db, sql: """
            SELECT url FROM urls WHERE id IN (\(ids.map(String.init).joined(separator: ",")))
            """))
    }
    #expect(urls == ["https://res.test/js/app.js"])
}

@MainActor
@Test func stylesheetsAndScriptsSeparateInTheReport() async throws {
    let store = try await crawl(checkResources: true)
    func paths(_ filter: String) throws -> Int {
        try store.ids(for: Reports.resources,
                      filter: Reports.resources.filters.first { $0.id == filter }!,
                      sortBy: nil, ascending: true).count
    }
    #expect(try paths("css") == 2)
    #expect(try paths("js") == 1)
}

/// A stylesheet is not a page. Without this it would appear in the Internal
/// table alongside real content, exactly as fetched images once did.
@MainActor
@Test func aResourceURLIsNotAPageInTheURLTable() async throws {
    let store = try await crawl(checkResources: true)
    let ids = try store.ids(for: Reports.internalURLs,
                            filter: Reports.internalURLs.defaultFilter,
                            sortBy: nil, ascending: true)
    let urls = try await store.dbQueue.read { db in
        Set(try String.fetchAll(db, sql: """
            SELECT url FROM urls WHERE id IN (\(ids.map(String.init).joined(separator: ",")))
            """))
    }
    #expect(!urls.contains { $0.hasSuffix(".css") || $0.hasSuffix(".js") })
    #expect(urls.contains("https://res.test/"))
}

@MainActor
@Test func turningResourceCheckingOffLeavesThemUnfetched() async throws {
    let store = try await crawl(checkResources: false)
    let fetched = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id
            WHERE u.url LIKE '%.css' OR u.url LIKE '%.js'
            """) ?? 0
    }
    #expect(fetched == 0)
}
