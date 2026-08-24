import Foundation
import GRDB
import Testing
@testable import KodaCore

private actor MethodLog {
    private(set) var calls: [(method: String, url: String)] = []
    func record(_ method: String, _ url: String) { calls.append((method, url)) }
    var methods: [String] { calls.map(\.method) }
}

/// One page linking to one image and one external URL, with configurable
/// responses for the assets.
private struct AssetSite: HTTPClient {
    let log: MethodLog
    let imageHeaders: [String: String]
    let headStatus: Int

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        await log.record(method, url)
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://asset.test/" {
            return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data("""
                <html><head><title>Assets</title></head><body><h1>H</h1>
                <img src="/big.png" alt="Big">
                <a href="https://other.test/page">Out</a>
                </body></html>
                """.utf8), elapsedMs: 1))
        }
        if url == "https://asset.test/big.png" {
            if method == "HEAD" && headStatus != 200 {
                return .response(HTTPResponse(status: headStatus, headers: [:], body: Data(), elapsedMs: 1))
            }
            return .response(HTTPResponse(status: 200, headers: imageHeaders, body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], body: Data(), elapsedMs: 1))
    }
}

private func crawlAssets(imageHeaders: [String: String], headStatus: Int = 200) async throws -> (Store, MethodLog) {
    let log = MethodLog()
    var config = CrawlConfig(seedURL: "https://asset.test/")
    config.workers = 2
    let store = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: AssetSite(log: log, imageHeaders: imageHeaders, headStatus: headStatus),
        parser: SwiftSoupParser(), onProgress: nil
    )
    return (store, log)
}

@Test func assetsAreCheckedWithHEAD() async throws {
    let (_, log) = try await crawlAssets(imageHeaders: ["Content-Length": "1234", "Content-Type": "image/png"])
    let calls = await log.calls
    let assetCalls = calls.filter { $0.url.hasSuffix("big.png") || $0.url.hasSuffix("other.test/page") }
    #expect(!assetCalls.isEmpty)
    #expect(assetCalls.allSatisfy { $0.method == "HEAD" }, "assets are never downloaded")
    #expect(calls.contains { $0.url == "https://asset.test/" && $0.method == "GET" }, "pages still use GET")
}

@Test func headContentLengthIsRecordedAsSize() async throws {
    let (store, _) = try await crawlAssets(imageHeaders: ["Content-Length": "204800", "Content-Type": "image/png"])
    let bytes = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT r.content_length FROM responses r JOIN urls u ON u.id = r.url_id
            WHERE u.path = '/big.png'
            """)
    }
    #expect(bytes == 204800, "a HEAD response has no body, so the header is the only size source")
}

@Test func imagesOver100KBAreReported() async throws {
    let (store, _) = try await crawlAssets(imageHeaders: ["Content-Length": "204800", "Content-Type": "image/png"])
    let rows = try store.runReport(ReportCatalogue.report(id: "images-over-100kb")!)
    #expect(rows.count == 1)
    #expect(rows[0][0] == "https://asset.test/big.png")
    #expect(rows[0][1] == "204800")
    #expect(rows[0][2] == "1")
}

@Test func smallImagesAreNotReported() async throws {
    let (store, _) = try await crawlAssets(imageHeaders: ["Content-Length": "2048", "Content-Type": "image/png"])
    #expect(try store.reportCount(ReportCatalogue.report(id: "images-over-100kb")!) == 0)
}

@Test func headRejectionFallsBackToGET() async throws {
    // Plenty of servers answer HEAD with 405 while serving GET perfectly well.
    // Reporting 405 as the link's status would be wrong.
    let (store, log) = try await crawlAssets(
        imageHeaders: ["Content-Length": "99", "Content-Type": "image/png"], headStatus: 405
    )
    let methods = await log.calls.filter { $0.url.hasSuffix("big.png") }.map(\.method)
    #expect(methods == ["HEAD", "GET"])

    let status = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT r.status FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/big.png'
            """)
    }
    #expect(status == 200, "the GET result wins, not the 405")
}

// MARK: - Per-host concurrency

private actor HostPeak {
    private var current: [String: Int] = [:]
    private(set) var peak: [String: Int] = [:]
    func enter(_ h: String) {
        let n = (current[h] ?? 0) + 1
        current[h] = n
        peak[h] = max(peak[h] ?? 0, n)
    }
    func leave(_ h: String) { current[h] = (current[h] ?? 1) - 1 }
}

private struct ManyExternalsSite: HTTPClient {
    let peak: HostPeak

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://many.test/" {
            let links = (0..<20).map { "<a href='https://slow.test/\($0)'>x</a>" }.joined()
            return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                          body: Data("<html><head><title>T</title></head><body><h1>H</h1>\(links)</body></html>".utf8),
                                          elapsedMs: 1))
        }
        let host = URLNormalizer.normalize(url, relativeTo: nil)?.host ?? "?"
        await peak.enter(host)
        try? await Task.sleep(nanoseconds: 3_000_000)
        await peak.leave(host)
        return .response(HTTPResponse(status: 200, headers: [:], body: Data(), elapsedMs: 1))
    }
}

@Test func perHostConcurrencyIsCappedDuringStatusChecks() async throws {
    let peak = HostPeak()
    var config = CrawlConfig(seedURL: "https://many.test/")
    config.workers = 10
    config.maxPerHost = 2

    _ = try await CrawlSession.start(dbPath: nil, config: config, client: ManyExternalsSite(peak: peak),
                                     parser: SwiftSoupParser(), onProgress: nil)

    let observed = await peak.peak["slow.test"] ?? 0
    #expect(observed > 0, "the external host was checked at all")
    #expect(observed <= config.maxPerHost, "20 links to one host must not arrive as 10 at once")
}
