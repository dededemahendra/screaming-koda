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

    let batch = try store.claimNext(limit: 10)
    #expect(batch.count == 2)
    #expect(try store.claimNext(limit: 10).isEmpty)
    #expect(try store.urlCounts().inFlight == 2)
}

@Test func claimReturnsShallowestFirst() throws {
    let store = try makeStore()
    _ = try store.insertURLIfNew(u("http://example.com/deep"), depth: 5, isInternal: true, discoveredAt: Date())
    _ = try store.insertURLIfNew(u("http://example.com/shallow"), depth: 0, isInternal: true, discoveredAt: Date())
    let batch = try store.claimNext(limit: 1)
    #expect(batch.first?.url.path == "/shallow")
}

@Test func markDoneRemovesFromFrontier() throws {
    let store = try makeStore()
    let id = try store.insertURLIfNew(u("http://example.com/a"), depth: 0, isInternal: true, discoveredAt: Date())
    _ = try store.claimNext(limit: 10)
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
    _ = try store.claimNext(limit: 10)

    let reset = try store.resetInFlight()

    #expect(reset == 2)
    #expect(try store.urlCounts().queued == 2)
    #expect(try store.claimNext(limit: 10).count == 2)
}

@Test func frontierItemCarriesDepth() throws {
    let store = try makeStore()
    _ = try store.insertURLIfNew(u("http://example.com/a"), depth: 4, isInternal: true, discoveredAt: Date())
    #expect(try store.claimNext(limit: 1).first?.depth == 4)
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

    let batch = try store.claimNext(limit: 10)

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
