import Foundation
import GRDB
import Testing
@testable import KodaCore

private func makeStore() throws -> Store {
    let s = try Store(path: nil)
    try s.migrate()
    return s
}

private func u(_ s: String) -> NormalizedURL {
    URLNormalizer.normalize(s, relativeTo: nil)!
}

@Test func insertReturnsSameIDForDuplicateURL() throws {
    let store = try makeStore()
    let first = try store.insertURLIfNew(u("http://example.com/a"), depth: 0, isInternal: true, discoveredAt: Date())
    let second = try store.insertURLIfNew(u("http://example.com/a"), depth: 3, isInternal: true, discoveredAt: Date())
    #expect(first == second)
    #expect(try store.urlCounts().total == 1)
}

@Test func claimFlipsStateAndIsNotReturnedTwice() throws {
    let store = try makeStore()
    _ = try store.insertURLIfNew(u("http://example.com/a"), depth: 0, isInternal: true, discoveredAt: Date())
    _ = try store.insertURLIfNew(u("http://example.com/b"), depth: 1, isInternal: true, discoveredAt: Date())

    let batch = try store.claimNext(limit: 10, maxPerHost: 10)
    #expect(batch.count == 2)
    #expect(try store.claimNext(limit: 10, maxPerHost: 10).isEmpty)
    #expect(try store.urlCounts().inFlight == 2)
}

@Test func claimReturnsShallowestFirst() throws {
    let store = try makeStore()
    _ = try store.insertURLIfNew(u("http://example.com/deep"), depth: 5, isInternal: true, discoveredAt: Date())
    _ = try store.insertURLIfNew(u("http://example.com/shallow"), depth: 0, isInternal: true, discoveredAt: Date())
    let batch = try store.claimNext(limit: 1, maxPerHost: 10)
    #expect(batch.first?.url.path == "/shallow")
}

@Test func markDoneRemovesFromFrontier() throws {
    let store = try makeStore()
    let id = try store.insertURLIfNew(u("http://example.com/a"), depth: 0, isInternal: true, discoveredAt: Date())
    _ = try store.claimNext(limit: 10, maxPerHost: 10)
    try store.markDone(id)
    let counts = try store.urlCounts()
    #expect(counts.done == 1)
    #expect(counts.inFlight == 0)
    #expect(counts.queued == 0)
}

@Test func resetInFlightRequeuesInterruptedURLs() throws {
    let store = try makeStore()
    _ = try store.insertURLIfNew(u("http://example.com/a"), depth: 0, isInternal: true, discoveredAt: Date())
    _ = try store.insertURLIfNew(u("http://example.com/b"), depth: 0, isInternal: true, discoveredAt: Date())
    _ = try store.claimNext(limit: 10, maxPerHost: 10)

    let reset = try store.resetInFlight()

    #expect(reset == 2)
    #expect(try store.urlCounts().queued == 2)
    #expect(try store.claimNext(limit: 10, maxPerHost: 10).count == 2)
}

@Test func frontierItemCarriesDepth() throws {
    let store = try makeStore()
    _ = try store.insertURLIfNew(u("http://example.com/a"), depth: 4, isInternal: true, discoveredAt: Date())
    #expect(try store.claimNext(limit: 1, maxPerHost: 10).first?.depth == 4)
}

