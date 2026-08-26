import Foundation
import Testing
@testable import KodaCore
@testable import KodaUI

private let stamp = Date(timeIntervalSince1970: 1_787_000_000)   // 2026-08-21 UTC

/// A small store built directly with SQL, the way `ExportCommandsTests`'
/// `smallStore()` does, rather than via a crawl — these tests are about
/// `ExportPlan.run` doing the query-and-write it claims, not about crawling.
/// Deliberately not `@MainActor`: `Store` isn't actor-isolated, and keeping
/// this off the main actor is what lets the tests below call `plan.run`
/// from a context that genuinely isn't the main actor either.
private func fixtureStore() throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        // All 200s: the Titles report's predicate excludes anything else
        // (`Reports.htmlPage` requires `r.status = 200`), and this fixture is
        // about proving the write happens correctly off the main actor, not
        // about exercising that predicate.
        let pages = [("/", 200), ("/missing", 200), ("/boom", 200)]
        for (path, status) in pages {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,1,1,0,2)
                    """,
                arguments: ["https://plan.test\(path)", Data(path.utf8), "plan.test", path])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO responses (url_id, status, content_type, fetched_at)
                    VALUES (?,?,'text/html; charset=utf-8',0)
                    """,
                arguments: [id, status])
            try db.execute(sql: "INSERT INTO page_facts (url_id, title) VALUES (?,?)",
                           arguments: [id, "Title for \(path)"])
        }
    }
    return store
}

private func scratchDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("export-plan-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - ExportPlan.run, off the main actor

/// Not `@MainActor`: this test function runs on the default (non-main)
/// executor, and `plan.run` is additionally dispatched through
/// `Task.detached` — the same mechanism `ContentView.export` uses — so this
/// genuinely exercises `run` away from the main actor rather than merely
/// compiling as `Sendable`.
@Test func currentViewPlanRunProducesACSVOffTheMainActor() async throws {
    let store = try fixtureStore()
    let plan = ExportPlan(store: store, report: Reports.titles, filter: Reports.titles.defaultFilter,
                          sortColumn: nil, ascending: true)
    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("titles.csv")

    let written = try await Task.detached {
        try plan.run(format: .csv, to: target, host: "plan.test", date: stamp)
    }.value

    #expect(written == [target])
    let text = try String(contentsOf: target, encoding: .utf8)
    #expect(text.contains("Title for /"))
    #expect(text.contains("Title for /missing"))
    #expect(text.contains("Title for /boom"))
    #expect(text.contains("https://plan.test/"))
}

/// Same off-main-actor requirement as above, for the `.everything` scope.
@Test func everythingPlanRunWritesEveryReportOffTheMainActor() async throws {
    let store = try fixtureStore()
    let plan = ExportPlan(store: store, reports: Reports.all)
    let directory = scratchDirectory().appendingPathComponent("out")
    defer { try? FileManager.default.removeItem(at: directory) }

    let written = try await Task.detached {
        try plan.run(format: .csv, to: directory, host: "plan.test", date: stamp)
    }.value

    #expect(written.count == Reports.all.count + 1, "one file per report, plus the overview")
    let names = written.map { $0.lastPathComponent }
    #expect(Set(names).count == written.count, "no two reports collide on a filename")
    for url in written {
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - CrawlController.exportPlan(scope:)

@MainActor
@Test func exportPlanIsNilWithoutAStore() {
    let c = CrawlController()
    #expect(c.exportPlan(scope: .currentView) == nil)
    #expect(c.exportPlan(scope: .everything) == nil)
}

/// Two pages at different response codes, so a plan captured under one sort
/// and a plan captured after changing it can be told apart by the row order
/// their exports come out in.
private struct StatusVaryingClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: ["Content-Type": "text/plain"],
                                          body: Data(), elapsedMs: 1))
        }
        if url.hasSuffix("/missing") {
            let body = "<html><head><title>Missing</title></head><body>gone</body></html>"
            return .response(HTTPResponse(status: 404, headers: ["Content-Type": "text/html"],
                                          body: Data(body.utf8), elapsedMs: 1))
        }
        let body = "<html><head><title>Home</title></head><body><a href=\"/missing\">x</a></body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

