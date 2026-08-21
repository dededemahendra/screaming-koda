import Foundation
import KodaCore
import Observation

/// Owns a crawl on behalf of the UI: starts it, controls it, and mirrors the
/// engine's actor-isolated state into main-actor observable properties so views
/// never await during a render pass.
@MainActor
@Observable
public final class CrawlController {
    /// How often a live crawl re-sorts for a column the user explicitly chose by
    /// clicking a header. They are watching that sort, so it gets refreshed
    /// often — but not on every 2 Hz tick, since a 500,000-row re-sort that
    /// often would spend the machine's time on ordering rather than crawling.
    static let sortRebuildInterval: TimeInterval = 2
    /// How often the default (discovery-order) sort gets a full rebuild
    /// alongside its cheap per-tick append.
    ///
    /// This exists to close a real gap: `RowIndex.appendNewIds()` only ever
    /// fetches ids above the largest one it already holds. A URL that was
    /// hidden by `Store.visibleURLsFilter` when first discovered — an
    /// image-only URL — and later becomes visible because a real link to it
    /// appears has an id *below* that watermark, so a pure append can never
    /// find it; it would be silently missing from the crawl for good. A
    /// periodic full rebuild recovers it.
    ///
    /// This can be less frequent than `sortRebuildInterval`: nobody picked
    /// this sort on purpose, the append already handles the overwhelming
    /// common case on every tick, and a late-revealed URL going unlisted for
    /// a few extra seconds during an active crawl is unnoticeable. 5s is
    /// short enough that it reads as "showed up a moment later" rather than
    /// "missing", while being well below the tick rate (10 ticks between
    /// rebuilds) so a large crawl still spends nearly all of its live-refresh
    /// time on the cheap append, not a full re-sort.
    static let liveFullRebuildInterval: TimeInterval = 5
    /// How often the sidebar's issue counts are recomputed during a crawl.
    ///
    /// Slower than everything else on purpose. Counts are one conditional-
    /// aggregation scan over every URL in the crawl, so at 500,000 rows doing it
    /// on every 2 Hz tick would spend the machine's time counting rather than
    /// crawling. The table is what the user is watching; a count two seconds
    /// stale is not a defect. Counts are refreshed unconditionally once the
    /// crawl stops, so the final numbers are never a stale sample.
    static let countsRefreshInterval: TimeInterval = 2

    public var seedURL: String = ""

    public private(set) var state: CrawlState = .idle
    public private(set) var progress: CrawlProgress?
    /// User-facing explanation for anything surprising — a refused start, a
    /// restricted crawl, or a failure. A window with no rows must never be
    /// silently ambiguous.
    public private(set) var notice: String?
    public private(set) var rows: RowStore?
    /// Bumped on every tick so the table knows to reload.
    public private(set) var revision = 0

    /// Which tab and filter the table is showing. Held as ids rather than as
    /// values so selection survives `Reports.all` being rebuilt.
    public private(set) var selectedReportID: String = Reports.internalURLs.id
    public private(set) var selectedFilterID: String = Reports.internalURLs.defaultFilter.id
    /// Row counts keyed "reportID.filterID", for the sidebar.
    public private(set) var counts: [String: Int] = [:]
    /// The row the inspector is describing, or nil when nothing is selected.
    public private(set) var selectedRowID: Int64?
    /// The inspector's four panes, loaded together when the selection changes.
    /// Loading on selection rather than on every tick keeps four extra queries
    /// off the crawl's refresh path.
    public private(set) var detail: URLDetail?
    public private(set) var inlinks: InspectorRows<LinkRow>?
    public private(set) var outlinks: InspectorRows<LinkRow>?
    public private(set) var images: InspectorRows<ImageRow>?

    public var selectedReport: Report {
        Reports.all.first { $0.id == selectedReportID } ?? Reports.internalURLs
    }

    public var selectedFilter: ReportFilter {
        let report = selectedReport
        return report.filters.first { $0.id == selectedFilterID } ?? report.defaultFilter
    }

