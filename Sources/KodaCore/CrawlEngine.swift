import Foundation

public struct CrawlProgress: Sendable {
    public let crawled: Int
    public let queued: Int
    public let discovered: Int
    /// External links and images given a status in the second phase.
    public let checked: Int

    public init(crawled: Int, queued: Int, discovered: Int, checked: Int = 0) {
        self.crawled = crawled
        self.queued = queued
        self.discovered = discovered
        self.checked = checked
    }
}

public actor CrawlEngine {
    private let store: Store
    private let client: any HTTPClient
    private let parser: any PageParser
    private let config: CrawlConfig
    private let robots: RobotsRules

    private var crawled = 0
    private var discovered = 0
    private var checked = 0

    public init(
        store: Store,
        client: any HTTPClient,
        parser: any PageParser,
        config: CrawlConfig,
        robots: RobotsRules = .allowAll
    ) {
        self.store = store
        self.client = client
        self.parser = parser
        self.config = config
        self.robots = robots
    }

    /// Drains the frontier until nothing is queued. Never throws on a bad page.
    public func run(onProgress: (@Sendable (CrawlProgress) -> Void)?) async throws {
        try store.resetInFlight()

        // A crawl-delay is a floor on the interval between *requests*, not between
        // batches. Claiming `workers` URLs at a time and sleeping once per batch
        // would issue `workers` concurrent requests per delay period — `workers`
        // times faster than the site asked for. Serialising the batch is the only
        // honest reading of the directive.
        let crawlDelay = config.respectRobots ? robots.crawlDelay(userAgent: config.userAgent) : nil
        let isDelayed = (crawlDelay ?? 0) > 0
        let batchSize = isDelayed ? 1 : max(config.workers, 1)

        while true {
            let batch = try store.claimNext(limit: batchSize)
            if batch.isEmpty { break }

            // Body retention is a size decision, not a preference: storing the HTML
            // of half a million pages turns a database that fits on a laptop into
            // one that does not. Re-checked per batch so a crawl that grows past
            // the limit stops retaining rather than having to be restarted.
            let retainBodies = try config.retainBodies && store.urlTotal() < config.retainBodyURLLimit

            var results: [CrawlResult] = []
            results.reserveCapacity(batch.count)

            await withTaskGroup(of: CrawlResult?.self) { group in
                for item in batch {
                    group.addTask { [config, robots, client, parser] in
                        await Self.process(item: item, config: config, robots: robots,
                                           client: client, parser: parser, retainBodies: retainBodies)
                    }
                }
                for await result in group {
                    if let result { results.append(result) }
                }
            }

            // URLs skipped by robots produce no result; close them out so they leave the frontier.
            let produced = Set(results.map(\.urlID))
            for item in batch where !produced.contains(item.id) {
                try store.markSkipped(item.id)
            }

            if !results.isEmpty {
                discovered += try store.write(results: results, config: config, now: Date())
                crawled += results.count
            }

            if let onProgress {
                let counts = try store.urlCounts()
                onProgress(CrawlProgress(crawled: crawled, queued: counts.queued,
                                         discovered: discovered, checked: checked))
            }

            if let crawlDelay, isDelayed {
                try? await Task.sleep(nanoseconds: UInt64(crawlDelay * 1_000_000_000))
            }
        }

        try await checkRecordedURLs(onProgress: onProgress)
        try store.markFinished(at: Date())
    }

    /// Second phase: give external links and internal images a status, without
    /// crawling or parsing either.
    ///
    /// This runs after the internal frontier drains rather than interleaved with
    /// it, so a slow third-party host can never starve the crawl of the site the
    /// user actually asked about.
    private func checkRecordedURLs(onProgress: (@Sendable (CrawlProgress) -> Void)?) async throws {
        guard config.checkExternalLinks || config.checkImages else { return }
        // One batch here can span dozens of hosts, so the global worker count is
        // no longer also the per-host count. This is where maxPerHost starts to matter.
        let limiter = HostLimiter(limit: config.maxPerHost)
        let batchSize = max(config.workers, 1)

        while true {
            let batch = try store.claimForStatusCheck(
                limit: batchSize, maxRedirects: config.maxRedirects,
                external: config.checkExternalLinks, images: config.checkImages
            )
            if batch.isEmpty { break }

            var results: [CrawlResult] = []
            results.reserveCapacity(batch.count)
            await withTaskGroup(of: CrawlResult?.self) { group in
                for item in batch {
                    group.addTask { [config, client] in
                        await Self.statusCheck(item: item, config: config, client: client, limiter: limiter)
                    }
                }
                for await result in group {
                    if let result { results.append(result) }
                }
            }

            let produced = Set(results.map(\.urlID))
            for item in batch where !produced.contains(item.id) {
                try store.markSkipped(item.id)
            }
            if !results.isEmpty {
                checked += results.count
                _ = try store.write(results: results, config: config, now: Date())
            }
            if let onProgress {
                let counts = try store.urlCounts()
                onProgress(CrawlProgress(crawled: crawled, queued: counts.queued,
                                         discovered: discovered, checked: checked))
            }
        }
    }

    /// HEAD, falling back to GET when a server rejects the method. Plenty of
    /// servers answer HEAD with 405 or 501 while serving GET perfectly well, and
    /// reporting that as the link's status would be wrong.
    private static func statusCheck(
        item: FrontierItem, config: CrawlConfig, client: any HTTPClient, limiter: HostLimiter
    ) async -> CrawlResult? {
        await limiter.acquire(host: item.url.host)
        var outcome = await client.fetch(url: item.url.absoluteString, method: "HEAD",
                                         userAgent: config.userAgent, timeout: config.timeout)
        if case .response(let response) = outcome, response.status == 405 || response.status == 501 {
            outcome = await client.fetch(url: item.url.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout)
        }
        await limiter.release(host: item.url.host)

        switch outcome {
        case .failure(let kind):
            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth, status: 0, errorKind: kind,
                contentType: nil, contentLength: nil, responseTimeMs: 0,
                redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: nil
            )
        case .response(let response):
            let redirectTarget = response.isRedirect
                ? response.location.flatMap { URLNormalizer.normalize($0, relativeTo: item.url) }
                : nil
            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth,
                status: response.status, errorKind: nil,
                contentType: response.contentType,
                // A HEAD response has no body, so the header is the only size source.
                contentLength: response.declaredContentLength ?? response.body?.count,
                responseTimeMs: response.elapsedMs,
                redirectTarget: redirectTarget, bodyGz: nil,
                xRobotsTag: response.header("x-robots-tag"), facts: nil
            )
        }
    }

    private static func process(
        item: FrontierItem, config: CrawlConfig, robots: RobotsRules,
        client: any HTTPClient, parser: any PageParser, retainBodies: Bool
    ) async -> CrawlResult? {
        if config.respectRobots, !robots.isAllowed(path: item.url.path, userAgent: config.userAgent) {
            return nil
        }

        let outcome = await client.fetch(url: item.url.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout)

        switch outcome {
        case .failure(let kind):
            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth, status: 0, errorKind: kind,
                contentType: nil, contentLength: nil, responseTimeMs: 0,
                redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: nil
            )

        case .response(let response):
            let redirectTarget = response.isRedirect
                ? response.location.flatMap { URLNormalizer.normalize($0, relativeTo: item.url) }
                : nil

            var facts: PageFacts?
            var bodyGz: Data?
            let isHTML = response.contentType?.contains("html") == true

            if isHTML, let body = response.body, !body.isEmpty {
                let html = String(decoding: body, as: UTF8.self)
                facts = try? parser.parse(html: html)
                if retainBodies { bodyGz = Gzip.compress(body) }
            }

            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth,
                status: response.status, errorKind: nil,
                contentType: response.contentType,
                contentLength: response.body?.count,
                responseTimeMs: response.elapsedMs,
                redirectTarget: redirectTarget, bodyGz: bodyGz,
                xRobotsTag: response.header("x-robots-tag"), facts: facts
            )
        }
    }
}
