# M3a Implementation Plan — Complete Data and a Real Table

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make external links and images carry real status and size data, stop any one host being hammered, make the table sort by any column at any depth, and let a user resume a crawl instead of silently destroying it.

**Architecture:** Status-checked URLs reuse the existing frontier via a `check_only` flag rather than a second pipeline, inheriting batching, politeness, pause/cancel, and hop limits. Arbitrary-column sorting comes from a materialised ordered id list — row *N* is `ids[N]`, fetched by primary key — replacing `LIMIT`/`OFFSET` entirely.

**Tech Stack:** Swift 6.3, SwiftPM, GRDB 6.29.3, SQLite 3.51 (window functions verified available), SwiftUI + AppKit, swift-testing.

**Spec:** `docs/superpowers/specs/2026-08-20-m3a-data-and-table-design.md`

## Global Constraints

- **Swift tools version 6.0**, platform floor `.macOS(.v14)`. Command Line Tools only, no Xcode.
- **swift-testing is an explicit package dependency.** Its deprecation warning is EXPECTED and must remain the ONLY warning class. Never remove the dependency to silence it.
- **`KodaCore` must never import AppKit or SwiftUI.** Verify with `grep -rE 'import (AppKit|SwiftUI)' Sources/KodaCore` returning nothing.
- **Politeness is a hard default.** robots.txt respected, crawl-delay honoured, and from this milestone the per-host cap actually enforced.
- **A crawl never dies from a bad page.**
- **Fetched work is never discarded** — pause and cancel let the in-flight batch finish and be written.
- **Run every build and test command in the FOREGROUND.** Do not background them, do not use monitors, do not poll. `swift test` takes about a minute. If a build appears to hang for minutes, run `pgrep -fl swift-build` and kill any stale `--experimental-prepare-for-indexing` process holding the package lock. Multiple agents on earlier milestones lost hours to this.
- **swift-testing macro quirk:** `#expect(try ...)` may need an outer `try` and `#expect(await ...)` an outer `await` — the macro expands its operand eagerly. If an error points into `Testing.__checkValue`, hoist the call into a `let` first.
- **GRDB quirk:** `store.dbQueue.read { }` inside an `async` function needs `await`.
- **Swift 6 concurrency:** weak-capturing `self` a second time inside a nested `Task { @MainActor ... }` is rejected; unwrap once with `guard let self else { return }`. A test helper constructing AppKit views needs `@MainActor`.
- **Git identity is configured.** Plain `git commit`. Commit after every task.

---

### Task 1: Migration v3 — the `check_only` column and sort indexes

**Files:**
- Modify: `Sources/KodaCore/Store.swift`
- Create: `Tests/KodaCoreTests/MigrationV3Tests.swift`

**Interfaces:**
- Consumes: the existing `Store.migrator` with migrations `v1` and `v2-redirect-hops`
- Produces: `urls.check_only INTEGER NOT NULL DEFAULT 0`, plus indexes `idx_urls_depth` and `idx_urls_url`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/MigrationV3Tests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore

@Test func checkOnlyColumnExistsAndDefaultsToZero() throws {
    let store = try Store(path: nil)
    try store.migrate()

    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                VALUES (?,?,?,?,0,1,0,0)
                """,
            arguments: ["https://m3.test/", Data("h".utf8), "m3.test", "/"]
        )
        let value = try Int.fetchOne(db, sql: "SELECT check_only FROM urls WHERE url = 'https://m3.test/'")
        #expect(value == 0, "an existing-style insert must still work and default to 0")
    }
}

@Test func sortIndexesExist() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let indexes = try store.dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
    }
    #expect(indexes.contains("idx_urls_depth"))
    #expect(indexes.contains("idx_urls_url"))
}

@Test func migrationIsIdempotentAcrossAllVersions() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let before = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") ?? 0
    }
    try store.migrate()
    let after = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") ?? 0
    }
    #expect(before == after, "re-migrating must not add or drop schema objects")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MigrationV3`
Expected: FAIL — `no such column: check_only`.

- [ ] **Step 3: Add the migration**

In `Sources/KodaCore/Store.swift`, register a third migration after `v2-redirect-hops`:

```swift
        m.registerMigration("v3-check-only") { db in
            // Status-checked URLs (external links, images) reuse the frontier rather
            // than a second pipeline: this flag is what tells the engine to HEAD the
            // URL and skip parsing. The two indexes back the table's new sort columns.
            try db.execute(sql: """
                ALTER TABLE urls ADD COLUMN check_only INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX idx_urls_depth ON urls(depth);
                CREATE INDEX idx_urls_url ON urls(url);
                """)
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MigrationV3`
Expected: PASS, 3 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS. Every existing test migrates a database, so the whole suite is the regression net for a schema change.

- [ ] **Step 6: Commit**

```bash
git add Sources/KodaCore/Store.swift Tests/KodaCoreTests/MigrationV3Tests.swift
git commit -m "feat: v3 migration adds check_only column and sort indexes"
```

---

### Task 2: Host-diverse batches — the per-host cap finally enforced

Until now every request in a crawl went to the seed host, so the global worker count *was* the per-host count and `maxPerHost` could sit unused. Once we fetch external URLs that stops being true, and a page carrying 200 links to one domain would become 200 rapid requests to a stranger's server.

**Files:**
- Modify: `Sources/KodaCore/Store+Frontier.swift`
- Modify: `Sources/KodaCore/CrawlEngine.swift` (the `claimNext` call site only)
- Create: `Tests/KodaCoreTests/HostDiversityTests.swift`

**Interfaces:**
- Consumes: `Store.claimNext(limit:)`, `FrontierItem`
- Produces:
  - `FrontierItem` gains `public let checkOnly: Bool`
  - `Store.claimNext(limit: Int, maxPerHost: Int) throws -> [FrontierItem]` — the old single-argument form is replaced, not kept

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/HostDiversityTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore

@MainActor
private func storeWith(hosts: [(host: String, count: Int)]) throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        var n = 0
        for entry in hosts {
            for i in 0..<entry.count {
                n += 1
                try db.execute(
                    sql: """
                        INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                        VALUES (?,?,?,?,1,1,0,0)
                        """,
                    arguments: ["https://\(entry.host)/p/\(i)", Data("h\(n)".utf8), entry.host, "/p/\(i)"]
                )
            }
        }
    }
    return store
}

@MainActor
@Test func aBatchNeverExceedsMaxPerHost() throws {
    // 50 URLs on one host: without the cap a batch of 10 would be 10 requests to it.
    let store = try storeWith(hosts: [("crowded.test", 50)])
    let batch = try store.claimNext(limit: 10, maxPerHost: 3)
    #expect(batch.count == 3, "only maxPerHost URLs from a single host may be claimed at once")
}

@MainActor
@Test func batchesSpreadAcrossHosts() throws {
    let store = try storeWith(hosts: [("a.test", 20), ("b.test", 20), ("c.test", 20)])
    let batch = try store.claimNext(limit: 9, maxPerHost: 3)
    #expect(batch.count == 9)
    var perHost: [String: Int] = [:]
    for item in batch { perHost[item.url.host, default: 0] += 1 }
    #expect(perHost.count == 3, "all three hosts should appear, got \(perHost)")
    #expect(perHost.values.allSatisfy { $0 <= 3 }, "no host over the cap: \(perHost)")
}

@MainActor
@Test func repeatedClaimsEventuallyDrainACrowdedHost() throws {
    let store = try storeWith(hosts: [("crowded.test", 7)])
    var claimed = 0
    for _ in 0..<10 {
        let batch = try store.claimNext(limit: 10, maxPerHost: 3)
        if batch.isEmpty { break }
        claimed += batch.count
        for item in batch { try store.markDone(item.id) }
    }
    #expect(claimed == 7, "the cap throttles a host per batch, it does not strand its URLs")
}

@MainActor
@Test func frontierItemCarriesCheckOnly() throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, check_only)
                VALUES (?,?,?,?,1,0,0,0,1)
                """,
            arguments: ["https://ext.test/img.png", Data("hi".utf8), "ext.test", "/img.png"]
        )
    }
    let batch = try store.claimNext(limit: 10, maxPerHost: 5)
    #expect(batch.first?.checkOnly == true)
}

