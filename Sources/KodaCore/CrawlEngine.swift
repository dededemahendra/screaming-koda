import Foundation

public struct CrawlProgress: Sendable {
    public let crawled: Int
    public let queued: Int
    public let discovered: Int
}

public enum CrawlEngineError: Error, CustomStringConvertible {
    /// `run()` was called while this engine already had a crawl underway
    /// (running or paused). A public API on an actor shouldn't rely on callers
    /// serializing their own calls, so a second concurrent `run()` is rejected
    /// rather than left to race the first on shared state.
    case alreadyRunning

    public var description: String {
        switch self {
        case .alreadyRunning: return "This CrawlEngine already has a crawl running or paused."
        }
    }
}

public actor CrawlEngine {
    private let store: Store
    private let client: HTTPClient
    private let parser: PageParser
    private let config: CrawlConfig
    private let robots: RobotsRules

    private var crawled = 0
    private var discovered = 0
    private var isPaused = false
    private var isCancelled = false
    private var currentState: CrawlState = .idle

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

    public var state: CrawlState { currentState }

    /// Stops claiming new batches. The in-flight batch still finishes and is
    /// written — fetched work is never discarded.
    public func pause() {
        guard currentState == .running else { return }
        isPaused = true
        currentState = .paused
    }

    public func resume() {
        guard currentState == .paused else { return }
        isPaused = false
        currentState = .running
    }

    /// Stops the crawl. The in-flight batch finishes and is written, then
    /// claimed-but-unproduced rows return to the queue so a restart continues.
    public func cancel() {
        guard currentState.isActive else { return }
        isCancelled = true
        isPaused = false
    }

    /// Drains the frontier until nothing is queued, paused, or cancelled. Never
    /// throws on a bad page.
    ///
    /// Rejects a second concurrent call while a crawl is already running or
    /// paused on this engine — two loops racing on `crawled`, `discovered`, and
    /// `currentState` could let one observe an empty frontier and mark the crawl
    /// finished while the other is still fetching. Calling `run()` again after
    /// this engine's crawl has ended (`.finished`, `.cancelled`, or `.failed`) is
    /// fine and is how a cancelled crawl is resumed.
    public func run(onProgress: (@Sendable (CrawlProgress) -> Void)?) async throws {
        guard !currentState.isActive else {
            throw CrawlEngineError.alreadyRunning
        }

        currentState = .running
        isPaused = false
        isCancelled = false

        do {
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
                // Pausing waits here, between batches, where there is no
                // in-flight state to lose. Polling rather than a stored
                // continuation: marginally less elegant, much harder to deadlock.
                while isPaused && !isCancelled {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                if isCancelled { break }

                let batch = try store.claimNext(limit: batchSize, maxPerHost: config.maxPerHost)
                if batch.isEmpty { break }

                // Bodies are only worth retaining while the crawl is small enough that
                // storing every HTML body doesn't balloon the database — see
                // `CrawlConfig.retainBodyURLLimit`. Once `crawled` (already tracked here
                // for progress reporting) passes the limit, newly-fetched bodies stop
                // being retained; bodies already stored are untouched. Reusing `crawled`
                // keeps this a plain integer comparison instead of a query per page.
                let retainBodies = config.retainBodies && crawled < config.retainBodyURLLimit

                var results: [CrawlResult] = []
                results.reserveCapacity(batch.count)

                await withTaskGroup(of: CrawlResult?.self) { group in
                    for item in batch {
                        group.addTask { [config, robots, client, parser, retainBodies] in
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
                    onProgress(CrawlProgress(crawled: crawled, queued: counts.queued, discovered: discovered))
                }

                if hasDelay, let delay {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }

            if isCancelled {
                try store.resetInFlight()
                currentState = .cancelled
            } else {
                try store.markFinished(at: Date())
                currentState = .finished
            }
        } catch {
            currentState = .failed("\(error)")
            throw error
        }
    }

    /// A status check: HEAD the URL, record what came back, parse nothing.
    /// Used for external links and image sources — we want their status and size,
    /// not their content, and we never crawl onwards from them.
    private static func statusCheck(
        item: FrontierItem, config: CrawlConfig, client: HTTPClient
    ) async -> CrawlResult {
        var outcome = await client.fetch(url: item.url.absoluteString, method: "HEAD",
                                         userAgent: config.userAgent, timeout: config.timeout,
                                         headers: config.requestHeaders)

        // 405 and 501 are the two codes that actually mean "this server does not do
        // HEAD". Retrying on any other 4xx would double our traffic on ordinary 404s.
        var usedGETFallback = false
        if case .response(let head) = outcome, head.status == 405 || head.status == 501 {
            outcome = await client.fetch(url: item.url.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout,
                                         headers: config.requestHeaders)
            usedGETFallback = true
        }

        switch outcome {
        case .failure(let kind):
            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth, status: 0, errorKind: kind,
                contentType: nil, contentLength: nil, responseTimeMs: 0,
                redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: nil
            )
        case .response(let response):
            // A HEAD carries no content by definition, regardless of what bytes the
            // transport happens to buffer — `URLSessionHTTPClient` hands back a
            // present-but-empty `Data()`, not nil, so `body?.count` would silently
            // read 0 there. Size can only come from the Content-Length header on a
            // HEAD response; when it's absent the column stays null — never zero,
            // which would masquerade as a real measurement of an empty file. The
            // body-count fallback is only legitimate when the GET fallback actually
            // downloaded a body.
            let length = response.header("content-length").flatMap { Int($0) }
                ?? (usedGETFallback ? response.body?.count : nil)
            let redirectTarget = response.isRedirect
                ? response.location.flatMap { URLNormalizer.normalize($0, relativeTo: item.url) }
                : nil
            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth,
                status: response.status, errorKind: nil,
                contentType: response.contentType, contentLength: length,
                responseTimeMs: response.elapsedMs,
                redirectTarget: redirectTarget, bodyGz: nil, xRobotsTag: nil, facts: nil
            )
        }
    }

    private static func process(
        item: FrontierItem, config: CrawlConfig, robots: RobotsRules,
        client: HTTPClient, parser: PageParser, retainBodies: Bool
    ) async -> CrawlResult? {
        // `robots` is the ruleset fetched once for the SEED host (CrawlSession never
        // fetches robots.txt for other hosts — one HEAD per unique URL is the agreed
        // politeness bar for third parties). It must therefore only gate URLs on the
        // seed host; applying it to a cross-host URL would silently drop links whenever
        // the seed's own robots.txt happens to disallow a matching path.
        let isOurHost = Store.isInternal(item.url, seedHost: config.seedHost, config: config)
        if config.respectRobots, isOurHost, !robots.isAllowed(path: item.url.path, userAgent: config.userAgent) {
            return nil
        }

        if item.checkOnly {
            return await statusCheck(item: item, config: config, client: client)
        }

        let outcome = await client.fetch(url: item.url.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout,
                                         headers: config.requestHeaders)

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

            if !isHTML, let body = response.body, !body.isEmpty,
               PDFFacts.isPDF(contentType: response.contentType, body: body) {
                // A PDF is a page a search engine indexes, so it gets the same
                // title and word-count treatment rather than being recorded as
                // an untitled binary. Its links are not followed: extracting
                // them is a separate feature, and guessing would be worse than
                // not doing it.
                facts = PDFFacts.parse(body)
                if retainBodies { bodyGz = Gzip.compress(body) }
            } else if isHTML, let body = response.body, !body.isEmpty {
                // Not a bare UTF-8 decode: a Windows-1252 page decoded as UTF-8
                // yields a mangled title, which the Titles report would then
                // present as a real finding. See TextDecoding.
                let html = TextDecoding.decode(body, contentType: response.contentType)
                facts = try? parser.parse(html: html, extractions: config.extractions)
                if retainBodies { bodyGz = Gzip.compress(body) }
            }

            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth,
                status: response.status, errorKind: nil,
                contentType: response.contentType,
                contentLength: response.body?.count,
                responseTimeMs: response.elapsedMs,
                redirectTarget: redirectTarget, bodyGz: bodyGz,
                xRobotsTag: response.header("x-robots-tag"), headers: response.headers,
                facts: facts
            )
        }
    }
}
