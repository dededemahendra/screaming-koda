import Darwin
import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaRender

/// A tiny HTTP server, so rendering is exercised against a real network load
/// rather than `loadHTMLString` — which skips the whole navigation path.
private final class TinyServer: @unchecked Sendable {
    let port: Int
    private let process: Process
    private let directory: URL

    init(pages: [String: String]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, body) in pages {
            try body.write(to: directory.appendingPathComponent(name),
                           atomically: true, encoding: .utf8)
        }
        port = try Self.freePort()
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-m", "http.server", String(port),
                             "--bind", "127.0.0.1", "--directory", directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
    }

    private static func freePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let _ = try? await URLSession.shared.data(from: url("/")) { return }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        throw RenderFailure.navigationFailed("server never came up")
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func stop() {
        process.terminate()
        try? FileManager.default.removeItem(at: directory)
    }
}

private let jsPage = """
    <!doctype html><html><head><title>Before JS</title></head>
    <body>
      <h1 id="h">static heading</h1>
      <div id="mount"></div>
      <script>
        document.title = 'After JS';
        document.getElementById('h').textContent = 'rendered heading';
        var a = document.createElement('a');
        a.href = '/discovered.html';
        a.textContent = 'Only reachable after rendering';
        document.getElementById('mount').appendChild(a);
      </script>
    </body></html>
    """

private let brokenPage = """
    <!doctype html><html><head><title>Broken</title></head>
    <body><h1>Broken</h1>
      <script>
        console.error('a deliberate console error');
        undefinedFunctionCall();
      </script>
    </body></html>
    """

