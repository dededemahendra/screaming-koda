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

    #expect(summary.byStatusClass["2xx"] == 3, "index, about, dupe")
    #expect(summary.byStatusClass["4xx"] == 1, "missing.html")
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