    /// Set when Start found an existing crawl for this host and is waiting for
    /// the user to choose. The window presents a sheet; nothing happens until
    /// they answer.
    public private(set) var pendingExistingCrawl: ExistingCrawl?

    @ObservationIgnored private let client: HTTPClient
    @ObservationIgnored private let parser: PageParser
    @ObservationIgnored private let dbPath: String?
    /// Where crawl databases live. When nil the controller stays in-memory,
    /// which is what every existing test relies on.
    @ObservationIgnored private let crawlsDirectory: (@MainActor @Sendable () -> URL)?
    @ObservationIgnored private var engine: CrawlEngine?
    /// Kept so the sidebar counts and the inspector can query after the crawl
    /// task has finished with it. Internal rather than private so tests can
    /// change the database behind the controller's back and prove a refresh
    /// really did (or did not) re-run — a throttle test that cannot observe the
    /// underlying data can only ever assert that nothing changed.
    @ObservationIgnored private(set) var store: Store?
    /// Backs `rows`. `RowStore` only fetches by id now (Task 6) — this is what
    /// actually notices new rows a live crawl has added; `rows?.refresh()`
    /// alone no longer does, since it only drops the page cache.
    @ObservationIgnored private var rowIndex: RowIndex?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Last rebuild for an explicitly-chosen sort; throttled by `sortRebuildInterval`.
    @ObservationIgnored private var lastSortRebuild = Date.distantPast
    /// Last periodic full rebuild under the default sort; throttled by
    /// `liveFullRebuildInterval`.
    @ObservationIgnored private var lastFullRebuild = Date.distantPast
    /// Last sidebar count refresh; throttled by `countsRefreshInterval`.
    @ObservationIgnored private var lastCountsRefresh = Date.distantPast
    /// Tracks whether the robots-unreachable notice was already shown this run,
    /// independent of whatever else `notice` may also contain (such as a
    /// "database replaced" message set earlier in `start()`) — the emptiness
    /// explanation below must not be suppressed just because *some* notice
    /// happens to already be set for an unrelated reason.
    @ObservationIgnored private var robotsUnreachableNoticeShown = false

    /// - Parameters:
    ///   - dbPath: A fixed database path, or nil for an in-memory database.
    ///     This is the default and is what every existing test relies on —
    ///     it must keep meaning "in-memory" unqualified.
    ///   - crawlsDirectory: When set, `start()` derives a real on-disk path from
    ///     the seed's host and checks it for an existing crawl before doing
    ///     anything else. This is how the shipped app (composed in `KodaApp`)
    ///     makes crawls durable without changing what a bare `CrawlController()`
    ///     does for tests — the resolution has to happen here, at `start()`,
    ///     because the host isn't known until the user has typed a seed URL,
    ///     which is after construction.
    public init(
        client: HTTPClient = URLSessionHTTPClient(),
        parser: PageParser = SwiftSoupParser(),
        dbPath: String? = nil,
        crawlsDirectory: (@MainActor @Sendable () -> URL)? = nil
    ) {
        self.client = client
        self.parser = parser
        self.dbPath = dbPath
        self.crawlsDirectory = crawlsDirectory
    }