@MainActor
@Test func ordinaryURLsAreNotCheckOnly() throws {
    let store = try storeWith(hosts: [("a.test", 1)])
    let batch = try store.claimNext(limit: 10, maxPerHost: 5)
    #expect(batch.first?.checkOnly == false)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HostDiversity`
Expected: FAIL — `extra argument 'maxPerHost' in call`.

- [ ] **Step 3: Add `checkOnly` to FrontierItem**

In `Sources/KodaCore/Store+Frontier.swift`:

```swift
public struct FrontierItem: Sendable {
    public let id: Int64
    public let url: NormalizedURL
    public let depth: Int
    /// True when this URL is only to be status-checked (HEAD), never parsed —
    /// an external link or an image source.
    public let checkOnly: Bool
}
```

- [ ] **Step 4: Make claimNext host-diverse**

Replace the SELECT and the `FrontierItem` construction in `claimNext`. Everything else in the method — the UPDATE to state 1, the `setState(db, id:, state: 3)` for a URL that no longer re-normalises, the single `dbQueue.write` transaction — stays exactly as it is. That skip-marking is the frontier's guarantee that nothing strands in-flight; do not touch it.

```swift
    public func claimNext(limit: Int, maxPerHost: Int) throws -> [FrontierItem] {
        try dbQueue.write { db in
            // ROW_NUMBER() partitions the queue by host so one crowded host cannot
            // fill a batch. Requires SQLite 3.25+; macOS 14 ships 3.43+ and this
            // machine has 3.51.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, url, depth, check_only FROM (
                      SELECT id, url, depth, check_only, host,
                             ROW_NUMBER() OVER (PARTITION BY host ORDER BY depth ASC, id ASC) AS rn
                      FROM urls WHERE state = 0
                    )
                    WHERE rn <= ?
                    ORDER BY depth ASC, id ASC
                    LIMIT ?
                    """,
                arguments: [max(maxPerHost, 1), limit]
            )
            guard !rows.isEmpty else { return [] }
            let ids = rows.map { $0["id"] as Int64 }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(
                sql: "UPDATE urls SET state = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            var items: [FrontierItem] = []
            items.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["id"]
                if let normalized = URLNormalizer.normalize(row["url"], relativeTo: nil) {
                    items.append(FrontierItem(id: id, url: normalized, depth: row["depth"],
                                              checkOnly: (row["check_only"] as Int) != 0))
                } else {
                    try Self.setState(db, id: id, state: 3)
                }
            }
            return items
        }
    }
```

- [ ] **Step 5: Update the engine's call site**

In `Sources/KodaCore/CrawlEngine.swift`, the single `claimNext` call becomes:

```swift
                let batch = try store.claimNext(limit: batchSize, maxPerHost: config.maxPerHost)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter HostDiversity`
Expected: PASS, 5 tests.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS. `CrawlEngineTests`, `CrawlControlTests`, `RedirectChainTests`, and the end-to-end tests all drive `claimNext` and are the regression net.

- [ ] **Step 8: Commit**

```bash
git add Sources/KodaCore/Store+Frontier.swift Sources/KodaCore/CrawlEngine.swift Tests/KodaCoreTests/HostDiversityTests.swift
git commit -m "feat: host-diverse batches enforce the per-host concurrency cap"
```

---

### Task 3: Status-check fetching — HEAD, with a GET fallback

**Files:**
- Modify: `Sources/KodaCore/CrawlEngine.swift`
- Create: `Tests/KodaCoreTests/CheckOnlyFetchTests.swift`

**Interfaces:**
- Consumes: `FrontierItem.checkOnly` (Task 2), `HTTPClient`, `CrawlResult`
- Produces: `CrawlEngine.process` handles check-only items; no new public API

- [ ] **Step 1: Write the failing tests**

These seed `check_only = 1` rows directly, so this task stands on its own — it
tests the *fetching* behaviour, not the enqueueing. Task 4 wires real external
links and images to produce those rows and tests that separately.

Create `Tests/KodaCoreTests/CheckOnlyFetchTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore

private actor MethodLog {
    private(set) var calls: [(url: String, method: String)] = []
    func record(_ url: String, _ method: String) { calls.append((url, method)) }
    func methods(for url: String) -> [String] { calls.filter { $0.url == url }.map(\.method) }
}

private struct CheckClient: HTTPClient {
    let log: MethodLog
    var headStatus: Int = 200
    var contentLength: String? = "4096"

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        await log.record(url, method)
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        var headers: [String: String] = ["Content-Type": "image/png"]
        if let contentLength { headers["Content-Length"] = contentLength }
        if method == "HEAD" {
            return .response(HTTPResponse(status: headStatus, headers: headers, body: nil, elapsedMs: 1))
        }
        // The GET fallback returns a real HTML body, so a test can prove it is
        // still never parsed for links.
        let body = "<html><head><title>T</title></head><body><a href=\"/onwards\">x</a></body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

/// A store holding exactly one queued check-only URL, ready for the engine.
private func storeWithCheckOnlyURL(_ url: String = "https://ext.test/thing.png") throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    let config = CrawlConfig(seedURL: "https://seed.test/")
    try store.initializeCrawl(config: config, startedAt: Date())
    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, check_only)
                VALUES (?,?,?,?,1,0,0,0,1)
                """,
            arguments: [url, Data("hk".utf8), "ext.test", "/thing.png"]
        )
    }
    return store
}

private func runEngine(store: Store, client: CheckClient) async throws {
    var config = CrawlConfig(seedURL: "https://seed.test/")
    config.workers = 1
    let engine = CrawlEngine(store: store, client: client, parser: SwiftSoupParser(), config: config)
    try await engine.run(onProgress: nil)
}

@Test func aCheckOnlyURLIsFetchedWithHEAD() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log))
    #expect(await log.methods(for: "https://ext.test/thing.png") == ["HEAD"])
}

@Test func theStatusIsRecorded() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log))
    let status = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT status FROM responses")
    }
    #expect(status == 200)
}

@Test func contentLengthComesFromTheHeader() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log))
    let size = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT content_length FROM responses")
    }
    #expect(size == 4096, "a HEAD has no body, so size can only come from the header")
}

@Test func aMissingContentLengthLeavesSizeNullNotZero() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, contentLength: nil))
    let size = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT content_length FROM responses")
    }
    #expect(size == nil, "an unknown size must never be reported as zero bytes")
}

@Test func a405TriggersExactlyOneGETRetry() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 405))
    #expect(await log.methods(for: "https://ext.test/thing.png") == ["HEAD", "GET"])
}

@Test func a501TriggersExactlyOneGETRetry() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 501))
    #expect(await log.methods(for: "https://ext.test/thing.png") == ["HEAD", "GET"])
}

@Test func a404IsRecordedWithoutRetrying() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 404))
    #expect(await log.methods(for: "https://ext.test/thing.png") == ["HEAD"],
            "retrying every 4xx would double our traffic on ordinary 404s")
}

@Test func aCheckOnlyResponseDiscoversNoLinks() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    // headStatus 405 forces the GET fallback, which returns a real HTML body.
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 405))
    let links = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM links") ?? 0
    }
    #expect(links == 0, "a status check never crawls onwards, even when the body is HTML")
}

@Test func aCheckOnlyResponseStoresNoPageFacts() async throws {
    let log = MethodLog()
    let store = try storeWithCheckOnlyURL()
    try await runEngine(store: store, client: CheckClient(log: log, headStatus: 405))
    let facts = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM page_facts") ?? 0
    }
    #expect(facts == 0)
}

@Test func aTransportFailureOnACheckIsRecordedNotDropped() async throws {
    struct FailingClient: HTTPClient {
        func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
            if url.hasSuffix("/robots.txt") {
                return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
            }
            return .failure(kind: "URLError.cannotFindHost")
        }
    }
    let store = try storeWithCheckOnlyURL()
    var config = CrawlConfig(seedURL: "https://seed.test/")
    config.workers = 1
    let engine = CrawlEngine(store: store, client: FailingClient(), parser: SwiftSoupParser(), config: config)
    try await engine.run(onProgress: nil)

    let row = try await store.dbQueue.read { db in
        try Row.fetchOne(db, sql: "SELECT status, error_kind FROM responses")
    }
    #expect(row?["status"] == 0)
    #expect(row?["error_kind"] == "URLError.cannotFindHost")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CheckOnlyFetch`
Expected: FAIL — the engine currently fetches every URL with GET and parses it, so the method log shows `["GET"]` where `["HEAD"]` is expected, and `page_facts` rows appear where none should.

- [ ] **Step 3: Implement the check-only branch**

In `Sources/KodaCore/CrawlEngine.swift`, add a static helper and branch to it at the top of `process`:

```swift
    /// A status check: HEAD the URL, record what came back, parse nothing.
    /// Used for external links and image sources — we want their status and size,
    /// not their content, and we never crawl onwards from them.
    private static func statusCheck(
        item: FrontierItem, config: CrawlConfig, client: HTTPClient
    ) async -> CrawlResult {
        var outcome = await client.fetch(url: item.url.absoluteString, method: "HEAD",
                                         userAgent: config.userAgent, timeout: config.timeout)

        // 405 and 501 are the two codes that actually mean "this server does not do
        // HEAD". Retrying on any other 4xx would double our traffic on ordinary 404s.
        if case .response(let head) = outcome, head.status == 405 || head.status == 501 {
            outcome = await client.fetch(url: item.url.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout)
        }

        switch outcome {
        case .failure(let kind):
            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth, status: 0, errorKind: kind,
                contentType: nil, contentLength: nil, responseTimeMs: 0,
                redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: nil
            )
        case .response(let response):
            // A HEAD has no body, so size can only come from the header. When the
            // header is absent the column stays null — never zero, which would
            // masquerade as a real measurement of an empty file.
            let length = response.header("content-length").flatMap { Int($0) } ?? response.body?.count
            let redirectTarget = response.isRedirect
                ? response.location.flatMap { URLNormalizer.normalize($0, relativeTo: item.url) }
                : nil
            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth,
                status: response.status, errorKind: nil,
                contentType: response.contentType, contentLength: length,
                responseTimeMs: response.elapsedMs,
                redirectTarget: redirectTarget, bodyGz: nil, xRobotsTag: nil, facts: nil
            )
        }
    }
```

Then, in `process`, immediately after the robots check and before the ordinary fetch:

```swift
        if item.checkOnly {
            return await statusCheck(item: item, config: config, client: client)
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CheckOnlyFetch`
Expected: PASS, 10 tests.

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS. Nothing yet enqueues check-only URLs, so ordinary crawling is untouched — Task 4 wires that up.

- [ ] **Step 6: Commit**

```bash
git add Sources/KodaCore/CrawlEngine.swift Tests/KodaCoreTests/CheckOnlyFetchTests.swift
git commit -m "feat: status-check fetching with HEAD and a GET fallback"
```

---

### Task 4: Enqueue external links and images as check-only — and fix the visibility filter

These two changes are one task because they are one consequence. The moment
images are fetched, every image gains a `responses` row, and the existing
visibility filter — which keeps an image-sourced URL *if* it has a response —
stops excluding anything. Ship the fetching without the filter change and every
`.png` floods the main URL table. Landing them separately would knowingly break
the suite in between.

**Files:**
- Modify: `Sources/KodaCore/CrawlConfig.swift`
- Modify: `Sources/KodaCore/Store+Write.swift`
- Modify: `Sources/KodaCore/Store.swift` (the `visibleURLsFilter` constant)
- Create: `Tests/KodaCoreTests/CheckOnlyEnqueueTests.swift`

**Interfaces:**
- Consumes: `upsertURL`, `upsertURLOrSkip`, `Store.visibleURLsFilter`, `FrontierItem.checkOnly`
- Produces:
  - `CrawlConfig.checkExternalLinks: Bool = true`, `CrawlConfig.checkImages: Bool = true`
  - `Store.upsertURL(..., checkOnly: Bool = false)` and the same defaulted parameter on `upsertURLOrSkip`
  - A revised `Store.visibleURLsFilter`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/CheckOnlyEnqueueTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore

/// A seed page with one external link and one image.
private struct SeedClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        if url == "https://seed.test/" {
            let body = """
                <html><head><title>Seed</title></head><body>
                <a href="https://other.test/page">out</a>
                <img src="/pic.png" alt="a">
                </body></html>
                """
            return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                          body: Data(body.utf8), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200,
                                      headers: ["Content-Type": "image/png", "Content-Length": "2048"],
                                      body: nil, elapsedMs: 1))
    }
}

