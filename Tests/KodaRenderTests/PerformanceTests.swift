import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaRender

private let page = """
    <!doctype html><html><head><meta charset="utf-8"><title>Timed</title>
    <style>.b{height:400px;background:#eee}</style></head>
    <body><h1>Heading</h1><div class="b">A large contentful block of content</div></body></html>
    """

/// What WebKit can actually observe, established by probing rather than assumed.
/// The earlier attempt registered its observers after load and concluded LCP was
/// unavailable; registered at document start, it arrives.
@Test func theBrowserReportsTheTimingsItCanObserve() async throws {
    let server = try TinyServer(pages: ["p.html": page])
    defer { server.stop() }
    try await server.waitUntilReady()

    let rendered = try await WebKitRenderer(poolSize: 1).render(
        url: server.url("/p.html").absoluteString, timeout: 20, settleMs: 900)
    let metrics = try #require(rendered.metrics)

    #expect((metrics.ttfb ?? -1) >= 0)
    #expect((metrics.fcp ?? 0) > 0, "the offscreen view does paint")
    #expect((metrics.lcp ?? 0) > 0, "LCP arrives when the observer starts at document start")
    #expect((metrics.dcl ?? 0) > 0)
    // loadEventEnd is not written until after the load handler returns, so this
    // is read a tick later. Read inside the handler it is always zero.
    #expect((metrics.load ?? 0) > 0, "the load timing is read after the event completes")
}

/// CLS and INP are absent on purpose, and their absence is worth a test: a
/// column that could only ever hold zero would read as a passing grade.
@Test func metricsWebKitCannotObserveAreAbsentRatherThanZero() async throws {
    let server = try TinyServer(pages: ["p.html": page])
    defer { server.stop() }
    try await server.waitUntilReady()

    let supported = try await WebKitRenderer(poolSize: 1).render(
        url: server.url("/p.html").absoluteString, timeout: 10, settleMs: 300,
        scripts: [ExtractionRule(
            name: "types",
            selector: "JSON.stringify(PerformanceObserver.supportedEntryTypes || [])")])
    let types = supported.scriptResults["types"] ?? ""
    #expect(!types.contains("layout-shift"),
            "if WebKit ever gains layout-shift, CLS becomes measurable and this should be revisited")

    let columns = Set(Reports.performance.columns.map(\.id))
    #expect(!columns.contains("cls"))
    #expect(!columns.contains("inp"))
}

@Test func timingsReachTheDatabaseThroughACrawl() async throws {
    let server = try TinyServer(pages: ["index.html": page])
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: server.url("/index.html").absoluteString)
    config.workers = 1
    config.renderJavaScript = true
    config.renderSettleMs = 700

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: URLSessionHTTPClient(),
        parser: SwiftSoupParser(), renderer: WebKitRenderer(poolSize: 1), onProgress: nil)

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT perf_ttfb_ms, perf_fcp_ms, perf_lcp_ms, perf_load_ms FROM responses LIMIT 1
            """)
    }
    #expect((row?["perf_fcp_ms"] as Int? ?? 0) > 0)
    #expect((row?["perf_lcp_ms"] as Int? ?? 0) > 0)
    #expect((row?["perf_load_ms"] as Int? ?? 0) > 0)

    // And the Performance tab shows it.
    let ids = try store.ids(for: Reports.performance,
                            filter: Reports.performance.defaultFilter,
                            sortBy: nil, ascending: true)
    #expect(ids.count == 1)
}

/// A crawl without rendering has no timings, and the tab is empty rather than
/// full of zeroes.
@Test func aStaticCrawlReportsNoTimingsAtAll() async throws {
    let server = try TinyServer(pages: ["index.html": page])
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: server.url("/index.html").absoluteString)
    config.workers = 1
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: URLSessionHTTPClient(),
        parser: SwiftSoupParser(), onProgress: nil)

    let ids = try store.ids(for: Reports.performance,
                            filter: Reports.performance.defaultFilter,
                            sortBy: nil, ascending: true)
    #expect(ids.isEmpty)
    let ttfb = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT perf_ttfb_ms FROM responses LIMIT 1")
    }
    #expect(ttfb == nil, "absent, not zero")
}
