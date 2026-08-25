import Foundation
import KodaCore
import Testing
@testable import KodaUI

private let internalAll = ReportCatalogue.report(id: "internal-all")!
private let duplicateTitles = ReportCatalogue.report(id: "titles-duplicate")!

// MARK: - ReportTableModel

@MainActor
@Test func tableModelStartsUnsortedWithEveryRow() async throws {
    let model = ReportTableModel(store: try await fixtureStore(), definition: internalAll)
    #expect(model.rowCount == FixtureSite.pageCount + 2)
    #expect(model.sortColumn == nil)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func clickingAHeaderSortsThenReverses() async throws {
    let model = ReportTableModel(store: try await fixtureStore(), definition: internalAll)
    model.toggleSort(column: 0)
    #expect(model.sortColumn == 0)
    #expect(model.direction == .ascending)
    let firstAscending = model.row(at: 0)?[0]

    model.toggleSort(column: 0)
    #expect(model.direction == .descending)
    #expect(model.row(at: 0)?[0] != firstAscending)

    model.toggleSort(column: 1)
    #expect(model.sortColumn == 1)
    #expect(model.direction == .ascending, "a different column starts ascending again")
}

@MainActor
@Test func anInvalidSortColumnIsRefused() async throws {
    let model = ReportTableModel(store: try await fixtureStore(), definition: internalAll)
    model.toggleSort(column: 99)
    #expect(model.sortColumn == nil)
}

@MainActor
@Test func filteringNarrowsTheRowCount() async throws {
    let model = ReportTableModel(store: try await fixtureStore(), definition: internalAll)
    let all = model.rowCount
    model.setFilter("Shared")
    #expect(model.rowCount < all)
    #expect(model.rowCount > 0)
    model.setFilter("")
    #expect(model.rowCount == all)
}

@MainActor
@Test func switchingReportDropsAStaleSort() async throws {
    let model = ReportTableModel(store: try await fixtureStore(), definition: internalAll)
    model.toggleSort(column: 6)
    #expect(model.sortColumn == 6)

    // internal-all has seven columns, titles-duplicate has three. Carrying the
    // index over would sort by a column that does not exist.
    model.show(duplicateTitles)
    #expect(model.definition.id == duplicateTitles.id)
    #expect(model.sortColumn == nil)
    #expect(model.errorMessage == nil)
    #expect(model.rowCount > 0)
}

@MainActor
@Test func urlAtRowIsNilForAggregateReports() async throws {
    let store = try await fixtureStore()
    let model = ReportTableModel(store: store, definition: internalAll)
    #expect(model.url(at: 0)?.hasPrefix("https://fx.test") == true)

    model.show(ReportCatalogue.report(id: "depth-distribution")!)
    #expect(model.url(at: 0) == nil, "a depth histogram row is not a URL")
}

// MARK: - CrawlController

@MainActor
@Test func controllerRunsACrawlToCompletion() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    #expect(controller.phase == .idle)
    #expect(controller.phase.canStart)

    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }

    #expect(controller.phase == .finished)
    #expect(controller.store != nil)
    #expect((controller.progress?.crawled ?? 0) > 0)
    #expect(controller.urlsPerSecond >= 0)
}

@MainActor
@Test func controllerReportsAnInvalidSeed() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    controller.start(config: CrawlConfig(seedURL: "not a url"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }

    guard case .failed(let message) = controller.phase else {
        Issue.record("expected failure, got \(controller.phase)")
        return
    }
    #expect(message.contains("not a url"))
}

@MainActor
@Test func startIsIgnoredWhileACrawlIsRunning() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    #expect(controller.phase.isRunning)

    // A second Start must not begin a competing crawl over the same database.
    controller.start(config: CrawlConfig(seedURL: "https://other.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }
    #expect(controller.phase == .finished)
    let seed = try controller.store?.loadConfig()?.seedURL
    #expect(seed == "https://fx.test/")
}

@MainActor
@Test func stopBeforeTheCrawlBeginsStillStops() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    controller.stop()
    #expect(controller.phase == .stopping)

    try await waitUntil { !controller.phase.isRunning }
    #expect(controller.phase == .stopped, "a stop during preparation is not lost")
}