private func crawl(configure: (inout CrawlConfig) -> Void = { _ in }) async throws -> Store {
    var config = CrawlConfig(seedURL: "https://seed.test/")
    config.workers = 1
    configure(&config)
    let (store, _) = try await CrawlSession.start(dbPath: nil, config: config, client: SeedClient(),
                                                  parser: SwiftSoupParser(), onProgress: nil)
    return store
}

private func checkOnlyFlag(_ store: Store, url: String) async throws -> Int? {
    try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT check_only FROM urls WHERE url = ?", arguments: [url])
    }
}

private func hasResponse(_ store: Store, url: String) async throws -> Bool {
    let n = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.url = ?
            """, arguments: [url]) ?? 0
    }
    return n > 0
}

@Test func externalLinksAreEnqueuedAsCheckOnly() async throws {
    let store = try await crawl()
    #expect(try await checkOnlyFlag(store, url: "https://other.test/page") == 1)
    #expect(try await hasResponse(store, url: "https://other.test/page"), "and actually fetched")
}

@Test func imagesAreEnqueuedAsCheckOnly() async throws {
    let store = try await crawl()
    #expect(try await checkOnlyFlag(store, url: "https://seed.test/pic.png") == 1)
    #expect(try await hasResponse(store, url: "https://seed.test/pic.png"))
}

@Test func theSeedPageIsNotCheckOnly() async throws {
    let store = try await crawl()
    #expect(try await checkOnlyFlag(store, url: "https://seed.test/") == 0)
}

@Test func disablingExternalChecksRestoresTheOldBehaviour() async throws {
    let store = try await crawl { $0.checkExternalLinks = false }
    #expect(try await hasResponse(store, url: "https://other.test/page") == false,
            "recorded but never fetched, exactly as before this milestone")
    let exists = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE url = 'https://other.test/page'") ?? 0
    }
    #expect(exists == 1, "the URL is still recorded")
}

@Test func disablingImageChecksRestoresTheOldBehaviour() async throws {
    let store = try await crawl { $0.checkImages = false }
    #expect(try await hasResponse(store, url: "https://seed.test/pic.png") == false)
}

@Test func aFetchedImageIsStillHiddenFromTheURLTable() async throws {
    // This is the regression the filter change exists to prevent: once images are
    // fetched they all have responses rows, and a filter keyed on "has a response"
    // would stop excluding them.
    let store = try await crawl()
    let visible = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT u.url FROM urls u WHERE \(Store.visibleURLsFilter) ORDER BY u.url
            """)
    }
    #expect(!visible.contains("https://seed.test/pic.png"),
            "a pure image must stay out of the URL table even once fetched; got \(visible)")
    #expect(visible.contains("https://seed.test/"))
    #expect(visible.contains("https://other.test/page"), "external links belong in the table")
}

