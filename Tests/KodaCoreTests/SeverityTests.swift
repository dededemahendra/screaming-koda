import Testing
@testable import KodaCore

/// Every issue filter and the band it belongs to. Kept here rather than derived
/// from `Reports.all` on purpose: a test that reads the source it is checking
/// asserts nothing. Adding an issue filter without adding it here fails.
private let expectedBands: [String: Severity] = [
    // Breaks indexing — the page cannot rank, or the crawler could not reach it.
    "internal.nonIndexable": .breaksIndexing,
    "external.broken": .breaksIndexing,
    "responseCodes.clientError": .breaksIndexing,
    "responseCodes.serverError": .breaksIndexing,
    "responseCodes.transportError": .breaksIndexing,
    "responseCodes.viaChain": .breaksIndexing,
    "responseCodes.loop": .breaksIndexing,
    "canonicals.canonicalised": .breaksIndexing,
    "canonicals.toNon200": .breaksIndexing,
    "canonicals.multiple": .breaksIndexing,
    "directives.noindex": .breaksIndexing,
    "directives.conflict": .breaksIndexing,
    "hreflang.non200": .breaksIndexing,
    "content.duplicate": .breaksIndexing,
    "content.nearDuplicate": .breaksIndexing,
    "sitemap.orphans": .breaksIndexing,
    "sitemap.nonIndexable": .breaksIndexing,
    "sitemap.uncrawled": .breaksIndexing,
    "resources.broken": .breaksIndexing,
    "javascript.contentNeedsJS": .breaksIndexing,
    "javascript.emptyWithoutJS": .breaksIndexing,
    "crawlability.robots": .breaksIndexing,
    "crawlability.cap": .breaksIndexing,
    "crawlability.redirects": .breaksIndexing,
    "crawlability.sitemapBlocked": .breaksIndexing,
    "externalData.trafficButNonIndexable": .breaksIndexing,

    // Costs clicks — indexed, but underperforming in results.
    "titles.missing": .costsClicks,
    "titles.duplicate": .costsClicks,
    "titles.over60": .costsClicks,
    "titles.under30": .costsClicks,
    "titles.multiple": .costsClicks,
    "titles.sameAsH1": .costsClicks,
    "titles.tooWide": .costsClicks,
    "metaDescription.missing": .costsClicks,
    "metaDescription.duplicate": .costsClicks,
    "metaDescription.over155": .costsClicks,
    "metaDescription.under70": .costsClicks,
    "metaDescription.multiple": .costsClicks,
    "metaDescription.tooWide": .costsClicks,
    "content.thin": .costsClicks,
    "content.veryThin": .costsClicks,
    "content.empty": .costsClicks,
    "performance.slowLCP": .costsClicks,
    "performance.slowTTFB": .costsClicks,
    "performance.slowLoad": .costsClicks,
    "serp.titleTruncated": .costsClicks,
    "serp.descTruncated": .costsClicks,
    "serp.titleShort": .costsClicks,
    "serp.noSnippet": .costsClicks,
    "externalData.impressionsNoClicks": .costsClicks,
    "externalData.noTraffic": .costsClicks,
    "externalData.sessionsButThin": .costsClicks,
    "externalData.cwvFailing": .costsClicks,
    "externalData.slowLighthouse": .costsClicks,

    // Hygiene — worth fixing, not costing traffic today.
    "internal.noAnalytics": .hygiene,
    "headings.missingH1": .hygiene,
    "headings.duplicateH1": .hygiene,
    "headings.multipleH1": .hygiene,
    "headings.longH1": .hygiene,
    "headings.missingH2": .hygiene,
    "headings.duplicateH2": .hygiene,
    "headings.longH2": .hygiene,
    "images.missingAlt": .hygiene,
    "images.longAlt": .hygiene,
    "images.over100kb": .hygiene,
    "images.noDimensions": .hygiene,
    "canonicals.missing": .hygiene,
    "directives.nofollow": .hygiene,
    "directives.noarchive": .hygiene,
    "hreflang.noReturn": .hygiene,
    "hreflang.noXDefault": .hygiene,
    "pageDepth.deep": .hygiene,
    "pageDepth.singleInlink": .hygiene,
    "content.lowTextRatio": .hygiene,
    "urls.insecure": .hygiene,
    "urls.mixedWWW": .hygiene,
    "urls.trackingParams": .hygiene,
    "urls.sessionParams": .hygiene,
    "urls.manyParams": .hygiene,
    "urls.httpWithHTTPSTwin": .hygiene,
    "urls.httpNoRedirect": .hygiene,
    "urls.long": .hygiene,
    "urls.uppercase": .hygiene,
    "urls.underscore": .hygiene,
    "urls.slashPair": .hygiene,
    "anchorText.empty": .hygiene,
    "anchorText.generic": .hygiene,
    "anchorText.inconsistent": .hygiene,
    "social.noOG": .hygiene,
    "social.noOGImage": .hygiene,
    "social.noOGTitle": .hygiene,
    "social.noTwitterCard": .hygiene,
    "structuredData.none": .hygiene,
    "structuredData.mixedFormats": .hygiene,
    "pagination.canonicalised": .hygiene,
    "pagination.noindexed": .hygiene,
    "security.noHSTS": .hygiene,
    "security.noCSP": .hygiene,
    "security.noNosniff": .hygiene,
    "security.noFrameOptions": .hygiene,
    "security.noReferrerPolicy": .hygiene,
    "security.insecure": .hygiene,
    "security.cookieNoSecure": .hygiene,
    "security.cookieNoHttpOnly": .hygiene,
    "security.cookieNoSameSite": .hygiene,
    "extraction.none": .hygiene,
    "sitemap.notInSitemap": .hygiene,
    "resources.over100kb": .hygiene,
    "resources.insecure": .hygiene,
    "javascript.errors": .hygiene,
    "javascript.slow": .hygiene,
    "performance.manyRequests": .hygiene,
]

