import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Every provider is tested against a stub rather than the live service. That is
/// not a compromise: the live services need paid accounts, and a test that
/// spends someone's quota to prove a JSON path is read correctly is a bad test
/// whether or not it passes. What is being verified is the request that goes out
/// and the parsing of what comes back — which is all the code there is.
private final class StubAPI: HTTPClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "stub")
    private var responses: [(match: String, status: Int, body: String)]
    private var seenURLs: [String] = []
    private var seenHeaders: [[String: String]] = []
    private var seenBodies: [String] = []

    init(_ responses: [(match: String, status: Int, body: String)]) {
        self.responses = responses
    }

    var urls: [String] { queue.sync { seenURLs } }
    var headers: [[String: String]] { queue.sync { seenHeaders } }
    var bodies: [String] { queue.sync { seenBodies } }

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        await fetch(url: url, method: method, userAgent: userAgent, timeout: timeout,
                    headers: [:], body: nil)
    }

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval,
               headers: [String: String], body: Data?) async -> FetchOutcome {
        queue.sync {
            seenURLs.append(url)
            seenHeaders.append(headers)
            seenBodies.append(body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
        let match = queue.sync { responses.first { url.contains($0.match) } }
        guard let match else {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: match.status, headers: [:],
                                      body: Data(match.body.utf8), elapsedMs: 1))
    }
}

private let tokenResponse = (match: "oauth2.googleapis.com", status: 200,
                             body: #"{"access_token":"ya29.stub","expires_in":3599}"#)

// MARK: - PageSpeed

private let pageSpeedBody = """
    {"lighthouseResult":{
       "categories":{"performance":{"score":0.42},"seo":{"score":0.91},
                     "accessibility":{"score":0.78}},
       "audits":{"largest-contentful-paint":{"numericValue":3400.5},
                 "cumulative-layout-shift":{"numericValue":0.21},
                 "total-blocking-time":{"numericValue":610}}},
     "loadingExperience":{"overall_category":"SLOW",
       "metrics":{"LARGEST_CONTENTFUL_PAINT_MS":{"percentile":3100,"category":"SLOW"},
                  "CUMULATIVE_LAYOUT_SHIFT_SCORE":{"percentile":18,"category":"AVERAGE"},
                  "INTERACTION_TO_NEXT_PAINT":{"percentile":240,"category":"AVERAGE"}}}}
    """

@Test func pageSpeedReadsLabScoresAndFieldData() async throws {
    let stub = StubAPI([(match: "pagespeedonline", status: 200, body: pageSpeedBody)])
    let metrics = try await PageSpeedProvider().fetch(
        urls: ["https://x.test/"], credentials: ProviderCredentials(), client: stub)
    let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.metric, $0) })

    #expect(byName["Lighthouse Performance"]?.value == 42)
    #expect(byName["Lab LCP"]?.value == 3400.5)
    #expect(byName["CWV LCP"]?.value == 3100)
    #expect(byName["CWV Assessment"]?.text == "SLOW")
}

/// The reason PageSpeed carries Core Web Vitals rather than the renderer: CLS
/// and INP are field metrics. WebKit reports no layout-shift entries at all, and
/// INP needs a real interaction. These numbers can only come from somewhere that
/// watched actual visitors.
@Test func pageSpeedSuppliesTheTwoVitalsWebKitCannot() async throws {
    let stub = StubAPI([(match: "pagespeedonline", status: 200, body: pageSpeedBody)])
    let metrics = try await PageSpeedProvider().fetch(
        urls: ["https://x.test/"], credentials: ProviderCredentials(), client: stub)
    let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.metric, $0) })

    // CLS arrives multiplied by a hundred so it can be an integer in the JSON.
    #expect(byName["CWV CLS"]?.value == 0.18)
    #expect(byName["CWV INP"]?.value == 240)
}

