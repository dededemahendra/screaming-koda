import Foundation
import GRDB
import Testing
@testable import KodaCore

/// A site built so that every rule in the catalogue has something to find.
private struct ReportSite: HTTPClient {
    private static let identicalBody = "<body><p>Identical body text.</p></body>"

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        func html(_ status: Int, _ body: String) -> FetchOutcome {
            .response(HTTPResponse(status: status, headers: ["Content-Type": "text/html"],
                                   body: Data(body.utf8), elapsedMs: 3))
        }
        func redirect(_ to: String) -> FetchOutcome {
            .response(HTTPResponse(status: 301, headers: ["Location": to], body: Data(), elapsedMs: 1))
        }

        switch url {
        case "https://rep.test/robots.txt":
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))

        case "https://rep.test/":
            return html(200, """
                <html lang="en"><head>
                <title>Home</title>
                <meta name="description" content="A home page description written deliberately long so that it comfortably exceeds one hundred and fifty-five characters, which is the threshold the report uses.">
                <link rel="canonical" href="https://rep.test/">
                <link rel="alternate" hreflang="en" href="https://rep.test/">
                <link rel="alternate" hreflang="fr" href="https://rep.test/fr">
                </head><body>
                <h1>Home</h1><h2>Section</h2>
                <a href="/a">A</a><a href="/b">B</a><a href="/copy">Copy</a>
                <a href="/notitle">No title</a><a href="/gone">Gone</a>
                <a href="/noindex">No index</a><a href="/loop">Loop</a>
                <a href="https://ext.test/x">External</a>
                <img src="/img/ok.png" alt="A picture">
                <img src="/img/bad.png">
                </body></html>
                """)

        case "https://rep.test/a":
            return html(200, """
                <html><head><title>Shared</title>
                <link rel="canonical" href="https://rep.test/"></head>
                \(Self.identicalBody)</html>
                """)

        case "https://rep.test/copy":
            return html(200, "<html><head><title>Copy</title></head>\(Self.identicalBody)</html>")

        case "https://rep.test/b":
            return html(200, """
                <html><head><title>Shared</title>
                <meta name="description" content="Short one."></head>
                <body><h1>Same H1</h1><h2>Sub</h2><a href="/deep">Deep</a></body></html>
                """)

        case "https://rep.test/deep":
            return html(200, "<html><head><title>Deep</title></head><body><h1>Same H1</h1></body></html>")

        case "https://rep.test/notitle":
            return html(200, "<html><head></head><body><p>Nothing here.</p></body></html>")

        case "https://rep.test/noindex":
            return html(200, """
                <html><head><title>No index</title>
                <meta name="robots" content="noindex, follow"></head>
                <body><h1>Hidden</h1></body></html>
                """)

        case "https://rep.test/fr":
            return html(200, "<html><head><title>Bonjour</title></head><body><h1>Bonjour</h1></body></html>")

        case "https://rep.test/loop":  return redirect("https://rep.test/loop2")
        case "https://rep.test/loop2": return redirect("https://rep.test/loop")

        default:
            return html(404, "<html><head><title>Not found</title></head><body>Gone</body></html>")
        }
    }
}

private func crawledStore() async throws -> Store {
    var config = CrawlConfig(seedURL: "https://rep.test/")
    config.workers = 3
    return try await CrawlSession.start(dbPath: nil, config: config, client: ReportSite(),
                                        parser: SwiftSoupParser(), onProgress: nil)
}

private func emptyStore() throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    return store
}

private func firstColumn(_ rows: [[String?]]) -> [String] {
    rows.compactMap { $0.first ?? nil }
}

// MARK: - Structural invariants

