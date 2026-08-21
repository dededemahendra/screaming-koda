import Foundation
import GRDB
import Testing
@testable import KodaCore

private func rows(_ store: Store, _ report: Report, _ filterID: String) throws -> Set<String> {
    guard let filter = report.filters.first(where: { $0.id == filterID }) else {
        Issue.record("\(report.id) has no filter '\(filterID)'")
        return []
    }
    return try ReportFixture.paths(store, store.ids(for: report, filter: filter,
                                                    sortBy: nil, ascending: true))
}

// MARK: - Structural

/// The load-bearing test. Prepares the exact statement every report and filter
/// would run, so a typo anywhere in the definitions fails here, named, rather
/// than as a mysteriously empty tab.
@Test func everyFilterIsValidSQL() throws {
    let store = try ReportFixture.make()
    var prepared = 0
    try store.dbQueue.read { db in
        for report in Reports.all {
            for filter in report.filters {
                // Both the unsorted form and a sorted one: ORDER BY interpolates
                // a column expression that the unsorted form never touches.
                for sort in [nil, report.columns.first] {
                    let sql = Store.idsSQL(report: report, filter: filter,
                                           sortBy: sort, ascending: true)
                    do {
                        _ = try db.makeStatement(sql: sql)
                        prepared += 1
                    } catch {
                        Issue.record("\(report.id).\(filter.id) is not valid SQL: \(error)")
                    }
                }
            }
        }
    }
    #expect(prepared == Reports.all.reduce(0) { $0 + $1.filters.count * 2 })
}

/// Every column expression has to survive being SELECTed too — `idsSQL` only
/// exercises the one column a sort names.
@Test func everyColumnExpressionIsValidSQL() throws {
    let store = try ReportFixture.make()
    for report in Reports.all {
        let ids = try store.ids(for: report, filter: report.defaultFilter,
                                sortBy: nil, ascending: true)
        #expect(throws: Never.self, "\(report.id) columns") {
            _ = try store.rows(ids: Array(ids.prefix(5)), columns: report.columns)
        }
    }
}

@Test func everyReportHasAnAllFilterFirst() {
    for report in Reports.all {
        #expect(report.defaultFilter.id == "all", "\(report.id) does not lead with All")
        #expect(report.defaultFilter.isIssue == false)
    }
}

/// Duplicate ids would shadow each other in the SELECT and silently render the
/// same value in two columns.
@Test func everyColumnIDIsUniqueWithinItsReport() {
    for report in Reports.all {
        let ids = report.columns.map(\.id)
        #expect(Set(ids).count == ids.count, "\(report.id) has duplicate column ids")
    }
}

@Test func everyReportIDAndFilterIDIsUnique() {
    #expect(Set(Reports.all.map(\.id)).count == Reports.all.count)
    for report in Reports.all {
        let ids = report.filters.map(\.id)
        #expect(Set(ids).count == ids.count, "\(report.id) has duplicate filter ids")
    }
}

@Test func thereAreElevenReports() {
    #expect(Reports.all.count == 11)
}

// MARK: - Behaviour, per report

@Test func internalReportExcludesExternalsImagesAndFindsNonIndexable() throws {
    let store = try ReportFixture.make()
    let all = try rows(store, Reports.internalURLs, "all")
    #expect(all.contains("/"))
    #expect(!all.contains("https://ext.test/ok"))
    #expect(!all.contains("/img/big.png"), "an image-only URL is not a page")
    #expect(all.contains("/queued"), "a discovered-but-unfetched URL still belongs in the table")

    let bad = try rows(store, Reports.internalURLs, "nonIndexable")
    #expect(bad.contains("/gone"))
    #expect(bad.contains("/noindex"))
    #expect(bad.contains("/canonicalised"))
    #expect(!bad.contains("/"), "a clean page is not a finding")
    #expect(!bad.contains("/queued"), "not-yet-crawled is not a finding")
}

@Test func externalReportListsOnlyExternalsAndFlagsBroken() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.external, "all")
            == ["https://ext.test/ok", "https://ext.test/broken"])
    #expect(try rows(store, Reports.external, "broken") == ["https://ext.test/broken"])
}

@Test func responseCodesSeparatesEveryStatusClass() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.responseCodes, "clientError")
            == ["/gone", "https://ext.test/broken"])
    #expect(try rows(store, Reports.responseCodes, "serverError") == ["/boom"])
    #expect(try rows(store, Reports.responseCodes, "transportError") == ["/dead"])
    #expect(try !rows(store, Reports.responseCodes, "all").contains("/queued"),
            "a URL with no response is not a response code")
}