@Test func pageSpeedWorksWithoutAKeyAndUsesOneWhenGiven() async throws {
    let stub = StubAPI([(match: "pagespeedonline", status: 200, body: pageSpeedBody)])
    _ = try await PageSpeedProvider().fetch(urls: ["https://x.test/"],
                                            credentials: ProviderCredentials(), client: stub)
    #expect(stub.urls.first?.contains("key=") == false, "the keyless quota is a valid way in")

    var credentials = ProviderCredentials()
    credentials.pageSpeedKey = "SECRET"
    let keyed = StubAPI([(match: "pagespeedonline", status: 200, body: pageSpeedBody)])
    _ = try await PageSpeedProvider().fetch(urls: ["https://x.test/"],
                                            credentials: credentials, client: keyed)
    #expect(keyed.urls.first?.contains("key=SECRET") == true)
}

// MARK: - Search Console

@Test func searchConsoleExchangesARefreshTokenAndReadsRows() async throws {
    let body = """
        {"rows":[{"keys":["https://x.test/a"],"clicks":12,"impressions":340,
                  "ctr":0.035,"position":8.2},
                 {"keys":["https://x.test/gone"],"clicks":3,"impressions":40,
                  "ctr":0.075,"position":30.1}]}
        """
    let stub = StubAPI([tokenResponse, (match: "searchAnalytics", status: 200, body: body)])
    var credentials = ProviderCredentials()
    credentials.googleClientID = "id"
    credentials.googleClientSecret = "secret"
    credentials.googleRefreshToken = "refresh"
    credentials.searchConsoleSite = "https://x.test/"

    let metrics = try await SearchConsoleProvider().fetch(
        urls: ["https://x.test/a"], credentials: credentials, client: stub)

    #expect(stub.urls.first?.contains("oauth2.googleapis.com") == true,
            "the refresh token is exchanged first")
    #expect(stub.headers.last?["Authorization"] == "Bearer ya29.stub")

    let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.metric, $0.value) })
    #expect(byName["Clicks"] == 12)
    #expect(byName["Position"] == 8.2)
    #expect(metrics.allSatisfy { $0.url == "https://x.test/a" },
            "a page Search Console knows but the crawl never found is not invented")
}

@Test func searchConsoleWithoutCredentialsSaysWhatIsMissing() async {
    await #expect(throws: ProviderError.missingCredentials(.searchConsole)) {
        _ = try await SearchConsoleProvider().fetch(
            urls: ["https://x.test/"], credentials: ProviderCredentials(), client: StubAPI([]))
    }
}

// MARK: - Analytics

/// GA4 reports a path where the crawl has a URL, so each row has to be matched
/// back. A path that matches nothing is skipped rather than guessed at.
@Test func analyticsMatchesPathsBackToCrawledURLs() async throws {
    let body = """
        {"rows":[{"dimensionValues":[{"value":"/about"}],
                  "metricValues":[{"value":"120"},{"value":"95"},{"value":"140"}]},
                 {"dimensionValues":[{"value":"/never-crawled"}],
                  "metricValues":[{"value":"9"},{"value":"9"},{"value":"9"}]}]}
        """
    let stub = StubAPI([tokenResponse, (match: "analyticsdata", status: 200, body: body)])
    var credentials = ProviderCredentials()
    credentials.googleClientID = "id"
    credentials.googleClientSecret = "secret"
    credentials.googleRefreshToken = "refresh"
    credentials.analyticsProperty = "123456"

    let metrics = try await AnalyticsProvider().fetch(
        urls: ["https://x.test/about"], credentials: credentials, client: stub)
    #expect(Set(metrics.map(\.url)) == ["https://x.test/about"])
    let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.metric, $0.value) })
    #expect(byName["Sessions"] == 120)
    #expect(byName["Users"] == 95)
}

// MARK: - Backlink providers

@Test func ahrefsReadsItsMetrics() async throws {
    let body = #"{"metrics":{"backlinks":540,"refdomains":88,"url_rating":31,"domain_rating":57}}"#
    let stub = StubAPI([(match: "ahrefs.com", status: 200, body: body)])
    var credentials = ProviderCredentials()
    credentials.ahrefsToken = "tok"
    let metrics = try await AhrefsProvider().fetch(
        urls: ["https://x.test/"], credentials: credentials, client: stub)
    let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.metric, $0.value) })
    #expect(byName["Backlinks"] == 540)
    #expect(byName["Referring domains"] == 88)
    #expect(stub.headers.first?["Authorization"] == "Bearer tok")
}