@MainActor
@Test func openingADatabaseDoesNotCrawl() async throws {
    let path = NSTemporaryDirectory() + "koda-ui-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }
    var config = CrawlConfig(seedURL: "https://fx.test/")
    config.workers = 4
    _ = try await CrawlSession.start(dbPath: path, config: config, client: FixtureSite(),
                                     parser: SwiftSoupParser(), onProgress: nil)

    let controller = CrawlController(clientFactory: { FixtureSite() })
    try controller.open(path: path)
    #expect(controller.phase == .finished)
    #expect(controller.progress == nil, "opening is not crawling")
    #expect(try controller.store?.urlCounts().done ?? 0 > 0)
}

// MARK: - AppModel

@MainActor
@Test func appModelBuildsTheSidebarFromCounts() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    let model = AppModel(controller: controller)
    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }
    await model.refresh()

    #expect(model.summary != nil)
    #expect(!model.visibleGroups.isEmpty)
    let shown = model.visibleGroups.flatMap(\.reports).map(\.id)
    #expect(shown.contains("titles-duplicate"))
    #expect(!shown.contains("response-5xx"), "empty reports stay hidden by default")

    model.showsEmptyReports = true
    #expect(model.visibleGroups.flatMap(\.reports).map(\.id).contains("response-5xx"))
}

@MainActor
@Test func selectingARowLoadsItsDetailAndLinks() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    let model = AppModel(controller: controller)
    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }
    await model.refresh()
    model.select(reportID: "internal-all")
    model.table?.toggleSort(column: 0)

    // Row 0 sorted by URL is the seed, which links to everything.
    model.selectRow(at: 0)
    #expect(model.selectedDetail?.url == "https://fx.test/")
    #expect(model.outlinks.count >= FixtureSite.pageCount)
    #expect(model.selectedImages.count == 1)

    model.clearSelection()
    #expect(model.selectedDetail == nil)
    #expect(model.outlinks.isEmpty)
}

@MainActor
@Test func selectingAnAggregateRowClearsTheInspector() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    let model = AppModel(controller: controller)
    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }
    await model.refresh()
    model.select(reportID: "depth-distribution")
    model.selectRow(at: 0)
    #expect(model.selectedDetail == nil, "a histogram row has no URL to inspect")
}

@MainActor
@Test func refreshBeforeAnyCrawlIsHarmless() async {
    let model = AppModel(controller: CrawlController(clientFactory: { FixtureSite() }))
    await model.refresh()
    #expect(model.table == nil)
    #expect(model.summary == nil)
    #expect(model.errorMessage == nil)
}

/// Polls until `condition` holds. The controller drives work from a detached
/// task, so tests wait on observable state rather than on a fixed sleep.
@MainActor
private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw CancellationError() }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

@MainActor
@Test func refreshPublishesLiveFrontierCounts() async throws {
    // The toolbar reads these rather than the engine's per-chunk callback, which
    // on a site of slow pages would leave a working crawl looking stalled.
    let controller = CrawlController(clientFactory: { FixtureSite() })
    let model = AppModel(controller: controller)
    #expect(model.liveCounts == nil)

    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }
    await model.refresh()

    let counts = try #require(model.liveCounts)
    #expect(counts.done > FixtureSite.pageCount)
    #expect(counts.queued == 0)
    #expect(counts.inFlight == 0)

    model.reset()
    #expect(model.liveCounts == nil)
}

// MARK: - Starting, resuming, and reopening

/// A scratch defaults suite, so a test never reads or writes the real one.
@MainActor
private func scratchModel(client: @escaping @Sendable () -> any HTTPClient = { FixtureSite() })
    -> (model: AppModel, cleanup: () -> Void) {
    let name = "koda.model.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    let model = AppModel(controller: CrawlController(clientFactory: client), defaults: suite)
    return (model, { suite.removePersistentDomain(forName: name) })
}

@MainActor
@Test func startingACrawlUsesTheConfiguredSettings() async throws {
    let (model, cleanup) = scratchModel()
    defer { cleanup() }
    let path = NSTemporaryDirectory() + "koda-start-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }

    model.seedURL = "https://fx.test/"
    model.settings.workers = 3
    model.settings.checkExternalLinks = false
    model.settings.excludeText = "/p1[0-9]"

    #expect(model.startCrawl(databasePath: path))
    try await waitUntil { !model.controller.phase.isRunning }

    let stored = try #require(try model.store?.loadConfig())
    #expect(stored.workers == 3)
    #expect(stored.checkExternalLinks == false)
    #expect(stored.exclude == ["/p1[0-9]"])
}

