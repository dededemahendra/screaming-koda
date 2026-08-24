import Foundation
import KodaCore

/// A site with enough rows to exercise paging, and enough wrong with it to fill
/// several reports.
struct FixtureSite: HTTPClient {
    static let pageCount = 25

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        func page(_ body: String) -> FetchOutcome {
            .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                   body: Data(body.utf8), elapsedMs: 2))
        }
        if url == "https://fx.test/" {
            let links = (0..<Self.pageCount).map { "<a href='/p\($0)'>p\($0)</a>" }.joined()
            return page("""
                <html><head><title>Home</title><meta name="description" content="Home"></head>
                <body><h1>Home</h1><h2>S</h2>\(links)
                <a href="https://away.test/x">Away</a>
                <img src="/i.png"></body></html>
                """)
        }
        if url.hasPrefix("https://fx.test/p") {
            let n = url.replacingOccurrences(of: "https://fx.test/p", with: "")
            // Every third page shares a title, so the duplicate report is non-empty.
            let title = (Int(n) ?? 0) % 3 == 0 ? "Shared" : "Page \(n)"
            return page("<html><head><title>\(title)</title></head><body><h1>H\(n)</h1></body></html>")
        }
        return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
    }
}

func fixtureStore() async throws -> Store {
    var config = CrawlConfig(seedURL: "https://fx.test/")
    config.workers = 4
    return try await CrawlSession.start(dbPath: nil, config: config, client: FixtureSite(),
                                        parser: SwiftSoupParser(), onProgress: nil)
}

func emptyStore() throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    return store
}
