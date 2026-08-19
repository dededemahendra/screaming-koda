import Foundation
import KodaCore
import Observation

/// Owns a crawl on behalf of the UI: starts it, controls it, and mirrors the
/// engine's actor-isolated state into main-actor observable properties so views
/// never await during a render pass.
@MainActor
@Observable
public final class CrawlController {
    public var seedURL: String = ""

    public private(set) var state: CrawlState = .idle
    public private(set) var progress: CrawlProgress?
    /// User-facing explanation for anything surprising — a refused start, a
    /// restricted crawl, or a failure. A window with no rows must never be
    /// silently ambiguous.
    public private(set) var notice: String?
    public private(set) var rows: RowStore?

    @ObservationIgnored private let client: HTTPClient
    @ObservationIgnored private let parser: PageParser
    @ObservationIgnored private let dbPath: String?
    @ObservationIgnored private var engine: CrawlEngine?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    public init(
        client: HTTPClient = URLSessionHTTPClient(),
        parser: PageParser = SwiftSoupParser(),
        dbPath: String? = nil
    ) {
        self.client = client
        self.parser = parser
        self.dbPath = dbPath
    }

    public func start() async {
        guard !state.isActive else { return }
        notice = nil
        progress = nil

        var config = CrawlConfig(seedURL: seedURL)
        config.workers = 5

        let prepared: (engine: CrawlEngine, store: Store, robotsOutcome: RobotsFetchOutcome)
        do {
            prepared = try await CrawlSession.prepare(
                dbPath: dbPath, config: config, client: client, parser: parser
            )
        } catch {
            notice = "Cannot start: \(error)"
            state = .idle
            return
        }

        if case .unreachable(let reason) = prepared.robotsOutcome {
            notice = "robots.txt could not be fetched (\(reason)), so this crawl is restricted to nothing. "
                + "Re-run against a site you own with robots checking disabled if that is not what you want."
        }

        engine = prepared.engine
        rows = RowStore(store: prepared.store)
        state = .running

        let engine = prepared.engine
        let store = prepared.store
        runTask = Task { [weak self] in
            // Unwrapping once up front, into a plain (non-weak) local `let`, gives every
            // nested closure below a stable, immutable reference to capture. Re-capturing
            // the *weak* `self` from this closure's own capture list inside a further
            // nested `Task` is rejected under Swift 6 strict concurrency ("reference to
            // captured var 'self' in concurrently-executing code") because a weak capture
            // is mutable by nature (ARC can nil it out at any time); a `let` isn't.
            guard let self else { return }
            do {
                try await engine.run(onProgress: { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                })
            } catch {
                await MainActor.run { self.notice = "Crawl failed: \(error)" }
            }
            let finalState = await engine.state
            await MainActor.run {
                self.state = finalState
                self.rows?.refresh()
                self.explainEmptyCrawlIfNeeded(store: store)
                self.stopTicking()
            }
        }
        startTicking()
    }

    public func pause() async {
        guard state == .running, let engine else { return }
        await engine.pause()
        state = await engine.state
    }

    public func resume() async {
        guard state == .paused, let engine else { return }
        await engine.resume()
        state = await engine.state
    }

    public func stop() async {
        guard state.isActive, let engine else { return }
        await engine.cancel()
    }

    /// A crawl that fetched nothing because robots.txt disallowed it looks
    /// identical to a broken tool. Say which it was.
    private func explainEmptyCrawlIfNeeded(store: Store) {
        guard notice == nil else { return }
        guard let summary = try? store.summary() else { return }
        let fetched = summary.byStatusClass.values.reduce(0, +) + summary.transportErrors
        if fetched == 0 {
            notice = "Nothing was crawled: robots.txt disallows this crawler. "
                + "Nothing is wrong with the app — the site is asking not to be crawled."
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.state.isActive else { return }
                self.rows?.refresh()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