@Test func majesticReadsABatchInOneCall() async throws {
    let body = """
        {"DataTables":{"Results":{"Data":[
          {"Item":"https://x.test/a","TrustFlow":24,"CitationFlow":31,"ExtBackLinks":410},
          {"Item":"https://x.test/b","TrustFlow":11,"CitationFlow":15,"ExtBackLinks":22}]}}}
        """
    let stub = StubAPI([(match: "majestic.com", status: 200, body: body)])
    var credentials = ProviderCredentials()
    credentials.majesticKey = "key"
    let metrics = try await MajesticProvider().fetch(
        urls: ["https://x.test/a", "https://x.test/b"], credentials: credentials, client: stub)
    #expect(Set(metrics.map(\.url)) == ["https://x.test/a", "https://x.test/b"])
    #expect(stub.urls.count == 1, "a batch provider makes one request, not one per URL")
}

@Test func mozReadsAuthorityScores() async throws {
    let body = """
        {"results":[{"page":"https://x.test/","page_authority":38,
                     "domain_authority":52,"spam_score":2}]}
        """
    let stub = StubAPI([(match: "seomoz.com", status: 200, body: body)])
    var credentials = ProviderCredentials()
    credentials.mozAccessID = "id"
    credentials.mozSecretKey = "secret"
    let metrics = try await MozProvider().fetch(
        urls: ["https://x.test/"], credentials: credentials, client: stub)
    let byName = Dictionary(uniqueKeysWithValues: metrics.map { ($0.metric, $0.value) })
    #expect(byName["Domain authority"] == 52)
    #expect(stub.headers.first?["Authorization"]?.hasPrefix("Basic ") == true)
}

// MARK: - Errors and credentials

@Test func aQuotaErrorIsReportedRatherThanSwallowed() async {
    let stub = StubAPI([(match: "pagespeedonline", status: 429, body: "rate limit exceeded")])
    await #expect(throws: ProviderError.self) {
        _ = try await PageSpeedProvider().fetch(
            urls: ["https://x.test/"], credentials: ProviderCredentials(), client: stub)
    }
}

@Test func availableSourcesReflectsWhatIsActuallyConfigured() {
    var credentials = ProviderCredentials()
    // PageSpeed alone works with nothing configured.
    #expect(credentials.availableSources == [.pageSpeed])

    credentials.ahrefsToken = "tok"
    #expect(credentials.availableSources.contains(.ahrefs))
    #expect(!credentials.availableSources.contains(.moz))

    credentials.googleClientID = "id"
    credentials.googleClientSecret = "secret"
    credentials.googleRefreshToken = "refresh"
    #expect(!credentials.availableSources.contains(.searchConsole),
            "OAuth alone is not enough; it needs the site too")
    credentials.searchConsoleSite = "sc-domain:x.test"
    #expect(credentials.availableSources.contains(.searchConsole))
}

@Test func everySourceSaysWhatItNeeds() {
    for source in MetricSource.allCases {
        #expect(!source.credentialHint.isEmpty)
        #expect(!source.label.isEmpty)
    }
}

// MARK: - Enrichment through a store

@MainActor
private func crawledStore() throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://x.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        for path in ["/", "/about", "/thin"] {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,1,1,0,2)
                    """,
                arguments: ["https://x.test\(path)", Data(path.utf8), "x.test", path])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO responses (url_id, status, content_type, fetched_at)
                    VALUES (?,200,'text/html; charset=utf-8',0)
                    """, arguments: [id])
            try db.execute(
                sql: "INSERT INTO page_facts (url_id, title, word_count) VALUES (?,?,?)",
                arguments: [id, "Title \(path)", path == "/thin" ? 20 : 800])
        }
    }
    return store
}

@MainActor
@Test func enrichmentStoresMetricsAgainstCrawledURLs() async throws {
    let store = try crawledStore()
    let stub = StubAPI([(match: "pagespeedonline", status: 200, body: pageSpeedBody)])
    let result = try await Enrichment.run(source: .pageSpeed, store: store,
                                          credentials: ProviderCredentials(), client: stub)
    #expect(result.failures.isEmpty)
    #expect(result.stored > 0)
    #expect(try store.metricCount(source: .pageSpeed) == result.stored)
    #expect(stub.urls.count == 3, "one call per URL for a single-URL provider")
}

