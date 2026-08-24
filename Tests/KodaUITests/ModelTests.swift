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
    model.refresh()

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
    model.refresh()
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
    model.refresh()
    model.select(reportID: "depth-distribution")
    model.selectRow(at: 0)
    #expect(model.selectedDetail == nil, "a histogram row has no URL to inspect")
}

@MainActor
@Test func refreshBeforeAnyCrawlIsHarmless() {
    let model = AppModel(controller: CrawlController(clientFactory: { FixtureSite() }))
    model.refresh()
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
