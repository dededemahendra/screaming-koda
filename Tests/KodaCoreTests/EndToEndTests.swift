import Darwin
import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Binds an ephemeral TCP port on 127.0.0.1 by asking the OS for port 0, reads back
/// whatever port it actually assigned, then releases the socket immediately.
///
/// swift-testing runs `@Test` functions concurrently by default, and every test in
/// this file starts its own `FixtureServer`. A single fixed port (the brief's original
/// approach) meant those servers raced each other for the same port and lost — the
/// first test to bind it succeeded, and every other test in the same run either failed
/// to start its own server or, worse, silently talked to a different test's server.
/// Discovering a free port per server avoids the collision entirely rather than papering
/// over it with retries. There's a theoretical TOCTOU window between closing this probe
/// socket and python binding the same port, but it's the standard "find a free port"
/// idiom and is more than good enough for a local test fixture.
private func findFreePort() throws -> Int {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
        throw NSError(domain: "FixtureServer", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "could not create a probe socket"])
    }
    defer { close(sock) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bindResult == 0 else {
        throw NSError(domain: "FixtureServer", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "could not bind probe socket to find a free port"])
    }

    var actual = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let getResult = withUnsafeMutablePointer(to: &actual) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
    }
    guard getResult == 0 else {
        throw NSError(domain: "FixtureServer", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "could not read back the assigned port"])
    }
    return Int(UInt16(bigEndian: actual.sin_port))
}

/// Serves the fixture directory over real HTTP for the duration of a test.
private final class FixtureServer {
    private let process = Process()
    let port: Int

    init(directory: URL) throws {
        port = try findFreePort()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Polls until the server answers, so tests never race the process starting up.
    func waitUntilReady(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let client = URLSessionHTTPClient()
        while Date() < deadline {
            let outcome = await client.fetch(url: "http://127.0.0.1:\(port)/index.html", method: "GET",
                                             userAgent: "probe", timeout: 1)
            if case .response(let r) = outcome, r.status == 200 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "FixtureServer", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "server did not start on port \(port) within \(timeout)s — the port was free when probed but may " +
                "have been grabbed by another process before python3 bound it (check with `lsof -i :\(port)`), " +
                "or python3 -m http.server may have failed to launch (check /usr/bin/python3 exists)",
        ])
    }

    /// Terminates the server and waits for exit so a failed test never leaves an
    /// orphaned python process holding the port for the next run.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

private func fixtureDirectory() throws -> URL {
    guard let url = Bundle.module.url(forResource: "Fixtures/site", withExtension: nil) else {
        throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture site not found"])
    }
    return url
}

/// Serves a real 301 redirect over real HTTP for the duration of a test.
///
/// `python3 -m http.server` (used by `FixtureServer` above) can only serve static files from a
/// directory and has no way to emit a redirect, so this runs a tiny standalone
/// `BaseHTTPRequestHandler` script (`Fixtures/redirect_server.py`) instead: `/redirect-me`
/// answers 301 with a `Location: /target.html` header, `/target.html` answers 200, everything
/// else (including `/robots.txt`) answers 404. Mirrors `FixtureServer`'s ephemeral-port
/// discovery and `defer`-based teardown so no python process is ever orphaned.
private final class RedirectFixtureServer {
    private let process = Process()
    let port: Int

    init(script: URL) throws {
        port = try findFreePort()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Polls `/target.html` (not the redirecting path) until it answers 200, so tests never
    /// race the process starting up.
    func waitUntilReady(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let client = URLSessionHTTPClient()
        while Date() < deadline {
            let outcome = await client.fetch(url: "http://127.0.0.1:\(port)/target.html", method: "GET",
                                             userAgent: "probe", timeout: 1)
            if case .response(let r) = outcome, r.status == 200 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "RedirectFixtureServer", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "server did not start on port \(port) within \(timeout)s — the port was free when probed but may " +
                "have been grabbed by another process before python3 bound it (check with `lsof -i :\(port)`), " +
                "or redirect_server.py may have failed to launch (check /usr/bin/python3 exists)",
        ])
    }

    /// Terminates the server and waits for exit so a failed test never leaves an
    /// orphaned python process holding the port for the next run.
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }
}

private func redirectServerScript() throws -> URL {
    guard let url = Bundle.module.url(forResource: "Fixtures/redirect_server", withExtension: "py") else {
        throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "redirect_server.py not found"])
    }
    return url
}

@Test func crawlsRealHTTPServerEndToEnd() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 3
    config.retainBodies = true

    let (store, robotsOutcome) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
    )
    #expect(robotsOutcome == .parsed)
    let summary = try store.summary()

    #expect(summary.byStatusClass["2xx"] == 6, "index, about, dupe, latin1, rich, report.pdf")
    // missing.html (a real dead link) plus pic.png and noalt.png: checkImages now fetches
    // both <img> sources on index.html, and neither file exists on the fixture server, so
    // both genuinely 404. blocked/secret.html is not among these three because robots.txt
    // disallows it, so it's never fetched at all (see `robotsBlockedPathIsNotFetched`).
    #expect(summary.byStatusClass["4xx"] == 3, "missing.html, pic.png, noalt.png")
    #expect(summary.duplicateTitles == 2, "'Shared Title' on about and dupe")
    #expect(summary.missingDescriptions == 1, "dupe.html")
    #expect(summary.missingH1 == 1, "dupe.html")
    #expect(summary.imagesMissingAlt == 1, "noalt.png")
    #expect(summary.transportErrors == 0)
}