/// Running twice updates rather than accumulating: an enrichment is a snapshot
/// of what a provider says now, not a log of what it has ever said.
@MainActor
@Test func runningEnrichmentTwiceUpdatesRatherThanDuplicating() async throws {
    let store = try crawledStore()
    let stub = StubAPI([(match: "pagespeedonline", status: 200, body: pageSpeedBody)])
    _ = try await Enrichment.run(source: .pageSpeed, store: store,
                                 credentials: ProviderCredentials(), client: stub)
    let first = try store.metricCount(source: .pageSpeed)
    _ = try await Enrichment.run(source: .pageSpeed, store: store,
                                 credentials: ProviderCredentials(), client: stub)
    #expect(try store.metricCount(source: .pageSpeed) == first)
}

/// Quota limits and per-URL errors are ordinary for these APIs. Losing an entire
/// enrichment because one URL upset a provider would be the same mistake as
/// letting one bad page kill a crawl.
@MainActor
@Test func oneFailingURLDoesNotLoseTheWholeEnrichment() async throws {
    let store = try crawledStore()
    let stub = StubAPI([
        (match: "%2Fabout", status: 429, body: "rate limited"),
        (match: "pagespeedonline", status: 200, body: pageSpeedBody),
    ])
    let result = try await Enrichment.run(source: .pageSpeed, store: store,
                                          credentials: ProviderCredentials(), client: stub)
    #expect(result.failures.count == 1)
    #expect(result.failures.first?.contains("about") == true, "the failure names the URL")
    #expect(result.stored > 0, "the other two URLs were still enriched")
}

/// Only pages the crawl actually reached are sent to a provider. Quota is often
/// paid for by the request, and asking about a URL that 404s wastes it.
@MainActor
@Test func onlyCrawledHTMLPagesAreSentToAProvider() throws {
    let store = try crawledStore()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://x.test/missing', x'FE', 'x.test', '/missing', 1, 1, 0, 2);
            INSERT INTO responses (url_id, status, content_type, fetched_at)
            VALUES (last_insert_rowid(), 404, 'text/html', 0);
            """)
    }
    let urls = try store.urlsToEnrich(limit: 100)
    #expect(!urls.contains { $0.hasSuffix("/missing") })
    #expect(urls.count == 3)
}

/// The comparison filters are the point of the whole framework: a crawl finding
/// on its own is a guess about what matters, and traffic says which guesses were
/// right.
@MainActor
@Test func theExternalReportComparesTrafficAgainstCrawlFindings() async throws {
    let store = try crawledStore()
    // /about gets clicks but is noindexed; /thin gets sessions but is thin.
    try await store.dbQueue.write { db in
        try db.execute(sql: """
            UPDATE page_facts SET meta_robots = 'noindex'
            WHERE url_id = (SELECT id FROM urls WHERE path = '/about')
            """)
    }
    try store.write(metrics: [
        ExternalMetric(url: "https://x.test/about", source: "gsc", metric: "Clicks", value: 42),
        ExternalMetric(url: "https://x.test/", source: "gsc", metric: "Clicks", value: 0),
        ExternalMetric(url: "https://x.test/", source: "gsc", metric: "Impressions", value: 900),
        ExternalMetric(url: "https://x.test/thin", source: "ga4", metric: "Sessions", value: 300),
    ], source: .searchConsole)

    func paths(_ filter: String) throws -> Set<String> {
        let f = Reports.externalData.filters.first { $0.id == filter }!
        let ids = try store.ids(for: Reports.externalData, filter: f, sortBy: nil, ascending: true)
        return try store.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT path FROM urls WHERE id IN (\(ids.map(String.init).joined(separator: ",")))
                """))
        }
    }
    #expect(try paths("trafficButNonIndexable") == ["/about"])
    #expect(try paths("impressionsNoClicks") == ["/"])
    #expect(try paths("sessionsButThin") == ["/thin"])
    #expect(try paths("notEnriched") == [])
}