@Test func aURLThatIsBothAPageAndAnImageSourceStaysVisible() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://dual.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        // /thing is linked as a page AND used as an image source.
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://dual.test/', x'01', 'dual.test', '/', 0, 1, 0, 2),
                   ('https://dual.test/thing', x'02', 'dual.test', '/thing', 1, 1, 0, 2)
            """)
        try db.execute(sql: "INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position) VALUES (1,2,'t',NULL,1,0)")
        try db.execute(sql: "INSERT INTO images (url_id, src_url_id, alt) VALUES (1,2,'alt')")
        try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (1,200,0),(2,200,0)")
    }
    let visible = try await store.dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT url FROM urls u WHERE \(Store.visibleURLsFilter)")
    }
    #expect(visible.contains("https://dual.test/thing"),
            "a real page that is also an image source must remain visible")
}

@Test func summaryAndTableStillAgree() async throws {
    let store = try await crawl()
    let filtered = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls u WHERE \(Store.visibleURLsFilter)") ?? 0
    }
    let totalURLs = try store.summary().totalURLs
    #expect(filtered == totalURLs, "one filter, one meaning of 'total URLs'")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CheckOnlyEnqueue`
Expected: FAIL — `value of type 'CrawlConfig' has no member 'checkExternalLinks'`.

- [ ] **Step 3: Add the config flags**

In `Sources/KodaCore/CrawlConfig.swift`, alongside the other politeness settings:

```swift
    /// Fetch external links with HEAD to record their status. On by default: a
    /// broken-outbound-links report is one of the genuinely useful things this
    /// tool does. Turn it off for a large site where the extra requests to third
    /// parties are not worth it.
    public var checkExternalLinks: Bool = true

    /// Fetch image sources with HEAD to record status and byte size. Needed for
    /// the "images over 100KB" report.
    public var checkImages: Bool = true
```

- [ ] **Step 4: Thread `checkOnly` through the writer**

In `Sources/KodaCore/Store+Write.swift`, add a defaulted parameter to `upsertURL` and persist it. Keep every other part of the method — the depth arithmetic, the filter checks, the redirect-hop limit, the URL cap — exactly as it is:

```swift
    static func upsertURL(
        _ db: Database, _ url: NormalizedURL, parentDepth: Int, config: CrawlConfig,
        seedHost: String?, now: Date, enqueue: Bool, discovered: inout Int,
        redirectHops: Int = 0,
        checkOnly: Bool = false
    ) throws -> Int64 {
```

Its INSERT gains the column:

```swift
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, redirect_hops, check_only)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [url.absoluteString, url.sha256, url.host, url.path, depth,
                        internalFlag ? 1 : 0, now.timeIntervalSince1970,
                        shouldQueue ? 0 : 3, redirectHops, checkOnly ? 1 : 0]
        )
```

Give `upsertURLOrSkip` the same defaulted `checkOnly: Bool = false` parameter and pass it straight through.

- [ ] **Step 5: Enqueue external links and images as check-only**

In `writeFacts`, the link loop currently enqueues only internal, followable links. External links become check-only instead of being recorded and abandoned:

```swift
            let isNofollow = link.rel?.lowercased().contains("nofollow") == true
            let followInternal = isInternal && (!isNofollow || config.followInternalNofollow)
            // External links are not crawled, but we do want their status — a
            // broken outbound link is a real finding.
            let statusCheckExternal = !isInternal && config.checkExternalLinks
            let crawlable = followInternal || statusCheckExternal

            guard let targetID = try Self.upsertURLOrSkip(db, target, parentDepth: result.depth, config: config,
                                                          seedHost: seedHost, now: now,
                                                          enqueue: crawlable, discovered: &discovered,
                                                          checkOnly: statusCheckExternal)
            else { continue }
```

And the image loop:

```swift
        for image in facts.images {
            guard let src = URLNormalizer.normalize(image.src, relativeTo: result.url) else { continue }
            let srcID = try Self.upsertURL(db, src, parentDepth: result.depth, config: config,
                                           seedHost: seedHost, now: now,
                                           enqueue: config.checkImages, discovered: &discovered,
                                           checkOnly: config.checkImages)
            try db.execute(sql: "INSERT INTO images (url_id, src_url_id, alt) VALUES (?,?,?)",
                           arguments: [result.urlID, srcID, image.alt])
        }
```

- [ ] **Step 6: Fix the visibility filter**

In `Sources/KodaCore/Store.swift`, `visibleURLsFilter` currently keeps an
image-sourced URL when it has a `responses` row. Once images are fetched they
all have one, so that clause stops excluding anything. Key on links alone:

```swift
    /// Which URLs count as rows a user should see — every URL except one that
    /// exists *only* as an image source.
    ///
    /// This deliberately does NOT consider whether the URL has been fetched.
    /// Before M3a, images were never fetched, so "has a response" was a safe
    /// proxy for "is a real page". M3a fetches images, so that proxy would now
    /// admit every `.png` into the URL table. A URL that is genuinely both a
    /// page and an image source is kept by the links clause instead.
    ///
    /// `Store.summary()` and `RowIndex` share this one constant. Two
    /// hand-maintained copies of this predicate is what produced M1's
    /// `urlCounts().total` versus `summary().totalURLs` divergence.
    public static let visibleURLsFilter = """
        u.id NOT IN (
          SELECT src_url_id FROM images
          WHERE src_url_id NOT IN (SELECT to_url_id FROM links)
        )
        """
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter CheckOnlyEnqueue`
Expected: PASS, 8 tests.

Then: `swift test --filter CheckOnlyFetch`
Expected: PASS, 10 tests — Task 3's engine work and this task's enqueueing now meet.

- [ ] **Step 8: Run the full suite**

Run: `swift test`
Expected: PASS.

This is the task most likely to move existing expectations, because crawls now
fetch more URLs than before. If `SummaryTests` or `EndToEndTests` fail, read the
failure carefully before touching anything: a changed count may be *correct*
now — an external link that gained a status genuinely belongs in `byStatusClass`.
Update an expectation only when you can state why the new number is right, and
say so in your report. Never adjust a test merely to make it green.

- [ ] **Step 9: Commit**

```bash
git add Sources/KodaCore/CrawlConfig.swift Sources/KodaCore/Store+Write.swift Sources/KodaCore/Store.swift Tests/KodaCoreTests/CheckOnlyEnqueueTests.swift
git commit -m "feat: status-check external links and images; images stay out of the URL table"
```

---

### Task 5: RowIndex — the ordered id list that makes sorting possible

`NSTableView` asks for row 40,000 directly. `LIMIT`/`OFFSET` answers that in
O(offset), and keyset pagination cannot answer it at all without walking there.
A materialised list of ids answers it exactly: row *N* is `ids[N]`. At the
500,000-URL target the array is about 4MB.

**Files:**
- Create: `Sources/KodaUI/RowIndex.swift`
- Create: `Tests/KodaUITests/RowIndexTests.swift`

**Interfaces:**
- Consumes: `Store`, `Store.visibleURLsFilter`
- Produces:
  - `public enum SortColumn: String, CaseIterable, Sendable { case discoveryOrder, address, status, title, depth }`, plus `static var selectable: [SortColumn]` (the four clickable columns)
  - `@MainActor public final class RowIndex` with `init(store:)`, `var count: Int`, `func id(at: Int) -> Int64?`, `func rebuild(sort: SortColumn, ascending: Bool)`, `func appendNewIds() -> Bool`, `var sort: SortColumn`, `var ascending: Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaUITests/RowIndexTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaUI

/// Four URLs with deliberately non-aligned orderings so a wrong sort column
/// cannot accidentally produce the right answer.
@MainActor
private func seeded() throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://s.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state) VALUES
              ('https://s.test/d', x'01', 's.test', '/d', 3, 1, 0, 2),
              ('https://s.test/a', x'02', 's.test', '/a', 1, 1, 0, 2),
              ('https://s.test/c', x'03', 's.test', '/c', 0, 1, 0, 2),
              ('https://s.test/b', x'04', 's.test', '/b', 2, 1, 0, 2)
            """)
        try db.execute(sql: """
            INSERT INTO responses (url_id, status, fetched_at) VALUES
              (1, 500, 0), (2, 200, 0), (3, 404, 0), (4, 301, 0)
            """)
        try db.execute(sql: """
            INSERT INTO page_facts (url_id, title) VALUES
              (1, 'Zebra'), (2, 'Apple'), (3, 'Mango'), (4, 'Banana')
            """)
    }
    return store
}

@MainActor
private func urls(_ store: Store, _ index: RowIndex) throws -> [String] {
    try store.dbQueue.read { db in
        try index.ids.map { id in
            try String.fetchOne(db, sql: "SELECT url FROM urls WHERE id = ?", arguments: [id]) ?? "?"
        }
    }
}

@MainActor
@Test func sortsByAddressAscending() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .address, ascending: true)
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["a", "b", "c", "d"])
}

@MainActor
@Test func sortsByAddressDescending() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .address, ascending: false)
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["d", "c", "b", "a"])
}

@MainActor
@Test func sortsByStatus() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .status, ascending: true)
    // 200, 301, 404, 500 → /a, /b, /c, /d
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["a", "b", "c", "d"])
}

@MainActor
@Test func sortsByTitle() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .title, ascending: true)
    // Apple, Banana, Mango, Zebra → /a, /b, /c, /d
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["a", "b", "c", "d"])
}

