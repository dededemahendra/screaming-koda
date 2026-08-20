import Foundation
import GRDB
import Testing
@testable import KodaCore

/// A seed page with one external link and one image.
private struct SeedClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://seed.test/" {
            let body = """
                <html><head><title>Seed</title></head><body>
                <a href="https://other.test/page">out</a>
                <img src="/pic.png" alt="a">
                </body></html>
                """
            return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                          body: Data(body.utf8), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200,
                                      headers: ["Content-Type": "image/png", "Content-Length": "2048"],
                                      body: nil, elapsedMs: 1))
    }
}

private func crawl(configure: (inout CrawlConfig) -> Void = { _ in }) async throws -> Store {
    var config = CrawlConfig(seedURL: "https://seed.test/")
    config.workers = 1
    configure(&config)
    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: SeedClient(),
                                                  parser: SwiftSoupParser(), onProgress: nil)
    return store
}

private func checkOnlyFlag(_ store: Store, url: String) async throws -> Int? {
    try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT check_only FROM urls WHERE url = ?", arguments: [url])
    }
}

private func hasResponse(_ store: Store, url: String) async throws -> Bool {
    let n = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.url = ?
            """, arguments: [url]) ?? 0
    }
    return n > 0
}

@Test func externalLinksAreEnqueuedAsCheckOnly() async throws {
    let store = try await crawl()
    #expect(try await checkOnlyFlag(store, url: "https://other.test/page") == 1)
    #expect(try await hasResponse(store, url: "https://other.test/page"), "and actually fetched")
}

@Test func imagesAreEnqueuedAsCheckOnly() async throws {
    let store = try await crawl()
    #expect(try await checkOnlyFlag(store, url: "https://seed.test/pic.png") == 1)
    #expect(try await hasResponse(store, url: "https://seed.test/pic.png"))
}

@Test func theSeedPageIsNotCheckOnly() async throws {
    let store = try await crawl()
    #expect(try await checkOnlyFlag(store, url: "https://seed.test/") == 0)
}

@Test func disablingExternalChecksRestoresTheOldBehaviour() async throws {
    let store = try await crawl { $0.checkExternalLinks = false }
    #expect(try await hasResponse(store, url: "https://other.test/page") == false,
            "recorded but never fetched, exactly as before this milestone")
    let exists = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE url = 'https://other.test/page'") ?? 0
    }
    #expect(exists == 1, "the URL is still recorded")
}

@Test func disablingImageChecksRestoresTheOldBehaviour() async throws {
    let store = try await crawl { $0.checkImages = false }
    #expect(try await hasResponse(store, url: "https://seed.test/pic.png") == false)
}

@Test func aFetchedImageIsStillHiddenFromTheURLTable() async throws {
    // This is the regression the filter change exists to prevent: once images are
    // fetched they all have responses rows, and a filter keyed on "has a response"
    // would stop excluding them.
    let store = try await crawl()
    let visible = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT u.url FROM urls u WHERE \(Store.visibleURLsFilter) ORDER BY u.url
            """)
    }
    #expect(!visible.contains("https://seed.test/pic.png"),
            "a pure image must stay out of the URL table even once fetched; got \(visible)")
    #expect(visible.contains("https://seed.test/"))
    #expect(visible.contains("https://other.test/page"), "external links belong in the table")
}

@Test func aURLThatIsBothAPageAndAnImageSourceStaysVisible() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://dual.test/"), startedAt: Date())
    try await store.dbQueue.write { db in
        // /thing is linked as a page AND used as an image source.
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://dual.test/', x'01', 'dual.test', '/', 0, 1, 0, 2),
                   ('https://dual.test/thing', x'02', 'dual.test', '/thing', 1, 1, 0, 2)
            """)
        try db.execute(sql: "INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position) VALUES (1,2,'t',NULL,1,0)")
        try db.execute(sql: "INSERT INTO images (url_id, src_url_id, alt) VALUES (1,2,'alt')")
        try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (1,200,0),(2,200,0)")
    }
    let visible = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT url FROM urls u WHERE \(Store.visibleURLsFilter)")
    }
    #expect(visible.contains("https://dual.test/thing"),
            "a real page that is also an image source must remain visible")
}

@Test func summaryAndTableStillAgree() async throws {
    let store = try await crawl()
    let filtered = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls u WHERE \(Store.visibleURLsFilter)") ?? 0
    }
    let totalURLs = try store.summary().totalURLs
    #expect(filtered == totalURLs, "one filter, one meaning of 'total URLs'")
}
