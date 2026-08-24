import Foundation
import GRDB
import Testing
@testable import KodaCore

/// The entire argument for measuring rather than counting: these two strings are
/// the same length and nowhere near the same width.
@Test func equalCharacterCountsCanHaveVeryDifferentWidths() throws {
    let wide = try #require(SERPMetrics.titleWidth(String(repeating: "W", count: 20)))
    let narrow = try #require(SERPMetrics.titleWidth(String(repeating: "i", count: 20)))
    #expect(wide > narrow * 3, "\(wide) vs \(narrow)")
}

@Test func widthGrowsWithTheText() throws {
    let short = try #require(SERPMetrics.titleWidth("Short"))
    let long = try #require(SERPMetrics.titleWidth("Short but rather longer than before"))
    #expect(long > short)
}

@Test func emptyOrAbsentTextHasNoWidth() {
    #expect(SERPMetrics.titleWidth(nil) == nil)
    #expect(SERPMetrics.titleWidth("") == nil)
}

/// A description is measured at a smaller size than a title, so the same string
/// is narrower as a description.
@Test func descriptionsAreMeasuredAtTheirOwnSize() throws {
    let text = "The same sentence measured two ways."
    let asTitle = try #require(SERPMetrics.titleWidth(text))
    let asDescription = try #require(SERPMetrics.descriptionWidth(text))
    #expect(asDescription < asTitle)
}

@Test func nonLatinTextIsMeasuredRatherThanRejected() throws {
    #expect(SERPMetrics.titleWidth("日本語のタイトル") != nil)
    #expect(SERPMetrics.titleWidth("Ünïcödé äccénts") != nil)
}

// MARK: - Through the write path

@MainActor
@Test func pixelWidthsArePersistedAndQueryable() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://serp.test/")
    config.workers = 1
    try store.initializeCrawl(config: config, startedAt: Date())
    try await store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://serp.test/', x'01', 'serp.test', '/', 0, 1, 0, 1)
            """)
    }

    var facts = PageFacts()
    // Comfortably past the title threshold when measured.
    facts.title = String(repeating: "Wide title ", count: 8)
    facts.metaDescription = "A short description."
    let result = CrawlResult(
        urlID: 1, url: URLNormalizer.normalize("https://serp.test/", relativeTo: nil)!,
        depth: 0, status: 200, errorKind: nil, contentType: "text/html; charset=utf-8",
        contentLength: 10, responseTimeMs: 1, redirectTarget: nil, bodyGz: nil,
        xRobotsTag: nil, facts: facts)
    try store.write(results: [result], config: config, now: Date())

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: "SELECT title_pixels, meta_description_pixels FROM page_facts")
    }
    let titlePixels = try #require(row?["title_pixels"] as Int?)
    #expect(titlePixels > Int(SERPMetrics.titleLimit))
    #expect((row?["meta_description_pixels"] as Int? ?? 0) > 0)

    let truncated = try store.ids(
        for: Reports.serp,
        filter: Reports.serp.filters.first { $0.id == "titleTruncated" }!,
        sortBy: nil, ascending: true)
    #expect(truncated.count == 1)
}
