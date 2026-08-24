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

@Test func theReportInventoryIsWhatWeThinkItIs() {
    // Hard-coded so a report silently vanishing fails here rather than as an
    // empty tab nobody opened.
    #expect(Reports.all.map(\.id) == [
        "internal", "external", "responseCodes", "titles", "metaDescription", "headings",
        "images", "canonicals", "directives", "hreflang", "pageDepth",
        "content", "urls", "anchorText",
        "social", "structuredData", "pagination", "security", "extraction", "sitemap", "resources", "javascript", "performance", "crawlability",
    ])
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
    // /page/3 canonicalises to page one, which is the pagination anti-pattern
    // the Pagination tab flags separately.
    #expect(try rows(store, Reports.canonicals, "canonicalised")
            == ["/canonicalised", "/canon-to-404", "/page/3"])
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
    // /anchor-generic is linked once, from the home page, so it belongs here too.
    #expect(try rows(store, Reports.pageDepth, "singleInlink")
            == ["/dupe-a", "/one-inlink", "/anchor-generic"])
    #expect(try !rows(store, Reports.pageDepth, "all").contains("/queued"),
            "an uncrawled URL has no observed depth position yet")
}


// MARK: - Wave 1 reports

/// The clearest win in the coverage audit: `content_hash` was computed, stored
/// and indexed on every crawl since M1, and no report ever queried it.
@Test func contentReportFindsDuplicateAndThinPages() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.content, "duplicate") == ["/same-body-a", "/same-body-b"])
    #expect(try rows(store, Reports.content, "veryThin") == ["/thin", "/empty-body"])
    #expect(try rows(store, Reports.content, "empty") == ["/empty-body"])

    let thin = try rows(store, Reports.content, "thin")
    #expect(thin.contains("/thin"))
    #expect(thin.contains("/empty-body"))
    #expect(!thin.contains("/"), "a 400-word page is not thin")
}

@Test func urlReportFindsAwkwardURLShapes() throws {
    let store = try ReportFixture.make()
    // /both is the unfinished-migration case and is also served over http.
    #expect(try rows(store, Reports.urlStructure, "insecure") == ["/insecure", "/both"])
    #expect(try rows(store, Reports.urlStructure, "uppercase") == ["/Upper/Case"])
    #expect(try rows(store, Reports.urlStructure, "underscore") == ["/has_underscore"])
    #expect(try rows(store, Reports.urlStructure, "encoded") == ["/percent%20encoded"])

    let long = try rows(store, Reports.urlStructure, "long")
    #expect(long.count == 1)
    #expect(long.first?.hasPrefix("/a-really-quite-long") == true)
}

/// Trailing slashes are deliberately preserved by the normaliser because they
/// can be significant, which is exactly why a site serving both forms is worth
/// flagging: both are reachable and they are duplicates of each other.
@Test func urlReportFindsTrailingSlashPairsInBothDirections() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.urlStructure, "slashPair") == ["/pair", "/pair/"])
}

@Test func urlReportFindsMixedWWWInBothDirections() throws {
    let store = try ReportFixture.make()
    let mixed = try rows(store, Reports.urlStructure, "mixedWWW")
    #expect(mixed.contains("/on-www"), "the www host sees its non-www twin")
    #expect(mixed.count > 1, "and every non-www page sees the www host")
}

@Test func anchorTextReportIsKeyedOnTheLinkTarget() throws {
    let store = try ReportFixture.make()
    let all = try rows(store, Reports.anchorText, "all")
    #expect(all.contains("/anchor-many"))
    #expect(!all.contains("/queued"), "a URL nothing links to is not in this tab")

    #expect(try rows(store, Reports.anchorText, "empty") == ["/anchor-empty"])
    #expect(try rows(store, Reports.anchorText, "generic") == ["/anchor-generic"])
    #expect(try rows(store, Reports.anchorText, "inconsistent") == ["/anchor-many"])
}

