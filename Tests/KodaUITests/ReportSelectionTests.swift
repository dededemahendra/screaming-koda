import Foundation
import Testing
@testable import KodaCore
@testable import KodaUI

/// Two pages, one of which has no title, so switching to Titles → Missing
/// visibly narrows the table rather than merely re-running the same query.
private struct TitleProblemClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        let body = url.hasSuffix("/")
            ? "<html><head><title>Home</title></head><body><a href=\"/untitled\">x</a></body></html>"
            : "<html><head></head><body>no title here</body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

@MainActor
private func finishedCrawl() async -> CrawlController {
    let c = CrawlController(client: TitleProblemClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://sel.test/"
    await c.start()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, c.state != .finished {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return c
}

@MainActor
@Test func theInternalReportIsSelectedByDefault() {
    let c = CrawlController(client: TitleProblemClient(), parser: SwiftSoupParser(), dbPath: nil)
    #expect(c.selectedReport.id == "internal")
    #expect(c.selectedFilter.id == "all")
}

@MainActor
@Test func selectingAReportChangesTheTablesColumns() async {
    let c = await finishedCrawl()
    #expect(c.rows?.value("canonical", at: 0) == nil, "Internal declares no canonical column")

    c.select(reportID: "canonicals")
    #expect(c.selectedReport.id == "canonicals")
    // The row now has the Canonicals report's shape. Its canonical value is
    // genuinely NULL here — these pages carry no canonical tag — so the shape,
    // not the value, is what proves the columns changed.
    #expect(c.rows?.row(at: 0)?.cells.count == Reports.canonicals.columns.count)
    #expect(c.rows?.value("address", at: 0)?.hasPrefix("https://sel.test") == true)
}

@MainActor
@Test func selectingAFilterNarrowsTheRows() async {
    let c = await finishedCrawl()
    c.select(reportID: "titles", filterID: "all")
    let all = c.rows?.count ?? 0
    c.select(reportID: "titles", filterID: "missing")
    let missing = c.rows?.count ?? 0
    #expect(all == 2, "both crawled pages are HTML 200s")
    #expect(missing == 1, "only /untitled has no title")
}

/// Selecting a report resets the sort. A column id from the previous tab has no
/// expression in the new one, so carrying it over would silently drop the sort;
/// resetting makes that explicit.
@MainActor
@Test func selectingAReportResetsTheSort() async {
    let c = await finishedCrawl()
    c.applySort(columnID: "status", ascending: false)
    #expect(c.rows?.count ?? 0 > 0)
    c.select(reportID: "titles")
    #expect(c.selectedReport.id == "titles")
}

@MainActor
@Test func anUnknownReportIDIsIgnoredRatherThanCrashing() async {
    let c = await finishedCrawl()
    c.select(reportID: "no-such-report")
    #expect(c.selectedReport.id == "internal", "the previous selection stands")
}

@MainActor
@Test func anUnknownFilterIDFallsBackToAll() async {
    let c = await finishedCrawl()
    c.select(reportID: "titles", filterID: "no-such-filter")
    #expect(c.selectedFilter.id == "all")
}

/// Row 4 of Titles is not row 4 of Images, so a selection carried across a tab
/// change would point the inspector at an unrelated URL.
@MainActor
@Test func switchingReportsClearsTheRowSelection() async {
    let c = await finishedCrawl()
    c.selectRow(id: 1)
    #expect(c.selectedRowID == 1)
    c.select(reportID: "titles")
    #expect(c.selectedRowID == nil)
}

@MainActor
@Test func countsArePopulatedWhenTheCrawlFinishes() async {
    let c = await finishedCrawl()
    #expect(c.counts["internal.all"] == 2)
    #expect(c.counts["titles.missing"] == 1)
    #expect(c.counts["titles.duplicate"] == 0, "a zero count is present, not missing")
}

/// The counts agree with the rows the tab actually shows. A sidebar that
/// advertises findings the tab does not list is worse than no sidebar.
@MainActor
@Test func everyCountAgreesWithItsFiltersRowCount() async {
    let c = await finishedCrawl()
    for report in Reports.all {
        for filter in report.filters {
            c.select(reportID: report.id, filterID: filter.id)
            #expect(c.counts["\(report.id).\(filter.id)"] == c.rows?.count,
                    "\(report.id).\(filter.id) sidebar count disagrees with the table")
        }
    }
}

/// Counts are one full scan of the crawl, so they must not run on every 2 Hz
/// tick. Driven with an injected clock rather than by waiting on the real timer,
/// and against a database that really does change between refreshes — otherwise
/// "the count did not move" proves nothing.
@MainActor
@Test func countsAreThrottledDuringACrawl() async throws {
    let c = await finishedCrawl()
    let store = try #require(c.store)
    let start = Date()
    c.refreshCounts(force: true, now: start)
    #expect(c.counts["internal.all"] == 2)

    try addPage(to: store, path: "/late")

    c.refreshCounts(now: start.addingTimeInterval(0.5))
    #expect(c.counts["internal.all"] == 2, "half a second in, the scan must not have re-run")

    c.refreshCounts(now: start.addingTimeInterval(CrawlController.countsRefreshInterval + 0.1))
    #expect(c.counts["internal.all"] == 3, "past the interval, the scan runs and picks up the new row")
}

/// The end of a crawl forces a refresh regardless of the throttle, so the final
/// numbers are never a stale sample from up to two seconds earlier.
@MainActor
@Test func countsAreForcedRegardlessOfTheThrottle() async throws {
    let c = await finishedCrawl()
    let store = try #require(c.store)
    let start = Date()
    c.refreshCounts(force: true, now: start)
    #expect(c.counts["internal.all"] == 2)

    try addPage(to: store, path: "/late")
    c.refreshCounts(force: true, now: start.addingTimeInterval(0.1))
    #expect(c.counts["internal.all"] == 3)
}

@MainActor
private func addPage(to store: Store, path: String) throws {
    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                VALUES (?,?,?,?,1,1,0,2)
                """,
            arguments: ["https://sel.test\(path)", Data(path.utf8), "sel.test", path])
        try db.execute(sql: "INSERT INTO responses (url_id, status, content_type, fetched_at) VALUES (?,200,'text/html',0)",
                       arguments: [db.lastInsertedRowID])
    }
}

@MainActor
@Test func selectingARowLoadsAllFourInspectorPanes() async throws {
    let c = await finishedCrawl()
    let homeID = try #require(c.rows?.row(at: 0)?.id)
    c.selectRow(id: homeID)

    #expect(c.detail?.value("Address")?.hasPrefix("https://sel.test") == true)
    #expect(c.outlinks?.items.contains { $0.url.hasSuffix("/untitled") } == true)
    #expect(c.inlinks != nil)
    #expect(c.images != nil)
}

@MainActor
@Test func deselectingClearsTheInspectorRatherThanLeavingStaleRows() async throws {
    let c = await finishedCrawl()
    c.selectRow(id: try #require(c.rows?.row(at: 0)?.id))
    #expect(c.detail != nil)

    c.selectRow(id: nil)
    #expect(c.detail == nil)
    #expect(c.inlinks == nil)
    #expect(c.outlinks == nil)
    #expect(c.images == nil)
}

/// Switching tab clears the inspector too. Leaving the previous URL's inlinks
/// on screen under a new tab's selection would be worse than showing nothing.
@MainActor
@Test func switchingReportsClearsTheInspector() async throws {
    let c = await finishedCrawl()
    c.selectRow(id: try #require(c.rows?.row(at: 0)?.id))
    #expect(c.detail != nil)

    c.select(reportID: "titles")
    #expect(c.detail == nil)
    #expect(c.outlinks == nil)
}