@Test func robotsBlockedPathIsNotFetched() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 2

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
    )
    let fetched = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path LIKE '/blocked/%'
            """) ?? 0
    }
    #expect(fetched == 0, "robots.txt disallows /blocked/")
}

@Test func bodiesAreRetainedAndDecompressible() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/about.html")
    config.workers = 1

    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
    )
    let body = try await store.dbQueue.read { db in
        try Data.fetchOne(db, sql: """
            SELECT r.body_gz FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/about.html'
            """)
    }
    let decompressed = try #require(body.flatMap { Gzip.decompress($0) })
    #expect(String(decoding: decompressed, as: UTF8.self).contains("Shared Title"))
}

/// Every other redirect test in the project uses a stub `HTTPClient` — this is the one place
/// that proves, over a real socket, that the crawler's manual redirect handling (refusing
/// `URLSession`'s automatic redirect following so each hop lands as its own row) actually
/// works against a real 301 response rather than only against a hand-written `FetchOutcome`.
@Test func redirectIsRecordedSeparatelyOverRealHTTP() async throws {
    let server = try RedirectFixtureServer(script: try redirectServerScript())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/redirect-me")
    config.workers = 1

    let (store, robotsOutcome) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
    )
    #expect(robotsOutcome == .absent, "the fixture server 404s /robots.txt")

    let redirectRow = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT r.status, r.redirect_target_id, t.path AS target_path FROM responses r
            JOIN urls u ON u.id = r.url_id
            LEFT JOIN urls t ON t.id = r.redirect_target_id
            WHERE u.path = '/redirect-me'
            """)
    }
    #expect(redirectRow?["status"] == 301)
    let targetID: Int64? = redirectRow?["redirect_target_id"]
    #expect(targetID != nil, "the redirect resolved to a target row instead of being followed silently")
    #expect(redirectRow?["target_path"] == "/target.html")

    let targetStatus = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT r.status FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/target.html'
            """)
    }
    #expect(targetStatus == 200, "the target was fetched separately, not collapsed into the redirect's own response")
}

// MARK: - The reports, against a real crawl
//
// `ReportFixture` is written by hand, so it could flatter the report SQL by
// containing exactly the shapes the SQL expects. These run the same eleven
// reports over a crawl the crawler actually produced from real HTTP responses.

@Test func everyReportRunsAgainstARealCrawl() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 3
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil)

    let counts = try store.counts(for: Reports.all)
    for report in Reports.all {
        for filter in report.filters {
            let ids = try store.ids(for: report, filter: filter, sortBy: nil, ascending: true)
            #expect(counts["\(report.id).\(filter.id)"] == ids.count,
                    "\(report.id).\(filter.id): sidebar count disagrees with the rows")
            // Every column must survive a real row, including the derived ones.
            _ = try store.rows(ids: Array(ids.prefix(20)), columns: report.columns)
            // And every sortable column must survive being ordered by.
            for column in report.columns where column.sortable {
                _ = try store.ids(for: report, filter: filter, sortBy: column, ascending: false)
            }
        }
    }
}

/// The findings a person would actually expect from this fixture site, arrived
/// at by reading the HTML rather than by running the code and writing down
/// whatever it said.
@Test func theReportsFindWhatTheFixtureSiteActuallyContains() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 3
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil)
    let counts = try store.counts(for: Reports.all)

    #expect(counts["titles.all"] == 5, "index, about, dupe, latin1, rich are the HTML 200s")
    #expect(counts["titles.duplicate"] == 2, "'Shared Title' on about and dupe")
    #expect(counts["titles.missing"] == 0)
    #expect(counts["metaDescription.missing"] == 1, "dupe.html has no description")
    #expect(counts["headings.missingH1"] == 1, "dupe.html has no h1")
    #expect(counts["images.all"] == 2, "pic.png and noalt.png")
    #expect(counts["images.missingAlt"] == 1, "noalt.png")
    #expect(counts["responseCodes.clientError"] == 3, "missing.html, pic.png, noalt.png")
    #expect(counts["responseCodes.serverError"] == 0)
    #expect(counts["external.all"] == 0, "the fixture site links nowhere off-host")

    // The reports and the M1 summary must not disagree about the same crawl.
    let summary = try store.summary()
    #expect(counts["titles.duplicate"] == summary.duplicateTitles)
    #expect(counts["metaDescription.missing"] == summary.missingDescriptions)
    #expect(counts["headings.missingH1"] == summary.missingH1)
    #expect(counts["images.missingAlt"] == summary.imagesMissingAlt)
    #expect(counts["internal.all"] == summary.totalURLs,
            "the Internal tab and the crawl summary must count the same rows")
}

/// The inspector against real crawl data, not hand-written rows.
@Test func theInspectorDescribesARealCrawledPage() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 3
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil)

    let homeID = try await store.dbQueue.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE path = '/index.html'")!
    }
    let detail = try #require(try store.detail(id: homeID))
    #expect(detail.value("Title") == "Fixture Home")
    #expect(detail.value("H1") == "Home")
    #expect(detail.value("Status") == "200")
    #expect(detail.value("Indexability") == Indexability.indexable)

    let outlinks = try store.outlinks(id: homeID)
    #expect(outlinks.total == 7, "about, dupe, missing, blocked, latin1, rich, report.pdf")
    #expect(outlinks.items.contains { $0.url.hasSuffix("/missing.html") && $0.status == 404 },
            "a broken outbound link is what this pane exists to show")

    let images = try store.imageRows(id: homeID)
    #expect(images.total == 2)
    #expect(images.items.contains { $0.url.hasSuffix("noalt.png") && $0.alt == nil })
}

/// The end-to-end proof for `TextDecoding`: a real page served in Windows-1252,
/// fetched over real HTTP, must land in the database with its accents intact.
///
/// The fixture page carries no `<meta charset>`, and python's http.server sends
/// no charset parameter for .html, so this exercises the fallback path — which
/// is the one that matters, because undeclared legacy pages are exactly where a
/// bare UTF-8 decode goes wrong.
@Test func aWindows1252PageKeepsItsAccents() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 3
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil)

    let title = try await store.dbQueue.read { db in
        try String.fetchOne(db, sql: """
            SELECT f.title FROM page_facts f
            JOIN urls u ON u.id = f.url_id
            WHERE u.path = '/latin1.html'
            """)
    }
    #expect(title == "Café naïve", "got \(title ?? "nil")")

    // And it must not then be reported as a problem it does not have.
    let counts = try store.counts(for: Reports.all)
    #expect(counts["titles.missing"] == 0)
}

/// Wave 2 end to end: social tags, structured data, pagination, analytics and
/// declared image dimensions, read off a real page served over real HTTP.
@Test func aRichlyMarkedUpPageIsFullyExtracted() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 3
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil)

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT f.og_title, f.og_type, f.twitter_card, f.amphtml,
                   f.rel_prev, f.rel_next, f.analytics, f.h2,
                   (SELECT group_concat(type) FROM structured_data sd WHERE sd.url_id = u.id) AS types,
                   (SELECT count(DISTINCT format) FROM structured_data sd WHERE sd.url_id = u.id) AS formats
            FROM urls u JOIN page_facts f ON f.url_id = u.id
            WHERE u.path = '/rich.html'
            """)
    }
    #expect(row?["og_title"] == "Rich fixture page")
    #expect(row?["og_type"] == "article")
    #expect(row?["twitter_card"] == "summary_large_image")
    #expect(row?["h2"] == "A subheading")
    #expect(row?["analytics"] == "Google Tag Manager")
    #expect((row?["amphtml"] as String?)?.hasSuffix("amp/rich.html") == true)
    #expect((row?["rel_next"] as String?)?.hasSuffix("about.html") == true)
    #expect(row?["formats"] == 2, "JSON-LD and microdata on the same page")

    let types = Set((row?["types"] as String? ?? "").split(separator: ",").map(String.init))
    #expect(types == ["Article", "BreadcrumbList", "Organization"])

    // Declared dimensions, and headers stored wholesale.
    let extras = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT (SELECT i.width FROM images i
                    JOIN urls s ON s.id = i.src_url_id
                    JOIN urls p ON p.id = i.url_id
                    WHERE s.path = '/pic.png' AND p.path = '/rich.html') AS w,
                   (SELECT r.headers_json FROM responses r JOIN urls u ON u.id = r.url_id
                    WHERE u.path = '/rich.html') AS h
            """)
    }
    #expect(extras?["w"] == 320)
    #expect((extras?["h"] as String?)?.lowercased().contains("content-type") == true)
}

/// A PDF linked from a real page, fetched over real HTTP, must land in the
/// database with its own title rather than as an untitled binary.
@Test func aLinkedPDFIsCrawledAndTitled() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 3
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil)

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: """
            SELECT f.title, f.meta_description, f.word_count, r.status, r.content_type
            FROM urls u
            JOIN responses r ON r.url_id = u.id
            LEFT JOIN page_facts f ON f.url_id = u.id
            WHERE u.path = '/report.pdf'
            """)
    }
    #expect(row?["status"] == 200)
    #expect(row?["title"] == "The Fixture Report")
    #expect(row?["meta_description"] == "A PDF served by the fixture site")
    #expect((row?["word_count"] as Int? ?? 0) > 0)
}
