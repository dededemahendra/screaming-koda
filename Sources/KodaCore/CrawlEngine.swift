import Foundation

/// Which of a crawl's two phases is running.
///
/// They are separate because a slow third-party host must never starve the
/// crawl of the site the user asked about, and separate phases are visible to
/// the user: during the second one the frontier is empty, and a UI that only
/// knows about the first shows a stalled crawl with nothing queued.
public enum CrawlStage: String, Sendable, Hashable {
    case crawling
    /// Giving external links and images a status, after the frontier drains.
    case checking
}

public struct CrawlProgress: Sendable {
    public let crawled: Int
    public let queued: Int
    public let discovered: Int
    /// External links and images given a status in the second phase.
    public let checked: Int
    public let stage: CrawlStage

    public init(crawled: Int, queued: Int, discovered: Int, checked: Int = 0,
                stage: CrawlStage = .crawling) {
        self.crawled = crawled
        self.queued = queued
        self.discovered = discovered
        self.checked = checked
        self.stage = stage
    }
}

public actor CrawlEngine {
    private let store: Store
    private let client: any HTTPClient
    private let parser: any PageParser
    private let config: CrawlConfig
    private let robots: RobotsRules

    /// Target transaction size for the writer. Per-row inserts would make SQLite
    /// the bottleneck long before the network is.
    static let writeBatchSize = 100

    private var crawled = 0
    private var discovered = 0
    private var checked = 0
    private var stopRequested = false

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

    /// Asks the crawl to stop after the chunk in flight.
    ///
    /// There is no separate paused state. The frontier lives in SQLite, so
    /// stopping and starting again *is* a resume: URLs left claimed are reset to
    /// queued by the next run. A real pause would add a way for the engine and
    /// the database to disagree about what had been done.
    /// A stopped engine stays stopped. Resuming means running a new engine over
    /// the same store, which is exactly what reopening a database already does.
    public func requestStop() {
        stopRequested = true
    }

    public var isStopRequested: Bool { stopRequested }

    /// Drains the frontier until nothing is queued. Never throws on a bad page.
    ///
    /// Returns whether the crawl finished. `false` means it stopped early and the
    /// frontier still holds work.
    @discardableResult
    public func run(onProgress: (@Sendable (CrawlProgress) -> Void)?) async throws -> Bool {
        try store.resetInFlight()

        // A crawl-delay is a floor on the interval between *requests*, not between
        // batches. Claiming `workers` URLs at a time and sleeping once per batch
        // would issue `workers` concurrent requests per delay period — `workers`
        // times faster than the site asked for. Serialising the batch is the only
        // honest reading of the directive.
        let crawlDelay = config.respectRobots ? robots.crawlDelay(userAgent: config.userAgent) : nil
        let isDelayed = (crawlDelay ?? 0) > 0
        let concurrency = isDelayed ? 1 : max(config.workers, 1)
        // One claim covers many workers' worth of URLs so results accumulate into
        // a transaction of roughly `writeBatchSize` rows rather than one per
        // worker-sized round. A delayed crawl claims one at a time: the sleep
        // between chunks is what paces the requests.
        let chunkSize = isDelayed ? 1 : max(Self.writeBatchSize, concurrency)

        while true {
            if stopRequested { return try stoppedEarly() }
            let chunk = try store.claimNext(limit: chunkSize)
            if chunk.isEmpty { break }

            // Body retention is a size decision, not a preference: storing the HTML
            // of half a million pages turns a database that fits on a laptop into
            // one that does not. Re-checked per chunk so a crawl that grows past
            // the limit stops retaining rather than having to be restarted.
            let retainBodies = try config.retainBodies && store.urlTotal() < config.retainBodyURLLimit

            var results: [CrawlResult] = []
            results.reserveCapacity(chunk.count)

            // A sliding window, not a barrier: as each request finishes the next
            // starts immediately. Waiting for a whole round to complete would let
            // one URL that sits until the 20s timeout stall every other worker.
            //
            // A stop stops feeding the window rather than waiting for the chunk,
            // so the longest a user waits is one request, not a hundred.
            var started: Set<Int64> = []
            await withTaskGroup(of: CrawlResult?.self) { group in
                var next = 0
                while next < min(concurrency, chunk.count) {
                    let item = chunk[next]
                    next += 1
                    started.insert(item.id)
                    group.addTask { [config, robots, client, parser] in
                        await Self.process(item: item, config: config, robots: robots,
                                           client: client, parser: parser, retainBodies: retainBodies)
                    }
                }
                while let result = await group.next() {
                    if let result { results.append(result) }
                    guard next < chunk.count, !stopRequested else { continue }
                    let item = chunk[next]
                    next += 1
                    started.insert(item.id)
                    group.addTask { [config, robots, client, parser] in
                        await Self.process(item: item, config: config, robots: robots,
                                           client: client, parser: parser, retainBodies: retainBodies)
                    }
                }
            }

            // Only URLs that were actually attempted and produced nothing were
            // skipped by robots. Anything a stop left unstarted stays claimed, for
            // resetInFlight to hand back to the frontier — marking it skipped would
            // quietly retire a URL that has never been fetched.
            let produced = Set(results.map(\.urlID))
            for item in chunk where started.contains(item.id) && !produced.contains(item.id) {
                try store.markSkipped(item.id)
            }

            if !results.isEmpty {
                discovered += try store.write(results: results, config: config, now: Date())
                crawled += results.count
            }

            try reportProgress(onProgress, stage: .crawling)

            if let crawlDelay, isDelayed {
                try? await Task.sleep(nanoseconds: UInt64(crawlDelay * 1_000_000_000))
            }
        }

        if stopRequested { return try stoppedEarly() }
        try await checkRecordedURLs(onProgress: onProgress)
        if stopRequested { return try stoppedEarly() }

        try store.markFinished(at: Date())
        return true
    }

    /// Hands anything still claimed back to the frontier and reports not-finished.
    /// The crawl is not marked finished, so reopening the database shows it as
    /// incomplete rather than silently looking done.
    private func stoppedEarly() throws -> Bool {
        try store.resetInFlight()
        return false
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
        // Announced before the first request, not after the first batch: this
        // phase can spend twenty seconds on one dead host, and a UI that only
        // hears about it afterwards shows a stalled crawl for the whole of it.
        try reportProgress(onProgress, stage: .checking)

        let limiter = HostLimiter(limit: config.maxPerHost)
        let concurrency = max(config.workers, 1)
        // One claim covers many workers, so results accumulate into a transaction
        // of roughly `writeBatchSize` rows rather than one per worker-sized round.
        let chunkSize = max(Self.writeBatchSize, concurrency)

        while true {
            // Checked before claiming, so a stop never leaves a batch claimed for
            // `resetInFlight` to recover.
            if stopRequested { return }
            let batch = try store.claimForStatusCheck(
                limit: chunkSize, maxRedirects: config.maxRedirects,
                external: config.checkExternalLinks, images: config.checkImages
            )
            if batch.isEmpty { break }

            var results: [CrawlResult] = []
            results.reserveCapacity(batch.count)
            // The same sliding window the crawl loop uses, and it matters more
            // here: these are third-party hosts, which is exactly where one URL
            // sitting until the timeout is likely.
            await withTaskGroup(of: CrawlResult?.self) { group in
                var next = 0
                while next < min(concurrency, batch.count) {
                    let item = batch[next]
                    next += 1
                    group.addTask { [config, client] in
                        await Self.statusCheck(item: item, config: config, client: client, limiter: limiter)
                    }
                }
                while let result = await group.next() {
                    if let result { results.append(result) }
                    guard next < batch.count else { continue }
                    let item = batch[next]
                    next += 1
                    group.addTask { [config, client] in
                        await Self.statusCheck(item: item, config: config, client: client, limiter: limiter)
                    }
                }
            }

            // Anything that produced nothing goes back to skipped, which is the
            // state it was claimed from.
            let produced = Set(results.map(\.urlID))
            for item in batch where !produced.contains(item.id) {
                try store.markSkipped(item.id)
            }
            if !results.isEmpty {
                checked += results.count
                _ = try store.write(results: results, config: config, now: Date())
            }
            try reportProgress(onProgress, stage: .checking)
        }
    }

    private func reportProgress(_ onProgress: (@Sendable (CrawlProgress) -> Void)?,
                                stage: CrawlStage) throws {
        guard let onProgress else { return }
        let counts = try store.urlCounts()
        onProgress(CrawlProgress(crawled: crawled, queued: counts.queued,
                                 discovered: discovered, checked: checked, stage: stage))
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
                // The header first: a PDF's body is never read, and a page over
                // the size cap was only read as far as the cap.
                contentLength: response.declaredContentLength ?? response.body?.count,
                responseTimeMs: response.elapsedMs,
                redirectTarget: redirectTarget, bodyGz: bodyGz,
                xRobotsTag: response.header("x-robots-tag"), facts: facts
            )
        }
    }
}
