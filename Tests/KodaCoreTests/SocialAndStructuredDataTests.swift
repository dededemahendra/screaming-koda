import Foundation
import GRDB
import Testing
@testable import KodaCore

private let parser = SwiftSoupParser()

// MARK: - Open Graph and Twitter

/// Open Graph specifies `property=`, Twitter specifies `name=`, and real pages
/// use both attributes for both vocabularies. Reading only the specified one
/// silently misses a large share of the web.
@Test func openGraphIsReadFromPropertyOrName() throws {
    let byProperty = try parser.parse(html: """
        <html><head><meta property="og:title" content="By property"></head><body></body></html>
        """)
    #expect(byProperty.ogTitle == "By property")

    let byName = try parser.parse(html: """
        <html><head><meta name="og:title" content="By name"></head><body></body></html>
        """)
    #expect(byName.ogTitle == "By name")
}

@Test func everyOpenGraphAndTwitterFieldIsCaptured() throws {
    let facts = try parser.parse(html: """
        <html><head>
        <meta property="og:title" content="OG title">
        <meta property="og:description" content="OG description">
        <meta property="og:image" content="https://x.test/card.png">
        <meta property="og:type" content="article">
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:title" content="Tw title">
        <meta name="twitter:image" content="https://x.test/tw.png">
        </head><body></body></html>
        """)
    #expect(facts.ogTitle == "OG title")
    #expect(facts.ogDescription == "OG description")
    #expect(facts.ogImage == "https://x.test/card.png")
    #expect(facts.ogType == "article")
    #expect(facts.twitterCard == "summary_large_image")
    #expect(facts.twitterTitle == "Tw title")
    #expect(facts.twitterImage == "https://x.test/tw.png")
}

@Test func aPageWithNoSocialTagsHasNone() throws {
    let facts = try parser.parse(html: "<html><head><title>T</title></head><body></body></html>")
    #expect(facts.ogTitle == nil)
    #expect(facts.twitterCard == nil)
}

// MARK: - Pagination and AMP

@Test func paginationAndAMPLinksAreCaptured() throws {
    let facts = try parser.parse(html: """
        <html><head>
        <link rel="prev" href="/page/1">
        <link rel="next" href="/page/3">
        <link rel="amphtml" href="/amp/page/2">
        </head><body></body></html>
        """)
    #expect(facts.relPrev == "/page/1")
    #expect(facts.relNext == "/page/3")
    #expect(facts.amphtml == "/amp/page/2")
}

// MARK: - Structured data

@Test func jsonLDTypesAreExtracted() throws {
    let facts = try parser.parse(html: """
        <html><head><script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Product","name":"A thing"}
        </script></head><body></body></html>
        """)
    #expect(facts.structuredData == [StructuredDataFact(format: "json-ld", type: "Product")])
}

/// Most real sites emit one `@graph` containing several nodes, so a parser that
/// only reads a top-level `@type` finds nothing on them.
@Test func jsonLDTypesInsideAGraphAreFound() throws {
    let facts = try parser.parse(html: """
        <html><head><script type="application/ld+json">
        {"@context":"https://schema.org","@graph":[
          {"@type":"Organization","name":"Acme"},
          {"@type":"WebSite","name":"Acme site"},
          {"@type":["BreadcrumbList","ItemList"]}
        ]}
        </script></head><body></body></html>
        """)
    let types = Set(facts.structuredData.map(\.type))
    #expect(types == ["Organization", "WebSite", "BreadcrumbList", "ItemList"])
}

/// A schema.org URL and the bare name are the same type; reporting them
/// separately would split one site's markup across two rows.
@Test func aSchemaURLIsReducedToItsTypeName() throws {
    let facts = try parser.parse(html: """
        <html><body><div itemscope itemtype="https://schema.org/Recipe"></div></body></html>
        """)
    #expect(facts.structuredData == [StructuredDataFact(format: "microdata", type: "Recipe")])
}

@Test func rdfaTypeofIsRead() throws {
    let facts = try parser.parse(html: """
        <html><body><div typeof="Person Organization"></div></body></html>
        """)
    #expect(Set(facts.structuredData.map(\.type)) == ["Person", "Organization"])
    #expect(facts.structuredData.allSatisfy { $0.format == "rdfa" })
}

