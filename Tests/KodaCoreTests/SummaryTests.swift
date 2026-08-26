import Foundation
import Testing
@testable import KodaCore

private struct SummaryClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        let pages: [String: (Int, String)] = [
            "https://sum.test/": (200, "<html><head><title>Dup</title></head><body><h1>H</h1><a href='/a'>a</a><a href='/b'>b</a><a href='/c'>c</a></body></html>"),
            "https://sum.test/a": (200, "<html><head><title>Dup</title><meta name='description' content='d'></head><body><h1>H</h1><img src='/i.png'></body></html>"),
            "https://sum.test/b": (200, "<html><head></head><body><p>no title no h1</p></body></html>"),
            "https://sum.test/c": (404, ""),
        ]
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        guard let (status, body) = pages[url] else {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: status, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

private func summarizedCrawl() async throws -> CrawlSummary {
    var config = CrawlConfig(seedURL: "https://sum.test/")
    config.workers = 2
    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: SummaryClient(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    return try store.summary()
}

@Test func countsInternalURLs() async throws {
    let s = try await summarizedCrawl()
    #expect(s.internalURLs == 4)
}

@Test func groupsStatusCodes() async throws {
    let s = try await summarizedCrawl()
    #expect(s.byStatusClass["2xx"] == 3)
    // /c (404) plus /i.png: checkImages now fetches the image src on /a with a HEAD,
    // and it 404s (not in the fixture's `pages` map), so it genuinely gains a status.
    #expect(s.byStatusClass["4xx"] == 2)
}

@Test func countsMissingTitles() async throws {
    let s = try await summarizedCrawl()
    #expect(s.missingTitles == 1, "/b has no title; /c is a 404 with no facts")
}

@Test func countsDuplicateTitles() async throws {
    let s = try await summarizedCrawl()
    #expect(s.duplicateTitles == 2, "'Dup' appears on / and /a")
}

@Test func countsMissingDescriptionsAndH1() async throws {
    let s = try await summarizedCrawl()
    #expect(s.missingDescriptions == 2, "/ and /b lack descriptions")
    #expect(s.missingH1 == 1, "/b lacks an h1")
}

@Test func countsImagesMissingAlt() async throws {
    let s = try await summarizedCrawl()
    #expect(s.imagesMissingAlt == 1)
}

@Test func reportsMaxDepth() async throws {
    let s = try await summarizedCrawl()
    // /a's image (/i.png) is now actually fetched (checkImages) and sits at depth 2 (one
    // level past /a's depth 1). Per the M3a design ("depth only affects reporting" for
    // check-only URLs), maxDepth's query was never restricted to page_facts rows — it was
    // simply that non-page URLs never had a `responses` row before this milestone, so they
    // never contributed. Now that they do, the deepest *fetched* resource is genuinely 2.
    #expect(s.maxDepth == 2)
}

// MARK: - Fix-round regression tests (review findings on the first cut of Task 11)

/// Finding 1: a non-empty-body 404 (a custom error-page template, extremely common in the
/// wild) still gets a `page_facts` row — `CrawlEngine.process` builds facts for any status
/// as long as the content type is HTML and the body is non-empty, not just for 200s. The
/// original `duplicateTitles` query had no status filter (unlike its siblings
/// `missingTitles`/`missingDescriptions`/`missingH1`), so an error template sharing a title
/// with a real page was wrongly counted as a duplicate. The brief's own fixture never
/// exercised this because its 404 returns an EMPTY body, so no facts row was ever created.
private struct NonEmpty404Client: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://dup404.test/" {
            return .response(HTTPResponse(
                status: 200, headers: ["Content-Type": "text/html"],
                body: Data("<html><head><title>Site</title></head><body><a href='/missing'>x</a></body></html>".utf8),
                elapsedMs: 1))
        }
        // Every other path 404s with a non-empty HTML body sharing the seed's title — a
        // stand-in for a custom error-page template.
        return .response(HTTPResponse(
            status: 404, headers: ["Content-Type": "text/html"],
            body: Data("<html><head><title>Site</title></head><body>Not found</body></html>".utf8),
            elapsedMs: 1))
    }
}

@Test func duplicateTitlesExcludesNon200Pages() async throws {
    var config = CrawlConfig(seedURL: "https://dup404.test/")
    config.workers = 1
    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: NonEmpty404Client(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    let s = try store.summary()
    #expect(s.duplicateTitles == 0, "the 404's title collides with the seed's, but a non-200 page isn't a real duplicate-title issue")
}

/// Finding 2: `urls` is deduplicated by `url_hash`, so a URL that is BOTH a normal link
/// target AND an `<img src>` reference collapses to a single row. The original exclusion
/// (`u.id NOT IN (SELECT src_url_id FROM images)`) excluded that row entirely, even though
/// it's a real page that was actually fetched — excluding by identity is wrong; only URLs
/// that exist *solely* as image sources should be excluded.
private struct LinkedAndEmbeddedClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://linkimg.test/" {
            return .response(HTTPResponse(
                status: 200, headers: ["Content-Type": "text/html"],
                body: Data("<html><head><title>Seed</title></head><body><a href='/b'>b</a><img src='/b'></body></html>".utf8),
                elapsedMs: 1))
        }
        if url == "https://linkimg.test/b" {
            return .response(HTTPResponse(
                status: 200, headers: ["Content-Type": "text/html"],
                body: Data("<html><head><title>B</title></head><body></body></html>".utf8),
                elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
    }
}

@Test func internalURLsKeepsPagesThatAreAlsoImageSources() async throws {
    var config = CrawlConfig(seedURL: "https://linkimg.test/")
    config.workers = 1
    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: LinkedAndEmbeddedClient(),
                                                   parser: SwiftSoupParser(), onProgress: nil)
    let s = try store.summary()
    #expect(s.internalURLs == 2, "/b is a real fetched page even though it's also embedded as an <img src>")
}

/// Since PDFs are parsed they get a `page_facts` row, and a PDF has no H1 by
/// definition — so counting it as "missing H1" invents a finding that no report
/// shows. Caught by the summary-versus-reports agreement test; pinned here so it
/// fails for the right reason if it ever comes back.
@Test func aPDFDoesNotCountAsAPageMissingItsHeadings() throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        for (path, type) in [("/page.html", "text/html; charset=utf-8"),
                             ("/doc.pdf", "application/pdf")] {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,1,1,0,2)
                    """,
                arguments: ["https://p.test\(path)", Data(path.utf8), "p.test", path])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO responses (url_id, status, content_type, fetched_at) VALUES (?,200,?,0)",
                arguments: [id, type])
            // Neither has an H1; only the HTML page is a finding.
            try db.execute(sql: "INSERT INTO page_facts (url_id, title) VALUES (?,?)",
                           arguments: [id, "A title"])
        }
    }
    let summary = try store.summary()
    #expect(summary.missingH1 == 1, "the HTML page only")
    #expect(summary.missingDescriptions == 1)

    // And the reports agree, which is the property that actually matters.
    let counts = try store.counts(for: Reports.all)
    #expect(counts["headings.missingH1"] == summary.missingH1)
    #expect(counts["metaDescription.missing"] == summary.missingDescriptions)
}