@MainActor
@Test func invalidSettingsReportAProblemInsteadOfStarting() {
    let (model, cleanup) = scratchModel()
    defer { cleanup() }
    model.seedURL = "https://fx.test/"
    model.settings.includeText = "[unclosed"

    #expect(model.startCrawl(databasePath: nil) == false)
    #expect(model.controller.phase == .idle)
    #expect(model.errorMessage?.contains("[unclosed") == true)

    model.clearError()
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func startingAlsoPersistsTheSettingsForNextTime() async throws {
    let name = "koda.model.\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: name)!
    defer { suite.removePersistentDomain(forName: name) }
    let path = NSTemporaryDirectory() + "koda-persist-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let model = AppModel(controller: CrawlController(clientFactory: { FixtureSite() }), defaults: suite)
    model.seedURL = "https://fx.test/"
    model.settings.crawlSubdomains = true
    #expect(model.startCrawl(databasePath: path))
    try await waitUntil { !model.controller.phase.isRunning }

    let relaunched = AppModel(controller: CrawlController(clientFactory: { FixtureSite() }), defaults: suite)
    #expect(relaunched.settings.crawlSubdomains == true)
}

@MainActor
@Test func openingADatabaseAdoptsTheSettingsItWasCrawledWith() async throws {
    let path = NSTemporaryDirectory() + "koda-open-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }
    var config = CrawlConfig(seedURL: "https://fx.test/")
    config.maxDepth = 2
    config.exclude = ["/p2"]
    config.respectRobots = false
    _ = try await CrawlSession.start(dbPath: path, config: config, client: FixtureSite(),
                                     parser: SwiftSoupParser(), onProgress: nil)

    let (model, cleanup) = scratchModel()
    defer { cleanup() }
    try await model.openDatabase(path: path)

    #expect(model.seedURL == "https://fx.test/")
    #expect(model.settings.maxDepthText == "2")
    #expect(model.settings.excludeText == "/p2")
    #expect(model.settings.respectRobots == false)
    #expect(model.summary != nil, "opening also loads the reports")
}

@MainActor
@Test func resumeReplaysTheConfigTheCrawlStartedWith() async throws {
    let (model, cleanup) = scratchModel(client: { SlowFixtureSite() })
    defer { cleanup() }
    let path = NSTemporaryDirectory() + "koda-resume-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }

    model.seedURL = "https://fx.test/"
    model.settings.excludeText = "/p2[0-9]"
    #expect(model.startCrawl(databasePath: path))
    try await waitUntil { model.controller.phase == .crawling }
    model.controller.stop()
    try await waitUntil { !model.controller.phase.isRunning }
    #expect(model.canResume)

    // The form now says something else. The frontier was already filtered by the
    // original rules, so finishing it under new ones would leave a database that
    // does not match its own crawl_meta.
    model.settings.excludeText = ""
    #expect(model.startCrawl())
    try await waitUntil { !model.controller.phase.isRunning }

    let stored = try #require(try model.store?.loadConfig())
    #expect(stored.exclude == ["/p2[0-9]"])
    let crawled = try #require(try model.store?.urlCounts().done)
    #expect(crawled > 0)
}

@MainActor
@Test func changingTheURLMeansANewCrawlRatherThanAResume() async throws {
    let (model, cleanup) = scratchModel(client: { SlowFixtureSite() })
    defer { cleanup() }
    let path = NSTemporaryDirectory() + "koda-newseed-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }

    model.seedURL = "https://fx.test/"
    #expect(model.startCrawl(databasePath: path))
    try await waitUntil { model.controller.phase == .crawling }
    model.controller.stop()
    try await waitUntil { !model.controller.phase.isRunning }

    #expect(model.canResume)
    model.seedURL = "https://other.test/"
    #expect(!model.canResume, "resuming into another site's frontier is never what was meant")
}

/// The fixture site with enough delay per page that a stop lands mid-crawl.
private struct SlowFixtureSite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if !url.hasSuffix("robots.txt") && url != "https://fx.test/" {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await FixtureSite().fetch(url: url, method: method, userAgent: userAgent, timeout: timeout)
    }
}