@Test func reportIDsAreUnique() {
    let ids = ReportCatalogue.all.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test func catalogueCoversEveryGroupInTheSpec() {
    let expected = ["Internal", "External", "Response Codes", "Titles", "Meta Description",
                    "Headings", "Images", "Canonicals", "Directives", "Hreflang", "Page Depth"]
    #expect(ReportCatalogue.groups == expected)
}

@Test func everyReportRunsOnAPopulatedDatabase() async throws {
    let store = try await crawledStore()
    for definition in ReportCatalogue.all {
        do {
            _ = try store.runReport(definition)
        } catch {
            Issue.record("\(definition.id) failed: \(error)")
        }
    }
}

@Test func everyReportRunsOnAnEmptyDatabase() throws {
    // A report opened before the first crawl finishes must return nothing, not throw.
    let store = try emptyStore()
    for definition in ReportCatalogue.all {
        do {
            let rows = try store.runReport(definition)
            #expect(rows.isEmpty, "\(definition.id) returned rows on an empty database")
        } catch {
            Issue.record("\(definition.id) failed: \(error)")
        }
    }
}

@Test func reportColumnsMatchTheirQueries() async throws {
    let store = try await crawledStore()
    for definition in ReportCatalogue.all {
        let actual = try store.reportColumnNames(definition)
        #expect(actual == definition.columns, "\(definition.id) column drift")
    }
}

@Test func reportCountMatchesRowCount() async throws {
    let store = try await crawledStore()
    for definition in ReportCatalogue.all {
        let rows = try store.runReport(definition).count
        #expect(try store.reportCount(definition) == rows, "\(definition.id) count mismatch")
    }
}

@Test func reportCountsCoverEveryReport() async throws {
    let store = try await crawledStore()
    let counts = try store.reportCounts()
    #expect(counts.count == ReportCatalogue.all.count)
    #expect(counts["response-4xx"] == 4, "/gone, the external link, and two images")
}

@Test func pagingSlicesTheSameRows() async throws {
    let store = try await crawledStore()
    let definition = ReportCatalogue.report(id: "internal-all")!
    let all = try store.runReport(definition)
    #expect(all.count > 3)

    let firstTwo = try store.runReport(definition, limit: 2, offset: 0)
    let rest = try store.runReport(definition, limit: nil, offset: 2)
    #expect(firstTwo.map { $0.first ?? nil } == all.prefix(2).map { $0.first ?? nil })
    #expect(rest.count == all.count - 2)
}

// MARK: - Behaviour

@Test func findsDuplicateTitles() async throws {
    let store = try await crawledStore()
    let rows = try store.runReport(ReportCatalogue.report(id: "titles-duplicate")!)
    #expect(firstColumn(rows) == ["https://rep.test/a", "https://rep.test/b"])
}

@Test func findsMissingTitlesAndH1s() async throws {
    let store = try await crawledStore()
    #expect(firstColumn(try store.runReport(ReportCatalogue.report(id: "titles-missing")!))
            == ["https://rep.test/notitle"])
    let missingH1 = firstColumn(try store.runReport(ReportCatalogue.report(id: "h1-missing")!))
    #expect(missingH1.contains("https://rep.test/a"))
    #expect(missingH1.contains("https://rep.test/notitle"))
    #expect(!missingH1.contains("https://rep.test/"))
}

@Test func findsDuplicateH1s() async throws {
    let store = try await crawledStore()
    let rows = try store.runReport(ReportCatalogue.report(id: "h1-duplicate")!)
    #expect(Set(firstColumn(rows)) == ["https://rep.test/b", "https://rep.test/deep"])
}

@Test func findsCanonicalisedPages() async throws {
    let store = try await crawledStore()
    let rows = try store.runReport(ReportCatalogue.report(id: "canonical-canonicalised")!)
    #expect(rows.count == 1)
    #expect(rows[0][0] == "https://rep.test/a")
    #expect(rows[0][1] == "https://rep.test/")
    #expect(firstColumn(try store.runReport(ReportCatalogue.report(id: "canonical-self")!))
            == ["https://rep.test/"])
}

@Test func findsNoindexDirectives() async throws {
    let store = try await crawledStore()
    #expect(firstColumn(try store.runReport(ReportCatalogue.report(id: "directives-noindex")!))
            == ["https://rep.test/noindex"])
}

@Test func findsBrokenLinksWithTheirSourcePage() async throws {
    let store = try await crawledStore()
    let rows = try store.runReport(ReportCatalogue.report(id: "response-broken-links")!)
    // Both the internal 404 and the external one: status checking is what makes
    // broken outbound links visible at all.
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0[0] == "https://rep.test/" })
    #expect(rows.map { $0[1] } == ["https://ext.test/x", "https://rep.test/gone"])
    #expect(rows.allSatisfy { $0[2] == "404" })
}

@Test func findsRedirectLoops() async throws {
    let store = try await crawledStore()
    let looping = Set(firstColumn(try store.runReport(ReportCatalogue.report(id: "response-redirect-loops")!)))
    #expect(looping == ["https://rep.test/loop", "https://rep.test/loop2"])
}

