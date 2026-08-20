import Foundation
import GRDB
import Testing
@testable import KodaCore

private actor MethodLog {
    private(set) var calls: [(url: String, method: String)] = []
    func record(_ url: String, _ method: String) { calls.append((url, method)) }
    func methods(for url: String) -> [String] { calls.filter { $0.url == url }.map(\.method) }
}

private struct CheckClient: HTTPClient {
    let log: MethodLog
    var headStatus: Int = 200
    var contentLength: String? = "4096"

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        await log.record(url, method)
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        var headers: [String: String] = ["Content-Type": "image/png"]
        if let contentLength { headers["Content-Length"] = contentLength }
        if method == "HEAD" {
            // Matches URLSessionHTTPClient's real contract: `session.data(for:)` returns
            // a non-optional Data, so a HEAD comes back with a present-but-empty body,
            // never nil. A mock returning nil here would hide a body?.count ?? 0 bug.
            return .response(HTTPResponse(status: headStatus, headers: headers, body: Data(), elapsedMs: 1))
        }
        // The GET fallback returns a real HTML body, so a test can prove it is
        // still never parsed for links.
        let body = "<html><head><title>T</title></head><body><a href=\"/onwards\">x</a></body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

/// A store holding exactly one queued check-only URL, ready for the engine.
private func storeWithCheckOnlyURL(_ url: String = "https://ext.test/thing.png") throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    let config = CrawlConfig(seedURL: "https://seed.test/")
    try store.initializeCrawl(config: config, startedAt: Date())
    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, check_only)
                VALUES (?,?,?,?,1,0,0,0,1)
                """,
            arguments: [url, Data("hk".utf8), "ext.test", "/thing.png"]
        )
    }
    return store
}

private func runEngine(store: Store, client: CheckClient) async throws {
    var config = CrawlConfig(seedURL: "https://seed.test/")
    config.workers = 1
    let engine = CrawlEngine(store: store, client: client, parser: SwiftSoupParser(), config: config)
    try await engine.run(onProgress: nil)
}

@Test func aCheckOnlyURLIsFetchedWithHEAD() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log))
    #expect(await log.methods(for: "https://ext.test/thing.png") == ["HEAD"])
}

@Test func theStatusIsRecorded() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log))
    let status = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT status FROM responses")
    }
    #expect(status == 200)
}

@Test func contentLengthComesFromTheHeader() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log))
    let size = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT content_length FROM responses")
    }
    #expect(size == 4096, "a HEAD has no body, so size can only come from the header")
}

@Test func aMissingContentLengthLeavesSizeNullNotZero() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, contentLength: nil))
    let size = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT content_length FROM responses")
    }
    #expect(size == nil, "an unknown size must never be reported as zero bytes")
}

@Test func aBodyDownloadedByTheGETFallbackHasItsRealSizeRecorded() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    // headStatus 405 forces the GET fallback, which genuinely downloads a body
    // (and sends no Content-Length header), so this is the one case where
    // falling back to body.count is legitimate rather than a phantom zero.
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 405))
    let body = "<html><head><title>T</title></head><body><a href=\"/onwards\">x</a></body></html>"
    let size = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT content_length FROM responses")
    }
    #expect(size == body.utf8.count,
            "a body the GET fallback actually downloaded must record its real size")
}

@Test func a405TriggersExactlyOneGETRetry() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 405))
    #expect(await log.methods(for: "https://ext.test/thing.png") == ["HEAD", "GET"])
}

@Test func a501TriggersExactlyOneGETRetry() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 501))
    #expect(await log.methods(for: "https://ext.test/thing.png") == ["HEAD", "GET"])
}

@Test func a404IsRecordedWithoutRetrying() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 404))
    #expect(await log.methods(for: "https://ext.test/thing.png") == ["HEAD"],
            "retrying every 4xx would double our traffic on ordinary 404s")
}

@Test func aCheckOnlyResponseDiscoversNoLinks() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    // headStatus 405 forces the GET fallback, which returns a real HTML body.
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 405))
    let links = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM links") ?? 0
    }
    #expect(links == 0, "a status check never crawls onwards, even when the body is HTML")
}

@Test func aCheckOnlyResponseStoresNoPageFacts() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 405))
    let facts = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM page_facts") ?? 0
    }
    #expect(facts == 0)
}

@Test func aTransportFailureOnACheckIsRecordedNotDropped() async throws {
    struct FailingClient: HTTPClient {
        func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
            if url.hasSuffix("/robots.txt") {
                return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
            }
            return .failure(kind: "URLError.cannotFindHost")
        }
    }
    let store = try storeWithCheckOnlyURL()
    var config = CrawlConfig(seedURL: "https://seed.test/")
    config.workers = 1
    let engine = CrawlEngine(store: store, client: FailingClient(), parser: SwiftSoupParser(), config: config)
    try await engine.run(onProgress: nil)

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: "SELECT status, error_kind FROM responses")
    }
    #expect(row?["status"] == 0)
    #expect(row?["error_kind"] == "URLError.cannotFindHost")
}