/// The decisive question for this whole milestone: does WebKit render inside the
/// test process, where swift-testing owns the main run loop? If it does not,
/// rendering can only ever be smoke-tested by hand.
@Test func webKitRendersInsideTheTestProcess() async throws {
    let server = try TinyServer(pages: ["js.html": jsPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    let renderer = WebKitRenderer(poolSize: 1)
    let page = try await renderer.render(url: server.url("/js.html").absoluteString,
                                         timeout: 20, settleMs: 400)

    #expect(page.html.contains("After JS"), "the title was changed by script")
    #expect(page.html.contains("rendered heading"))
    #expect(page.html.contains("/discovered.html"), "a link that exists only after rendering")
    #expect(page.elapsedMs > 0)
    #expect(page.status == 200, "the rendered navigation's own status")
}

/// The static parse must NOT see what only rendering reveals — otherwise the
/// test above proves nothing about rendering.
@Test func theStaticParserCannotSeeWhatRenderingReveals() throws {
    let facts = try SwiftSoupParser().parse(html: jsPage)
    #expect(facts.title == "Before JS")
    #expect(facts.h1 == "static heading")
    #expect(!facts.links.contains { $0.href == "/discovered.html" })
}

@Test func javascriptErrorsAreCaptured() async throws {
    let server = try TinyServer(pages: ["broken.html": brokenPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    let renderer = WebKitRenderer(poolSize: 1)
    let page = try await renderer.render(url: server.url("/broken.html").absoluteString,
                                         timeout: 20, settleMs: 400)
    #expect(page.errors.contains { $0.contains("a deliberate console error") })
    #expect(page.errors.contains { $0.contains("undefinedFunctionCall") || $0.contains("uncaught") })
}

/// WebKit's failure reporting is narrower than it looks. Probing the delegate
/// sequence showed a blocked or refused port produces
/// `startProvisional → didCommit → didFinish` with an empty 39-byte document and
/// no error, while only a DNS failure reports `didFailProvisional`. So neither
/// didFinish nor didCommit tells you a real page loaded — the arrival of an HTTP
/// response does. Reporting an empty document as a successful render would make
/// the caller discard a good static parse and store nothing in its place.
@Test func aBlockedPortIsAFailureNotAnEmptyPage() async throws {
    let renderer = WebKitRenderer(poolSize: 1)
    await #expect(throws: RenderFailure.self) {
        _ = try await renderer.render(url: "http://127.0.0.1:1/nothing",
                                      timeout: 5, settleMs: 100)
    }
}

/// And an ordinary refused connection, on a port WebKit does not block.
@Test func aRefusedConnectionFails() async throws {
    let renderer = WebKitRenderer(poolSize: 1)
    await #expect(throws: RenderFailure.self) {
        _ = try await renderer.render(url: "http://127.0.0.1:9/nothing",
                                      timeout: 5, settleMs: 100)
    }
}

@Test func aMalformedURLIsRejected() async throws {
    let renderer = WebKitRenderer(poolSize: 1)
    await #expect(throws: RenderFailure.self) {
        _ = try await renderer.render(url: "not a url at all", timeout: 5, settleMs: 100)
    }
}

/// The pool must actually bound concurrency, and must not deadlock when more
/// renders are asked for than slots exist.
@Test func thePoolServesMoreRendersThanItHasSlots() async throws {
    let server = try TinyServer(pages: ["js.html": jsPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    let renderer = WebKitRenderer(poolSize: 2)
    let target = server.url("/js.html").absoluteString
    let results = await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<5 {
            group.addTask {
                (try? await renderer.render(url: target, timeout: 20, settleMs: 200)) != nil
            }
        }
        var out: [Bool] = []
        for await ok in group { out.append(ok) }
        return out
    }
    #expect(results.count == 5)
    #expect(results.allSatisfy { $0 }, "every render completed despite only two slots")
}

// MARK: - Through a real crawl

private let spaIndex = """
    <!doctype html><html><head><title>Loading…</title></head>
    <body><div id="app"></div>
    <script>
      document.title = 'Fully rendered home';
      var app = document.getElementById('app');
      app.innerHTML = '<h1>Client-side heading</h1>'
        + '<p>' + Array(60).fill('word').join(' ') + '</p>'
        + '<a href="/deep.html">A link only rendering reveals</a>';
    </script>
    </body></html>
    """

private let spaDeep = """
    <!doctype html><html><head><title>Deep page</title></head>
    <body><h1>Deep</h1><p>Reached only because rendering found the link.</p></body></html>
    """

/// The whole justification for this milestone: a client-rendered site is
/// invisible to a static crawl, and rendering makes it visible. Both halves are
/// asserted, because "rendering found things" means nothing without "the static
/// crawl did not".
@Test func renderingFindsPagesAStaticCrawlCannot() async throws {
    let server = try TinyServer(pages: ["index.html": spaIndex, "deep.html": spaDeep])
    defer { server.stop() }
    try await server.waitUntilReady()

    func crawl(renderer: PageRenderer?) async throws -> Store {
        var config = CrawlConfig(seedURL: server.url("/index.html").absoluteString)
        config.workers = 1
        config.renderJavaScript = renderer != nil
        config.renderSettleMs = 300
        let (store, _) = try await CrawlSession.start(
            dbPath: nil, config: config, client: URLSessionHTTPClient(),
            parser: SwiftSoupParser(), renderer: renderer, onProgress: nil)
        return store
    }

    let staticStore = try await crawl(renderer: nil)
    let staticFacts = try await staticStore.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT f.title, f.h1, (SELECT count(*) FROM responses) AS pages
            FROM page_facts f LIMIT 1
            """)
    }
    #expect(staticFacts?["title"] == "Loading…", "the pre-render placeholder")
    #expect(staticFacts?["h1"] == nil, "the heading does not exist yet")
    #expect(staticFacts?["pages"] == 1, "the deep link exists only after scripts run")

    let renderedStore = try await crawl(renderer: WebKitRenderer(poolSize: 2))
    let renderedFacts = try await renderedStore.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT f.title, f.h1, r.rendered, r.rendered_words, r.static_words
            FROM page_facts f JOIN responses r ON r.url_id = f.url_id
            JOIN urls u ON u.id = f.url_id WHERE u.path = '/index.html'
            """)
    }
    #expect(renderedFacts?["title"] == "Fully rendered home")
    #expect(renderedFacts?["h1"] == "Client-side heading")
    #expect(renderedFacts?["rendered"] == 1)
    #expect((renderedFacts?["rendered_words"] as Int? ?? 0)
            > (renderedFacts?["static_words"] as Int? ?? 0),
            "the rendered DOM has content the static one does not")

    let renderedPages = try await renderedStore.dbQueue.read { db in
        Set(try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id
            """))
    }
    #expect(renderedPages == ["/index.html", "/deep.html"],
            "rendering discovered a page the static crawl could not reach")
}

/// Rendering must not cost the page when it fails. A crawl that loses a page
/// because a browser hiccuped is worse than one that never rendered.
@Test func aFailedRenderKeepsTheStaticParse() async throws {
    let server = try TinyServer(pages: ["index.html": spaIndex])
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: server.url("/index.html").absoluteString)
    config.workers = 1
    config.renderJavaScript = true

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: URLSessionHTTPClient(),
        parser: SwiftSoupParser(), renderer: AlwaysFailingRenderer(), onProgress: nil)

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT f.title, r.rendered FROM page_facts f JOIN responses r ON r.url_id = f.url_id
            """)
    }
    #expect(row?["title"] == "Loading…", "the static parse survives intact")
    #expect(row?["rendered"] == 0, "and the page is honestly marked as not rendered")
}

private struct AlwaysFailingRenderer: PageRenderer {
    func render(url: String, timeout: TimeInterval, settleMs: Int) async throws -> RenderedPage {
        throw RenderFailure.navigationFailed("deliberate test failure")
    }
}