@Test func findsDuplicateContent() async throws {
    let store = try await crawledStore()
    let rows = try store.runReport(ReportCatalogue.report(id: "internal-duplicate-content")!)
    #expect(Set(firstColumn(rows)) == ["https://rep.test/a", "https://rep.test/copy"])
}

@Test func findsImagesMissingAlt() async throws {
    let store = try await crawledStore()
    let rows = try store.runReport(ReportCatalogue.report(id: "images-missing-alt")!)
    #expect(rows.count == 1)
    #expect(rows[0][0] == "https://rep.test/img/bad.png")
    #expect(rows[0][1] == "https://rep.test/")
}

@Test func findsHreflangProblems() async throws {
    let store = try await crawledStore()
    let missingReturn = try store.runReport(ReportCatalogue.report(id: "hreflang-missing-return")!)
    #expect(missingReturn.count == 1)
    #expect(missingReturn[0][1] == "fr")
    #expect(missingReturn[0][2] == "https://rep.test/fr")

    #expect(firstColumn(try store.runReport(ReportCatalogue.report(id: "hreflang-missing-x-default")!))
            == ["https://rep.test/"])
}

@Test func listsExternalURLsWithTheirStatus() async throws {
    let store = try await crawledStore()
    let rows = try store.runReport(ReportCatalogue.report(id: "external-all")!)
    #expect(rows.count == 1)
    #expect(rows[0][0] == "https://ext.test/x")
    #expect(rows[0][2] == "404", "external links are status-checked")
    #expect(rows[0][3] == "1", "and carry the count of pages linking to them")
}

@Test func reportsDepthDistribution() async throws {
    let store = try await crawledStore()
    let rows = try store.runReport(ReportCatalogue.report(id: "depth-distribution")!)
    #expect(rows.first?[0] == "0")
    #expect(rows.first?[1] == "1", "only the seed is at depth 0")
}

// MARK: - Inventory vs issues

@Test func inventoryReportsAreNotCountedAsFindings() {
    let inventoryIDs = Set(ReportCatalogue.all.filter { $0.kind == .inventory }.map(\.id))
    // Listing "4 internal URLs" as a finding trains people to ignore the list.
    #expect(inventoryIDs.contains("internal-all"))
    #expect(inventoryIDs.contains("external-all"))
    #expect(inventoryIDs.contains("response-2xx"))
    #expect(inventoryIDs.contains("depth-distribution"))
    #expect(inventoryIDs.contains("canonical-self"))

    let issueIDs = Set(ReportCatalogue.issues.map(\.id))
    #expect(issueIDs.isDisjoint(with: inventoryIDs))
    #expect(issueIDs.count + inventoryIDs.count == ReportCatalogue.all.count)
    #expect(issueIDs.contains("response-4xx"))
    #expect(issueIDs.contains("titles-duplicate"))
}

@Test func aCleanSiteProducesNoFindings() async throws {
    struct CleanSite: HTTPClient {
        func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
            guard url == "https://clean.test/" else {
                return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
            }
            return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"], elapsedMs: 1,
                                          bodyText: """
                <html lang="en"><head>
                <title>A clean page with a title of a sensible length</title>
                <meta name="description" content="A meta description that sits comfortably between seventy and one hundred and fifty-five characters, so neither length rule fires here.">
                <link rel="canonical" href="https://clean.test/">
                </head><body><h1>Heading</h1><h2>Sub</h2><p>Some words.</p></body></html>
                """))
        }
    }
    var config = CrawlConfig(seedURL: "https://clean.test/")
    config.workers = 1
    let store = try await CrawlSession.start(dbPath: nil, config: config, client: CleanSite(),
                                             parser: SwiftSoupParser(), onProgress: nil)

    let counts = try store.reportCounts()
    let findings = ReportCatalogue.issues.filter { (counts[$0.id] ?? 0) > 0 }
    #expect(findings.map(\.id) == [], "a page with nothing wrong must produce an empty findings list")
    #expect(counts["internal-all"] == 1, "but it still appears in the inventory")
}

private extension HTTPResponse {
    init(status: Int, headers: [String: String], elapsedMs: Int, bodyText: String) {
        self.init(status: status, headers: headers, body: Data(bodyText.utf8), elapsedMs: elapsedMs)
    }
}
