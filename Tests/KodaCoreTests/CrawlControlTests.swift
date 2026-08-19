import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Counts fetches so a test can assert that pausing actually stops the network.
private actor FetchCounter {
    private(set) var count = 0
    func bump() { count += 1 }
    func value() -> Int { count }
}

/// A site of `pageCount` pages, each linking to the next, with a small delay per
/// fetch so pause has a realistic window in which to take effect.
private struct SlowSiteClient: HTTPClient {
    let counter: FetchCounter
    let pageCount: Int

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        await counter.bump()
        try? await Task.sleep(nanoseconds: 5_000_000)

        let index = Int(url.split(separator: "/").last.flatMap { Int($0) } ?? 0)
        let next = index + 1
        let body = next < pageCount
            ? "<html><head><title>P\(index)</title></head><body><a href=\"/p/\(next)\">next</a></body></html>"
            : "<html><head><title>P\(index)</title></head><body>end</body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

private func makeEngine(pageCount: Int = 200) throws -> (CrawlEngine, Store, FetchCounter, CrawlConfig) {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://slow.test/p/0")
    config.workers = 1
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize(config.seedURL, relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())
    let counter = FetchCounter()
    let engine = CrawlEngine(store: store, client: SlowSiteClient(counter: counter, pageCount: pageCount),
                             parser: SwiftSoupParser(), config: config)
    return (engine, store, counter, config)
}

/// Polls until `condition` holds or the deadline passes. Returns whether it held.
private func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

@Test func engineStartsIdleAndRunsToFinished() async throws {
    let (engine, store, _, _) = try makeEngine(pageCount: 3)
    #expect(await engine.state == .idle)
    try await engine.run(onProgress: nil)
    #expect(await engine.state == .finished)

    let finishedAt = try await store.dbQueue.read { db in
        try Double.fetchOne(db, sql: "SELECT finished_at FROM crawl_meta WHERE id = 1")
    }
    #expect(finishedAt != nil, "a completed crawl records finished_at")
}

@Test func pauseStopsFetchingAndResumeContinues() async throws {
    let (engine, _, counter, _) = try makeEngine()
    let task = Task { try await engine.run(onProgress: nil) }

    #expect(await waitUntil { await counter.value() >= 3 }, "crawl should get going")
    await engine.pause()
    #expect(await engine.state == .paused)

    let atPause = await counter.value()
    try await Task.sleep(nanoseconds: 400_000_000)
    let afterWait = await counter.value()

    #expect(afterWait - atPause <= 1, "at most the in-flight batch finishes; got \(afterWait - atPause)")

    await engine.resume()
    #expect(await engine.state == .running)
    #expect(await waitUntil { await counter.value() > afterWait }, "fetching resumes")

    await engine.cancel()
    _ = try? await task.value
}

@Test func cancelStopsTheCrawlAndLeavesItUnfinished() async throws {
    let (engine, store, counter, _) = try makeEngine()
    let task = Task { try await engine.run(onProgress: nil) }

    #expect(await waitUntil { await counter.value() >= 3 })
    await engine.cancel()
    _ = try? await task.value

    #expect(await engine.state == .cancelled)

    let finishedAt = try await store.dbQueue.read { db in
        try Double.fetchOne(db, sql: "SELECT finished_at FROM crawl_meta WHERE id = 1")
    }
    #expect(finishedAt == nil, "a cancelled crawl is not finished")
}

@Test func cancelKeepsResultsAlreadyFetched() async throws {
    let (engine, store, counter, _) = try makeEngine()
    let task = Task { try await engine.run(onProgress: nil) }

    #expect(await waitUntil { await counter.value() >= 5 })
    await engine.cancel()
    _ = try? await task.value

    let written = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM responses") ?? 0
    }
    #expect(written >= 3, "fetched pages are written, never discarded; got \(written)")
}

@Test func cancelLeavesNothingStrandedInFlight() async throws {
    let (engine, store, counter, _) = try makeEngine()
    let task = Task { try await engine.run(onProgress: nil) }

    #expect(await waitUntil { await counter.value() >= 3 })
    await engine.cancel()
    _ = try? await task.value

    #expect(try store.urlCounts().inFlight == 0, "claimed-but-unproduced rows return to the queue")
}

@Test func cancelledCrawlCanBeRestartedAndContinues() async throws {
    let (engine, store, counter, config) = try makeEngine(pageCount: 12)
    let task = Task { try await engine.run(onProgress: nil) }
    #expect(await waitUntil { await counter.value() >= 3 })
    await engine.cancel()
    _ = try? await task.value

    let afterCancel = try store.urlCounts().done

    let counter2 = FetchCounter()
    let engine2 = CrawlEngine(store: store, client: SlowSiteClient(counter: counter2, pageCount: 12),
                              parser: SwiftSoupParser(), config: config)
    try await engine2.run(onProgress: nil)

    #expect(try store.urlCounts().done > afterCancel, "restarting continues where it stopped")
    #expect(await engine2.state == .finished)
}

@Test func pauseBeforeRunningIsIgnored() async throws {
    let (engine, _, _, _) = try makeEngine(pageCount: 2)
    await engine.pause()
    #expect(await engine.state == .idle, "pausing an idle engine does nothing")
    try await engine.run(onProgress: nil)
    #expect(await engine.state == .finished)
}