@MainActor
@Test func sortsByDepth() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .depth, ascending: true)
    // depths 0,1,2,3 → /c, /a, /b, /d
    #expect(try urls(store, index).map { String($0.suffix(1)) } == ["c", "a", "b", "d"])
}

@MainActor
@Test func nullsSortLastAscending() throws {
    let store = try seeded()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/queued', x'05', 's.test', '/queued', 9, 1, 0, 0)
            """)
        // No responses row, so status is null.
        try db.execute(sql: "INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position) VALUES (1,5,'q',NULL,1,0)")
    }
    let index = RowIndex(store: store)
    index.rebuild(sort: .status, ascending: true)
    #expect(try urls(store, index).last == "https://s.test/queued")
}

@MainActor
@Test func nullsSortLastDescendingToo() throws {
    let store = try seeded()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/queued', x'05', 's.test', '/queued', 9, 1, 0, 0)
            """)
        try db.execute(sql: "INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position) VALUES (1,5,'q',NULL,1,0)")
    }
    let index = RowIndex(store: store)
    index.rebuild(sort: .status, ascending: false)
    #expect(try urls(store, index).last == "https://s.test/queued",
            "a table sorted either way should open on real values, not blanks")
}

@MainActor
@Test func idAtBoundsIsSafe() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .address, ascending: true)
    #expect(index.count == 4)
    #expect(index.id(at: 0) != nil)
    #expect(index.id(at: 3) != nil)
    #expect(index.id(at: 4) == nil)
    #expect(index.id(at: -1) == nil)
}

@MainActor
@Test func excludesImageOnlyURLs() throws {
    let store = try seeded()
    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/pic.png', x'06', 's.test', '/pic.png', 1, 1, 0, 2)
            """)
        try db.execute(sql: "INSERT INTO images (url_id, src_url_id, alt) VALUES (1,5,'a')")
        try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (5,200,0)")
    }
    let index = RowIndex(store: store)
    index.rebuild(sort: .address, ascending: true)
    #expect(index.count == 4, "a fetched image is still not a row in the URL table")
}

@MainActor
@Test func appendNewIdsPicksUpRowsAddedMidCrawl() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    #expect(index.count == 4)

    try store.dbQueue.write { db in
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/e', x'07', 's.test', '/e', 4, 1, 0, 2)
            """)
        try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (5,200,0)")
    }

    let grew = index.appendNewIds()
    #expect(grew)
    #expect(index.count == 5)
}

@MainActor
@Test func appendNewIdsRefusesUnderANonDefaultSort() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .status, ascending: true)
    let grew = index.appendNewIds()
    #expect(!grew, "appending only makes sense in discovery order; other sorts must rebuild")
}

@MainActor
@Test func appendNewIdsRefusesUnderAddressSort() throws {
    // Address order is NOT id order, so a newly discovered URL could belong
    // anywhere in the list — appending it would look plausible and be wrong.
    let store = try seeded()
    let index = RowIndex(store: store)
    index.rebuild(sort: .address, ascending: true)
    #expect(!index.appendNewIds())
}

@MainActor
@Test func discoveryOrderIsTheDefaultBeforeAnyRebuild() throws {
    let store = try seeded()
    let index = RowIndex(store: store)
    #expect(index.sort == .discoveryOrder)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RowIndex`
Expected: FAIL — `cannot find 'RowIndex' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/KodaUI/RowIndex.swift`:

```swift
import Foundation
import GRDB
import KodaCore

public enum SortColumn: String, CaseIterable, Sendable {
    /// The default: the order URLs were discovered in. Not a clickable column —
    /// it is the state the table is in before the user sorts anything, and it
    /// matches how the table behaved before this milestone.
    case discoveryOrder
    case address, status, title, depth

    /// The SQL expression to order by. Kept here rather than at the call site so
    /// there is one place that decides what "sort by status" means.
    var orderExpression: String {
        switch self {
        case .discoveryOrder: return "u.id"
        case .address: return "u.url"
        case .status: return "r.status"
        case .title: return "f.title"
        case .depth: return "u.depth"
        }
    }

    /// Only discovery order can be appended to during a live crawl. New rows
    /// always get larger ids, so they belong at the end — but under any other
    /// sort a new row could belong anywhere, and appending it would put the
    /// table in a wrong order that looks plausible. Those sorts rebuild instead.
    var isAppendable: Bool { self == .discoveryOrder }

    /// The columns a user can actually click. `discoveryOrder` is excluded
    /// because there is no column header for it.
    public static var selectable: [SortColumn] { [.address, .status, .title, .depth] }
}

/// The ordered list of row ids behind the table.
///
/// `NSTableView` asks for arbitrary rows, so the table needs random access into
/// a sorted result. Holding the ordered ids gives that in O(1) — row `N` is
/// `ids[N]` — where `LIMIT`/`OFFSET` costs O(offset) and keyset pagination
/// cannot answer "row 40,000" at all. At 500,000 URLs the array is about 4MB.
@MainActor
public final class RowIndex {
    private let store: Store
    public private(set) var ids: [Int64] = []
    public private(set) var sort: SortColumn = .discoveryOrder
    public private(set) var ascending = true

    public init(store: Store) {
        self.store = store
    }

    public var count: Int { ids.count }

    public func id(at index: Int) -> Int64? {
        guard index >= 0, index < ids.count else { return nil }
        return ids[index]
    }

    /// Re-runs the ordering query. On failure the previous ordering is kept, so
    /// a transient read error leaves the table usable rather than empty.
    public func rebuild(sort: SortColumn, ascending: Bool) {
        let direction = ascending ? "ASC" : "DESC"
        // Nulls last in BOTH directions: a table sorted by status should open on
        // real statuses whichever way the arrow points.
        let sql = """
            SELECT u.id
            FROM urls u
            LEFT JOIN responses r ON r.url_id = u.id
            LEFT JOIN page_facts f ON f.url_id = u.id
            WHERE \(Store.visibleURLsFilter)
            ORDER BY (\(sort.orderExpression) IS NULL) ASC, \(sort.orderExpression) \(direction), u.id ASC
            """
        guard let fresh = try? store.dbQueue.read({ db in try Int64.fetchAll(db, sql: sql) }) else {
            return
        }
        self.ids = fresh
        self.sort = sort
        self.ascending = ascending
    }

    /// Fast path for a live crawl under the default sort: fetch only ids beyond
    /// the largest one already held, instead of re-sorting the whole crawl twice
    /// a second. Returns whether anything was added.
    @discardableResult
    public func appendNewIds() -> Bool {
        guard sort.isAppendable, ascending else { return false }
        let after = ids.last ?? 0
        let sql = """
            SELECT u.id FROM urls u
            WHERE u.id > ? AND \(Store.visibleURLsFilter)
            ORDER BY u.id ASC
            """
        guard let fresh = try? store.dbQueue.read({ db in
            try Int64.fetchAll(db, sql: sql, arguments: [after])
        }), !fresh.isEmpty else { return false }
        ids.append(contentsOf: fresh)
        return true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RowIndex`
Expected: PASS, 13 tests.

Why `discoveryOrder` exists as a separate case: appending is only correct when
new rows genuinely belong at the end, which is true for id order and nothing
else. Under an alphabetical or status sort a newly discovered URL could belong
anywhere in the list, so appending it would produce a wrong order that still
looks plausible — the worst kind of bug. Those sorts rebuild instead, throttled
in Task 7.

- [ ] **Step 5: Commit**

```bash
git add Sources/KodaUI/RowIndex.swift Tests/KodaUITests/RowIndexTests.swift
git commit -m "feat: ordered row index enabling arbitrary-column sorting"
```

---

### Task 6: RowStore fetches by id

**Files:**
- Modify: `Sources/KodaUI/RowStore.swift`
- Modify: `Tests/KodaUITests/RowStoreTests.swift`

**Interfaces:**
- Consumes: `RowIndex` (Task 5), `CrawlRow`
- Produces: `RowStore.init(store:index:pageSize:maxPages:)`; `count` and `row(at:)` now read through the index. `refresh()` and `invalidate()` keep their names and meanings.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/KodaUITests/RowStoreTests.swift` (keep every existing test; several will need their `RowStore(store:)` construction updated to pass an index, which is a mechanical change, not a weakening):

```swift
@MainActor
@Test func rowsComeBackInTheIndexsOrderNotTheDatabasesOrder() throws {
    let store = try seededStore(pages: 10)
    let index = RowIndex(store: store)
    index.rebuild(sort: .address, ascending: false)   // reverse alphabetical
    let rows = RowStore(store: store, index: index)
    rows.refresh()

    let addresses = (0..<rows.count).compactMap { rows.row(at: $0)?.address }
    #expect(addresses == addresses.sorted(by: >),
            "SQL `IN` does not preserve order; RowStore must reorder to match the index")
}

