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
    /// Bound on how many redirect hops `fetchRobots` will follow before giving up.
    /// robots.txt redirects are ordinarily one hop (bare host → canonical host, or
    /// http → https) — three is generous headroom, not an expected chain length.
    static let robotsRedirectHopLimit = 3

    /// Fetches and parses robots.txt, following redirects itself.
    ///
    /// A missing file (404, and 4xx generally) means allow-all — there is no
    /// robots.txt, so nothing is disallowed. A file that could not be reached at all
    /// (5xx, a 429 rate-limit signal, timeout, DNS failure, connection refused, ...)
    /// is different: per RFC 9309 that is not permission to crawl, so it deliberately
    /// falls back to disallow-all rather than treating server trouble as consent.
    /// `respectRobots == false` skips the fetch entirely rather than fetching and
    /// discarding the result.
    ///
    /// `HTTPClient` deliberately never follows redirects on its own — that is correct
    /// for page fetches, where each hop must be recorded as its own row — but it means
    /// this method has to hop through 3xx responses itself. That matters here because
    /// nearly every site 301s bare `http://` to `https://`, or non-`www` to `www`: without
    /// following the hop, that ordinary redirect would fall through to `.absent` and the
    /// crawl would silently ignore the site's real robots.txt for its entire run.
    public static func fetchRobots(
        for seed: NormalizedURL,
        client: HTTPClient,
        config: CrawlConfig
    ) async -> (rules: RobotsRules, outcome: RobotsFetchOutcome) {
        guard config.respectRobots else { return (.allowAll, .absent) }
        guard let robotsURL = URLNormalizer.normalize("/robots.txt", relativeTo: seed) else {
            return (.allowAll, .absent)
        }

        var currentURL = robotsURL
        for hop in 0...robotsRedirectHopLimit {
            let outcome = await client.fetch(url: currentURL.absoluteString, method: "GET",
                                             userAgent: config.userAgent, timeout: config.timeout)
            switch outcome {
            case .response(let response):
                if response.status == 200, let body = response.body {
                    return (RobotsRules.parse(String(decoding: body, as: UTF8.self)), .parsed)
                }
                // A 429 is a rate-limit signal, not "there is no robots.txt" — transient
                // like a 5xx, so it gets the same conservative disallow-all treatment.
                if (500...599).contains(response.status) || response.status == 429 {
                    return (.disallowAll, .unreachable(reason: "http \(response.status)"))
                }
                if response.isRedirect {
                    guard hop < robotsRedirectHopLimit,
                          let location = response.location,
                          let next = URLNormalizer.normalize(location, relativeTo: currentURL)
                    else {
                        return (.disallowAll, .unreachable(reason: "too many robots.txt redirects"))
                    }
                    currentURL = next
                    continue
                }
                // 404 and other non-server-error, non-redirect statuses: no reachable
                // robots.txt, but not the server misbehaving — treat as legitimately absent.
                return (.allowAll, .absent)

            case .failure(let kind):
                return (.disallowAll, .unreachable(reason: kind))
            }
        }
        return (.disallowAll, .unreachable(reason: "too many robots.txt redirects"))
    }

    /// Creates the database, seeds the frontier, fetches robots, and runs the crawl to completion.
    ///
    /// Returns the `RobotsFetchOutcome` alongside the `Store` because it is not just an
    /// internal detail: when robots.txt is `.unreachable`, the crawl runs disallow-all and
    /// legitimately produces zero (or very few) pages. Callers such as the CLI need this to
    /// explain an otherwise-mysterious empty result rather than silently discarding it.
    @discardableResult
    public static func start(
        dbPath: String?,
        config: CrawlConfig,
        client: HTTPClient,
        parser: PageParser,
        onProgress: (@Sendable (CrawlProgress) -> Void)?
    ) async throws -> (store: Store, robotsOutcome: RobotsFetchOutcome) {
        guard let seed = URLNormalizer.normalize(config.seedURL, relativeTo: nil) else {
            throw CrawlSessionError.invalidSeedURL(config.seedURL)
        }

        let store = try Store(path: dbPath)
        try store.migrate()
        try store.initializeCrawl(config: config, startedAt: Date())
        _ = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())

        let (robots, outcome) = await fetchRobots(for: seed, client: client, config: config)
        let engine = CrawlEngine(store: store, client: client, parser: parser, config: config, robots: robots)
        try await engine.run(onProgress: onProgress)
        return (store, outcome)
    }
}