    public func start() async {
        guard !state.isActive, pendingExistingCrawl == nil else { return }
        notice = nil
        progress = nil

        guard let host = CrawlConfig(seedURL: seedURL).seedHost else {
            notice = "Cannot start: \(seedURL) is not a crawlable http(s) URL."
            state = .idle
            return
        }

        guard let crawlsDirectory else {
            // No directory provider: fall back to the fixed dbPath (nil means
            // in-memory), exactly as every controller test that doesn't inject
            // a directory relies on — this includes tests that pass a concrete
            // on-disk `dbPath`, not just the in-memory ones.
            await beginCrawl(dbPath: dbPath)
            return
        }
        let directory = crawlsDirectory()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            notice = "Cannot start: \(error)"
            state = .idle
            return
        }
        if let existing = CrawlDatabaseLocation.existing(forHost: host, in: directory) {
            pendingExistingCrawl = existing
            return
        }
        await beginCrawl(dbPath: CrawlDatabaseLocation.path(forHost: host, in: directory).path)
    }

    /// Continue the existing crawl. An interrupted one picks up its frontier; a
    /// finished one has an empty frontier, so this simply opens and displays it.
    public func resumePending() async {
        guard let pending = pendingExistingCrawl else { return }
        pendingExistingCrawl = nil
        await beginCrawl(dbPath: pending.path.path)
    }

    /// Discard the existing crawl and start fresh.
    public func replacePending() async {
        guard let pending = pendingExistingCrawl else { return }
        pendingExistingCrawl = nil
        do {
            try CrawlDatabaseLocation.replace(at: pending.path)
        } catch {
            notice = "Could not replace the existing crawl: \(error)"
            state = .idle
            return
        }
        await beginCrawl(dbPath: pending.path.path)
    }

    public func cancelPending() {
        pendingExistingCrawl = nil
        state = .idle
    }

    /// Prepares the session, creates the index and row store, launches the run
    /// task, and starts the tick. Shared by all three routes into a crawl:
    /// a fresh start, Resume, and Replace.
    private func beginCrawl(dbPath: String?) async {
        robotsUnreachableNoticeShown = false

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
            notice = appendNotice(notice, "robots.txt could not be fetched (\(reason)), so this crawl is "
                + "restricted to nothing. Re-run against a site you own with robots checking disabled if "
                + "that is not what you want.")
            robotsUnreachableNoticeShown = true
        }

        engine = prepared.engine
        store = prepared.store
        selectRow(id: nil)
        let freshIndex = RowIndex(store: prepared.store, report: selectedReport)
        freshIndex.rebuild(report: selectedReport, filter: selectedFilter,
                           sortColumnID: nil, ascending: true)
        rowIndex = freshIndex
        rows = RowStore(store: prepared.store, index: freshIndex)
        refreshCounts(force: true)
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
                // A full rebuild, not just an append: ticking stops right after
                // this, so this is the last chance to pick up anything that
                // appendNewIds() alone would miss — a URL that became visible
                // late (see refreshRowIndexForLiveCrawl), or, under a non-default
                // sort, any row added since the last throttled rebuild.
                // Performance no longer matters once the crawl has stopped, so
                // there is no reason to take the cheap-but-incomplete path here.
                self.rowIndex?.rebuild()
                self.rows?.refresh()
                self.refreshCounts(force: true)
                self.revision &+= 1
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

    /// Rebuilds the index under a newly chosen sort and reloads. Called from a
    /// column header click; the coordinator resolves which column and
    /// direction, this is where it's actually applied. An id the current report
    /// does not declare is ignored by `RowIndex`, so it cannot reach the SQL.
    public func applySort(columnID: String, ascending: Bool) {
        guard let index = rowIndex else { return }
        index.rebuild(report: index.report, filter: index.filter,
                      sortColumnID: columnID, ascending: ascending)
        lastSortRebuild = Date()
        rows?.refresh()
        revision &+= 1
    }

    /// Switches tab or filter. Clears the selection, because row 4 of Titles is
    /// not row 4 of Images and carrying the index over would silently point the
    /// inspector at an unrelated URL. An unknown id is ignored rather than
    /// crashing — the sidebar is the only caller, but it is a public entry point.
    public func select(reportID: String, filterID: String? = nil) {
        guard let report = Reports.all.first(where: { $0.id == reportID }) else { return }
        let filter = filterID.flatMap { id in report.filters.first { $0.id == id } }
            ?? report.defaultFilter
        selectedReportID = report.id
        selectedFilterID = filter.id
        selectRow(id: nil)
        rowIndex?.rebuild(report: report, filter: filter, sortColumnID: nil, ascending: true)
        lastSortRebuild = Date()
        rows?.refresh()
        revision &+= 1
    }

    /// Loads the inspector for a row. A failed read empties the panes rather
    /// than leaving the previous URL's inlinks on screen under a new heading,
    /// which would be actively misleading.
    public func selectRow(id: Int64?) {
        selectedRowID = id
        guard let store, let id else {
            detail = nil
            inlinks = nil
            outlinks = nil
            images = nil
            return
        }
        detail = try? store.detail(id: id)
        inlinks = try? store.inlinks(id: id)
        outlinks = try? store.outlinks(id: id)
        images = try? store.imageRows(id: id)
    }

    /// Recomputes the sidebar counts, at most once per `countsRefreshInterval`
    /// unless forced. Internal so tests can drive it with an injected clock
    /// rather than waiting on the real tick.
    func refreshCounts(force: Bool = false, now: Date = Date()) {
        guard let store else { return }
        if !force, now.timeIntervalSince(lastCountsRefresh) < Self.countsRefreshInterval { return }
        lastCountsRefresh = now
        // A failed read keeps the previous counts rather than blanking the
        // sidebar: the same rule the row index follows.
        if let fresh = try? store.counts(for: Reports.all) { counts = fresh }
    }

    /// A crawl that fetched nothing because robots.txt disallowed it looks
    /// identical to a broken tool. Say which it was — unless the
    /// robots-unreachable notice already explained the emptiness, which would
    /// make this one redundant.
    private func explainEmptyCrawlIfNeeded(store: Store) {
        guard !robotsUnreachableNoticeShown else { return }
        guard let summary = try? store.summary() else { return }
        let fetched = summary.byStatusClass.values.reduce(0, +) + summary.transportErrors
        if fetched == 0 {
            notice = appendNotice(notice, "Nothing was crawled: robots.txt disallows this crawler. "
                + "Nothing is wrong with the app — the site is asking not to be crawled.")
        }
    }

    /// Joins a new notice onto whatever is already there, rather than
    /// overwriting it — `start()` can have a legitimate reason to show more
    /// than one thing (e.g. "the old database was replaced" and "robots.txt
    /// disallows everything" are both true and both worth telling the user).
    private func appendNotice(_ existing: String?, _ addition: String) -> String {
        guard let existing, !existing.isEmpty else { return addition }
        return existing + "\n\n" + addition
    }

    /// One tick's worth of live-crawl index bookkeeping, plus the reload it
    /// implies. Internal (not private) so tests can drive it directly with an
    /// injected `now`, without waiting on the real 500ms tick or the rebuild
    /// throttles below it.
    ///
    /// Discovery order only ever appends on every tick — cheap, and correct
    /// for the overwhelming majority of new rows, which really do belong at
    /// the end. But `RowIndex.appendNewIds()`'s watermark is the last id it
    /// has actually appended, not "the largest id that exists": a URL hidden
    /// by `Store.visibleURLsFilter` when first discovered (an image-only URL)
    /// that later becomes visible — a real link to it appears — can have an
    /// id below that watermark forever, and a pure append will never find it
    /// again. So alongside the append, this also does a full rebuild every
    /// `liveFullRebuildInterval`, which is not id-relative and therefore
    /// always catches such a URL. Any other (explicitly user-chosen) sort
    /// always rebuilds, throttled to the shorter `sortRebuildInterval`
    /// instead, since the user is actively watching that one.
    func refreshRowIndexForLiveCrawl(now: Date = Date()) {
        if let index = rowIndex {
            if index.isAppendable {
                index.appendNewIds()
                if now.timeIntervalSince(lastFullRebuild) >= Self.liveFullRebuildInterval {
                    index.rebuild()
                    lastFullRebuild = now
                }
            } else if now.timeIntervalSince(lastSortRebuild) >= Self.sortRebuildInterval {
                index.rebuild()
                lastSortRebuild = now
            }
        }
        rows?.refresh()
        refreshCounts(now: now)
        revision &+= 1
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, self.state.isActive else { return }
                self.refreshRowIndexForLiveCrawl()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