/// JavaScript errors from a rendered crawl reach the database, not just the
/// renderer's return value.
@Test func javascriptErrorsFromACrawlArePersisted() async throws {
    let server = try TinyServer(pages: ["index.html": brokenPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: server.url("/index.html").absoluteString)
    config.workers = 1
    config.renderJavaScript = true

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: URLSessionHTTPClient(),
        parser: SwiftSoupParser(), renderer: WebKitRenderer(poolSize: 1), onProgress: nil)

    let errors = try await store.dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT js_errors FROM responses LIMIT 1")
    }
    #expect(errors?.contains("a deliberate console error") == true)
}

// MARK: - Custom JavaScript extraction

/// The charset declaration is load-bearing, not decoration. Without it — and
/// python's http.server sends no charset for .html — WebKit falls back to a
/// legacy encoding exactly as any browser does, and renders "£" as "Â£". The
/// static decoder tries UTF-8 first and gets it right, so the two paths
/// genuinely disagree on an undeclared page. The browser is the authority for a
/// rendered page, and real pages declare their encoding.
private let dataPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Data</title></head>
    <body><div id="price" data-cents="4999">£49.99</div>
    <script>window.__STOCK__ = 17; window.__SKU__ = 'ACME-1';</script>
    </body></html>
    """

/// The thing CSS selectors cannot reach: a value that exists only as a
/// JavaScript variable, never in the DOM.
@Test func aJavaScriptSnippetCanExtractAValueThatIsNotInTheDOM() async throws {
    let server = try TinyServer(pages: ["data.html": dataPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    let page = try await WebKitRenderer(poolSize: 1).render(
        url: server.url("/data.html").absoluteString, timeout: 20, settleMs: 300,
        scripts: [
            ExtractionRule(name: "Stock", selector: "window.__STOCK__"),
            ExtractionRule(name: "SKU", selector: "window.__SKU__"),
            ExtractionRule(name: "Price cents",
                           selector: "document.getElementById('price').dataset.cents"),
        ])
    #expect(page.scriptResults["Stock"] == "17")
    #expect(page.scriptResults["SKU"] == "ACME-1")
    #expect(page.scriptResults["Price cents"] == "4999")
}

/// One broken snippet must not cost the page or the other snippets — the same
/// rule an invalid CSS selector already follows.
@Test func aThrowingSnippetYieldsNothingAndSpareTheRest() async throws {
    let server = try TinyServer(pages: ["data.html": dataPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    let page = try await WebKitRenderer(poolSize: 1).render(
        url: server.url("/data.html").absoluteString, timeout: 20, settleMs: 300,
        scripts: [
            ExtractionRule(name: "Broken", selector: "nope.does.not.exist()"),
            ExtractionRule(name: "SKU", selector: "window.__SKU__"),
        ])
    #expect(page.scriptResults["Broken"] == nil)
    #expect(page.scriptResults["SKU"] == "ACME-1")
    #expect(!page.html.isEmpty, "the render itself survived")
}

/// A snippet is user text going into a JavaScript program, so it is passed as a
/// JSON string literal rather than spliced in — the same reasoning that keeps
/// user input out of the SQL.
@Test func aSnippetContainingQuotesIsNotSpliced() async throws {
    let server = try TinyServer(pages: ["data.html": dataPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    // A snippet whose source contains both quote characters. Spliced in
    // naively this would end the wrapper's own string and change the program.
    let snippet = #"'a"b' + "c'd""#
    let page = try await WebKitRenderer(poolSize: 1).render(
        url: server.url("/data.html").absoluteString, timeout: 20, settleMs: 300,
        scripts: [ExtractionRule(name: "Quoted", selector: snippet)])
    #expect(page.scriptResults["Quoted"] == #"a"bc'd"#)
}

@Test func jsLiteralEscapesWhatItMust() {
    #expect(RenderSession.jsLiteral("simple") == #""simple""#)
    #expect(RenderSession.jsLiteral(#"has "quotes""#).contains(#"\""#))
    #expect(RenderSession.jsLiteral("has\nnewline").contains(#"\n"#))
}

/// And the results reach the database as extractions, beside the CSS ones.
@Test func javaScriptExtractionsLandInTheExtractionTab() async throws {
    let server = try TinyServer(pages: ["index.html": dataPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: server.url("/index.html").absoluteString)
    config.workers = 1
    config.renderJavaScript = true
    config.extractions = [ExtractionRule(name: "Price text", selector: "#price")]
    config.javaScriptExtractions = [ExtractionRule(name: "Stock", selector: "window.__STOCK__")]

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: URLSessionHTTPClient(),
        parser: SwiftSoupParser(), renderer: WebKitRenderer(poolSize: 1), onProgress: nil)

    let rows = try await store.dbQueue.read { db in
        try Row.fetchAll(db, sql: "SELECT name, value FROM extractions ORDER BY name")
    }
    let byName = Dictionary(uniqueKeysWithValues: rows.map {
        ($0["name"] as String? ?? "", $0["value"] as String? ?? "")
    })
    #expect(byName["Stock"] == "17", "a JavaScript-only value")
    #expect(byName["Price text"] == "£49.99", "and a CSS-selector one, side by side")
}