/// A whitespace-only anchor is as useless as an absent one and must count as empty.
@Test func aWhitespaceOnlyAnchorCountsAsMissing() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.anchorText, "empty").contains("/anchor-empty"))
}

@Test func canonicalsReportNowFindsMultipleDeclarations() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.canonicals, "multiple") == ["/canon-multiple"])
    #expect(try rows(store, Reports.canonicals, "missing") == ["/canon-missing"])
}

@Test func headingsReportNowFindsDuplicateAndOverlongH2s() throws {
    let store = try ReportFixture.make()
    // Every fixture page gets a path-derived H2, so nothing is duplicated yet —
    // the filter must return nothing rather than everything.
    #expect(try rows(store, Reports.headings, "duplicateH2").isEmpty)
    #expect(try rows(store, Reports.headings, "longH2") == ["/long-h2"])
}


// MARK: - Wave 2 reports

@Test func socialReportFindsMissingShareTags() throws {
    let store = try ReportFixture.make()
    let none = try rows(store, Reports.social, "noOG")
    #expect(none.contains("/social-none"))
    #expect(!none.contains("/social-full"))

    #expect(try rows(store, Reports.social, "hasAMP") == ["/social-full"])
    #expect(try rows(store, Reports.social, "ogTitleDiffers") == ["/social-og-differs"])

    let noImage = try rows(store, Reports.social, "noOGImage")
    #expect(noImage.contains("/social-none"))
    #expect(!noImage.contains("/social-full"))
}

@Test func structuredDataReportSeparatesFormats() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.structuredData, "none") == ["/schema-none"])
    #expect(try rows(store, Reports.structuredData, "mixedFormats") == ["/schema-mixed"])

    let microdata = try rows(store, Reports.structuredData, "microdata")
    #expect(microdata == ["/schema-mixed"])
    #expect(try rows(store, Reports.structuredData, "jsonLD").contains("/schema-product"))
    #expect(try rows(store, Reports.structuredData, "rdfa").isEmpty)
}

/// The tab exists to answer "what is in a paginated set", so a page with
/// neither rel does not belong in it at all.
@Test func paginationReportOnlyContainsPaginatedPages() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.pagination, "all") == ["/page/1", "/page/2", "/page/3"])
    #expect(try rows(store, Reports.pagination, "firstPage") == ["/page/1"])
    #expect(try rows(store, Reports.pagination, "lastPage") == ["/page/3"])
}

/// A paginated page that canonicalises to page one removes itself, and
/// everything only reachable through it, from the index.
@Test func paginationReportFlagsPagesCanonicalisedAway() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.pagination, "canonicalised") == ["/page/3"])
}

@Test func securityReportFindsMissingHeaders() throws {
    let store = try ReportFixture.make()
    for (filter, header) in [("noHSTS", "HSTS"), ("noCSP", "CSP"),
                             ("noNosniff", "nosniff"), ("noFrameOptions", "frame options"),
                             ("noReferrerPolicy", "referrer policy")] {
        let found = try rows(store, Reports.security, filter)
        #expect(found.contains("/no-security-headers"), "\(header) not flagged")
        #expect(!found.contains("/"), "the home page sets \(header) and must not be flagged")
    }
}