@MainActor
@Test func openingAnInterruptedCrawlOffersResumeRatherThanClaimingItFinished() async throws {
    let (model, cleanup) = scratchModel(client: { SlowFixtureSite() })
    defer { cleanup() }
    let path = NSTemporaryDirectory() + "koda-reopen-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }

    model.seedURL = "https://fx.test/"
    #expect(model.startCrawl(databasePath: path))
    try await waitUntil { model.controller.phase == .crawling }
    model.controller.stop()
    try await waitUntil { !model.controller.phase.isRunning }

    // A fresh app, opening the file someone quit halfway through.
    let (reopened, cleanupReopened) = scratchModel(client: { SlowFixtureSite() })
    defer { cleanupReopened() }
    try await reopened.openDatabase(path: path)

    #expect(reopened.controller.phase == .stopped, "an unfinished crawl is not a finished one")
    #expect(reopened.canResume)
    #expect(reopened.meta?.isFinished == false)
}

@MainActor
@Test func openingACompletedCrawlSaysSoAndDoesNotOfferResume() async throws {
    let path = NSTemporaryDirectory() + "koda-done-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }
    _ = try await CrawlSession.start(dbPath: path, config: CrawlConfig(seedURL: "https://fx.test/"),
                                     client: FixtureSite(), parser: SwiftSoupParser(), onProgress: nil)

    let (model, cleanup) = scratchModel()
    defer { cleanup() }
    try await model.openDatabase(path: path)

    #expect(model.controller.phase == .finished)
    #expect(!model.canResume)
    #expect(model.meta?.isFinished == true)
    #expect((model.meta?.duration ?? -1) >= 0)
    #expect(model.meta?.duration != nil, "a finished crawl knows how long it took")
}

// MARK: - Copying a selection

@MainActor
@Test func copyingASelectionGivesTabSeparatedTextWithAHeader() async throws {
    let model = ReportTableModel(store: try await fixtureStore(), definition: internalAll)
    model.toggleSort(column: 0)

    let text = model.clipboardText(for: IndexSet(0..<2))
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 3)
    #expect(lines[0] == internalAll.columns.joined(separator: "\t"))
    // Every line has a field per column, so a spreadsheet pastes it into cells.
    for line in lines {
        #expect(line.components(separatedBy: "\t").count == internalAll.columns.count)
    }
    #expect(lines[1].hasPrefix("https://fx.test/"))

    #expect(model.clipboardText(for: IndexSet(0..<1), includingHeader: false)
        .split(separator: "\n").count == 1)
    #expect(model.clipboardText(for: IndexSet(), includingHeader: false).isEmpty)
}

@MainActor
@Test func aTabInsideAValueCannotShiftTheColumns() async throws {
    // A title is whatever the site put in it, and a literal tab would silently
    // push every later column one to the right in whatever it is pasted into.
    let store = try emptyStore()
    let seed = URLNormalizer.normalize("https://t.test/", relativeTo: nil)!
    let url = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())
    var facts = PageFacts()
    facts.title = "A\tB\nC"
    facts.titleCount = 1
    _ = try store.write(results: [CrawlResult(
        urlID: url, url: seed, depth: 0,
        status: 200, errorKind: nil, contentType: "text/html", contentLength: 10, responseTimeMs: 1,
        redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts
    )], config: CrawlConfig(seedURL: "https://t.test/"), now: Date())

    let model = ReportTableModel(store: store, definition: ReportCatalogue.report(id: "internal-all")!)
    let line = model.clipboardText(for: IndexSet(integer: 0), includingHeader: false)
    #expect(!line.contains("\n"))
    #expect(line.components(separatedBy: "\t").count == internalAll.columns.count)
    #expect(line.contains("A B C"))
}

@MainActor
@Test func anAggregateReportOffersNoURLsToOpen() async throws {
    let store = try await fixtureStore()
    let urls = ReportTableModel(store: store, definition: ReportCatalogue.report(id: "depth-distribution")!)
    #expect(urls.urls(at: IndexSet(0..<3)).isEmpty, "a histogram row has no URL to open")

    let pages = ReportTableModel(store: store, definition: internalAll)
    #expect(pages.urls(at: IndexSet(0..<3)).count == 3)
    #expect(pages.urls(at: IndexSet(0..<3)).allSatisfy { $0.hasPrefix("https://") })
}

