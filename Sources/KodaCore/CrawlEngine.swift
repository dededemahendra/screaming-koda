import Foundation

public struct CrawlProgress: Sendable {
    public let crawled: Int
    public let queued: Int
    public let discovered: Int
}

public actor CrawlEngine {
    private let store: Store
    private let client: HTTPClient
    private let parser: PageParser
    private let config: CrawlConfig
    private let robots: RobotsRules

    private var crawled = 0
    private var discovered = 0

    public init(
        store: Store,
        client: HTTPClient,
        parser: PageParser,
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
        let delay = robots.crawlDelay(userAgent: config.userAgent)
        // A crawl-delay directive means requests must be serialized and spaced by
        // that delay, not fired in a `workers`-wide concurrent burst every interval.
        // Driving the batch size to 1 makes each loop iteration process exactly one
        // URL, so the per-iteration sleep below ends up spacing individual requests
        // instead of whole batches — without touching the termination reconciliation.
        let hasDelay = (delay ?? 0) > 0
        let batchSize = hasDelay ? 1 : max(config.workers, 1)

        while true {
            let batch = try store.claimNext(limit: batchSize)
            if batch.isEmpty { break }

            var results: [CrawlResult] = []
            results.reserveCapacity(batch.count)

            await withTaskGroup(of: CrawlResult?.self) { group in
                for item in batch {
                    group.addTask { [config, robots, client, parser] in
                        await Self.process(item: item, config: config, robots: robots,
                                           client: client, parser: parser)
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
                onProgress(CrawlProgress(crawled: crawled, queued: counts.queued, discovered: discovered))
            }

            if hasDelay, let delay {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        try store.markFinished(at: Date())
    }

    private static func process(
        item: FrontierItem, config: CrawlConfig, robots: RobotsRules,
        client: HTTPClient, parser: PageParser
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
                if config.retainBodies { bodyGz = Gzip.compress(body) }
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
