import Foundation
import KodaCore
import Observation

/// Drives one crawl and exposes its progress.
///
/// There is no paused state, because the frontier is in SQLite: stopping and
/// starting again over the same database is a resume. Modelling pause separately
/// would create a state the database cannot represent.
@MainActor
@Observable
public final class CrawlController {
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing
        case crawling
        case stopping
        /// Drained the frontier and finished cleanly.
        case finished
        /// Stopped early. The frontier still holds work, so starting again resumes.
        case stopped
        case failed(String)

        public var isRunning: Bool {
            self == .preparing || self == .crawling || self == .stopping
        }

        public var canStart: Bool { !isRunning }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var progress: CrawlProgress?
    public private(set) var store: Store?
    public private(set) var databasePath: String?
    public private(set) var startedAt: Date?
    public private(set) var elapsed: TimeInterval = 0

    private var engine: CrawlEngine?
    private var task: Task<Void, Never>?
    private let clientFactory: @Sendable () -> any HTTPClient

    /// The client is injected so tests can drive a controller without a network.
    public init(clientFactory: @escaping @Sendable () -> any HTTPClient = { URLSessionHTTPClient() }) {
        self.clientFactory = clientFactory
    }

    public func start(config: CrawlConfig, dbPath: String?) {
        guard phase.canStart else { return }
        phase = .preparing
        progress = nil
        startedAt = Date()
        databasePath = dbPath
        let client = clientFactory()

        task = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await CrawlSession.prepare(
                    dbPath: dbPath, config: config, client: client, parser: SwiftSoupParser()
                )
                self.store = prepared.store
                self.engine = prepared.engine
                // A stop pressed while robots.txt was still in flight must still count.
                if self.phase == .stopping {
                    await prepared.engine.requestStop()
                } else {
                    self.phase = .crawling
                }

                let finished = try await prepared.engine.run(onProgress: { update in
                    Task { @MainActor [weak self] in self?.record(update) }
                })
                self.finish(completed: finished)
            } catch {
                self.phase = .failed(String(describing: error))
            }
        }
    }

    /// Asks the crawl to stop after the requests already in flight.
    public func stop() {
        guard phase.isRunning else { return }
        phase = .stopping
        let engine = engine
        Task { await engine?.requestStop() }
    }

    /// Continues a stopped crawl. Identical to starting one, because resuming is
    /// what running against an existing database already does.
    public func resume(config: CrawlConfig) {
        guard phase.canStart, let databasePath else { return }
        start(config: config, dbPath: databasePath)
    }

    /// Opens a finished crawl for browsing, with no crawling at all.
    public func open(path: String) throws {
        guard phase.canStart else { return }
        let store = try Store(path: path)
        try store.migrate()
        self.store = store
        self.databasePath = path
        self.phase = .finished
        self.progress = nil
    }

    private func record(_ update: CrawlProgress) {
        progress = update
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
    }

    private func finish(completed: Bool) {
        if let startedAt { elapsed = Date().timeIntervalSince(startedAt) }
        phase = completed ? .finished : .stopped
        engine = nil
        task = nil
    }

    /// URLs per second so far, for the toolbar.
    public var urlsPerSecond: Double {
        guard let progress, elapsed > 0 else { return 0 }
        return Double(progress.crawled + progress.checked) / elapsed
    }
}
