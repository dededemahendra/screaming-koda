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

    let (status, title) = try store.dbQueue.read { db in
        let status = try Int.fetchOne(db, sql: "SELECT status FROM responses WHERE url_id = ?", arguments: [id])
        let title = try String.fetchOne(db, sql: "SELECT title FROM page_facts WHERE url_id = ?", arguments: [id])
        return (status, title)
    }
    #expect(status == 200)
    #expect(title == "T")
    #expect(try store.urlCounts().done == 1)
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
    #expect(try store.urlCounts().queued == 2)
    #expect(try store.claimNext(limit: 10).first?.depth == 1, "children are one level deeper than the parent")
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
    let isInternal = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT is_internal FROM urls WHERE host = 'other.com'")
    }
    #expect(isInternal == 0)
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
    #expect(try store.urlCounts().done == 1, "a failed fetch still completes the URL")
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
    let (alt, lang) = try store.dbQueue.read { db in
        let alt = try String.fetchOne(db, sql: "SELECT alt FROM images WHERE url_id = ?", arguments: [id])
        let lang = try String.fetchOne(db, sql: "SELECT lang FROM hreflang WHERE url_id = ?", arguments: [id])
        return (alt, lang)
    }
    #expect(alt == "Alt")
    #expect(lang == "fr")
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
    let adminCount = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE path LIKE '/admin%'")
    }
    #expect(adminCount == 0)
}

@Test func nofollowLinksAreNotQueuedByDefault() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [LinkFact(href: "/nofollowed", anchor: "N", rel: "nofollow", position: 0)])
    let discovered = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                                          contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                                          redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                                     config: config, now: Date())
    #expect(discovered == 0)
    let linkCount = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM links WHERE from_url_id = ?", arguments: [id])
    }
    #expect(linkCount == 1, "the link is still recorded, just not crawled")
}

@Test func gzipRoundTrips() {
    let original = Data(String(repeating: "hello world ", count: 500).utf8)
    let compressed = Gzip.compress(original)
    #expect(compressed != nil)
    #expect(compressed!.count < original.count)
    #expect(Gzip.decompress(compressed!) == original)
}

@Test func pageFactsUpsertRefreshesAllColumns() throws {
    let (store, config, id, url) = try seededStore()

    var first = PageFacts()
    first.title = "First"
    first.titleCount = 1
    first.h1 = "H1-first"
    first.h1Count = 1
    first.h2Count = 2
    first.metaDescription = "First desc"
    first.metaDescriptionCount = 1
    first.metaRobots = "index,follow"
    first.lang = "en"
    first.wordCount = 100
    first.contentHash = Data([0x01])

    let firstResult = CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                  contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                  redirectTarget: nil, bodyGz: nil, xRobotsTag: "noindex", facts: first)
    _ = try store.write(results: [firstResult], config: config, now: Date())

    var second = PageFacts()
    second.title = "Second"
    second.titleCount = 2
    second.h1 = "H1-second"
    second.h1Count = 3
    second.h2Count = 4
    second.metaDescription = "Second desc"
    second.metaDescriptionCount = 2
    second.metaRobots = "noindex,nofollow"
    second.lang = "fr"
    second.wordCount = 999
    second.contentHash = Data([0x02])
    second.canonical = "https://example.com/canonical"

    let secondResult = CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                   contentType: "text/html", contentLength: 2, responseTimeMs: 2,
                                   redirectTarget: nil, bodyGz: nil, xRobotsTag: "noindex,nofollow", facts: second)
    _ = try store.write(results: [secondResult], config: config, now: Date())

    let row = try store.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT title, title_count, h1, h1_count, h2_count, meta_description,
                   meta_description_count, meta_robots, x_robots_tag, lang, word_count,
                   content_hash, canonical_id
            FROM page_facts WHERE url_id = ?
            """, arguments: [id])
    }

    #expect(row?["title"] == "Second")
    #expect(row?["title_count"] == 2)
    #expect(row?["h1"] == "H1-second", "h1 must reflect the second write, not stay stuck on the first")
    #expect(row?["h1_count"] == 3)
    #expect(row?["h2_count"] == 4)
    #expect(row?["meta_description"] == "Second desc")
    #expect(row?["meta_description_count"] == 2)
    #expect(row?["meta_robots"] == "noindex,nofollow")
    #expect(row?["x_robots_tag"] == "noindex,nofollow")
    #expect(row?["lang"] == "fr")
    #expect(row?["word_count"] == 999, "word_count must reflect the second write, not stay stuck on the first")
    let contentHash: Data? = row?["content_hash"]
    #expect(contentHash == Data([0x02]), "content_hash must reflect the second write, not stay stuck on the first")
    let canonicalID: Int64? = row?["canonical_id"]
    #expect(canonicalID != nil, "canonical_id must be populated by the second write")
}

@Test func canonicalTargetDescendsOneLevelFromParent() throws {
    let (store, config, id, url) = try seededStore()
    var facts = makeFacts()
    facts.canonical = "https://example.com/canonical-target"
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                             contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)
    _ = try store.write(results: [result], config: config, now: Date())

    let depth = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT depth FROM urls WHERE url = ?",
                         arguments: ["https://example.com/canonical-target"])
    }
    #expect(depth == 1, "a canonical to a previously-undiscovered URL is one level deeper than the page declaring it")
}

@Test func canonicalTargetRespectsMaxDepthCutoff() throws {
    let (store, config, id, url) = try seededStore()
    var cappedConfig = config
    cappedConfig.maxDepth = 0
    var facts = makeFacts()
    facts.canonical = "https://example.com/canonical-target"
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                             contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)
    _ = try store.write(results: [result], config: cappedConfig, now: Date())

    let state = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT state FROM urls WHERE url = ?",
                         arguments: ["https://example.com/canonical-target"])
    }
    #expect(state == 3, "with maxDepth 0, a canonical target one level deeper must be skipped, not queued")
    #expect(try store.urlCounts().queued == 0, "the depth cutoff must apply to canonical targets, not just links")
}

@Test func redirectTargetStillInheritsParentDepth() throws {
    let (store, config, id, url) = try seededStore()
    let target = URLNormalizer.normalize("https://example.com/redirect-target", relativeTo: nil)!
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 301, errorKind: nil,
                             contentType: nil, contentLength: nil, responseTimeMs: 5,
                             redirectTarget: target, bodyGz: nil, xRobotsTag: nil, facts: nil)
    _ = try store.write(results: [result], config: config, now: Date())

    let depth = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT depth FROM urls WHERE url = ?",
                         arguments: ["https://example.com/redirect-target"])
    }
    #expect(depth == 0, "a redirect target is the same logical page as its parent, so it inherits the parent's depth")
}

@Test func urlCapExcludesSkippedRowsFromBudget() throws {
    let (store, config, id, url) = try seededStore()
    var cappedConfig = config
    cappedConfig.urlCap = 2
    let facts = makeFacts(links: [
        LinkFact(href: "https://other.com/x", anchor: "Ext", rel: nil, position: 0),
        LinkFact(href: "/internal", anchor: "Int", rel: nil, position: 1),
    ])
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                             contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)

    let discovered = try store.write(results: [result], config: cappedConfig, now: Date())

    #expect(discovered == 1, "the external link must not consume crawl budget, so the internal link still fits under the cap")
    let counts = try store.urlCounts()
    #expect(counts.queued == 1, "the internal link is queued; the seed itself is now done, the external link is skipped")
    #expect(counts.done == 1, "the seed page was crawled by this very result")
}