@Test func responseCodesFindsChainsAndLoops() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.responseCodes, "viaChain") == ["/chain-final"])
    #expect(try rows(store, Reports.responseCodes, "loop") == ["/loop-a", "/loop-b", "/loop-self"])
}

@Test func titlesReportFindsEveryTitleProblem() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.titles, "missing") == ["/no-title"])
    #expect(try rows(store, Reports.titles, "duplicate") == ["/dupe-a", "/dupe-b"])
    #expect(try rows(store, Reports.titles, "over60") == ["/long-title"])
    #expect(try rows(store, Reports.titles, "under30") == ["/short-title"])
    #expect(try rows(store, Reports.titles, "multiple") == ["/multi-title"])
    #expect(try rows(store, Reports.titles, "sameAsH1") == ["/title-is-h1"])

    // The base predicate: a 404 has no title finding, its finding is the 404.
    #expect(try !rows(store, Reports.titles, "all").contains("/gone"))
    #expect(try !rows(store, Reports.titles, "missing").contains("/gone"))
}

@Test func metaDescriptionReportFindsEveryDescriptionProblem() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.metaDescription, "missing") == ["/no-desc"])
    #expect(try rows(store, Reports.metaDescription, "duplicate")
            == ["/dupe-desc-a", "/dupe-desc-b"])
    #expect(try rows(store, Reports.metaDescription, "over155") == ["/long-desc"])
    #expect(try rows(store, Reports.metaDescription, "under70") == ["/short-desc"])
    #expect(try rows(store, Reports.metaDescription, "multiple") == ["/multi-desc"])
}

@Test func headingsReportFindsEveryHeadingProblem() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.headings, "missingH1") == ["/no-h1"])
    #expect(try rows(store, Reports.headings, "duplicateH1") == ["/dupe-h1-a", "/dupe-h1-b"])
    #expect(try rows(store, Reports.headings, "multipleH1") == ["/multi-h1"])
    #expect(try rows(store, Reports.headings, "longH1") == ["/long-h1"])
    #expect(try rows(store, Reports.headings, "missingH2") == ["/no-h2"])
}

@Test func imagesReportIsKeyedOnImageURLsNotPages() throws {
    let store = try ReportFixture.make()
    let all = try rows(store, Reports.images, "all")
    #expect(all == ["/img/plain.png", "/img/noalt.png", "/img/longalt.png", "/img/big.png"])
    #expect(!all.contains("/"), "the page referencing an image is not itself an image")

    #expect(try rows(store, Reports.images, "missingAlt") == ["/img/noalt.png"])
    #expect(try rows(store, Reports.images, "longAlt") == ["/img/longalt.png"])
    #expect(try rows(store, Reports.images, "over100kb") == ["/img/big.png"])
}

@Test func canonicalsReportDistinguishesSelfFromCanonicalised() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.canonicals, "missing") == ["/canon-missing"])
    #expect(try rows(store, Reports.canonicals, "canonicalised")
            == ["/canonicalised", "/canon-to-404"])
    #expect(try rows(store, Reports.canonicals, "toNon200") == ["/canon-to-404"])
    #expect(try rows(store, Reports.canonicals, "self").contains("/"))
    #expect(try !rows(store, Reports.canonicals, "self").contains("/canonicalised"))
}

@Test func directivesReportFindsRobotsTokensAndConflicts() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.directives, "noindex") == ["/noindex", "/robots-conflict"])
    #expect(try rows(store, Reports.directives, "nofollow") == ["/nofollow"])
    #expect(try rows(store, Reports.directives, "conflict") == ["/robots-conflict"])
    #expect(try rows(store, Reports.directives, "noarchive").isEmpty)
}

@Test func hreflangReportFindsReturnLinkAndTargetProblems() throws {
    let store = try ReportFixture.make()
    let all = try rows(store, Reports.hreflang, "all")
    #expect(all == ["/hl-a", "/hl-b", "/hl-noreturn", "/hl-404", "/hl-nodefault"])
    #expect(!all.contains("/hl-orphan"), "a page nobody's hreflang set includes is not in this tab")

    #expect(try rows(store, Reports.hreflang, "noReturn") == ["/hl-noreturn", "/hl-404"])
    #expect(try rows(store, Reports.hreflang, "non200") == ["/hl-404"])
    #expect(try rows(store, Reports.hreflang, "noXDefault") == ["/hl-nodefault"])
}

@Test func pageDepthReportFindsDeepAndWeaklyLinkedPages() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.pageDepth, "deep") == ["/deep/four"])
    #expect(try rows(store, Reports.pageDepth, "singleInlink") == ["/dupe-a", "/one-inlink"])
    #expect(try !rows(store, Reports.pageDepth, "all").contains("/queued"),
            "an uncrawled URL has no observed depth position yet")
}