@MainActor
private func finishedStatusCrawl() async -> CrawlController {
    let c = CrawlController(client: StatusVaryingClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.seedURL = "https://plan4.test/"
    await c.start()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, c.state != .finished {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return c
}

/// Reads back the order of `Address` values a CSV export holds, in the order
/// they appear — the observable signature of whichever sort produced it.
private func addressOrder(in csv: URL) throws -> [String] {
    let text = try String(contentsOf: csv, encoding: .utf8)
    return text.components(separatedBy: "\r\n").dropFirst()
        .filter { !$0.isEmpty }
        .compactMap { $0.components(separatedBy: ",").first }
}

@MainActor
@Test func exportPlanCapturesTheCurrentSort() async throws {
    let c = await finishedStatusCrawl()
    #expect(c.state == .finished)

    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Discovery order: "/" before "/missing".
    let ascendingPlan = try #require(c.exportPlan(scope: .currentView))
    let ascendingFile = directory.appendingPathComponent("ascending.csv")
    _ = try ascendingPlan.run(format: .csv, to: ascendingFile, host: "plan4.test", date: stamp)
    let ascendingOrder = try addressOrder(in: ascendingFile)

    // Reverse it by status: 404 ("/missing") now sorts before 200 ("/").
    c.applySort(columnID: "status", ascending: false)
    let descendingPlan = try #require(c.exportPlan(scope: .currentView))
    let descendingFile = directory.appendingPathComponent("descending.csv")
    _ = try descendingPlan.run(format: .csv, to: descendingFile, host: "plan4.test", date: stamp)
    let descendingOrder = try addressOrder(in: descendingFile)

    #expect(ascendingOrder.count == 2)
    #expect(descendingOrder.count == 2)
    #expect(ascendingOrder != descendingOrder,
            "capturing again after applySort must pick up the new sort, not the one at first capture")
    #expect(ascendingOrder == Array(descendingOrder.reversed()))
}

@MainActor
@Test func exportPlanCapturesTheCurrentReportAndFilter() async throws {
    let c = await finishedStatusCrawl()
    #expect(c.state == .finished)
    #expect(c.selectedReport.id == "internal", "the default report is Internal, with no Status column")

    let directory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let internalPlan = try #require(c.exportPlan(scope: .currentView))
    let internalFile = directory.appendingPathComponent("internal.csv")
    _ = try internalPlan.run(format: .csv, to: internalFile, host: "plan4.test", date: stamp)
    let internalHeader = try String(contentsOf: internalFile, encoding: .utf8)
        .components(separatedBy: "\r\n").first ?? ""

    c.select(reportID: "responseCodes", filterID: "clientError")
    let filteredPlan = try #require(c.exportPlan(scope: .currentView))
    let filteredFile = directory.appendingPathComponent("client-error.csv")
    _ = try filteredPlan.run(format: .csv, to: filteredFile, host: "plan4.test", date: stamp)
    let filteredText = try String(contentsOf: filteredFile, encoding: .utf8)
    let filteredHeader = filteredText.components(separatedBy: "\r\n").first ?? ""
    let filteredRows = filteredText.components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty }

    #expect(internalHeader != filteredHeader,
            "a different report's columns must show up in the re-captured plan")
    #expect(filteredRows.count == 1, "only /missing (404) is a client error")
    #expect(filteredText.contains("/missing"))
}

// MARK: - The export menu disables while an export is running

@Test func exportIsUnavailableWithNothingToExport() {
    #expect(exportIsAvailable(canExport: false, isExporting: false) == false)
}

@Test func exportIsAvailableWhenThereIsSomethingToExportAndNothingRunning() {
    #expect(exportIsAvailable(canExport: true, isExporting: false) == true)
}

@Test func exportIsUnavailableWhileAnExportIsRunning() {
    #expect(exportIsAvailable(canExport: true, isExporting: true) == false)
}

@MainActor
@Test func theControllerReportsExportingWhileAPlanRuns() async {
    let c = await finishedStatusCrawl()
    #expect(c.canExport)
    #expect(!c.isExporting, "nothing is running yet")

    c.isExporting = true
    #expect(!exportIsAvailable(canExport: c.canExport, isExporting: c.isExporting),
            "the menu must go unavailable the moment an export starts")

    c.isExporting = false
    #expect(exportIsAvailable(canExport: c.canExport, isExporting: c.isExporting),
            "and available again once it clears")
}
