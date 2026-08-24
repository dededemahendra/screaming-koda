import Foundation
import Testing
@testable import KodaCore

private struct QuerySite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        let titles = ["/": "Zulu", "/a": "Alpha", "/b": "Bravo", "/c": "Charlie 50% off", "/d": "Delta_one"]
        let path = URLNormalizer.normalize(url, relativeTo: nil)?.path ?? "/"
        guard let title = titles[path] else {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        let links = path == "/" ? "<a href='/a'>a</a><a href='/b'>b</a><a href='/c'>c</a><a href='/d'>d</a>" : ""
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data("<html><head><title>\(title)</title></head><body><h1>H</h1>\(links)</body></html>".utf8),
                                      elapsedMs: 1))
    }
}

private func querySite() async throws -> Store {
    var config = CrawlConfig(seedURL: "https://q.test/")
    config.workers = 2
    config.checkExternalLinks = false
    config.checkImages = false
    return try await CrawlSession.start(dbPath: nil, config: config, client: QuerySite(),
                                        parser: SwiftSoupParser(), onProgress: nil)
}

private let internalAll = ReportCatalogue.report(id: "internal-all")!

private func titles(_ rows: [[String?]]) -> [String] {
    rows.compactMap { $0.count > 3 ? $0[3] : nil }
}

@Test func pagingCoversTheWholeSetWithoutOverlap() async throws {
    let store = try await querySite()
    let query = ReportQuery(definition: internalAll, sortColumn: 0)
    let total = try store.count(for: query)
    #expect(total == 5)

    var collected: [[String?]] = []
    var offset = 0
    while collected.count < total {
        let page = try store.rows(for: query, limit: 2, offset: offset)
        #expect(!page.isEmpty)
        collected += page
        offset += 2
    }
    let all = try store.rows(for: query)
    #expect(collected.map { $0[0] } == all.map { $0[0] })
    #expect(Set(collected.map { $0[0] }).count == total, "pages do not overlap")
}

@Test func sortingIsAppliedInSQL() async throws {
    let store = try await querySite()
    var query = ReportQuery(definition: internalAll, sortColumn: 3, direction: .ascending)
    let ascending = titles(try store.rows(for: query))
    #expect(ascending == ascending.sorted())

    query.direction = .descending
    #expect(titles(try store.rows(for: query)) == ascending.reversed())
}

@Test func sortingSurvivesPaging() async throws {
    let store = try await querySite()
    let query = ReportQuery(definition: internalAll, sortColumn: 3, direction: .ascending)
    let all = titles(try store.rows(for: query))
    let firstPage = titles(try store.rows(for: query, limit: 2, offset: 0))
    let secondPage = titles(try store.rows(for: query, limit: 2, offset: 2))
    #expect(firstPage + secondPage == Array(all.prefix(4)))
}

@Test func anOutOfRangeSortColumnIsIgnored() async throws {
    let store = try await querySite()
    let query = ReportQuery(definition: internalAll, sortColumn: 99)
    #expect(try store.rows(for: query).count == 5, "a stale column index must not break the table")
}

@Test func filterNarrowsAcrossEveryColumn() async throws {
    let store = try await querySite()
    var query = ReportQuery(definition: internalAll)
    query.filter = "Alpha"
    #expect(titles(try store.rows(for: query)) == ["Alpha"])

    // Matching a URL rather than a title proves the filter spans columns.
    query.filter = "/b"
    #expect(titles(try store.rows(for: query)) == ["Bravo"])
}

@Test func filterIsCaseInsensitive() async throws {
    let store = try await querySite()
    var query = ReportQuery(definition: internalAll)
    query.filter = "alpha"
    #expect(titles(try store.rows(for: query)) == ["Alpha"])
}

@Test func filterTreatsWildcardsLiterally() async throws {
    let store = try await querySite()
    var query = ReportQuery(definition: internalAll)

    // Without ESCAPE, "%" would match every row and "_" any single character.
    query.filter = "50%"
    #expect(titles(try store.rows(for: query)) == ["Charlie 50% off"])

    query.filter = "_"
    #expect(titles(try store.rows(for: query)) == ["Delta_one"])

    query.filter = "Delta_one"
    #expect(titles(try store.rows(for: query)) == ["Delta_one"])
}

@Test func filterCannotInject() async throws {
    let store = try await querySite()
    var query = ReportQuery(definition: internalAll)
    query.filter = "'; DROP TABLE urls; --"
    #expect(try store.rows(for: query).isEmpty)
    // The table is still there.
    #expect(try store.urlCounts().total == 5)
}

@Test func countMatchesFilteredRows() async throws {
    let store = try await querySite()
    var query = ReportQuery(definition: internalAll)
    query.filter = "Alpha"
    #expect(try store.count(for: query) == 1)
    query.filter = ""
    let unfilteredCount = try store.count(for: query)
    let unfilteredRows = try store.rows(for: query).count
    #expect(unfilteredCount == unfilteredRows)
}

@Test func everyReportSupportsSortingByEveryColumn() async throws {
    let store = try await querySite()
    // A report whose SQL does not survive being wrapped, or whose declared column
    // names do not match its output, would fail here rather than in the UI.
    for definition in ReportCatalogue.all {
        for index in definition.columns.indices {
            let query = ReportQuery(definition: definition, sortColumn: index, filter: "a")
            do {
                _ = try store.rows(for: query, limit: 5)
                _ = try store.count(for: query)
            } catch {
                Issue.record("\(definition.id) column \(index) (\(definition.columns[index])): \(error)")
            }
        }
    }
}
