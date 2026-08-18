import Foundation

public enum CrawlSessionError: Error, CustomStringConvertible {
    case invalidSeedURL(String)

    public var description: String {
        switch self {
        case .invalidSeedURL(let raw): return "Not a crawlable http(s) URL: \(raw)"
        }
    }
}

/// What happened when robots.txt was fetched, independent of the rules that resulted.
/// `start` doesn't surface this yet, but the CLI (a later task) needs to be able to
/// tell "no robots.txt" (fine, proceed) apart from "robots.txt was unreachable" (the
/// crawl is running in a deliberately conservative disallow-all mode, and the user
/// should be told why rather than just seeing zero pages crawled).
public enum RobotsFetchOutcome: Sendable, Equatable {
    /// robots.txt was fetched and parsed successfully.
    case parsed
    /// robots.txt does not exist (404 or other 4xx) — there is nothing to disallow.
    case absent
    /// robots.txt could not be reached — a 5xx, or a transport failure such as a
    /// timeout, DNS failure, or connection refused. Not the site owner's permission
    /// to crawl, so this pairs with `RobotsRules.disallowAll`, not `.allowAll`.
    case unreachable(reason: String)
}

public enum CrawlSession {
    /// Fetches and parses robots.txt.
    ///
    /// A missing file (404, and 4xx generally) means allow-all — there is no
    /// robots.txt, so nothing is disallowed. A file that could not be reached at all
    /// (5xx, timeout, DNS failure, connection refused, ...) is different: per RFC 9309
    /// that is not permission to crawl, so it deliberately falls back to disallow-all
    /// rather than treating server trouble as consent. `respectRobots == false` skips
    /// the fetch entirely rather than fetching and discarding the result.
    public static func fetchRobots(
        for seed: NormalizedURL,
        client: HTTPClient,
        config: CrawlConfig
    ) async -> (rules: RobotsRules, outcome: RobotsFetchOutcome) {
        guard config.respectRobots else { return (.allowAll, .absent) }
        guard let robotsURL = URLNormalizer.normalize("/robots.txt", relativeTo: seed) else {
            return (.allowAll, .absent)
        }

        let outcome = await client.fetch(url: robotsURL.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout)
        switch outcome {
        case .response(let response):
            if response.status == 200, let body = response.body {
                return (RobotsRules.parse(String(decoding: body, as: UTF8.self)), .parsed)
            }
            if (500...599).contains(response.status) {
                return (.disallowAll, .unreachable(reason: "http \(response.status)"))
            }
            // 404 and other non-server-error statuses: no reachable robots.txt, but
            // not the server misbehaving — treat as legitimately absent.
            return (.allowAll, .absent)

        case .failure(let kind):
            return (.disallowAll, .unreachable(reason: kind))
        }
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

        let (robots, _) = await fetchRobots(for: seed, client: client, config: config)
        let engine = CrawlEngine(store: store, client: client, parser: parser, config: config, robots: robots)
        try await engine.run(onProgress: onProgress)
        return store
    }
}
