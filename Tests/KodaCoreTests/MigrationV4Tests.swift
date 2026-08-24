import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Two gaps the coverage audit found, both of which make a page look clean when
/// it is not: only the *first* canonical was captured, so conflicting canonicals
/// were invisible; and H2s were counted but never stored, so no duplicate or
/// length check on them was possible.
@Test func v4AddsCanonicalCountAndH2Text() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let columns = try store.dbQueue.read { db in
        try db.columns(in: "page_facts").map(\.name)
    }
    #expect(columns.contains("canonical_count"))
    #expect(columns.contains("h2"))
}

@Test func v4DefaultsCanonicalCountForExistingRows() throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://m4.test/', x'01', 'm4.test', '/', 0, 1, 0, 2)
            """)
        try db.execute(sql: "INSERT INTO page_facts (url_id) VALUES (?)",
                       arguments: [db.lastInsertedRowID])
    }
    let count = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT canonical_count FROM page_facts")
    }
    #expect(count == 0, "a row that predates the column must read as zero, not null")
}

// MARK: - Parser

@Test func theParserCountsEveryCanonicalNotJustTheFirst() throws {
    let html = """
        <html><head>
        <link rel="canonical" href="https://a.test/one">
        <link rel="canonical" href="https://a.test/two">
        </head><body></body></html>
        """
    let facts = try SwiftSoupParser().parse(html: html)
    #expect(facts.canonicalCount == 2)
    #expect(facts.canonical == "https://a.test/one", "the first still wins for the stored target")
}

@Test func aSingleCanonicalCountsAsOne() throws {
    let facts = try SwiftSoupParser().parse(
        html: "<html><head><link rel=\"canonical\" href=\"/x\"></head><body></body></html>")
    #expect(facts.canonicalCount == 1)
}

@Test func noCanonicalCountsAsZero() throws {
    let facts = try SwiftSoupParser().parse(html: "<html><head></head><body></body></html>")
    #expect(facts.canonicalCount == 0)
    #expect(facts.canonical == nil)
}

@Test func theParserCapturesTheFirstH2Text() throws {
    let facts = try SwiftSoupParser().parse(
        html: "<html><body><h2>First heading</h2><h2>Second heading</h2></body></html>")
    #expect(facts.h2 == "First heading")
    #expect(facts.h2Count == 2)
}

@Test func aPageWithNoH2HasNoH2Text() throws {
    let facts = try SwiftSoupParser().parse(html: "<html><body><h1>Only an h1</h1></body></html>")
    #expect(facts.h2 == nil)
    #expect(facts.h2Count == 0)
}

/// The new columns have to survive the write path, not just the parse.
@Test func canonicalCountAndH2ArePersisted() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://persist.test/")
    config.workers = 1
    try store.initializeCrawl(config: config, startedAt: Date())
    try await store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://persist.test/', x'0A', 'persist.test', '/', 0, 1, 0, 1)
            """)
    }

    var facts = PageFacts()
    facts.canonicalCount = 3
    facts.h2 = "A stored subheading"
    facts.h2Count = 3
    let result = CrawlResult(
        urlID: 1, url: URLNormalizer.normalize("https://persist.test/", relativeTo: nil)!,
        depth: 0, status: 200, errorKind: nil, contentType: "text/html",
        contentLength: 10, responseTimeMs: 1, redirectTarget: nil, bodyGz: nil,
        xRobotsTag: nil, facts: facts)
    try store.write(results: [result], config: config, now: Date())

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: "SELECT canonical_count, h2 FROM page_facts WHERE url_id = 1")
    }
    #expect(row?["canonical_count"] == 3)
    #expect(row?["h2"] == "A stored subheading")
}