@Test func claimNextMarksUnrenormalizableRowSkippedInsteadOfStranding() throws {
    let store = try makeStore()
    let goodID = try store.insertURLIfNew(u("http://example.com/a"), depth: 0, isInternal: true, discoveredAt: Date())

    // Write a row directly, bypassing NormalizedURL/insertURLIfNew, whose stored
    // `url` string cannot be re-normalized (URLNormalizer.normalize returns nil
    // for an empty string). This simulates a future normalizer change or corrupt
    // data making a previously-valid stored URL unparseable.
    let badID = try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                VALUES (?,?,?,?,?,?,?,0)
                """,
            arguments: ["", Data(repeating: 9, count: 32), "bad", "/bad", 0, 1, 0.0]
        )
        return db.lastInsertedRowID
    }

    let batch = try store.claimNext(limit: 10, maxPerHost: 10)

    // The malformed row is not handed back to the caller...
    #expect(batch.map(\.id) == [goodID])
    #expect(!batch.contains { $0.id == badID })

    // ...because it was marked skipped (state 3) in the same transaction, not
    // left behind at state 1 (in-flight) with no way to ever leave that state.
    let badState = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT state FROM urls WHERE id = ?", arguments: [badID])
    }
    #expect(badState == 3)

    // Only the legitimately-claimed valid row counts as in-flight — the bad row
    // does not inflate it or occupy it permanently.
    #expect(try store.urlCounts().inFlight == 1)

    // Draining the valid row proves nothing was left stranded: in-flight returns to 0.
    try store.markDone(goodID)
    #expect(try store.urlCounts().inFlight == 0)
}

// MARK: - seedFromSitemap

/// Before this, `seedFromSitemap`'s INSERT omitted `skip_reason` entirely, so
/// every URL it declined to queue landed in state 3 with no reason recorded —
/// unlike `discover()`, which has always said why. A sitemap listing another
/// site's URLs (e.g. because the seed redirected off-host) then looked
/// identical, in the Crawlability report, to hundreds of real indexing
/// failures, because nothing distinguished "external" from "blocked".
@Test func seedFromSitemapRecordsWhyEachURLWasNotQueued() throws {
    let store = try makeStore()
    let config = CrawlConfig(seedURL: "https://example.com/")
    let offHost = u("https://other.test/a")
    let internalURL = u("https://example.com/b")

    let queued = try store.seedFromSitemap([offHost, internalURL], config: config, now: Date())
    #expect(queued == 1, "only the internal URL is ever crawlable from this seed")

    let (offHostReason, internalReason) = try store.dbQueue.read { db in
        (try String.fetchOne(db, sql: "SELECT skip_reason FROM urls WHERE path = '/a'"),
         try String.fetchOne(db, sql: "SELECT skip_reason FROM urls WHERE path = '/b'"))
    }
    #expect(offHostReason == "external", "a sitemap entry on another host was never this crawl's to fetch")
    #expect(internalReason == nil, "the internal, unfiltered URL was queued, so it has nothing to explain")
}

// MARK: - seedRedirectHost

private func seededStoreForRedirect(seedURL: String) throws -> (Store, CrawlConfig, Int64, NormalizedURL) {
    let store = try makeStore()
    let config = CrawlConfig(seedURL: seedURL)
    try store.initializeCrawl(config: config, startedAt: Date())
    let seed = u(seedURL)
    let id = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())
    return (store, config, id, seed)
}

@Test func seedRedirectHostFindsWhereAnOffHostSeedWentTo() throws {
    let (store, config, id, seed) = try seededStoreForRedirect(seedURL: "https://old.test/")
    let destination = u("https://new.test/")
    let result = CrawlResult(urlID: id, url: seed, depth: 0, status: 301, errorKind: nil,
                             contentType: nil, contentLength: nil, responseTimeMs: 1,
                             redirectTarget: destination, bodyGz: nil, xRobotsTag: nil, facts: nil)
    _ = try store.write(results: [result], config: config, now: Date())

    #expect(try store.seedRedirectHost(seedHost: "old.test") == "new.test")
}

@Test func seedRedirectHostIsNilForASameHostRedirect() throws {
    let (store, config, id, seed) = try seededStoreForRedirect(seedURL: "https://old.test/a")
    let destination = u("https://old.test/b")
    let result = CrawlResult(urlID: id, url: seed, depth: 0, status: 301, errorKind: nil,
                             contentType: nil, contentLength: nil, responseTimeMs: 1,
                             redirectTarget: destination, bodyGz: nil, xRobotsTag: nil, facts: nil)
    _ = try store.write(results: [result], config: config, now: Date())

    #expect(try store.seedRedirectHost(seedHost: "old.test") == nil)
}

@Test func seedRedirectHostIsNilWhenTheSeedDoesNotRedirect() throws {
    let (store, config, id, seed) = try seededStoreForRedirect(seedURL: "https://old.test/")
    let result = CrawlResult(urlID: id, url: seed, depth: 0, status: 200, errorKind: nil,
                             contentType: "text/html", contentLength: 10, responseTimeMs: 1,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: nil)
    _ = try store.write(results: [result], config: config, now: Date())

    #expect(try store.seedRedirectHost(seedHost: "old.test") == nil)
}

@Test func seedRedirectHostIsNilWithNoSeedRowAtAll() throws {
    let store = try makeStore()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://old.test/"), startedAt: Date())
    #expect(try store.seedRedirectHost(seedHost: "old.test") == nil)
}