@MainActor
@Test func exportingTheCurrentReportKeepsItsSortAndFilter() async throws {
    let store = try await fixtureStore()
    let model = ReportTableModel(store: store, definition: internalAll)
    model.setFilter("p1")
    model.toggleSort(column: 0)

    let csv = try store.csv(for: model.query)
    let lines = csv.components(separatedBy: CSVWriter.lineTerminator).filter { !$0.isEmpty }
    #expect(lines.count == model.rowCount + 1, "the header plus exactly the rows on screen")
    #expect(lines.dropFirst().allSatisfy { $0.contains("p1") })
    let urls = lines.dropFirst().map { $0.components(separatedBy: ",")[0] }
    #expect(urls == urls.sorted(), "and in the order they are on screen")
}

@MainActor
@Test func theControllerSaysWhenItIsCheckingLinksRatherThanCrawling() async throws {
    // The frontier is empty during the status check. Without its own phase the
    // toolbar shows a running crawl with nothing queued, which reads as stalled.
    let controller = CrawlController(clientFactory: { SlowExternalFixtureSite() })
    var seen: [CrawlController.Phase] = []
    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    while controller.phase.isRunning {
        if seen.last != controller.phase { seen.append(controller.phase) }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    #expect(seen.contains(.checking), "saw \(seen)")
    #expect(controller.phase == .finished, "a late progress callback must not undo finishing")
    #expect((controller.progress?.checked ?? 0) > 0)
}

/// The fixture site with a slow third-party host, so the status-check phase is
/// long enough to be observed rather than raced past.
private struct SlowExternalFixtureSite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasPrefix("https://away.test/") {
            try? await Task.sleep(nanoseconds: 60_000_000)
            return .response(HTTPResponse(status: 200, headers: [:], body: Data(), elapsedMs: 1))
        }
        return await FixtureSite().fetch(url: url, method: method, userAgent: userAgent, timeout: timeout)
    }
}

@MainActor
@Test func selectingAPageLoadsItsHreflangAlternates() async throws {
    let path = NSTemporaryDirectory() + "koda-hreflang-\(UUID().uuidString).koda"
    defer { try? FileManager.default.removeItem(atPath: path) }
    _ = try await CrawlSession.start(dbPath: path, config: CrawlConfig(seedURL: "https://hl.test/"),
                                     client: HreflangSite(), parser: SwiftSoupParser(), onProgress: nil)

    let (model, cleanup) = scratchModel(client: { HreflangSite() })
    defer { cleanup() }
    try await model.openDatabase(path: path)
    model.select(reportID: "internal-all")
    model.table?.toggleSort(column: 0)
    model.selectRow(at: 0)

    #expect(model.selectedDetail?.url == "https://hl.test/")
    #expect(model.selectedHreflang.map(\.lang) == ["en", "fr", "x-default"])
    #expect(model.selectedHreflang.allSatisfy { $0.url.hasPrefix("https://hl.test/") })

    model.clearSelection()
    #expect(model.selectedHreflang.isEmpty)
}

private struct HreflangSite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        let body = url == "https://hl.test/"
            ? """
              <html><head><title>Home</title>
              <link rel="alternate" hreflang="en" href="https://hl.test/">
              <link rel="alternate" hreflang="fr" href="https://hl.test/fr">
              <link rel="alternate" hreflang="x-default" href="https://hl.test/">
              </head><body><h1>H</h1><a href="/fr">FR</a></body></html>
              """
            : "<html><head><title>FR</title></head><body><h1>FR</h1></body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

// MARK: - What Start would do

@MainActor
@Test func startingOverAFinishedCrawlReplacesItRatherThanDrainingNothing() async throws {
    // A finished crawl has an empty frontier. Continuing one drains nothing, so
    // Start would appear to do nothing at all.
    let path = NSTemporaryDirectory() + "koda-restart-\(UUID().uuidString).koda"
    defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
    _ = try await CrawlSession.start(dbPath: path, config: CrawlConfig(seedURL: "https://fx.test/"),
                                     client: FixtureSite(), parser: SwiftSoupParser(), onProgress: nil)

    let (model, cleanup) = scratchModel()
    defer { cleanup() }
    try await model.openDatabase(path: path)
    #expect(!model.canResume, "a finished crawl is not resumable")
    #expect(model.startPlan(databasePath: path) == .replaces(path: path))

    #expect(model.startCrawl(databasePath: path))
    try await waitUntil { !model.controller.phase.isRunning }
    #expect(model.controller.phase == .finished)
    #expect(try model.store?.urlCounts().done ?? 0 > FixtureSite.pageCount, "it really crawled again")
}

