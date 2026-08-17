import Foundation
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