@MainActor
@Test func countComesFromTheIndex() throws {
    let store = try seededStore(pages: 7)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()
    #expect(rows.count == 7)
    #expect(rows.count == index.count)
}

@MainActor
@Test func aRowDeepInALargeCrawlIsFetchedDirectly() throws {
    // The point of the index: row 4,999 costs the same as row 0.
    let store = try seededStore(pages: 5_000)
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
    rows.refresh()

    #expect(rows.row(at: 4_999)?.title == "T4999")
    #expect(rows.row(at: 0)?.title == "T0")
}

@MainActor
@Test func changingTheSortChangesWhatRowZeroIs() throws {
    let store = try seededStore(pages: 5)
    let index = RowIndex(store: store)
    let rows = RowStore(store: store, index: index)

    index.rebuild(sort: .address, ascending: true)
    rows.refresh()
    let ascendingFirst = rows.row(at: 0)?.address

    index.rebuild(sort: .address, ascending: false)
    rows.refresh()
    let descendingFirst = rows.row(at: 0)?.address

    #expect(ascendingFirst != descendingFirst)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RowStore`
Expected: FAIL — `extra argument 'index' in call`.

- [ ] **Step 3: Rework RowStore to fetch by id**

Replace the paging internals in `Sources/KodaUI/RowStore.swift`. Keep the LRU
page cache and its `touch(_:)` discipline exactly as they are — that was fixed
in M2 and its regression test still guards it. What changes is only how a page
is loaded: by a slice of ids from the index, rather than by `LIMIT`/`OFFSET`.

```swift
    private let store: Store
    private let index: RowIndex
    private let pageSize: Int
    private let maxPages: Int

    public init(store: Store, index: RowIndex, pageSize: Int = 200, maxPages: Int = 20) {
        self.store = store
        self.index = index
        self.pageSize = max(pageSize, 1)
        self.maxPages = max(maxPages, 1)
    }

    /// The index decides how many rows there are and in what order; RowStore only
    /// fetches their contents. One place owns the filter and the ordering.
    public var count: Int { index.count }

    public func refresh() {
        invalidate()
    }
```

and `loadPage` becomes:

```swift
    private func loadPage(_ pageIndex: Int) -> [CrawlRow] {
        let start = pageIndex * pageSize
        let end = min(start + pageSize, index.count)
        guard start < end else { return [] }
        let wanted: [Int64] = (start..<end).compactMap { index.id(at: $0) }
        guard !wanted.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: wanted.count).joined(separator: ",")
        let fetched: [Int64: CrawlRow] = (try? store.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT u.id AS id, u.url AS url, r.status AS status, f.title AS title, u.depth AS depth
                FROM urls u
                LEFT JOIN responses r ON r.url_id = u.id
                LEFT JOIN page_facts f ON f.url_id = u.id
                WHERE u.id IN (\(placeholders))
                """, arguments: StatementArguments(wanted))
            .reduce(into: [Int64: CrawlRow]()) { acc, row in
                let id: Int64 = row["id"]
                acc[id] = CrawlRow(id: id, address: row["url"], status: row["status"],
                                   title: row["title"], depth: row["depth"])
            }
        }) ?? [:]

        // `IN` returns rows in whatever order SQLite likes, so reorder to match
        // the index. Without this the table would show correct rows in the wrong
        // places — which looks like data corruption rather than a sorting bug.
        let rows = wanted.compactMap { fetched[$0] }

        pages[pageIndex] = rows
        touch(pageIndex)
        while lru.count > maxPages, let oldest = lru.first {
            lru.removeFirst()
            pages.removeValue(forKey: oldest)
        }
        return rows
    }
```

`row(at:)` keeps its shape but bounds-checks against `index.count`:

```swift
    public func row(at index rowIndex: Int) -> CrawlRow? {
        guard rowIndex >= 0, rowIndex < index.count else { return nil }
        let pageIndex = rowIndex / pageSize
        if let cached = pages[pageIndex] {
            touch(pageIndex)
            let offset = rowIndex - pageIndex * pageSize
            return offset < cached.count ? cached[offset] : nil
        }
        let page = loadPage(pageIndex)
        let offset = rowIndex - pageIndex * pageSize
        return offset < page.count ? page[offset] : nil
    }
```

Delete the old `cachedCount` property and the `visibleURLsFilter` usage from
this file — the index owns both now.

- [ ] **Step 4: Update the existing RowStore tests**

Every existing test constructs `RowStore(store:)`. Each needs an index:

```swift
    let index = RowIndex(store: store)
    index.rebuild(sort: .discoveryOrder, ascending: true)
    let rows = RowStore(store: store, index: index)
```

Do not change any assertion. If an assertion now fails, that is a real finding —
report it rather than adjusting the expectation.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter RowStore`
Expected: PASS — the existing tests plus 4 new ones.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/KodaUI/RowStore.swift Tests/KodaUITests/RowStoreTests.swift
git commit -m "feat: RowStore fetches by id through the row index"
```

---

### Task 7: Sortable column headers

**Files:**
- Modify: `Sources/KodaUI/URLTableView.swift`
- Modify: `Sources/KodaUI/CrawlController.swift`
- Modify: `Sources/KodaUI/ContentView.swift`
- Create: `Tests/KodaUITests/SortMappingTests.swift`

**Interfaces:**
- Consumes: `RowIndex`, `SortColumn`, `URLTableColumn`, `CrawlController`
- Produces:
  - `URLTableColumn.sortColumn: SortColumn` mapping each visible column to its sort
  - `CrawlController.applySort(_ column: SortColumn, ascending: Bool)`
  - `URLTableCoordinator.onSortChange: ((SortColumn, Bool) -> Void)?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaUITests/SortMappingTests.swift`:

```swift
import AppKit
import Testing
@testable import KodaUI

@MainActor
@Test func everyVisibleColumnMapsToASortColumn() {
    #expect(URLTableColumn.address.sortColumn == .address)
    #expect(URLTableColumn.status.sortColumn == .status)
    #expect(URLTableColumn.title.sortColumn == .title)
    #expect(URLTableColumn.depth.sortColumn == .depth)
}

@MainActor
@Test func everySelectableSortHasAColumn() {
    let mapped = Set(URLTableColumn.allCases.map(\.sortColumn))
    for sort in SortColumn.selectable {
        #expect(mapped.contains(sort), "\(sort) has no column header to click")
    }
}

@MainActor
@Test func discoveryOrderIsNotClickable() {
    #expect(!SortColumn.selectable.contains(.discoveryOrder),
            "discovery order is the default state, not a column")
}

@MainActor
@Test func aSortDescriptorMapsToColumnAndDirection() {
    let descriptor = NSSortDescriptor(key: URLTableColumn.status.rawValue, ascending: false)
    let resolved = URLTableCoordinator.sort(from: descriptor)
    #expect(resolved?.column == .status)
    #expect(resolved?.ascending == false)
}

@MainActor
@Test func anUnknownSortDescriptorResolvesToNil() {
    let descriptor = NSSortDescriptor(key: "nonsense", ascending: true)
    #expect(URLTableCoordinator.sort(from: descriptor) == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SortMapping`
Expected: FAIL — `value of type 'URLTableColumn' has no member 'sortColumn'`.

- [ ] **Step 3: Map columns to sorts**

In `Sources/KodaUI/URLTableView.swift`, extend `URLTableColumn`:

```swift
    /// Which ordering this column's header applies when clicked.
    public var sortColumn: SortColumn {
        switch self {
        case .address: return .address
        case .status: return .status
        case .title: return .title
        case .depth: return .depth
        }
    }
```

Add to `URLTableCoordinator` a static resolver and a callback:

```swift
    /// Called when the user clicks a column header. The controller rebuilds the
    /// index and reloads; the coordinator does not sort anything itself.
    public var onSortChange: ((SortColumn, Bool) -> Void)?

    public static func sort(from descriptor: NSSortDescriptor) -> (column: SortColumn, ascending: Bool)? {
        guard let key = descriptor.key,
              let column = URLTableColumn(rawValue: key)
        else { return nil }
        return (column.sortColumn, descriptor.ascending)
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let resolved = Self.sort(from: descriptor)
        else { return }
        onSortChange?(resolved.column, resolved.ascending)
    }
```

In `makeNSView`, give each column a sort prototype so its header is clickable:

```swift
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
```

and wire the coordinator's callback in `makeNSView`/`updateNSView` from a new
`onSortChange` parameter on `URLTableView`.

- [ ] **Step 4: Apply the sort from the controller**

In `Sources/KodaUI/CrawlController.swift`, the controller owns the index and
rebuilds it. Add:

```swift
    /// Rebuilding sorts the whole crawl, so it is throttled during a live crawl —
    /// a 500,000-row re-sort twice a second would spend the machine's time on
    /// ordering rather than crawling.
    @ObservationIgnored private var lastSortRebuild = Date.distantPast

    public func applySort(_ column: SortColumn, ascending: Bool) {
        guard let index = rowIndex else { return }
        index.rebuild(sort: column, ascending: ascending)
        lastSortRebuild = Date()
        rows?.refresh()
        revision &+= 1
    }
```

The controller creates a `RowIndex` alongside the `RowStore` in `start()`, and
its tick uses the cheap path when possible:

```swift
                // Discovery order only ever appends, so a live crawl does not need
                // to re-sort. Any other sort rebuilds, at most every 2 seconds.
                if let index = self.rowIndex {
                    if index.sort.isAppendable {
                        index.appendNewIds()
                    } else if Date().timeIntervalSince(self.lastSortRebuild) >= 2 {
                        index.rebuild(sort: index.sort, ascending: index.ascending)
                        self.lastSortRebuild = Date()
                    }
                }
                self.rows?.refresh()
                self.revision &+= 1
```

- [ ] **Step 5: Pass the callback through the view**

In `Sources/KodaUI/ContentView.swift`, hand the table a closure:

```swift
            URLTableView(rows: controller.rows,
                         revision: controller.revision,
                         onSortChange: { column, ascending in
                             controller.applySort(column, ascending: ascending)
                         })
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter SortMapping`
Expected: PASS, 5 tests.

- [ ] **Step 7: Run the full suite and the app**

Run: `swift test`
Expected: PASS.

Then `swift build && ./.build/debug/KodaApp`, crawl a site of at least a few
hundred pages, and click each column header. Confirm the order changes, that
clicking again reverses it, and that rows with no status or title sort to the
bottom in both directions. Report what you saw.

- [ ] **Step 8: Commit**

```bash
git add Sources/KodaUI/URLTableView.swift Sources/KodaUI/CrawlController.swift Sources/KodaUI/ContentView.swift Tests/KodaUITests/SortMappingTests.swift
git commit -m "feat: sortable column headers"
```

---

### Task 8: Resume, Replace, or Cancel

Today, starting a crawl against a host that already has a database deletes it and
mentions so afterwards. That notice explains the data loss; it does not prevent
it. This is the third milestone this choice has been deferred from, and M3a is
where the excuse runs out — the UI now exists to host the question.

**Files:**
- Modify: `Sources/KodaUI/CrawlDatabaseLocation.swift`
- Modify: `Sources/KodaUI/CrawlController.swift`
- Modify: `Sources/KodaUI/ContentView.swift`
- Create: `Tests/KodaUITests/ResumeChoiceTests.swift`

**Interfaces:**
- Consumes: `CrawlDatabaseLocation.crawlsDirectory`, `path(forHost:in:)`, `prepare(...)`, `CrawlController`
- Produces:
  - `public struct ExistingCrawl: Equatable, Sendable { public let host: String; public let path: URL; public let modifiedAt: Date; public let urlCount: Int }`
  - `CrawlDatabaseLocation.existing(forHost:in:) -> ExistingCrawl?`
  - `CrawlDatabaseLocation.replace(at:) throws` — deletes the database and its `-wal`/`-shm` sidecars
  - `CrawlController.pendingExistingCrawl: ExistingCrawl?`, plus `resumePending() async`, `replacePending() async`, `cancelPending()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaUITests/ResumeChoiceTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaUI

@MainActor
private func tempDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("koda-resume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a real crawl database with `urls` rows so `existing` can count them.
@MainActor
private func makeCrawl(at path: URL, urls count: Int, finished: Bool) throws {
    let store = try Store(path: path.path)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://old.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        for i in 0..<count {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,0,1,0,?)
                    """,
                arguments: ["https://old.test/\(i)", Data("h\(i)".utf8), "old.test", "/\(i)",
                            finished ? 2 : 0]
            )
        }
    }
    if finished { try store.markFinished(at: Date()) }
}

@MainActor
@Test func existingReturnsNilWhenThereIsNoDatabase() throws {
    let dir = try tempDirectory()
    #expect(CrawlDatabaseLocation.existing(forHost: "absent.test", in: dir) == nil)
}

@MainActor
@Test func existingDescribesWhatWasFound() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 12, finished: true)

    let found = try #require(CrawlDatabaseLocation.existing(forHost: "old.test", in: dir))
    #expect(found.host == "old.test")
    #expect(found.urlCount == 12, "the user needs to know how much they would lose")
    #expect(found.path == path)
}

@MainActor
@Test func replaceRemovesTheDatabaseAndItsSidecars() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 3, finished: true)
    // Simulate the WAL sidecars a live database leaves behind.
    let wal = URL(fileURLWithPath: path.path + "-wal")
    let shm = URL(fileURLWithPath: path.path + "-shm")
    FileManager.default.createFile(atPath: wal.path, contents: Data("stale".utf8))
    FileManager.default.createFile(atPath: shm.path, contents: Data("stale".utf8))

    try CrawlDatabaseLocation.replace(at: path)

    #expect(!FileManager.default.fileExists(atPath: path.path))
    #expect(!FileManager.default.fileExists(atPath: wal.path), "a stale -wal makes the next open fail")
    #expect(!FileManager.default.fileExists(atPath: shm.path))
}

@MainActor
@Test func replaceSucceedsWhenNoSidecarsExist() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 1, finished: true)
    try CrawlDatabaseLocation.replace(at: path)   // must not throw on absent sidecars
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@MainActor
@Test func aFinishedCrawlCanBeReopenedAndStillHasItsRows() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 9, finished: true)

    let reopened = try Store(path: path.path)
    try reopened.migrate()
    let count = try reopened.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
    }
    #expect(count == 9, "resuming a finished crawl means looking at it, not re-running it")
    #expect(try reopened.urlCounts().queued == 0, "nothing left to crawl")
}

@MainActor
@Test func anInterruptedCrawlStillHasAQueueToResume() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 6, finished: false)

    let reopened = try Store(path: path.path)
    try reopened.migrate()
    #expect(try reopened.urlCounts().queued == 6, "resuming continues where it stopped")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ResumeChoice`
Expected: FAIL — `type 'CrawlDatabaseLocation' has no member 'existing'`.

- [ ] **Step 3: Split the location helper**

In `Sources/KodaUI/CrawlDatabaseLocation.swift`, add a description type and two
explicit actions alongside the existing `prepare`:

```swift
/// What was found on disk for a host the user is about to crawl.
/// `Identifiable` so SwiftUI's `.sheet(item:)` can present it directly.
public struct ExistingCrawl: Equatable, Sendable, Identifiable {
    public let host: String
    public let path: URL
    public let modifiedAt: Date
    /// How many URLs the existing crawl holds — the size of what Replace destroys.
    public let urlCount: Int

    public var id: URL { path }
}

extension CrawlDatabaseLocation {
    /// Describes an existing crawl for this host, or nil if there is none.
    /// A database that cannot be read is reported with a count of zero rather
    /// than treated as absent — silently overwriting an unreadable file would be
    /// the same data loss this whole flow exists to prevent.
    public static func existing(forHost host: String, in directory: URL) -> ExistingCrawl? {
        let path = self.path(forHost: host, in: directory)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        let modified = (attributes?[.modificationDate] as? Date) ?? Date.distantPast
        let count = (try? {
            let store = try Store(path: path.path)
            return try store.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
            }
        }()) ?? 0

        return ExistingCrawl(host: host, path: path, modifiedAt: modified, urlCount: count)
    }

    /// Deletes a crawl database and its write-ahead-log sidecars. Leaving a stale
    /// `-wal` behind makes the next open fail with a disk I/O error — found the
    /// hard way in M2.
    public static func replace(at path: URL) throws {
        let fm = FileManager.default
        for candidate in [path.path, path.path + "-wal", path.path + "-shm"] {
            if fm.fileExists(atPath: candidate) {
                try fm.removeItem(atPath: candidate)
            }
        }
    }
}
```

- [ ] **Step 4: Give the controller a pending decision**

In `Sources/KodaUI/CrawlController.swift`, `start()` stops deciding for the user.

**First, replace the existing injection point.** The controller currently takes:

```swift
    private let dbPathForHost: (@MainActor @Sendable (String) throws -> (path: String, replacedExisting: Bool))?
```

That closure does the replacing itself — exactly the decision we are handing back
to the user. Replace it with a directory provider, so the controller derives the
path and owns the choice:

```swift
    /// Where crawl databases live. When nil the controller stays in-memory,
    /// which is what every existing test relies on.
    @ObservationIgnored private let crawlsDirectory: (@MainActor @Sendable () -> URL)?
```

Update `init` accordingly, keeping `dbPath: String? = nil` untouched so the
library stays testable in memory. Note `CrawlDatabaseLocation.crawlsDirectory()`
is **non-throwing and returns a `URL` directly** — no `try`, no optional.

When a database already exists, `start()` publishes the finding and waits:

```swift
    /// Set when Start found an existing crawl for this host and is waiting for
    /// the user to choose. The window presents a sheet; nothing happens until
    /// they answer.
    public private(set) var pendingExistingCrawl: ExistingCrawl?

    /// Continue the existing crawl. An interrupted one picks up its frontier; a
    /// finished one has an empty frontier, so this simply opens and displays it.
    public func resumePending() async {
        guard let pending = pendingExistingCrawl else { return }
        pendingExistingCrawl = nil
        await beginCrawl(dbPath: pending.path.path)
    }

    /// Discard the existing crawl and start fresh.
    public func replacePending() async {
        guard let pending = pendingExistingCrawl else { return }
        pendingExistingCrawl = nil
        do {
            try CrawlDatabaseLocation.replace(at: pending.path)
        } catch {
            notice = "Could not replace the existing crawl: \(error)"
            state = .idle
            return
        }
        await beginCrawl(dbPath: pending.path.path)
    }

    public func cancelPending() {
        pendingExistingCrawl = nil
        state = .idle
    }
```

`start()` becomes the decision point, and the existing crawl-launching body moves
into a private `beginCrawl(dbPath:)` so all three routes share it:

```swift
    public func start() async {
        guard !state.isActive, pendingExistingCrawl == nil else { return }
        notice = nil
        progress = nil

        guard let host = CrawlConfig(seedURL: seedURL).seedHost else {
            notice = "Cannot start: \(seedURL) is not a crawlable http(s) URL."
            state = .idle
            return
        }

        guard let crawlsDirectory else {
            // No directory provider: in-memory, as the tests use it.
            await beginCrawl(dbPath: nil)
            return
        }
        let directory = crawlsDirectory()
        if let existing = CrawlDatabaseLocation.existing(forHost: host, in: directory) {
            pendingExistingCrawl = existing
            return
        }
        await beginCrawl(dbPath: CrawlDatabaseLocation.path(forHost: host, in: directory).path)
    }
```

Keep `beginCrawl`'s body identical to what `start()` does today — preparing the
session, creating the index and row store, launching the run task, and starting
the tick. You are moving code, not rewriting it.

- [ ] **Step 5: Update KodaApp's wiring**

`Sources/KodaApp/KodaApp.swift` currently passes a `dbPathForHost` closure that
prepares and replaces. It now passes only the directory:

```swift
    ContentView(controller: CrawlController(
        crawlsDirectory: { CrawlDatabaseLocation.crawlsDirectory() }
    ))
```

`CrawlDatabaseLocation.prepare(...)` and its `PreparationOutcome` become unused
once nothing calls them. Delete them rather than leaving dead code — the Resume
sheet supersedes the replace-and-notify behaviour they existed for. If something
still references them, say what and why in your report instead of leaving both
paths alive.

- [ ] **Step 6: Present the sheet**

In `Sources/KodaUI/ContentView.swift`, attach a sheet to the root view:

```swift
        .sheet(item: Binding(
            get: { controller.pendingExistingCrawl },
            set: { if $0 == nil { controller.cancelPending() } }
        )) { existing in
            VStack(alignment: .leading, spacing: 14) {
                Text("A crawl of \(existing.host) already exists")
                    .font(.headline)
                Text("\(existing.urlCount) URLs, last updated \(existing.modifiedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .foregroundStyle(.secondary)
                Text("Resuming continues where it stopped. A finished crawl simply opens for browsing. Replacing deletes it permanently.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { controller.cancelPending() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Replace") { Task { await controller.replacePending() } }
                    Button("Resume") { Task { await controller.resumePending() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter ResumeChoice`
Expected: PASS, 6 tests.

- [ ] **Step 8: Run the full suite**

Run: `swift test`
Expected: PASS. `CrawlControllerTests` construct controllers without
`dbPathForHost`, so they take the direct path and are unaffected — confirm that
rather than assuming it.

- [ ] **Step 9: Verify the flow in the app**

Rebuild the bundle (`./Scripts/make-app.sh`) and:

1. Crawl a small site to completion. Confirm a `.koda` file appears under
   `~/Library/Application Support/ScreamingKoda/Crawls/`.
2. Start the same URL again. Confirm the sheet appears and states the URL count.
3. Choose **Resume**. Confirm the previous crawl's rows appear without re-fetching.
4. Start again and choose **Replace**. Confirm the crawl re-runs from scratch.
5. Start again and choose **Cancel**. Confirm nothing happens and the existing
   file is untouched.

Report what you observed at each step. If you cannot drive the UI in this
environment, say so plainly and describe exactly which parts you verified another
way rather than asserting interactions you did not perform.

- [ ] **Step 10: Commit**

```bash
git add Sources/KodaUI/CrawlDatabaseLocation.swift Sources/KodaUI/CrawlController.swift Sources/KodaApp/KodaApp.swift Sources/KodaUI/ContentView.swift Tests/KodaUITests/ResumeChoiceTests.swift
git commit -m "feat: resume, replace, or cancel when a crawl already exists"
```

---

## M3a Completion Criteria

- [ ] `swift test` passes: all M1 and M2 tests plus the new ones
- [ ] A crawl records statuses for external links and sizes for images
- [ ] No batch exceeds `maxPerHost` requests to a single host
- [ ] `checkExternalLinks = false` restores M2's behaviour exactly
- [ ] A fetched image does not appear in the URL table
- [ ] Clicking a column header sorts the table; clicking again reverses it
- [ ] Rows with no status or title sort last in both directions
- [ ] Scrolling to the end of a 10,000-row crawl is as fast as scrolling to the start
- [ ] Starting a crawl over an existing database offers Resume / Replace / Cancel
- [ ] Resuming an interrupted crawl continues it; resuming a finished one displays it
- [ ] `grep -rE 'import (AppKit|SwiftUI)' Sources/KodaCore` returns nothing
- [ ] The only build warning class is the swift-testing deprecation notice

## Deliberately deferred to M3b

The eleven report tabs, sidebar filters and issue counts, and the detail
inspector. Both tabs that needed crawler work — External and Images — now have
data behind them.

## Deferred beyond M3b

CSV and Excel export; a crawl configuration UI; a browsable list of past crawls
beyond the Resume sheet; crawl comparison; resizable and reorderable columns.

Still open from M1, and not addressed here: the write-batching cadence (the spec
promises 100 rows or 500ms, the implementation flushes per fetch batch), and
character-encoding detection (bodies are always decoded as UTF-8). Encoding in
particular will start to matter more in M3b, where garbled titles feed the
duplicate-title report.
