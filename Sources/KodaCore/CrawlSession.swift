import Foundation

public enum CrawlSessionError: Error, CustomStringConvertible {
    case invalidSeedURL(String)

    public var description: String {
        switch self {
        case .invalidSeedURL(let raw): return "Not a crawlable http(s) URL: \(raw)"
        }
    }
}

public enum CrawlSession {
    /// Fetches and parses robots.txt. Any failure means allow-all — a missing
    /// robots.txt permits crawling, and a broken one must not block the crawl.
    public static func fetchRobots(
        for seed: NormalizedURL,
        client: HTTPClient,
        config: CrawlConfig
    ) async -> RobotsRules {
        guard config.respectRobots else { return .allowAll }
        guard let robotsURL = URLNormalizer.normalize("/robots.txt", relativeTo: seed) else { return .allowAll }

        let outcome = await client.fetch(url: robotsURL.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout)
        guard case .response(let response) = outcome,
              response.status == 200,
              let body = response.body
        else { return .allowAll }

        return RobotsRules.parse(String(decoding: body, as: UTF8.self))
    }

    /// Creates the database, seeds the frontier, fetches robots, and runs the crawl to completion.
    @discardableResult
    public static func start(
        dbPath: String?,
        config: CrawlConfig,
        client: HTTPClient,
        parser: PageParser,
        onProgress: (@Sendable (CrawlProgress) -> Void)?
    ) async throws -> Store {
        guard let seed = URLNormalizer.normalize(config.seedURL, relativeTo: nil) else {
            throw CrawlSessionError.invalidSeedURL(config.seedURL)
        }

        let store = try Store(path: dbPath)
        try store.migrate()
        try store.initializeCrawl(config: config, startedAt: Date())
        _ = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())

        let robots = await fetchRobots(for: seed, client: client, config: config)
        let engine = CrawlEngine(store: store, client: client, parser: parser, config: config, robots: robots)
        try await engine.run(onProgress: onProgress)
        return store
    }
}