/// A response with no headers recorded at all — a HEAD check, or a row written
/// before v5 — has to count as missing rather than silently passing.
@Test func aResponseWithNoRecordedHeadersCountsAsMissing() throws {
    let store = try ReportFixture.make()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            UPDATE responses SET headers_json = NULL
            WHERE url_id = (SELECT id FROM urls WHERE path = '/one-inlink')
            """)
    }
    #expect(try rows(store, Reports.security, "noHSTS").contains("/one-inlink"))
}

@Test func internalReportFlagsPagesWithNoTracking() throws {
    let store = try ReportFixture.make()
    let untracked = try rows(store, Reports.internalURLs, "noAnalytics")
    #expect(untracked.contains("/no-tracking"))
    #expect(!untracked.contains("/"), "the home page has a tag and must not be flagged")
    #expect(!untracked.contains("/gone"), "a 404 is not a tracking problem")
}

@Test func imagesReportFlagsUndeclaredDimensions() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.images, "noDimensions") == ["/img/big.png"])
}

/// An image referenced by two pages, declared with a size on one and without on
/// the other, must show the declared size rather than whichever row the database
/// happened to return first.
@Test func theDeclaredSizeColumnIsDeterministic() throws {
    let store = try ReportFixture.make()
    try store.dbQueue.write { db in
        // /img/big.png is referenced once, with no dimensions. Add a second
        // reference that does declare them.
        try db.execute(sql: """
            INSERT INTO images (url_id, src_url_id, alt, width, height)
            SELECT (SELECT id FROM urls WHERE path = '/dupe-a'),
                   (SELECT id FROM urls WHERE path = '/img/big.png'), 'big', 1200, 630
            """)
    }
    let ids = try store.ids(for: Reports.images,
                            filter: Reports.images.defaultFilter, sortBy: nil, ascending: true)
    let big = try store.rows(ids: ids, columns: Reports.images.columns)
        .first { $0.cells[0]?.hasSuffix("big.png") == true }
    let column = Reports.images.columns.firstIndex { $0.id == "dimensions" }!
    #expect(big?.cells[column] == "1200 x 630")

    // And the page that omitted them is still flagged.
    #expect(try ReportFixture.paths(store, store.ids(
        for: Reports.images,
        filter: Reports.images.filters.first { $0.id == "noDimensions" }!,
        sortBy: nil, ascending: true)) == ["/img/big.png"])
}

// MARK: - Wave 6 reports

@Test func urlReportFindsTrackingAndSessionParameters() throws {
    let store = try ReportFixture.make()
    // `paths` reads urls.path, which is the path alone — the query lives in the
    // URL, exactly as a real crawl stores it.
    #expect(try rows(store, Reports.urlStructure, "trackingParams") == ["/tracked"])
    #expect(try rows(store, Reports.urlStructure, "sessionParams") == ["/session"])
    #expect(try rows(store, Reports.urlStructure, "manyParams") == ["/many"])
}

/// The pair that says an HTTPS migration is unfinished: the same path reachable
/// on both schemes.
@Test func urlReportFindsAnUnfinishedHTTPSMigration() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.urlStructure, "httpWithHTTPSTwin") == ["/both"])
}

@Test func securityReportReadsCookieFlagsFromStoredHeaders() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.security, "setsCookies")
            == ["/cookie-strict", "/cookie-loose"])
    #expect(try rows(store, Reports.security, "cookieNoSecure") == ["/cookie-loose"])
    #expect(try rows(store, Reports.security, "cookieNoHttpOnly") == ["/cookie-loose"])
    #expect(try rows(store, Reports.security, "cookieNoSameSite") == ["/cookie-loose"])
}

@Test func contentReportFindsPagesThatAreMostlyMarkup() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.content, "lowTextRatio") == ["/mostly-markup"])
}

/// Before skip reasons existed, a row said "skipped" and nothing said why — so a
/// crawl that quietly stopped short looked exactly like one that had finished.
@Test func crawlabilityReportSaysWhyEachURLWasNotCrawled() throws {
    let store = try ReportFixture.make()
    #expect(try rows(store, Reports.crawlability, "robots") == ["/robots-blocked"])
    #expect(try rows(store, Reports.crawlability, "depth") == ["/too-deep"])
    #expect(try rows(store, Reports.crawlability, "cap") == ["/over-cap"])

    let all = try rows(store, Reports.crawlability, "all")
    #expect(all.isSuperset(of: ["/robots-blocked", "/too-deep", "/over-cap"]))
    #expect(!all.contains("/"), "a crawled page is not in the crawlability tab")
}