private var declaredBands: [String: Severity] {
    var out: [String: Severity] = [:]
    for report in Reports.all {
        for filter in report.filters {
            if let severity = filter.severity { out["\(report.id).\(filter.id)"] = severity }
        }
    }
    return out
}

@Test func everyIssueFilterDeclaresTheBandTheTableSays() {
    #expect(declaredBands == expectedBands)
}

/// Guards the inventory itself. A new report or filter that nobody banded shows
/// up here as a count mismatch before it shows up as an unranked row.
@Test func theInventoryIsTwentySixReportsAndOneHundredTwelveFindings() {
    let filters = Reports.all.flatMap(\.filters)
    #expect(Reports.all.count == 26)
    #expect(filters.count == 163)
    #expect(filters.filter { $0.severity != nil }.count == 112)
}

@Test func eachBandHoldsTheCountTheDesignAssigned() {
    let bands = Reports.all.flatMap(\.filters).compactMap(\.severity)
    #expect(bands.filter { $0 == .breaksIndexing }.count == 26)
    #expect(bands.filter { $0 == .costsClicks }.count == 28)
    #expect(bands.filter { $0 == .hygiene }.count == 58)
}

/// "All", "Success (2xx)" and "Redirection (3xx)" are navigation, not findings.
@Test func navigationFiltersCarryNoBand() {
    let internalReport = Reports.all.first { $0.id == "internal" }!
    #expect(internalReport.defaultFilter.severity == nil)
    let codes = Reports.all.first { $0.id == "responseCodes" }!
    #expect(codes.filters.first { $0.id == "success" }?.severity == nil)
    #expect(codes.filters.first { $0.id == "redirection" }?.severity == nil)
}

/// Declaration order is the order a person works through them, and `<` follows
/// it, so sorting a set of bands is the same thing as reading order.
@Test func bandsSortIntoWorkingOrder() {
    #expect(Severity.allCases == [.breaksIndexing, .costsClicks, .hygiene])
    #expect(Severity.breaksIndexing < Severity.costsClicks)
    #expect(Severity.costsClicks < Severity.hygiene)
    #expect([Severity.hygiene, .breaksIndexing, .costsClicks].sorted()
            == [.breaksIndexing, .costsClicks, .hygiene])
}

@Test func bandTitlesAreSentenceCase() {
    #expect(Severity.breaksIndexing.title == "Breaks indexing")
    #expect(Severity.costsClicks.title == "Costs clicks")
    #expect(Severity.hygiene.title == "Hygiene")
}
