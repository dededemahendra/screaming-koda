import Darwin
import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Serves the fixture directory over real HTTP for the duration of a test.
///
/// The port is chosen by the kernel rather than hard-coded: swift-testing runs
/// tests in parallel, so a fixed port would have every end-to-end test racing for
/// the same bind, and a busy port on the developer's machine would fail the suite
/// for reasons that have nothing to do with the crawler.
private final class FixtureServer: @unchecked Sendable {
    private let process = Process()
    let port: Int

    init(directory: URL) throws {
        port = try Self.reserveEphemeralPort()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Binds port 0, asks the kernel what it got, and releases it. There is a small
    /// window before python3 claims it, which is why `waitUntilReady` still polls.
    private static func reserveEphemeralPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.message("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ServerError.message("bind() failed") }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { throw ServerError.message("getsockname() failed") }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// Polls until the server answers, so tests never race the process starting up.
    func waitUntilReady(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let client = URLSessionHTTPClient()
        while Date() < deadline {
            let outcome = await client.fetch(url: "http://127.0.0.1:\(port)/index.html", method: "GET",
                                             userAgent: "probe", timeout: 1)
            if case .response(let r) = outcome, r.status == 200 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ServerError.message("server did not start on port \(port)")
    }

    func stop() {
        process.terminate()
    }

    enum ServerError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self { case .message(let m): return m }
        }
    }
}

private func fixtureDirectory() throws -> URL {
    guard let url = Bundle.module.url(forResource: "Fixtures/site", withExtension: nil) else {
        throw FixtureServer.ServerError.message("fixture site not found in test bundle")
    }
    return url
}

/// Starts a server, runs the body against it, and always tears the server down.
private func withFixtureServer<T>(_ body: (FixtureServer) async throws -> T) async throws -> T {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()
    return try await body(server)
}

@Test func crawlsRealHTTPServerEndToEnd() async throws {
    let summary = try await withFixtureServer { server in
        var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
        config.workers = 3
        config.retainBodies = true

        let store = try await CrawlSession.start(
            dbPath: nil, config: config,
            client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
        )
        return try store.summary()
    }

    #expect(summary.byStatusClass["2xx"] == 5, "index, about, dupe, and both images")
    #expect(summary.byStatusClass["4xx"] == 1, "missing.html")
    #expect(summary.duplicateTitles == 2, "'Shared Title' on about and dupe")
    #expect(summary.missingDescriptions == 1, "dupe.html")
    #expect(summary.missingH1 == 1, "dupe.html")
    #expect(summary.imagesMissingAlt == 1, "noalt.png")
    #expect(summary.transportErrors == 0)
}

@Test func imagesAreStatusCheckedWithHeadOverRealHTTP() async throws {
    let sizes = try await withFixtureServer { server in
        var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
        config.workers = 2

        let store = try await CrawlSession.start(
            dbPath: nil, config: config,
            client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
        )
        return try await store.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.path AS path, r.status AS status, r.content_length AS bytes
                FROM images i
                JOIN urls u ON u.id = i.src_url_id
                JOIN responses r ON r.url_id = u.id
                ORDER BY u.path
                """).map { ($0["path"] as String, $0["status"] as Int, $0["bytes"] as Int?) }
        }
    }
    #expect(sizes.map(\.0) == ["/noalt.png", "/pic.png"])
    #expect(sizes.allSatisfy { $0.1 == 200 })
    // HEAD returns no body, so a size at all proves Content-Length was read.
    #expect(sizes.allSatisfy { ($0.2 ?? 0) > 0 }, "size comes from the HEAD response header")
}

@Test func robotsBlockedPathIsNotFetched() async throws {
    let fetched = try await withFixtureServer { server in
        var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
        config.workers = 2

        let store = try await CrawlSession.start(
            dbPath: nil, config: config,
            client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
        )
        return try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path LIKE '/blocked/%'
                """) ?? 0
        }
    }
    #expect(fetched == 0, "robots.txt disallows /blocked/")
}

@Test func bodiesAreRetainedAndDecompressible() async throws {
    let body = try await withFixtureServer { server in
        var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/about.html")
        config.workers = 1

        let store = try await CrawlSession.start(
            dbPath: nil, config: config,
            client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
        )
        return try await store.dbQueue.read { db in
            try Data.fetchOne(db, sql: """
                SELECT r.body_gz FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/about.html'
                """)
        }
    }
    let decompressed = try #require(body.flatMap { Gzip.decompress($0) })
    #expect(String(decoding: decompressed, as: UTF8.self).contains("Shared Title"))
}
