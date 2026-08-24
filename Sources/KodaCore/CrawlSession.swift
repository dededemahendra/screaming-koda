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

/// What the sitemap pass found, so a caller can explain a crawl that started
/// from a sitemap which turned out to be empty or unreachable.
public struct SitemapOutcome: Sendable, Equatable {
    public let fetched: Int
    public let urls: Int
    public let queued: Int
    public let failed: [String]

    public var isEmpty: Bool { fetched == 0 }

    public init(fetched: Int, urls: Int, queued: Int, failed: [String]) {
        self.fetched = fetched
        self.urls = urls
        self.queued = queued
        self.failed = failed
    }
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

    /// Creates the database, seeds the frontier, and fetches robots.txt, then
    /// hands back an engine that has NOT been run. The caller owns the task, so
    /// it can pause, resume, or cancel while the crawl is underway.
    /// Fetches the sitemaps a crawl should start from: those configured
    /// explicitly, plus any robots.txt announced.
    ///
    /// A sitemap index is followed one level at a time, bounded by
    /// `config.maxSitemaps`, because an index is allowed to point at another
    /// index and nothing stops that being a cycle. Already-seen URLs are
    /// skipped, which is what actually breaks such a cycle.
    static func collectSitemapURLs(
        starting: [String], client: HTTPClient, config: CrawlConfig
    ) async -> (urls: [NormalizedURL], fetched: Int, failed: [String]) {
        var pending = starting
        var seen = Set<String>()
        var collected: [NormalizedURL] = []
        var found = Set<Data>()
        var fetched = 0
        var failed: [String] = []

        while !pending.isEmpty, fetched < config.maxSitemaps {
            let next = pending.removeFirst()
            guard seen.insert(next).inserted else { continue }
            fetched += 1

            let outcome = await client.fetch(url: next, method: "GET",
                                             userAgent: config.userAgent, timeout: config.timeout)
            guard case .response(let response) = outcome,
                  response.status == 200, let body = response.body, !body.isEmpty
            else {
                failed.append(next)
                continue
            }
            let document = SitemapParser.parse(body)
            if document.isEmpty { failed.append(next) }
            pending.append(contentsOf: document.sitemaps)
            for raw in document.urls {
                guard let url = URLNormalizer.normalize(raw, relativeTo: nil),
                      found.insert(url.sha256).inserted else { continue }
                collected.append(url)
            }
        }
        return (collected, fetched, failed)
    }

    public static func prepare(
        dbPath: String?,
        config: CrawlConfig,
        client: HTTPClient,
        parser: PageParser
    ) async throws -> (engine: CrawlEngine, store: Store, robotsOutcome: RobotsFetchOutcome,
                       sitemap: SitemapOutcome) {
        guard let seed = URLNormalizer.normalize(config.seedURL, relativeTo: nil) else {
            throw CrawlSessionError.invalidSeedURL(config.seedURL)
        }

        let store = try Store(path: dbPath)
        try store.migrate()
        try store.initializeCrawl(config: config, startedAt: Date())
        let now = Date()
        _ = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: now)

        // Any extra URLs the caller supplied, at depth 0 alongside the seed.
        for entry in config.seedList {
            guard let url = URLNormalizer.normalize(entry, relativeTo: nil) else { continue }
            _ = try store.insertURLIfNew(url, depth: 0,
                                         isInternal: Store.isInternal(url, seedHost: config.seedHost,
                                                                      config: config),
                                         discoveredAt: now)
        }

        // Robots first: its `Sitemap:` directives are one of the two sources of
        // sitemaps, and its rules govern whether they may be crawled at all.
        let (robots, outcome) = await fetchRobots(for: seed, client: client, config: config)

        var sitemapStart = config.sitemapURLs
        if config.discoverSitemaps { sitemapStart.append(contentsOf: robots.sitemaps) }
        var sitemapReport = SitemapOutcome(fetched: 0, urls: 0, queued: 0, failed: [])
        if !sitemapStart.isEmpty {
            let collected = await collectSitemapURLs(starting: sitemapStart, client: client,
                                                     config: config)
            let queued = try store.seedFromSitemap(collected.urls, config: config, now: now)
            sitemapReport = SitemapOutcome(fetched: collected.fetched, urls: collected.urls.count,
                                           queued: queued, failed: collected.failed)
        }

        let engine = CrawlEngine(store: store, client: client, parser: parser,
                                 config: config, robots: robots)
        return (engine, store, outcome, sitemapReport)
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
        let (engine, store, outcome, _) = try await prepare(
            dbPath: dbPath, config: config, client: client, parser: parser
        )
        try await engine.run(onProgress: onProgress)
        return (store, outcome)
    }
}