@Test func malformedJSONLDIsSkippedRatherThanFailingTheParse() throws {
    let facts = try parser.parse(html: """
        <html><head>
        <script type="application/ld+json">{ this is not json </script>
        <script type="application/ld+json">{"@type":"Article"}</script>
        </head><body><h1>Still parsed</h1></body></html>
        """)
    #expect(facts.structuredData == [StructuredDataFact(format: "json-ld", type: "Article")])
    #expect(facts.h1 == "Still parsed", "a bad script must not cost the rest of the page")
}

@Test func theSameTypeDeclaredTwiceIsRecordedOnce() throws {
    let facts = try parser.parse(html: """
        <html><head>
        <script type="application/ld+json">{"@type":"Article"}</script>
        <script type="application/ld+json">{"@type":"Article"}</script>
        </head><body></body></html>
        """)
    #expect(facts.structuredData.count == 1)
}

// MARK: - Analytics

@Test func analyticsScriptsAreDetectedBySrcAndByInlineCode() throws {
    let bySrc = try parser.parse(html: """
        <html><head><script src="https://www.googletagmanager.com/gtag/js?id=G-X"></script>
        </head><body></body></html>
        """)
    #expect(bySrc.analytics == ["Google Analytics 4"])

    let inline = try parser.parse(html: """
        <html><head><script>fbq('init', '123');</script></head><body></body></html>
        """)
    #expect(inline.analytics == ["Meta Pixel"])
}

@Test func aPageWithNoTrackingReportsNone() throws {
    let facts = try parser.parse(html: "<html><body><script>var x = 1;</script></body></html>")
    #expect(facts.analytics.isEmpty)
}

// MARK: - Image dimensions

@Test func declaredImageDimensionsAreCaptured() throws {
    let facts = try parser.parse(html: """
        <html><body><img src="/a.png" width="640" height="480" alt="a"></body></html>
        """)
    #expect(facts.images.first?.width == 640)
    #expect(facts.images.first?.height == 480)
}

/// A percentage or `auto` is not a pixel dimension, and treating it as declared
/// would hide exactly the layout-shift risk this is meant to surface.
@Test func nonPixelDimensionsCountAsUndeclared() throws {
    let facts = try parser.parse(html: """
        <html><body><img src="/a.png" width="100%" height="auto" alt="a"></body></html>
        """)
    #expect(facts.images.first?.width == nil)
    #expect(facts.images.first?.height == nil)
}

// MARK: - Persistence

@Test func waveTwoFactsSurviveTheWritePath() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://w2.test/")
    config.workers = 1
    try store.initializeCrawl(config: config, startedAt: Date())
    try await store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://w2.test/', x'0B', 'w2.test', '/', 0, 1, 0, 1)
            """)
    }

    var facts = PageFacts()
    facts.ogTitle = "Stored OG title"
    facts.twitterCard = "summary"
    facts.relNext = "https://w2.test/page/2"
    facts.amphtml = "https://w2.test/amp"
    facts.analytics = ["Plausible", "Matomo"]
    facts.structuredData = [StructuredDataFact(format: "json-ld", type: "Article")]
    facts.images = [ImageFact(src: "https://w2.test/i.png", alt: "i", width: 12, height: 34)]

    let result = CrawlResult(
        urlID: 1, url: URLNormalizer.normalize("https://w2.test/", relativeTo: nil)!,
        depth: 0, status: 200, errorKind: nil, contentType: "text/html", contentLength: 1,
        responseTimeMs: 1, redirectTarget: nil, bodyGz: nil, xRobotsTag: nil,
        headers: ["Strict-Transport-Security": "max-age=63072000"], facts: facts)
    try store.write(results: [result], config: config, now: Date())

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT f.og_title, f.twitter_card, f.rel_next, f.amphtml, f.analytics,
                   r.headers_json,
                   (SELECT count(*) FROM structured_data WHERE url_id = 1) AS sd,
                   (SELECT width FROM images WHERE url_id = 1) AS w
            FROM page_facts f JOIN responses r ON r.url_id = f.url_id WHERE f.url_id = 1
            """)
    }
    #expect(row?["og_title"] == "Stored OG title")
    #expect(row?["twitter_card"] == "summary")
    #expect(row?["rel_next"] == "https://w2.test/page/2")
    #expect(row?["amphtml"] == "https://w2.test/amp")
    #expect(row?["analytics"] == "Plausible, Matomo")
    #expect(row?["sd"] == 1)
    #expect(row?["w"] == 12)
    let headers: String? = row?["headers_json"]
    #expect(headers?.contains("Strict-Transport-Security") == true)
}