@MainActor
@Test func startPlanTellsTheViewWhenItIsAboutToDestroySomething() async throws {
    let (model, cleanup) = scratchModel(client: { SlowFixtureSite() })
    defer { cleanup() }
    let path = NSTemporaryDirectory() + "koda-plan-\(UUID().uuidString).koda"
    defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

    model.seedURL = "https://fx.test/"
    #expect(model.startPlan(databasePath: path) == .fresh(path: path), "nothing there yet")

    #expect(model.startCrawl(databasePath: path))
    try await waitUntil { model.controller.phase == .crawling }
    model.controller.stop()
    try await waitUntil { !model.controller.phase.isRunning }

    #expect(model.startPlan(databasePath: path) == .resume, "an interrupted crawl continues")

    // Resuming replays the stored config, so what the form says does not matter.
    model.settings.includeText = "[unclosed"
    #expect(model.startPlan(databasePath: path) == .resume)

    // For a new crawl it matters, and the plan says so before anything is touched.
    model.seedURL = "https://other.test/"
    guard case .invalid(let message) = model.startPlan() else {
        Issue.record("a bad regex is not a plan")
        return
    }
    #expect(message.contains("[unclosed"))
}

@MainActor
@Test func replacingACrawlTakesItsWriteAheadLogWithIt() async throws {
    // WAL mode leaves -wal and -shm beside the database. Removing only the
    // database has the next crawl replay a journal for a crawl that is gone.
    let path = NSTemporaryDirectory() + "koda-wal-\(UUID().uuidString).koda"
    defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
    _ = try await CrawlSession.start(dbPath: path, config: CrawlConfig(seedURL: "https://fx.test/"),
                                     client: FixtureSite(), parser: SwiftSoupParser(), onProgress: nil)
    try Data("stale".utf8).write(to: URL(fileURLWithPath: path + "-wal"))

    let (model, cleanup) = scratchModel()
    defer { cleanup() }
    model.seedURL = "https://fx.test/"
    #expect(model.startCrawl(databasePath: path))
    try await waitUntil { !model.controller.phase.isRunning }

    #expect(model.controller.phase == .finished)
    #expect(model.errorMessage == nil)
}

// MARK: - Pacing the refresh

@MainActor
@Test func refreshPacesItselfByWhatTheLastPassCost() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    let model = AppModel(controller: controller)

    // Nothing measured yet, so the interval is the floor rather than zero: a
    // loop that reads it before the first pass must not spin.
    #expect(model.refreshInterval == 0.5)

    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }
    await model.refresh()

    #expect(model.lastRefreshDuration > 0, "the pass was timed")
    #expect(model.refreshInterval >= model.lastRefreshDuration,
            "the app never spends more than half its time counting")
    #expect(model.refreshInterval >= 0.5, "and never busier than twice a second")
}

@MainActor
@Test func aRefreshThatLandsAfterTheCrawlWasReplacedIsDropped() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    let model = AppModel(controller: controller)
    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }
    await model.refresh()
    #expect(model.summary != nil)

    // Counting now happens off the main thread, so a pass can still be in flight
    // when the crawl it was reading is closed. Publishing it then would put a
    // dead crawl's numbers on screen beside a live one's.
    model.reset()
    #expect(model.summary == nil)
}

// MARK: - Exporting

@MainActor
@Test func anExportRunsAwayFromTheMainThreadAndSaysWhileItIs() async throws {
    let controller = CrawlController(clientFactory: { FixtureSite() })
    let model = AppModel(controller: controller)
    controller.start(config: CrawlConfig(seedURL: "https://fx.test/"), dbPath: nil)
    try await waitUntil { !controller.phase.isRunning }

    #expect(!model.isExporting)
    let written = try await model.runExport { 42 }
    #expect(written == 42)
    #expect(!model.isExporting, "and stops saying so afterwards")
}

@MainActor
@Test func anExportThatFailsStillClearsTheFlag() async throws {
    let model = AppModel(controller: CrawlController(clientFactory: { FixtureSite() }))
    struct Boom: Error {}
    await #expect(throws: Boom.self) {
        try await model.runExport { throw Boom() }
    }
    // Otherwise one failed export disables the menu for the rest of the session.
    #expect(!model.isExporting)
}
