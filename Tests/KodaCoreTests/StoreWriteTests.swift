import Foundation
import GRDB
import Testing
@testable import KodaCore

private func seededStore() throws -> (Store, CrawlConfig, Int64, NormalizedURL) {
    let store = try Store(path: nil)
    try store.migrate()
    let config = CrawlConfig(seedURL: "https://example.com/")
    try store.initializeCrawl(config: config, startedAt: Date())
    let seed = URLNormalizer.normalize("https://example.com/", relativeTo: nil)!
    let id = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())
    return (store, config, id, seed)
}

private func makeFacts(links: [LinkFact] = [], images: [ImageFact] = [], hreflang: [HreflangFact] = []) -> PageFacts {
    var f = PageFacts()
    f.title = "T"
    f.h1 = "H"
    f.links = links
    f.images = images
    f.hreflang = hreflang
    return f
}

@Test func writesResponseAndFacts() throws {
    let (store, config, id, url) = try seededStore()
    let result = CrawlResult(
        urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
        contentType: "text/html", contentLength: 100, responseTimeMs: 42,
        redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: makeFacts()
    )
    _ = try store.write(results: [result], config: config, now: Date())

    try store.dbQueue.read { db in
        try #expect(try Int.fetchOne(db, sql: "SELECT status FROM responses WHERE url_id = ?", arguments: [id]) == 200)
        try #expect(try String.fetchOne(db, sql: "SELECT title FROM page_facts WHERE url_id = ?", arguments: [id]) == "T")
    }
    try #expect(try store.urlCounts().done == 1)
}

@Test func discoveredLinksBecomeQueuedURLs() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [
        LinkFact(href: "/a", anchor: "A", rel: nil, position: 0),
        LinkFact(href: "/b", anchor: "B", rel: nil, position: 1),
    ])
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                             contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)

    let discovered = try store.write(results: [result], config: config, now: Date())

    #expect(discovered == 2)
    try #expect(try store.urlCounts().queued == 2)
    try #expect(try store.claimNext(limit: 10).first?.depth == 1, "children are one level deeper than the parent")
}

@Test func linkRowsRecordAnchorAndRel() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [LinkFact(href: "https://other.com/x", anchor: "Out", rel: "nofollow", position: 0)])
    _ = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                              contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                              redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                        config: config, now: Date())
    try store.dbQueue.read { db in
        let row = try Row.fetchOne(db, sql: "SELECT anchor_text, rel, is_internal FROM links WHERE from_url_id = ?",
                                   arguments: [id])
        #expect(row?["anchor_text"] == "Out")
        #expect(row?["rel"] == "nofollow")
        #expect(row?["is_internal"] == 0, "other.com is external to example.com")
    }
}

@Test func externalHostsAreMarkedExternal() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [LinkFact(href: "https://other.com/x", anchor: "x", rel: nil, position: 0)])
    _ = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                              contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                              redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                        config: config, now: Date())
    try store.dbQueue.read { db in
        try #expect(try Int.fetchOne(db, sql: "SELECT is_internal FROM urls WHERE host = 'other.com'") == 0)
    }
}

@Test func transportFailureIsRecordedNotDropped() throws {
    let (store, config, id, url) = try seededStore()
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 0, errorKind: "URLError.timedOut",
                             contentType: nil, contentLength: nil, responseTimeMs: 20_000,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: nil)
    _ = try store.write(results: [result], config: config, now: Date())
    try store.dbQueue.read { db in
        let row = try Row.fetchOne(db, sql: "SELECT status, error_kind FROM responses WHERE url_id = ?", arguments: [id])
        #expect(row?["status"] == 0)
        #expect(row?["error_kind"] == "URLError.timedOut")
    }
    try #expect(try store.urlCounts().done == 1, "a failed fetch still completes the URL")
}

@Test func redirectTargetIsLinkedAndQueued() throws {
    let (store, config, id, url) = try seededStore()
    let target = URLNormalizer.normalize("https://example.com/new", relativeTo: nil)!
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 301, errorKind: nil,
                             contentType: nil, contentLength: nil, responseTimeMs: 5,
                             redirectTarget: target, bodyGz: nil, xRobotsTag: nil, facts: nil)
    _ = try store.write(results: [result], config: config, now: Date())
    try store.dbQueue.read { db in
        let targetID = try Int64.fetchOne(db, sql: "SELECT redirect_target_id FROM responses WHERE url_id = ?",
                                          arguments: [id])
        #expect(targetID != nil)
        let targetURL = try String.fetchOne(db, sql: "SELECT url FROM urls WHERE id = ?", arguments: [targetID])
        #expect(targetURL == "https://example.com/new")
    }
}

@Test func imagesAndHreflangAreWritten() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(
        images: [ImageFact(src: "/img/a.png", alt: "Alt")],
        hreflang: [HreflangFact(lang: "fr", href: "https://example.com/fr")]
    )
    _ = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                              contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                              redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                        config: config, now: Date())
    try store.dbQueue.read { db in
        try #expect(try String.fetchOne(db, sql: "SELECT alt FROM images WHERE url_id = ?", arguments: [id]) == "Alt")
        try #expect(try String.fetchOne(db, sql: "SELECT lang FROM hreflang WHERE url_id = ?", arguments: [id]) == "fr")
    }
}

@Test func excludePatternsBlockDiscovery() throws {
    var (store, config, id, url) = try seededStore()
    config.exclude = ["/admin"]
    let facts = makeFacts(links: [
        LinkFact(href: "/admin/panel", anchor: "Admin", rel: nil, position: 0),
        LinkFact(href: "/public", anchor: "Public", rel: nil, position: 1),
    ])
    let discovered = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                                          contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                                          redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                                     config: config, now: Date())
    #expect(discovered == 1)
    try store.dbQueue.read { db in
        try #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE path LIKE '/admin%'") == 0)
    }
}

@Test func nofollowLinksAreNotQueuedByDefault() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [LinkFact(href: "/nofollowed", anchor: "N", rel: "nofollow", position: 0)])
    let discovered = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                                          contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                                          redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                                     config: config, now: Date())
    #expect(discovered == 0)
    try store.dbQueue.read { db in
        try #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM links WHERE from_url_id = ?", arguments: [id]) == 1,
                "the link is still recorded, just not crawled")
    }
}

@Test func gzipRoundTrips() {
    let original = Data(String(repeating: "hello world ", count: 500).utf8)
    let compressed = Gzip.compress(original)
    #expect(compressed != nil)
    #expect(compressed!.count < original.count)
    #expect(Gzip.decompress(compressed!) == original)
}
