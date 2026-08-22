# M1 Headless Crawler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `KodaCore` end to end — fetch, robots, frontier, parse, store — plus a CLI that crawls a real site and prints a summary. No UI.

**Architecture:** A pure-Swift library with one responsibility per unit and no UI dependencies. `CrawlEngine` is an actor owning frontier state; worker tasks fetch and parse off the actor, then hand results to a batching SQLite writer. Every analyzer-facing type is a plain `Sendable` struct so parsing and analysis are testable with no network and no database.

**Tech Stack:** Swift 6.3, SwiftPM, GRDB 6.29.3 (SQLite), SwiftSoup 2.13.7 (HTML), swift-argument-parser (CLI), swift-testing (tests).

**Spec:** `docs/superpowers/specs/2026-08-17-screaming-koda-design.md`

## Global Constraints

- **Swift tools version:** 6.0. Platform floor `.macOS(.v14)`.
- **No Xcode required.** Everything builds and tests under Command Line Tools. Verified: `swift build` and `swift test` both work.
- **`Testing` and `XCTest` are NOT in the Command Line Tools SDK.** swift-testing must be an explicit package dependency. This is why `Package.swift` depends on `https://github.com/swiftlang/swift-testing`. A deprecation warning ("Swift Testing is now included in the Swift 6 toolchain") is expected and harmless under CLT — do not "fix" it by removing the dependency, which breaks the build. If full Xcode is installed later, remove the dependency then.
- **`KodaCore` must never import AppKit or SwiftUI.** It has to run headless.
- **Analyzer-facing types are plain `Sendable` structs** with no I/O.
- **User agent:** `ScreamingKoda/0.1` (exact string).
- **Politeness defaults are defaults, not options:** respect robots.txt, respect crawl-delay, 5 workers, 5 concurrent per host, 20s timeout, 10-hop max redirect chain, internal `nofollow` not followed, subdomains not crawled, external links status-checked only.
- **A crawl never dies from a bad page.** Transport failures become rows with `status = 0` and an `error_kind`.
- **Commit after every task.**

---

### Task 1: Package skeleton and verified test harness

**Files:**
- Create: `Package.swift`
- Create: `Sources/KodaCore/KodaCore.swift`
- Create: `Sources/koda/main.swift`
- Create: `Tests/KodaCoreTests/HarnessTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: targets `KodaCore` (library), `koda` (executable), `KodaCoreTests` (test target). Public symbol `KodaCore.versionString: String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/KodaCoreTests/HarnessTests.swift`:

```swift
import Testing
@testable import KodaCore

@Test func versionStringIsSet() {
    #expect(KodaCoreInfo.versionString == "0.1.0")
}
```

- [ ] **Step 2: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreamingKoda",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KodaCore", targets: ["KodaCore"]),
        .executable(name: "koda", targets: ["koda"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.3"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.13.7"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Required: XCTest and Testing are absent from the Command Line Tools SDK.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "KodaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SwiftSoup",
            ]
        ),
        .executableTarget(
            name: "koda",
            dependencies: [
                "KodaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "KodaCoreTests",
            dependencies: [
                "KodaCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test`
Expected: FAIL — `cannot find 'KodaCoreInfo' in scope`.

- [ ] **Step 4: Write the minimal implementation**

Create `Sources/KodaCore/KodaCore.swift`:

```swift
import Foundation

public enum KodaCoreInfo {
    public static let versionString = "0.1.0"
    public static let userAgent = "ScreamingKoda/0.1"
}
```

Create `Sources/koda/main.swift`:

```swift
import KodaCore

print("koda \(KodaCoreInfo.versionString)")
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test`
Expected: PASS. First run downloads dependencies and may take several minutes.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources Tests
git commit -m "feat: package skeleton with verified test harness"
```

---

### Task 2: URLNormalizer

Normalisation is where crawlers quietly fail — a normaliser that treats `/a` and `/a/` as identical will silently drop real pages, and one that ignores case in hostnames will crawl the same site twice.

**Deliberate non-normalisations:** trailing slashes are preserved and query parameter order is preserved. Both can be semantically significant (`/a` and `/a/` are different resources on many servers; parameter order matters to some applications). The spec's mention of "trailing slash, parameter order" under this unit refers to *handling them consistently*, not to rewriting them.

**Files:**
- Create: `Sources/KodaCore/URLNormalizer.swift`
- Create: `Tests/KodaCoreTests/URLNormalizerTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct NormalizedURL: Hashable, Sendable` with `absoluteString: String`, `host: String`, `path: String`, `sha256: Data`
  - `public enum URLNormalizer { public static func normalize(_ raw: String, relativeTo base: NormalizedURL?) -> NormalizedURL? }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/URLNormalizerTests.swift`:

```swift
import Foundation
import Testing
@testable import KodaCore

private func norm(_ s: String, base: String? = nil) -> NormalizedURL? {
    let b = base.flatMap { URLNormalizer.normalize($0, relativeTo: nil) }
    return URLNormalizer.normalize(s, relativeTo: b)
}

@Test func lowercasesSchemeAndHost() {
    #expect(norm("HTTP://Example.COM/Path")?.absoluteString == "http://example.com/Path")
}

@Test func preservesPathCase() {
    #expect(norm("http://example.com/CaseSensitive")?.path == "/CaseSensitive")
}

@Test func stripsFragment() {
    #expect(norm("http://example.com/a#section")?.absoluteString == "http://example.com/a")
}

@Test func removesDefaultPorts() {
    #expect(norm("http://example.com:80/a")?.absoluteString == "http://example.com/a")
    #expect(norm("https://example.com:443/a")?.absoluteString == "https://example.com/a")
}

@Test func keepsNonDefaultPort() {
    #expect(norm("http://example.com:8080/a")?.absoluteString == "http://example.com:8080/a")
}

@Test func preservesTrailingSlashDistinction() {
    #expect(norm("http://example.com/a")?.absoluteString != norm("http://example.com/a/")?.absoluteString)
}

@Test func preservesQueryParameterOrder() {
    #expect(norm("http://example.com/a?b=2&a=1")?.absoluteString == "http://example.com/a?b=2&a=1")
}

@Test func emptyPathBecomesRoot() {
    #expect(norm("http://example.com")?.path == "/")
}

@Test func resolvesRelativeReference() {
    #expect(norm("../c", base: "http://example.com/a/b/page")?.absoluteString == "http://example.com/a/c")
}

@Test func resolvesRootRelativeReference() {
    #expect(norm("/x", base: "http://example.com/a/b")?.absoluteString == "http://example.com/x")
}

@Test func rejectsNonHTTPSchemes() {
    #expect(norm("mailto:a@b.com") == nil)
    #expect(norm("tel:+123") == nil)
    #expect(norm("javascript:void(0)") == nil)
    #expect(norm("ftp://example.com/f") == nil)
}

@Test func rejectsGarbage() {
    #expect(norm("") == nil)
    #expect(norm("   ") == nil)
    #expect(norm("http://") == nil)
}

@Test func hashIsStableAndDistinct() {
    let a = norm("http://example.com/a")!
    let b = norm("HTTP://EXAMPLE.com/a")!
    let c = norm("http://example.com/b")!
    #expect(a.sha256 == b.sha256)
    #expect(a.sha256 != c.sha256)
    #expect(a.sha256.count == 32)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter URLNormalizer`
Expected: FAIL — `cannot find 'URLNormalizer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/KodaCore/URLNormalizer.swift`:

```swift
import CryptoKit
import Foundation

public struct NormalizedURL: Hashable, Sendable {
    public let absoluteString: String
    public let host: String
    public let path: String
    public let sha256: Data

    init(absoluteString: String, host: String, path: String) {
        self.absoluteString = absoluteString
        self.host = host
        self.path = path
        self.sha256 = Data(SHA256.hash(data: Data(absoluteString.utf8)))
    }
}

public enum URLNormalizer {
    /// Returns nil for anything that is not a crawlable http(s) URL.
    public static func normalize(_ raw: String, relativeTo base: NormalizedURL?) -> NormalizedURL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolved: URL?
        if let base, let baseURL = URL(string: base.absoluteString) {
            resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        } else {
            resolved = URL(string: trimmed)
        }
        guard let url = resolved,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let rawHost = components.host?.lowercased(), !rawHost.isEmpty else { return nil }

        components.scheme = scheme
        components.host = rawHost
        components.fragment = nil
        components.user = nil
        components.password = nil

        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        // Preserve an empty-but-present query ("?") as absent; keep parameter order otherwise.
        if components.query?.isEmpty == true {
            components.query = nil
        }

        guard let finalURL = components.url else { return nil }
        return NormalizedURL(
            absoluteString: finalURL.absoluteString,
            host: rawHost,
            path: components.path
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter URLNormalizer`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/KodaCore/URLNormalizer.swift Tests/KodaCoreTests/URLNormalizerTests.swift
git commit -m "feat: URL normalization with stable hashing"
```

---

### Task 3: Store — schema and migrations

**Files:**
- Create: `Sources/KodaCore/Store.swift`
- Create: `Sources/KodaCore/CrawlConfig.swift`
- Create: `Tests/KodaCoreTests/StoreSchemaTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct CrawlConfig: Codable, Sendable` (fields listed in implementation below)
  - `public final class Store: @unchecked Sendable` with `init(path: String?) throws` (nil path = in-memory), `let dbQueue: DatabaseQueue`, `func migrate() throws`, `func initializeCrawl(config: CrawlConfig, startedAt: Date) throws`, `func loadConfig() throws -> CrawlConfig?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/StoreSchemaTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore

@Test func migrationCreatesAllTables() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let tables = try store.dbQueue.read { db in
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
    }
    for expected in ["crawl_meta", "hreflang", "images", "links", "page_facts", "responses", "urls"] {
        #expect(tables.contains(expected), "missing table \(expected)")
    }
}

@Test func migrationIsIdempotent() throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.migrate()
    let count = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='table'") ?? 0
    }
    #expect(count > 0)
}

@Test func configRoundTrips() throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://example.com/")
    config.workers = 9
    config.respectRobots = false
    try store.initializeCrawl(config: config, startedAt: Date(timeIntervalSince1970: 1000))
    let loaded = try store.loadConfig()
    #expect(loaded?.workers == 9)
    #expect(loaded?.respectRobots == false)
    #expect(loaded?.seedURL == "https://example.com/")
}

@Test func urlHashIsUnique() throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        let hash = Data(repeating: 1, count: 32)
        try db.execute(
            sql: "INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state) VALUES (?,?,?,?,?,?,?,?)",
            arguments: ["http://a/", hash, "a", "/", 0, 1, 0.0, 0]
        )
        var threw = false
        do {
            try db.execute(
                sql: "INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state) VALUES (?,?,?,?,?,?,?,?)",
                arguments: ["http://a/dup", hash, "a", "/dup", 0, 1, 0.0, 0]
            )
        } catch { threw = true }
        #expect(threw, "duplicate url_hash must be rejected")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Store`
Expected: FAIL — `cannot find 'Store' in scope`.

- [ ] **Step 3: Write CrawlConfig**

Create `Sources/KodaCore/CrawlConfig.swift`:

```swift
import Foundation

public struct CrawlConfig: Codable, Sendable {
    public var seedURL: String
    public var workers: Int = 5
    public var maxPerHost: Int = 5
    public var userAgent: String = KodaCoreInfo.userAgent
    public var timeout: TimeInterval = 20
    public var maxRedirects: Int = 10
    public var respectRobots: Bool = true
    public var followInternalNofollow: Bool = false
    public var crawlSubdomains: Bool = false
    public var maxDepth: Int? = nil
    public var urlCap: Int = 500_000
    public var retainBodies: Bool = true
    public var retainBodyURLLimit: Int = 50_000
    public var include: [String] = []
    public var exclude: [String] = []

    public init(seedURL: String) {
        self.seedURL = seedURL
    }

    /// Host of the seed URL; used to decide internal vs external.
    public var seedHost: String? {
        URLNormalizer.normalize(seedURL, relativeTo: nil)?.host
    }
}
```

- [ ] **Step 4: Write Store with the schema migration**

Create `Sources/KodaCore/Store.swift`:

```swift
import Foundation
import GRDB

public final class Store: @unchecked Sendable {
    public let dbQueue: DatabaseQueue

    /// - Parameter path: file path, or nil for an in-memory database (tests).
    public init(path: String?) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        if let path {
            dbQueue = try DatabaseQueue(path: path, configuration: config)
        } else {
            dbQueue = try DatabaseQueue(configuration: config)
        }
    }

    public func migrate() throws {
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE crawl_meta (
                  id INTEGER PRIMARY KEY CHECK (id = 1),
                  seed_url TEXT NOT NULL,
                  started_at REAL NOT NULL,
                  finished_at REAL,
                  config_json TEXT NOT NULL,
                  schema_version INTEGER NOT NULL
                );

                CREATE TABLE urls (
                  id INTEGER PRIMARY KEY,
                  url TEXT NOT NULL,
                  url_hash BLOB NOT NULL,
                  host TEXT NOT NULL,
                  path TEXT NOT NULL,
                  depth INTEGER NOT NULL,
                  is_internal INTEGER NOT NULL,
                  discovered_at REAL NOT NULL,
                  state INTEGER NOT NULL
                );
                CREATE UNIQUE INDEX idx_urls_hash ON urls(url_hash);
                CREATE INDEX idx_urls_state ON urls(state, depth);

                CREATE TABLE responses (
                  url_id INTEGER PRIMARY KEY REFERENCES urls(id),
                  status INTEGER NOT NULL,
                  error_kind TEXT,
                  content_type TEXT,
                  content_length INTEGER,
                  response_time_ms INTEGER,
                  redirect_target_id INTEGER REFERENCES urls(id),
                  fetched_at REAL NOT NULL,
                  body_gz BLOB
                );
                CREATE INDEX idx_responses_status ON responses(status);

                CREATE TABLE page_facts (
                  url_id INTEGER PRIMARY KEY REFERENCES urls(id),
                  title TEXT, title_length INTEGER, title_count INTEGER,
                  meta_description TEXT, meta_description_length INTEGER, meta_description_count INTEGER,
                  h1 TEXT, h1_count INTEGER, h2_count INTEGER,
                  canonical_id INTEGER REFERENCES urls(id),
                  meta_robots TEXT, x_robots_tag TEXT,
                  lang TEXT,
                  word_count INTEGER,
                  content_hash BLOB
                );
                CREATE INDEX idx_facts_title ON page_facts(title);
                CREATE INDEX idx_facts_desc ON page_facts(meta_description);
                CREATE INDEX idx_facts_hash ON page_facts(content_hash);

                CREATE TABLE links (
                  from_url_id INTEGER NOT NULL REFERENCES urls(id),
                  to_url_id INTEGER NOT NULL REFERENCES urls(id),
                  anchor_text TEXT,
                  rel TEXT,
                  is_internal INTEGER NOT NULL,
                  position INTEGER NOT NULL
                );
                CREATE INDEX idx_links_from ON links(from_url_id);
                CREATE INDEX idx_links_to ON links(to_url_id);

                CREATE TABLE images (
                  url_id INTEGER NOT NULL REFERENCES urls(id),
                  src_url_id INTEGER NOT NULL REFERENCES urls(id),
                  alt TEXT
                );
                CREATE INDEX idx_images_url ON images(url_id);

                CREATE TABLE hreflang (
                  url_id INTEGER NOT NULL REFERENCES urls(id),
                  lang TEXT NOT NULL,
                  href_url_id INTEGER NOT NULL REFERENCES urls(id)
                );
                CREATE INDEX idx_hreflang_url ON hreflang(url_id);
                """)
        }
        return m
    }

    public func initializeCrawl(config: CrawlConfig, startedAt: Date) throws {
        let json = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? "{}"
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO crawl_meta (id, seed_url, started_at, config_json, schema_version)
                    VALUES (1, ?, ?, ?, 1)
                    ON CONFLICT(id) DO UPDATE SET seed_url=excluded.seed_url, config_json=excluded.config_json
                    """,
                arguments: [config.seedURL, startedAt.timeIntervalSince1970, json]
            )
        }
    }

    public func loadConfig() throws -> CrawlConfig? {
        try dbQueue.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT config_json FROM crawl_meta WHERE id = 1") else {
                return nil
            }
            return try JSONDecoder().decode(CrawlConfig.self, from: Data(json.utf8))
        }
    }

    public func markFinished(at date: Date) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE crawl_meta SET finished_at = ? WHERE id = 1",
                arguments: [date.timeIntervalSince1970]
            )
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter Store`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/KodaCore/Store.swift Sources/KodaCore/CrawlConfig.swift Tests/KodaCoreTests/StoreSchemaTests.swift
git commit -m "feat: SQLite schema and crawl configuration"
```

---

### Task 4: Store — frontier operations

The frontier lives in SQLite rather than memory, which is what makes crawls resumable and keeps RAM flat.

**Files:**
- Create: `Sources/KodaCore/Store+Frontier.swift`
- Create: `Tests/KodaCoreTests/FrontierTests.swift`

**Interfaces:**
- Consumes: `Store`, `NormalizedURL` from Tasks 2–3
- Produces, all on `Store`:
  - `public struct FrontierItem: Sendable { public let id: Int64; public let url: NormalizedURL; public let depth: Int }`
  - `func insertURLIfNew(_ url: NormalizedURL, depth: Int, isInternal: Bool, discoveredAt: Date) throws -> Int64` — returns existing id if present
  - `func claimNext(limit: Int) throws -> [FrontierItem]` — flips state 0 → 1
  - `func markDone(_ id: Int64) throws`
  - `func markSkipped(_ id: Int64) throws`
  - `func resetInFlight() throws -> Int`
  - `func urlCounts() throws -> (queued: Int, inFlight: Int, done: Int, total: Int)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/FrontierTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Frontier`
Expected: FAIL — `value of type 'Store' has no member 'insertURLIfNew'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/KodaCore/Store+Frontier.swift`:

```swift
import Foundation
import GRDB

public struct FrontierItem: Sendable {
    public let id: Int64
    public let url: NormalizedURL
    public let depth: Int
}

extension Store {
    /// Inserts the URL if unseen; returns the row id either way.
    public func insertURLIfNew(
        _ url: NormalizedURL,
        depth: Int,
        isInternal: Bool,
        discoveredAt: Date
    ) throws -> Int64 {
        try dbQueue.write { db in
            try Self.insertURL(db, url, depth: depth, isInternal: isInternal, discoveredAt: discoveredAt)
        }
    }

    /// Same as `insertURLIfNew` but inside a caller-managed transaction.
    static func insertURL(
        _ db: Database,
        _ url: NormalizedURL,
        depth: Int,
        isInternal: Bool,
        discoveredAt: Date
    ) throws -> Int64 {
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url_hash = ?", arguments: [url.sha256]) {
            return existing
        }
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                VALUES (?,?,?,?,?,?,?,0)
                """,
            arguments: [url.absoluteString, url.sha256, url.host, url.path, depth, isInternal ? 1 : 0,
                        discoveredAt.timeIntervalSince1970]
        )
        return db.lastInsertedRowID
    }

    /// Claims up to `limit` queued URLs, shallowest first, marking them in-flight.
    public func claimNext(limit: Int) throws -> [FrontierItem] {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, url, host, path, depth FROM urls WHERE state = 0 ORDER BY depth ASC, id ASC LIMIT ?",
                arguments: [limit]
            )
            guard !rows.isEmpty else { return [] }
            let ids = rows.map { $0["id"] as Int64 }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(
                sql: "UPDATE urls SET state = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            return rows.compactMap { row in
                guard let normalized = URLNormalizer.normalize(row["url"], relativeTo: nil) else { return nil }
                return FrontierItem(id: row["id"], url: normalized, depth: row["depth"])
            }
        }
    }

    public func markDone(_ id: Int64) throws {
        try dbQueue.write { db in try Self.setState(db, id: id, state: 2) }
    }

    public func markSkipped(_ id: Int64) throws {
        try dbQueue.write { db in try Self.setState(db, id: id, state: 3) }
    }

    static func setState(_ db: Database, id: Int64, state: Int) throws {
        try db.execute(sql: "UPDATE urls SET state = ? WHERE id = ?", arguments: [state, id])
    }

    /// Requeues URLs left in-flight by a crash or quit. Returns how many were reset.
    @discardableResult
    public func resetInFlight() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE urls SET state = 0 WHERE state = 1")
            return db.changesCount
        }
    }

    public func urlCounts() throws -> (queued: Int, inFlight: Int, done: Int, total: Int) {
        try dbQueue.read { db in
            func count(_ state: Int) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE state = ?", arguments: [state]) ?? 0
            }
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
            return (try count(0), try count(1), try count(2), total)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter Frontier`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/KodaCore/Store+Frontier.swift Tests/KodaCoreTests/FrontierTests.swift
git commit -m "feat: SQLite-backed resumable frontier"
```

---

### Task 5: RobotsPolicy

Parsing only — no network. The fetching half is wired in at Task 10.

Matching rule: the longest matching path pattern wins; `Allow` beats `Disallow` on equal length. `*` matches any sequence, `$` anchors the end. A group for the exact user agent wins over the `*` group.

**Files:**
- Create: `Sources/KodaCore/RobotsPolicy.swift`
- Create: `Tests/KodaCoreTests/RobotsPolicyTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct RobotsRules: Sendable` with `static func parse(_ text: String) -> RobotsRules`, `func isAllowed(path: String, userAgent: String) -> Bool`, `func crawlDelay(userAgent: String) -> Double?`, `var sitemaps: [String]`, `static var allowAll: RobotsRules`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/RobotsPolicyTests.swift`:

```swift
import Testing
@testable import KodaCore

private let sample = """
User-agent: *
Disallow: /private/
Disallow: /tmp
Allow: /private/public-thing
Crawl-delay: 2

User-agent: ScreamingKoda
Disallow: /nope/

Sitemap: https://example.com/sitemap.xml
"""

@Test func allowsUnlistedPaths() {
    let r = RobotsRules.parse(sample)
    #expect(r.isAllowed(path: "/", userAgent: "SomeBot"))
    #expect(r.isAllowed(path: "/about", userAgent: "SomeBot"))
}

@Test func disallowsMatchingPrefix() {
    let r = RobotsRules.parse(sample)
    #expect(!r.isAllowed(path: "/private/secret", userAgent: "SomeBot"))
    #expect(!r.isAllowed(path: "/tmp/x", userAgent: "SomeBot"))
}

@Test func longestMatchWins() {
    let r = RobotsRules.parse(sample)
    #expect(r.isAllowed(path: "/private/public-thing", userAgent: "SomeBot"))
}

@Test func exactUserAgentGroupOverridesWildcard() {
    let r = RobotsRules.parse(sample)
    #expect(!r.isAllowed(path: "/nope/x", userAgent: "ScreamingKoda"))
    // Our own group has no /private rule, so the wildcard group does not apply to us.
    #expect(r.isAllowed(path: "/private/secret", userAgent: "ScreamingKoda"))
}

@Test func userAgentMatchIsCaseInsensitive() {
    let r = RobotsRules.parse(sample)
    #expect(!r.isAllowed(path: "/nope/x", userAgent: "screamingkoda"))
}

@Test func parsesCrawlDelay() {
    let r = RobotsRules.parse(sample)
    #expect(r.crawlDelay(userAgent: "SomeBot") == 2)
    #expect(r.crawlDelay(userAgent: "ScreamingKoda") == nil)
}

@Test func parsesSitemaps() {
    #expect(RobotsRules.parse(sample).sitemaps == ["https://example.com/sitemap.xml"])
}

@Test func emptyDisallowMeansAllowAll() {
    let r = RobotsRules.parse("User-agent: *\nDisallow:")
    #expect(r.isAllowed(path: "/anything", userAgent: "Bot"))
}

@Test func disallowSlashBlocksEverything() {
    let r = RobotsRules.parse("User-agent: *\nDisallow: /")
    #expect(!r.isAllowed(path: "/", userAgent: "Bot"))
    #expect(!r.isAllowed(path: "/a/b", userAgent: "Bot"))
}

@Test func supportsWildcardAndAnchor() {
    let r = RobotsRules.parse("User-agent: *\nDisallow: /*.pdf$")
    #expect(!r.isAllowed(path: "/docs/file.pdf", userAgent: "Bot"))
    #expect(r.isAllowed(path: "/docs/file.pdf.html", userAgent: "Bot"))
}

@Test func ignoresCommentsAndBlankLines() {
    let r = RobotsRules.parse("# comment\n\nUser-agent: *\n  Disallow: /x  # trailing\n")
    #expect(!r.isAllowed(path: "/x", userAgent: "Bot"))
}

@Test func allowAllIsPermissive() {
    #expect(RobotsRules.allowAll.isAllowed(path: "/anything", userAgent: "Bot"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Robots`
Expected: FAIL — `cannot find 'RobotsRules' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/KodaCore/RobotsPolicy.swift`:

```swift
import Foundation

public struct RobotsRules: Sendable {
    struct Rule: Sendable {
        let pattern: String
        let isAllow: Bool
    }

    struct Group: Sendable {
        var rules: [Rule] = []
        var crawlDelay: Double?
    }

    var groups: [String: Group]
    public var sitemaps: [String]

    public static let allowAll = RobotsRules(groups: [:], sitemaps: [])

    public static func parse(_ text: String) -> RobotsRules {
        var groups: [String: Group] = [:]
        var currentAgents: [String] = []
        var sitemaps: [String] = []
        var lastLineWasAgent = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }

            let field = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch field {
            case "user-agent":
                if !lastLineWasAgent { currentAgents = [] }
                currentAgents.append(value.lowercased())
                groups[value.lowercased()] = groups[value.lowercased()] ?? Group()
                lastLineWasAgent = true
            case "disallow", "allow":
                lastLineWasAgent = false
                guard !currentAgents.isEmpty, !value.isEmpty else { continue }
                for agent in currentAgents {
                    groups[agent, default: Group()].rules.append(Rule(pattern: value, isAllow: field == "allow"))
                }
            case "crawl-delay":
                lastLineWasAgent = false
                guard let delay = Double(value) else { continue }
                for agent in currentAgents {
                    groups[agent, default: Group()].crawlDelay = delay
                }
            case "sitemap":
                lastLineWasAgent = false
                sitemaps.append(value)
            default:
                lastLineWasAgent = false
            }
        }
        return RobotsRules(groups: groups, sitemaps: sitemaps)
    }

    /// The group for this agent: an exact match if present, otherwise the wildcard group.
    func group(for userAgent: String) -> Group? {
        let lower = userAgent.lowercased()
        if let exact = groups[lower] { return exact }
        for (name, group) in groups where name != "*" && lower.contains(name) {
            return group
        }
        return groups["*"]
    }

    public func isAllowed(path: String, userAgent: String) -> Bool {
        guard let group = group(for: userAgent) else { return true }
        var best: (length: Int, isAllow: Bool)?
        for rule in group.rules where Self.matches(pattern: rule.pattern, path: path) {
            let length = rule.pattern.count
            if best == nil || length > best!.length || (length == best!.length && rule.isAllow) {
                best = (length, rule.isAllow)
            }
        }
        return best?.isAllow ?? true
    }

    public func crawlDelay(userAgent: String) -> Double? {
        group(for: userAgent)?.crawlDelay
    }

    /// robots.txt globbing: `*` matches any run of characters, `$` anchors the end.
    static func matches(pattern: String, path: String) -> Bool {
        let anchored = pattern.hasSuffix("$")
        let body = anchored ? String(pattern.dropLast()) : pattern
        let segments = body.components(separatedBy: "*")

        var index = path.startIndex
        for (offset, segment) in segments.enumerated() {
            if segment.isEmpty {
                if offset == segments.count - 1 && anchored { return index == path.endIndex }
                continue
            }
            guard let found = path.range(of: segment, range: index..<path.endIndex) else { return false }
            if offset == 0 && found.lowerBound != path.startIndex { return false }
            index = found.upperBound
        }
        if anchored { return index == path.endIndex }
        return true
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter Robots`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/KodaCore/RobotsPolicy.swift Tests/KodaCoreTests/RobotsPolicyTests.swift
git commit -m "feat: robots.txt parsing and path matching"
```

---

### Task 6: HTTPClient and URLSession implementation

Redirects are never followed automatically — each hop must become its own row so chains are reconstructable.

**Files:**
- Create: `Sources/KodaCore/HTTPClient.swift`
- Create: `Tests/KodaCoreTests/HTTPClientTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct HTTPResponse: Sendable { public let status: Int; public let headers: [String: String]; public let body: Data?; public let elapsedMs: Int }`
  - `public enum FetchOutcome: Sendable { case response(HTTPResponse); case failure(kind: String) }`
  - `public protocol HTTPClient: Sendable { func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome }`
  - `public struct URLSessionHTTPClient: HTTPClient` with `init(session: URLSession = ...)`
  - `public extension HTTPResponse { var contentType: String? ; var isRedirect: Bool ; var location: String? }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/HTTPClientTests.swift`:

```swift
import Foundation
import Testing
@testable import KodaCore

/// Serves canned responses so fetcher tests never touch the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, [String: String], Data)] = [:]
    nonisolated(unsafe) static var failWith: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.failWith {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let key = request.url?.absoluteString ?? ""
        let (status, headers, body) = Self.routes[key] ?? (404, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeClient() -> URLSessionHTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSessionHTTPClient(session: URLSession(configuration: config))
}

@Test func fetchesBodyAndStatus() async {
    StubURLProtocol.failWith = nil
    StubURLProtocol.routes = ["https://example.com/": (200, ["Content-Type": "text/html"], Data("<html></html>".utf8))]
    let outcome = await makeClient().fetch(url: "https://example.com/", method: "GET",
                                           userAgent: "ScreamingKoda/0.1", timeout: 5)
    guard case .response(let r) = outcome else { Issue.record("expected response"); return }
    #expect(r.status == 200)
    #expect(r.contentType == "text/html")
    #expect(r.body.map { String(decoding: $0, as: UTF8.self) } == "<html></html>")
}

@Test func doesNotFollowRedirects() async {
    StubURLProtocol.failWith = nil
    StubURLProtocol.routes = [
        "https://example.com/old": (301, ["Location": "https://example.com/new"], Data()),
        "https://example.com/new": (200, ["Content-Type": "text/html"], Data("ok".utf8)),
    ]
    let outcome = await makeClient().fetch(url: "https://example.com/old", method: "GET",
                                           userAgent: "ScreamingKoda/0.1", timeout: 5)
    guard case .response(let r) = outcome else { Issue.record("expected response"); return }
    #expect(r.status == 301)
    #expect(r.isRedirect)
    #expect(r.location == "https://example.com/new")
}

@Test func transportFailureBecomesFailureOutcome() async {
    StubURLProtocol.routes = [:]
    StubURLProtocol.failWith = URLError(.cannotFindHost)
    let outcome = await makeClient().fetch(url: "https://nope.invalid/", method: "GET",
                                           userAgent: "ScreamingKoda/0.1", timeout: 5)
    guard case .failure(let kind) = outcome else { Issue.record("expected failure"); return }
    #expect(kind.contains("cannotFindHost"))
    StubURLProtocol.failWith = nil
}

@Test func invalidURLFails() async {
    let outcome = await makeClient().fetch(url: "not a url", method: "GET",
                                           userAgent: "ScreamingKoda/0.1", timeout: 5)
    guard case .failure(let kind) = outcome else { Issue.record("expected failure"); return }
    #expect(kind == "invalidURL")
}

@Test func headersAreCaseInsensitive() async {
    StubURLProtocol.failWith = nil
    StubURLProtocol.routes = ["https://example.com/h": (200, ["X-Robots-Tag": "noindex"], Data())]
    let outcome = await makeClient().fetch(url: "https://example.com/h", method: "GET",
                                           userAgent: "ScreamingKoda/0.1", timeout: 5)
    guard case .response(let r) = outcome else { Issue.record("expected response"); return }
    #expect(r.header("x-robots-tag") == "noindex")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter HTTPClient`
Expected: FAIL — `cannot find 'URLSessionHTTPClient' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/KodaCore/HTTPClient.swift`:

```swift
import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data?
    public let elapsedMs: Int

    public init(status: Int, headers: [String: String], body: Data?, elapsedMs: Int) {
        self.status = status
        self.headers = headers
        self.body = body
        self.elapsedMs = elapsedMs
    }

    /// Header lookup is case-insensitive, as HTTP requires.
    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    public var contentType: String? {
        header("content-type")?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    public var isRedirect: Bool { (300...399).contains(status) }
    public var location: String? { header("location") }
}

public enum FetchOutcome: Sendable {
    case response(HTTPResponse)
    case failure(kind: String)
}

public protocol HTTPClient: Sendable {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome
}

/// Refuses every redirect so each hop is recorded separately.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private static let delegate = NoRedirectDelegate()

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config, delegate: Self.delegate, delegateQueue: nil)
        }
    }

    public func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        guard let parsed = URL(string: url), parsed.host != nil else {
            return .failure(kind: "invalidURL")
        }
        var request = URLRequest(url: parsed, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let (data, response) = try await session.data(for: request, delegate: Self.delegate)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            guard let http = response as? HTTPURLResponse else {
                return .failure(kind: "nonHTTPResponse")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String { headers[k] = v }
            }
            return .response(HTTPResponse(status: http.statusCode, headers: headers, body: data, elapsedMs: elapsed))
        } catch let error as URLError {
            return .failure(kind: "URLError.\(error.code)")
        } catch {
            return .failure(kind: "\(type(of: error))")
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter HTTPClient`
Expected: PASS, 5 tests. If `kind.contains("cannotFindHost")` fails because `URLError.Code` prints numerically, change the implementation to map codes explicitly and update the test to match the mapped name.

- [ ] **Step 5: Commit**

```bash
git add Sources/KodaCore/HTTPClient.swift Tests/KodaCoreTests/HTTPClientTests.swift
git commit -m "feat: HTTP client with manual redirect handling"
```

---

### Task 7: Parser — HTML to PageFacts

This is the heart of every future report. `PageFacts` is a plain struct, so all analysis downstream is testable with no network and no database.

**Files:**
- Create: `Sources/KodaCore/PageFacts.swift`
- Create: `Sources/KodaCore/Parser.swift`
- Create: `Tests/KodaCoreTests/ParserTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `public struct LinkFact: Sendable { public let href: String; public let anchor: String; public let rel: String?; public let position: Int }`
  - `public struct ImageFact: Sendable { public let src: String; public let alt: String? }`
  - `public struct HreflangFact: Sendable { public let lang: String; public let href: String }`
  - `public struct PageFacts: Sendable` — fields as in the implementation
  - `public protocol PageParser: Sendable { func parse(html: String) throws -> PageFacts }`
  - `public struct SwiftSoupParser: PageParser { public init() }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/ParserTests.swift`:

```swift
import Foundation
import Testing
@testable import KodaCore

private let parser = SwiftSoupParser()

private let page = """
<!doctype html>
<html lang="en-GB">
<head>
  <title>Example Page</title>
  <meta name="description" content="A description here.">
  <link rel="canonical" href="https://example.com/canonical">
  <meta name="robots" content="noindex, follow">
  <link rel="alternate" hreflang="fr" href="https://example.com/fr">
  <link rel="alternate" hreflang="x-default" href="https://example.com/">
</head>
<body>
  <h1>Main Heading</h1>
  <h2>Sub one</h2><h2>Sub two</h2>
  <p>Some visible words here.</p>
  <a href="/internal">Internal link</a>
  <a href="https://other.com/x" rel="nofollow">External link</a>
  <img src="/img/a.png" alt="Alt text">
  <img src="/img/b.png">
  <script>var hidden = "script words";</script>
</body>
</html>
"""

@Test func extractsTitleAndLength() throws {
    let f = try parser.parse(html: page)
    #expect(f.title == "Example Page")
    #expect(f.titleLength == 12)
    #expect(f.titleCount == 1)
}

@Test func extractsMetaDescription() throws {
    let f = try parser.parse(html: page)
    #expect(f.metaDescription == "A description here.")
    #expect(f.metaDescriptionLength == 19)
    #expect(f.metaDescriptionCount == 1)
}

@Test func extractsHeadings() throws {
    let f = try parser.parse(html: page)
    #expect(f.h1 == "Main Heading")
    #expect(f.h1Count == 1)
    #expect(f.h2Count == 2)
}

@Test func extractsCanonicalAndRobotsAndLang() throws {
    let f = try parser.parse(html: page)
    #expect(f.canonical == "https://example.com/canonical")
    #expect(f.metaRobots == "noindex, follow")
    #expect(f.lang == "en-GB")
}

@Test func extractsLinksWithRelAndPosition() throws {
    let f = try parser.parse(html: page)
    #expect(f.links.count == 2)
    #expect(f.links[0].href == "/internal")
    #expect(f.links[0].anchor == "Internal link")
    #expect(f.links[0].position == 0)
    #expect(f.links[1].rel == "nofollow")
}

@Test func extractsImagesIncludingMissingAlt() throws {
    let f = try parser.parse(html: page)
    #expect(f.images.count == 2)
    #expect(f.images[0].alt == "Alt text")
    #expect(f.images[1].alt == nil)
}

@Test func extractsHreflang() throws {
    let f = try parser.parse(html: page)
    #expect(f.hreflang.count == 2)
    #expect(f.hreflang.contains { $0.lang == "fr" && $0.href == "https://example.com/fr" })
    #expect(f.hreflang.contains { $0.lang == "x-default" })
}

@Test func wordCountExcludesScriptContent() throws {
    let f = try parser.parse(html: page)
    #expect(f.wordCount > 0)
    #expect(f.wordCount < 20, "script text must not be counted, got \(f.wordCount)")
}

@Test func contentHashIgnoresScriptsAndWhitespace() throws {
    let a = try parser.parse(html: "<html><body><p>Same   words</p><script>x=1</script></body></html>")
    let b = try parser.parse(html: "<html><body>\n  <p>Same words</p>\n<script>x=2</script></body></html>")
    #expect(a.contentHash == b.contentHash)
}

@Test func contentHashDiffersForDifferentText() throws {
    let a = try parser.parse(html: "<html><body><p>One</p></body></html>")
    let b = try parser.parse(html: "<html><body><p>Two</p></body></html>")
    #expect(a.contentHash != b.contentHash)
}

@Test func handlesMissingElementsWithoutThrowing() throws {
    let f = try parser.parse(html: "<html><body></body></html>")
    #expect(f.title == nil)
    #expect(f.titleCount == 0)
    #expect(f.metaDescription == nil)
    #expect(f.h1 == nil)
    #expect(f.links.isEmpty)
}

@Test func countsDuplicateTitleAndDescriptionTags() throws {
    let html = """
    <html><head><title>A</title><title>B</title>
    <meta name="description" content="one"><meta name="description" content="two"></head><body></body></html>
    """
    let f = try parser.parse(html: html)
    #expect(f.titleCount == 2)
    #expect(f.title == "A", "the first tag wins, matching how browsers behave")
    #expect(f.metaDescriptionCount == 2)
}

@Test func survivesMalformedHTML() throws {
    let f = try parser.parse(html: "<html><head><title>Broken<body><p>text<a href=/x>link")
    #expect(f.title != nil)
    #expect(f.links.count == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Parser`
Expected: FAIL — `cannot find 'SwiftSoupParser' in scope`.

- [ ] **Step 3: Write PageFacts**

Create `Sources/KodaCore/PageFacts.swift`:

```swift
import Foundation

public struct LinkFact: Sendable {
    public let href: String
    public let anchor: String
    public let rel: String?
    public let position: Int

    public init(href: String, anchor: String, rel: String?, position: Int) {
        self.href = href
        self.anchor = anchor
        self.rel = rel
        self.position = position
    }
}

public struct ImageFact: Sendable {
    public let src: String
    public let alt: String?

    public init(src: String, alt: String?) {
        self.src = src
        self.alt = alt
    }
}

public struct HreflangFact: Sendable {
    public let lang: String
    public let href: String

    public init(lang: String, href: String) {
        self.lang = lang
        self.href = href
    }
}

public struct PageFacts: Sendable {
    public var title: String?
    public var titleCount: Int = 0
    public var metaDescription: String?
    public var metaDescriptionCount: Int = 0
    public var h1: String?
    public var h1Count: Int = 0
    public var h2Count: Int = 0
    public var canonical: String?
    public var metaRobots: String?
    public var lang: String?
    public var wordCount: Int = 0
    public var contentHash: Data = Data()
    public var links: [LinkFact] = []
    public var images: [ImageFact] = []
    public var hreflang: [HreflangFact] = []

    public var titleLength: Int? { title?.count }
    public var metaDescriptionLength: Int? { metaDescription?.count }

    public init() {}
}
```

- [ ] **Step 4: Write the parser**

Create `Sources/KodaCore/Parser.swift`:

```swift
import CryptoKit
import Foundation
import SwiftSoup

public protocol PageParser: Sendable {
    func parse(html: String) throws -> PageFacts
}

public struct SwiftSoupParser: PageParser {
    public init() {}

    public func parse(html: String) throws -> PageFacts {
        let doc = try SwiftSoup.parse(html)
        var facts = PageFacts()

        let titles = try doc.select("head title")
        facts.titleCount = titles.count
        facts.title = try titles.first()?.text().trimmed()

        let descriptions = try doc.select("meta[name=description]")
        facts.metaDescriptionCount = descriptions.count
        facts.metaDescription = try descriptions.first()?.attr("content").trimmed()

        let h1s = try doc.select("h1")
        facts.h1Count = h1s.count
        facts.h1 = try h1s.first()?.text().trimmed()
        facts.h2Count = try doc.select("h2").count

        facts.canonical = try doc.select("link[rel=canonical]").first()?.attr("href").trimmed()
        facts.metaRobots = try doc.select("meta[name=robots]").first()?.attr("content").trimmed()
        facts.lang = try doc.select("html").first()?.attr("lang").trimmed()

        // `.array()` is used throughout: SwiftSoup's Elements is not reliably a Sequence across versions.
        for (index, element) in try doc.select("a[href]").array().enumerated() {
            let href = try element.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else { continue }
            let rel = try element.attr("rel").trimmed()
            facts.links.append(
                LinkFact(href: href, anchor: try element.text().trimmed() ?? "", rel: rel, position: index)
            )
        }

        for element in try doc.select("img[src]").array() {
            let src = try element.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !src.isEmpty else { continue }
            let alt = element.hasAttr("alt") ? try element.attr("alt") : nil
            facts.images.append(ImageFact(src: src, alt: alt))
        }

        for element in try doc.select("link[rel=alternate][hreflang]").array() {
            let lang = try element.attr("hreflang").trimmed()
            let href = try element.attr("href").trimmed()
            if let lang, let href { facts.hreflang.append(HreflangFact(lang: lang, href: href)) }
        }

        let text = try Self.visibleText(doc)
        facts.wordCount = text.split(whereSeparator: { $0 == " " }).count
        facts.contentHash = Data(SHA256.hash(data: Data(text.utf8)))

        return facts
    }

    /// Visible text with script, style, and noscript removed and whitespace collapsed.
    static func visibleText(_ doc: Document) throws -> String {
        let copy = doc.copy() as! Document
        try copy.select("script, style, noscript").remove()
        let raw = try copy.body()?.text() ?? ""
        return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension String {
    /// Trimmed, or nil when empty — attributes that are absent and attributes that are blank mean the same thing here.
    func trimmed() -> String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter Parser`
Expected: PASS, 13 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/KodaCore/PageFacts.swift Sources/KodaCore/Parser.swift Tests/KodaCoreTests/ParserTests.swift
git commit -m "feat: HTML parsing into PageFacts"
```

---

### Task 8: Store — batched result writing

Per-row inserts would make SQLite the bottleneck long before the network is. Everything for one page goes in a single transaction, and link targets are created as queued URLs in the same pass — which is what makes discovery and enqueueing the same operation.

**Files:**
- Create: `Sources/KodaCore/CrawlResult.swift`
- Create: `Sources/KodaCore/Store+Write.swift`
- Create: `Tests/KodaCoreTests/StoreWriteTests.swift`

**Interfaces:**
- Consumes: `Store`, `NormalizedURL`, `PageFacts`, `CrawlConfig`
- Produces:
  - `public struct CrawlResult: Sendable` with `urlID: Int64`, `url: NormalizedURL`, `depth: Int`, `status: Int`, `errorKind: String?`, `contentType: String?`, `contentLength: Int?`, `responseTimeMs: Int`, `redirectTarget: NormalizedURL?`, `bodyGz: Data?`, `xRobotsTag: String?`, `facts: PageFacts?`
  - `func write(results: [CrawlResult], config: CrawlConfig, now: Date) throws -> Int` — returns count of newly discovered URLs
  - `public enum Gzip { static func compress(_ data: Data) -> Data?; static func decompress(_ data: Data) -> Data? }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/StoreWriteTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore

private func seededStore() throws -> (Store, CrawlConfig, Int64, NormalizedURL) {
    let store = try Store(path: nil)
    try store.migrate()
    let config = CrawlConfig(seedURL: "https://example.com/")
    try store.initializeCrawl(config: config, startedAt: Date())
    let seed = URLNormalizer.normalize("https://example.com/", relativeTo: nil)!
    let id = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())
    return (store, config, id, seed)
}

private func makeFacts(links: [LinkFact] = [], images: [ImageFact] = [], hreflang: [HreflangFact] = []) -> PageFacts {
    var f = PageFacts()
    f.title = "T"
    f.h1 = "H"
    f.links = links
    f.images = images
    f.hreflang = hreflang
    return f
}

@Test func writesResponseAndFacts() throws {
    let (store, config, id, url) = try seededStore()
    let result = CrawlResult(
        urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
        contentType: "text/html", contentLength: 100, responseTimeMs: 42,
        redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: makeFacts()
    )
    _ = try store.write(results: [result], config: config, now: Date())

    try store.dbQueue.read { db in
        #expect(try Int.fetchOne(db, sql: "SELECT status FROM responses WHERE url_id = ?", arguments: [id]) == 200)
        #expect(try String.fetchOne(db, sql: "SELECT title FROM page_facts WHERE url_id = ?", arguments: [id]) == "T")
    }
    #expect(try store.urlCounts().done == 1)
}

@Test func discoveredLinksBecomeQueuedURLs() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [
        LinkFact(href: "/a", anchor: "A", rel: nil, position: 0),
        LinkFact(href: "/b", anchor: "B", rel: nil, position: 1),
    ])
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                             contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)

    let discovered = try store.write(results: [result], config: config, now: Date())

    #expect(discovered == 2)
    #expect(try store.urlCounts().queued == 2)
    #expect(try store.claimNext(limit: 10).first?.depth == 1, "children are one level deeper than the parent")
}

@Test func linkRowsRecordAnchorAndRel() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [LinkFact(href: "https://other.com/x", anchor: "Out", rel: "nofollow", position: 0)])
    _ = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                              contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                              redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                        config: config, now: Date())
    try store.dbQueue.read { db in
        let row = try Row.fetchOne(db, sql: "SELECT anchor_text, rel, is_internal FROM links WHERE from_url_id = ?",
                                   arguments: [id])
        #expect(row?["anchor_text"] == "Out")
        #expect(row?["rel"] == "nofollow")
        #expect(row?["is_internal"] == 0, "other.com is external to example.com")
    }
}

@Test func externalHostsAreMarkedExternal() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [LinkFact(href: "https://other.com/x", anchor: "x", rel: nil, position: 0)])
    _ = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                              contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                              redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                        config: config, now: Date())
    try store.dbQueue.read { db in
        #expect(try Int.fetchOne(db, sql: "SELECT is_internal FROM urls WHERE host = 'other.com'") == 0)
    }
}

@Test func transportFailureIsRecordedNotDropped() throws {
    let (store, config, id, url) = try seededStore()
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 0, errorKind: "URLError.timedOut",
                             contentType: nil, contentLength: nil, responseTimeMs: 20_000,
                             redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: nil)
    _ = try store.write(results: [result], config: config, now: Date())
    try store.dbQueue.read { db in
        let row = try Row.fetchOne(db, sql: "SELECT status, error_kind FROM responses WHERE url_id = ?", arguments: [id])
        #expect(row?["status"] == 0)
        #expect(row?["error_kind"] == "URLError.timedOut")
    }
    #expect(try store.urlCounts().done == 1, "a failed fetch still completes the URL")
}

@Test func redirectTargetIsLinkedAndQueued() throws {
    let (store, config, id, url) = try seededStore()
    let target = URLNormalizer.normalize("https://example.com/new", relativeTo: nil)!
    let result = CrawlResult(urlID: id, url: url, depth: 0, status: 301, errorKind: nil,
                             contentType: nil, contentLength: nil, responseTimeMs: 5,
                             redirectTarget: target, bodyGz: nil, xRobotsTag: nil, facts: nil)
    _ = try store.write(results: [result], config: config, now: Date())
    try store.dbQueue.read { db in
        let targetID = try Int64.fetchOne(db, sql: "SELECT redirect_target_id FROM responses WHERE url_id = ?",
                                          arguments: [id])
        #expect(targetID != nil)
        let targetURL = try String.fetchOne(db, sql: "SELECT url FROM urls WHERE id = ?", arguments: [targetID])
        #expect(targetURL == "https://example.com/new")
    }
}

@Test func imagesAndHreflangAreWritten() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(
        images: [ImageFact(src: "/img/a.png", alt: "Alt")],
        hreflang: [HreflangFact(lang: "fr", href: "https://example.com/fr")]
    )
    _ = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                              contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                              redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                        config: config, now: Date())
    try store.dbQueue.read { db in
        #expect(try String.fetchOne(db, sql: "SELECT alt FROM images WHERE url_id = ?", arguments: [id]) == "Alt")
        #expect(try String.fetchOne(db, sql: "SELECT lang FROM hreflang WHERE url_id = ?", arguments: [id]) == "fr")
    }
}

@Test func excludePatternsBlockDiscovery() throws {
    var (store, config, id, url) = try seededStore()
    config.exclude = ["/admin"]
    let facts = makeFacts(links: [
        LinkFact(href: "/admin/panel", anchor: "Admin", rel: nil, position: 0),
        LinkFact(href: "/public", anchor: "Public", rel: nil, position: 1),
    ])
    let discovered = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                                          contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                                          redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                                     config: config, now: Date())
    #expect(discovered == 1)
    try store.dbQueue.read { db in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE path LIKE '/admin%'") == 0)
    }
}

@Test func nofollowLinksAreNotQueuedByDefault() throws {
    let (store, config, id, url) = try seededStore()
    let facts = makeFacts(links: [LinkFact(href: "/nofollowed", anchor: "N", rel: "nofollow", position: 0)])
    let discovered = try store.write(results: [CrawlResult(urlID: id, url: url, depth: 0, status: 200, errorKind: nil,
                                                          contentType: "text/html", contentLength: 1, responseTimeMs: 1,
                                                          redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: facts)],
                                     config: config, now: Date())
    #expect(discovered == 0)
    try store.dbQueue.read { db in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM links WHERE from_url_id = ?", arguments: [id]) == 1,
                "the link is still recorded, just not crawled")
    }
}

@Test func gzipRoundTrips() {
    let original = Data(String(repeating: "hello world ", count: 500).utf8)
    let compressed = Gzip.compress(original)
    #expect(compressed != nil)
    #expect(compressed!.count < original.count)
    #expect(Gzip.decompress(compressed!) == original)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter StoreWrite`
Expected: FAIL — `cannot find 'CrawlResult' in scope`.

- [ ] **Step 3: Write CrawlResult and Gzip**

Create `Sources/KodaCore/CrawlResult.swift`:

```swift
import Foundation

public struct CrawlResult: Sendable {
    public let urlID: Int64
    public let url: NormalizedURL
    public let depth: Int
    public let status: Int
    public let errorKind: String?
    public let contentType: String?
    public let contentLength: Int?
    public let responseTimeMs: Int
    public let redirectTarget: NormalizedURL?
    public let bodyGz: Data?
    public let xRobotsTag: String?
    public let facts: PageFacts?

    public init(
        urlID: Int64, url: NormalizedURL, depth: Int, status: Int, errorKind: String?,
        contentType: String?, contentLength: Int?, responseTimeMs: Int,
        redirectTarget: NormalizedURL?, bodyGz: Data?, xRobotsTag: String?, facts: PageFacts?
    ) {
        self.urlID = urlID
        self.url = url
        self.depth = depth
        self.status = status
        self.errorKind = errorKind
        self.contentType = contentType
        self.contentLength = contentLength
        self.responseTimeMs = responseTimeMs
        self.redirectTarget = redirectTarget
        self.bodyGz = bodyGz
        self.xRobotsTag = xRobotsTag
        self.facts = facts
    }
}

public enum Gzip {
    public static func compress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    public static func decompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }
}
```

- [ ] **Step 4: Write the batched writer**

Create `Sources/KodaCore/Store+Write.swift`:

```swift
import Foundation
import GRDB

extension Store {
    /// Writes a batch of results in one transaction. Returns the number of newly discovered URLs.
    @discardableResult
    public func write(results: [CrawlResult], config: CrawlConfig, now: Date) throws -> Int {
        guard !results.isEmpty else { return 0 }
        let seedHost = config.seedHost
        var discovered = 0

        try dbQueue.write { db in
            for result in results {
                try db.execute(
                    sql: """
                        INSERT INTO responses
                          (url_id, status, error_kind, content_type, content_length,
                           response_time_ms, redirect_target_id, fetched_at, body_gz)
                        VALUES (?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(url_id) DO UPDATE SET
                          status=excluded.status, error_kind=excluded.error_kind,
                          content_type=excluded.content_type, content_length=excluded.content_length,
                          response_time_ms=excluded.response_time_ms,
                          redirect_target_id=excluded.redirect_target_id,
                          fetched_at=excluded.fetched_at, body_gz=excluded.body_gz
                        """,
                    arguments: [
                        result.urlID, result.status, result.errorKind, result.contentType,
                        result.contentLength, result.responseTimeMs,
                        try Self.resolveTarget(db, result.redirectTarget, parent: result,
                                               config: config, seedHost: seedHost, now: now, discovered: &discovered),
                        now.timeIntervalSince1970, result.bodyGz,
                    ]
                )

                if let facts = result.facts {
                    try writeFacts(db, facts: facts, result: result, config: config,
                                   seedHost: seedHost, now: now, discovered: &discovered)
                }

                try Self.setState(db, id: result.urlID, state: 2)
            }
        }
        return discovered
    }

    private func writeFacts(
        _ db: Database, facts: PageFacts, result: CrawlResult, config: CrawlConfig,
        seedHost: String?, now: Date, discovered: inout Int
    ) throws {
        let canonicalNormalized = facts.canonical.flatMap { URLNormalizer.normalize($0, relativeTo: result.url) }
        let canonicalID = try Self.resolveTarget(db, canonicalNormalized, parent: result, config: config,
                                                 seedHost: seedHost, now: now, discovered: &discovered)

        try db.execute(
            sql: """
                INSERT INTO page_facts
                  (url_id, title, title_length, title_count,
                   meta_description, meta_description_length, meta_description_count,
                   h1, h1_count, h2_count, canonical_id, meta_robots, x_robots_tag,
                   lang, word_count, content_hash)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(url_id) DO UPDATE SET title=excluded.title
                """,
            arguments: [
                result.urlID, facts.title, facts.titleLength, facts.titleCount,
                facts.metaDescription, facts.metaDescriptionLength, facts.metaDescriptionCount,
                facts.h1, facts.h1Count, facts.h2Count, canonicalID, facts.metaRobots, result.xRobotsTag,
                facts.lang, facts.wordCount, facts.contentHash,
            ]
        )

        try db.execute(sql: "DELETE FROM links WHERE from_url_id = ?", arguments: [result.urlID])
        for link in facts.links {
            guard let target = URLNormalizer.normalize(link.href, relativeTo: result.url) else { continue }
            let isInternal = Self.isInternal(target, seedHost: seedHost, config: config)
            let isNofollow = link.rel?.lowercased().contains("nofollow") == true
            let crawlable = isInternal && (!isNofollow || config.followInternalNofollow)

            // nil means the URL was filtered out — skip just this link, never the transaction.
            guard let targetID = try Self.upsertURLOrSkip(db, target, parentDepth: result.depth, config: config,
                                                          seedHost: seedHost, now: now,
                                                          enqueue: crawlable, discovered: &discovered)
            else { continue }
            try db.execute(
                sql: "INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position) VALUES (?,?,?,?,?,?)",
                arguments: [result.urlID, targetID, link.anchor, link.rel, isInternal ? 1 : 0, link.position]
            )
        }

        try db.execute(sql: "DELETE FROM images WHERE url_id = ?", arguments: [result.urlID])
        for image in facts.images {
            guard let src = URLNormalizer.normalize(image.src, relativeTo: result.url) else { continue }
            let srcID = try Self.upsertURL(db, src, parentDepth: result.depth, config: config,
                                           seedHost: seedHost, now: now, enqueue: false, discovered: &discovered)
            try db.execute(sql: "INSERT INTO images (url_id, src_url_id, alt) VALUES (?,?,?)",
                           arguments: [result.urlID, srcID, image.alt])
        }

        try db.execute(sql: "DELETE FROM hreflang WHERE url_id = ?", arguments: [result.urlID])
        for entry in facts.hreflang {
            guard let href = URLNormalizer.normalize(entry.href, relativeTo: result.url) else { continue }
            let hrefID = try Self.upsertURL(db, href, parentDepth: result.depth, config: config,
                                            seedHost: seedHost, now: now,
                                            enqueue: Self.isInternal(href, seedHost: seedHost, config: config),
                                            discovered: &discovered)
            try db.execute(sql: "INSERT INTO hreflang (url_id, lang, href_url_id) VALUES (?,?,?)",
                           arguments: [result.urlID, entry.lang, hrefID])
        }
    }

    static func resolveTarget(
        _ db: Database, _ target: NormalizedURL?, parent: CrawlResult, config: CrawlConfig,
        seedHost: String?, now: Date, discovered: inout Int
    ) throws -> Int64? {
        guard let target else { return nil }
        return try upsertURL(db, target, parentDepth: parent.depth, config: config, seedHost: seedHost,
                             now: now, enqueue: isInternal(target, seedHost: seedHost, config: config),
                             discovered: &discovered)
    }

    /// Inserts the URL if unseen. `enqueue` false means the row is recorded as skipped rather than queued.
    static func upsertURL(
        _ db: Database, _ url: NormalizedURL, parentDepth: Int, config: CrawlConfig,
        seedHost: String?, now: Date, enqueue: Bool, discovered: inout Int
    ) throws -> Int64 {
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url_hash = ?", arguments: [url.sha256]) {
            return existing
        }
        let internalFlag = isInternal(url, seedHost: seedHost, config: config)
        let depth = parentDepth + 1

        var shouldQueue = enqueue
        if shouldQueue, let maxDepth = config.maxDepth, depth > maxDepth { shouldQueue = false }
        if shouldQueue, !passesFilters(url, config: config) { shouldQueue = false }
        if shouldQueue {
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
            if total >= config.urlCap { shouldQueue = false }
        }

        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                VALUES (?,?,?,?,?,?,?,?)
                """,
            arguments: [url.absoluteString, url.sha256, url.host, url.path, depth,
                        internalFlag ? 1 : 0, now.timeIntervalSince1970, shouldQueue ? 0 : 3]
        )
        if shouldQueue { discovered += 1 }
        return db.lastInsertedRowID
    }

    static func isInternal(_ url: NormalizedURL, seedHost: String?, config: CrawlConfig) -> Bool {
        guard let seedHost else { return false }
        if url.host == seedHost { return true }
        if config.crawlSubdomains {
            let base = seedHost.hasPrefix("www.") ? String(seedHost.dropFirst(4)) : seedHost
            return url.host == base || url.host.hasSuffix("." + base)
        }
        return false
    }

    static func passesFilters(_ url: NormalizedURL, config: CrawlConfig) -> Bool {
        let target = url.absoluteString
        for pattern in config.exclude where target.range(of: pattern, options: .regularExpression) != nil {
            return false
        }
        guard !config.include.isEmpty else { return true }
        return config.include.contains { target.range(of: $0, options: .regularExpression) != nil }
    }

    /// Returns nil when a to-be-crawled URL is filtered out, so the caller skips
    /// only that link. Excluded URLs are never recorded, so they stay out of reports.
    static func upsertURLOrSkip(
        _ db: Database, _ url: NormalizedURL, parentDepth: Int, config: CrawlConfig,
        seedHost: String?, now: Date, enqueue: Bool, discovered: inout Int
    ) throws -> Int64? {
        if enqueue && !passesFilters(url, config: config) { return nil }
        return try upsertURL(db, url, parentDepth: parentDepth, config: config, seedHost: seedHost,
                             now: now, enqueue: enqueue, discovered: &discovered)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter StoreWrite`
Expected: PASS, 10 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/KodaCore/CrawlResult.swift Sources/KodaCore/Store+Write.swift Tests/KodaCoreTests/StoreWriteTests.swift
git commit -m "feat: batched result writing with link discovery"
```

---

### Task 9: CrawlEngine

**Files:**
- Create: `Sources/KodaCore/CrawlEngine.swift`
- Create: `Tests/KodaCoreTests/CrawlEngineTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–8
- Produces:
  - `public struct CrawlProgress: Sendable { public let crawled: Int; public let queued: Int; public let discovered: Int }`
  - `public actor CrawlEngine` with `init(store: Store, client: HTTPClient, parser: PageParser, config: CrawlConfig, robots: RobotsRules = .allowAll)`, `func run(onProgress: (@Sendable (CrawlProgress) -> Void)?) async throws`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/CrawlEngineTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore

/// A fixture site with a known shape: a redirect chain, a 404, duplicate titles, a noindex page.
private struct FixtureClient: HTTPClient {
    let pages: [String: (Int, [String: String], String)]

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        guard let (status, headers, body) = pages[url] else {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        var merged = headers
        if merged["Content-Type"] == nil { merged["Content-Type"] = "text/html" }
        return .response(HTTPResponse(status: status, headers: merged, body: Data(body.utf8), elapsedMs: 1))
    }
}

private func html(title: String, body: String) -> String {
    "<html><head><title>\(title)</title></head><body>\(body)</body></html>"
}

private let site: [String: (Int, [String: String], String)] = [
    "https://site.test/": (200, [:], html(title: "Home", body: """
        <a href="/about">About</a><a href="/old">Old</a><a href="/gone">Gone</a>
        <a href="/dupe">Dupe</a><a href="https://external.test/x">Ext</a>
        """)),
    "https://site.test/about": (200, [:], html(title: "About", body: "<p>About us</p>")),
    "https://site.test/old": (301, ["Location": "https://site.test/new"], ""),
    "https://site.test/new": (200, [:], html(title: "New", body: "<p>Moved here</p>")),
    "https://site.test/gone": (404, [:], ""),
    "https://site.test/dupe": (200, [:], html(title: "About", body: "<p>Duplicate title</p>")),
]

private func runCrawl(config: CrawlConfig? = nil) async throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    var cfg = config ?? CrawlConfig(seedURL: "https://site.test/")
    cfg.workers = 2
    try store.initializeCrawl(config: cfg, startedAt: Date())
    let seed = URLNormalizer.normalize(cfg.seedURL, relativeTo: nil)!
    _ = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())

    let engine = CrawlEngine(store: store, client: FixtureClient(pages: site),
                             parser: SwiftSoupParser(), config: cfg)
    try await engine.run(onProgress: nil)
    return store
}

@Test func crawlsEveryInternalPage() async throws {
    let store = try await runCrawl()
    let crawled = try store.dbQueue.read { db in
        try String.fetchAll(db, sql: """
            SELECT u.path FROM urls u JOIN responses r ON r.url_id = u.id
            WHERE u.is_internal = 1 ORDER BY u.path
            """)
    }
    #expect(crawled == ["/", "/about", "/dupe", "/gone", "/new", "/old"])
}

@Test func recordsRedirectChain() async throws {
    let store = try await runCrawl()
    try store.dbQueue.read { db in
        let row = try Row.fetchOne(db, sql: """
            SELECT r.status, t.url AS target FROM responses r
            JOIN urls u ON u.id = r.url_id
            LEFT JOIN urls t ON t.id = r.redirect_target_id
            WHERE u.path = '/old'
            """)
        #expect(row?["status"] == 301)
        #expect(row?["target"] == "https://site.test/new")
    }
}

@Test func recordsNotFound() async throws {
    let store = try await runCrawl()
    let status = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT r.status FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/gone'")
    }
    #expect(status == 404)
}

@Test func externalLinksAreRecordedButNotCrawled() async throws {
    let store = try await runCrawl()
    try store.dbQueue.read { db in
        let external = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE host = 'external.test'")
        #expect(external == 1)
        let fetched = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.host = 'external.test'
            """)
        #expect(fetched == 0, "external URLs are not fetched in M1")
    }
}

@Test func duplicateTitlesAreQueryable() async throws {
    let store = try await runCrawl()
    let dupes = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM (SELECT title FROM page_facts WHERE title IS NOT NULL
                                  GROUP BY title HAVING count(*) > 1)
            """)
    }
    #expect(dupes == 1, "About appears twice")
}

@Test func terminatesAndMarksNothingInFlight() async throws {
    let store = try await runCrawl()
    let counts = try store.urlCounts()
    #expect(counts.queued == 0)
    #expect(counts.inFlight == 0)
}

@Test func respectsURLCap() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.urlCap = 2
    let store = try await runCrawl(config: config)
    #expect(try store.urlCounts().done <= 3, "cap limits how much gets queued")
}

@Test func respectsMaxDepth() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.maxDepth = 0
    let store = try await runCrawl(config: config)
    let fetched = try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM responses") ?? 0 }
    #expect(fetched == 1, "only the seed is crawled at depth 0")
}

@Test func robotsDisallowSkipsURL() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 1
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize("https://site.test/", relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    let robots = RobotsRules.parse("User-agent: *\nDisallow: /about")
    let engine = CrawlEngine(store: store, client: FixtureClient(pages: site),
                             parser: SwiftSoupParser(), config: config, robots: robots)
    try await engine.run(onProgress: nil)

    let aboutFetched = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/about'
            """) ?? 0
    }
    #expect(aboutFetched == 0)
}

@Test func reportsProgress() async throws {
    let store = try Store(path: nil)
    try store.migrate()
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 1
    try store.initializeCrawl(config: config, startedAt: Date())
    _ = try store.insertURLIfNew(URLNormalizer.normalize("https://site.test/", relativeTo: nil)!,
                                 depth: 0, isInternal: true, discoveredAt: Date())

    final class Box: @unchecked Sendable { var updates: [CrawlProgress] = [] }
    let box = Box()
    let engine = CrawlEngine(store: store, client: FixtureClient(pages: site),
                             parser: SwiftSoupParser(), config: config)
    try await engine.run(onProgress: { box.updates.append($0) })

    #expect(!box.updates.isEmpty)
    #expect(box.updates.last!.crawled >= 6)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CrawlEngine`
Expected: FAIL — `cannot find 'CrawlEngine' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/KodaCore/CrawlEngine.swift`:

```swift
import Foundation

public struct CrawlProgress: Sendable {
    public let crawled: Int
    public let queued: Int
    public let discovered: Int
}

public actor CrawlEngine {
    private let store: Store
    private let client: HTTPClient
    private let parser: PageParser
    private let config: CrawlConfig
    private let robots: RobotsRules

    private var crawled = 0
    private var discovered = 0

    public init(
        store: Store,
        client: HTTPClient,
        parser: PageParser,
        config: CrawlConfig,
        robots: RobotsRules = .allowAll
    ) {
        self.store = store
        self.client = client
        self.parser = parser
        self.config = config
        self.robots = robots
    }

    /// Drains the frontier until nothing is queued. Never throws on a bad page.
    public func run(onProgress: (@Sendable (CrawlProgress) -> Void)?) async throws {
        try store.resetInFlight()
        let batchSize = max(config.workers, 1)

        while true {
            let batch = try store.claimNext(limit: batchSize)
            if batch.isEmpty { break }

            var results: [CrawlResult] = []
            results.reserveCapacity(batch.count)

            await withTaskGroup(of: CrawlResult?.self) { group in
                for item in batch {
                    group.addTask { [config, robots, client, parser] in
                        await Self.process(item: item, config: config, robots: robots,
                                           client: client, parser: parser)
                    }
                }
                for await result in group {
                    if let result { results.append(result) }
                }
            }

            // URLs skipped by robots produce no result; close them out so they leave the frontier.
            let produced = Set(results.map(\.urlID))
            for item in batch where !produced.contains(item.id) {
                try store.markSkipped(item.id)
            }

            if !results.isEmpty {
                discovered += try store.write(results: results, config: config, now: Date())
                crawled += results.count
            }

            if let onProgress {
                let counts = try store.urlCounts()
                onProgress(CrawlProgress(crawled: crawled, queued: counts.queued, discovered: discovered))
            }

            if let delay = robots.crawlDelay(userAgent: config.userAgent), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        try store.markFinished(at: Date())
    }

    private static func process(
        item: FrontierItem, config: CrawlConfig, robots: RobotsRules,
        client: HTTPClient, parser: PageParser
    ) async -> CrawlResult? {
        if config.respectRobots, !robots.isAllowed(path: item.url.path, userAgent: config.userAgent) {
            return nil
        }

        let outcome = await client.fetch(url: item.url.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout)

        switch outcome {
        case .failure(let kind):
            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth, status: 0, errorKind: kind,
                contentType: nil, contentLength: nil, responseTimeMs: 0,
                redirectTarget: nil, bodyGz: nil, xRobotsTag: nil, facts: nil
            )

        case .response(let response):
            let redirectTarget = response.isRedirect
                ? response.location.flatMap { URLNormalizer.normalize($0, relativeTo: item.url) }
                : nil

            var facts: PageFacts?
            var bodyGz: Data?
            let isHTML = response.contentType?.contains("html") == true

            if isHTML, let body = response.body, !body.isEmpty {
                let html = String(decoding: body, as: UTF8.self)
                facts = try? parser.parse(html: html)
                if config.retainBodies { bodyGz = Gzip.compress(body) }
            }

            return CrawlResult(
                urlID: item.id, url: item.url, depth: item.depth,
                status: response.status, errorKind: nil,
                contentType: response.contentType,
                contentLength: response.body?.count,
                responseTimeMs: response.elapsedMs,
                redirectTarget: redirectTarget, bodyGz: bodyGz,
                xRobotsTag: response.header("x-robots-tag"), facts: facts
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CrawlEngine`
Expected: PASS, 10 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, all tests from Tasks 1–9.

- [ ] **Step 6: Commit**

```bash
git add Sources/KodaCore/CrawlEngine.swift Tests/KodaCoreTests/CrawlEngineTests.swift
git commit -m "feat: crawl engine actor with worker pool"
```

---

### Task 10: Robots fetching and crawl session assembly

Task 9 takes robots rules as a parameter. This wires in fetching them, and gives callers one entry point that sets up a crawl from nothing.

**Files:**
- Create: `Sources/KodaCore/CrawlSession.swift`
- Create: `Tests/KodaCoreTests/CrawlSessionTests.swift`

**Interfaces:**
- Consumes: `Store`, `CrawlConfig`, `HTTPClient`, `CrawlEngine`, `RobotsRules`
- Produces:
  - `public enum CrawlSession { public static func fetchRobots(for seed: NormalizedURL, client: HTTPClient, config: CrawlConfig) async -> RobotsRules }`
  - `public static func start(dbPath: String?, config: CrawlConfig, client: HTTPClient, parser: PageParser, onProgress: (@Sendable (CrawlProgress) -> Void)?) async throws -> Store`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/CrawlSessionTests.swift`:

```swift
import Foundation
import Testing
@testable import KodaCore

private struct RobotsClient: HTTPClient {
    let robotsStatus: Int
    let robotsBody: String

    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: robotsStatus, headers: ["Content-Type": "text/plain"],
                                          body: Data(robotsBody.utf8), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data("<html><head><title>P</title></head><body></body></html>".utf8),
                                      elapsedMs: 1))
    }
}

@Test func fetchesAndParsesRobots() async {
    let seed = URLNormalizer.normalize("https://site.test/some/page", relativeTo: nil)!
    let client = RobotsClient(robotsStatus: 200, robotsBody: "User-agent: *\nDisallow: /blocked")
    let rules = await CrawlSession.fetchRobots(for: seed, client: client, config: CrawlConfig(seedURL: seed.absoluteString))
    #expect(!rules.isAllowed(path: "/blocked", userAgent: "ScreamingKoda/0.1"))
    #expect(rules.isAllowed(path: "/allowed", userAgent: "ScreamingKoda/0.1"))
}

@Test func missingRobotsMeansAllowAll() async {
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    let client = RobotsClient(robotsStatus: 404, robotsBody: "")
    let rules = await CrawlSession.fetchRobots(for: seed, client: client, config: CrawlConfig(seedURL: seed.absoluteString))
    #expect(rules.isAllowed(path: "/anything", userAgent: "ScreamingKoda/0.1"))
}

@Test func robotsDisabledSkipsFetchEntirely() async {
    let seed = URLNormalizer.normalize("https://site.test/", relativeTo: nil)!
    var config = CrawlConfig(seedURL: seed.absoluteString)
    config.respectRobots = false
    let client = RobotsClient(robotsStatus: 200, robotsBody: "User-agent: *\nDisallow: /")
    let rules = await CrawlSession.fetchRobots(for: seed, client: client, config: config)
    #expect(rules.isAllowed(path: "/anything", userAgent: "ScreamingKoda/0.1"))
}

@Test func startSeedsFrontierAndCrawls() async throws {
    var config = CrawlConfig(seedURL: "https://site.test/")
    config.workers = 1
    let store = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: RobotsClient(robotsStatus: 404, robotsBody: ""),
        parser: SwiftSoupParser(), onProgress: nil
    )
    let counts = try store.urlCounts()
    #expect(counts.done >= 1)
    #expect(counts.queued == 0)
}

@Test func startRejectsInvalidSeed() async {
    let config = CrawlConfig(seedURL: "not a url")
    await #expect(throws: (any Error).self) {
        _ = try await CrawlSession.start(dbPath: nil, config: config,
                                         client: RobotsClient(robotsStatus: 404, robotsBody: ""),
                                         parser: SwiftSoupParser(), onProgress: nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CrawlSession`
Expected: FAIL — `cannot find 'CrawlSession' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/KodaCore/CrawlSession.swift`:

```swift
import Foundation

public enum CrawlSessionError: Error, CustomStringConvertible {
    case invalidSeedURL(String)

    public var description: String {
        switch self {
        case .invalidSeedURL(let raw): return "Not a crawlable http(s) URL: \(raw)"
        }
    }
}

public enum CrawlSession {
    /// Fetches and parses robots.txt. Any failure means allow-all — a missing
    /// robots.txt permits crawling, and a broken one must not block the crawl.
    public static func fetchRobots(
        for seed: NormalizedURL,
        client: HTTPClient,
        config: CrawlConfig
    ) async -> RobotsRules {
        guard config.respectRobots else { return .allowAll }
        guard let robotsURL = URLNormalizer.normalize("/robots.txt", relativeTo: seed) else { return .allowAll }

        let outcome = await client.fetch(url: robotsURL.absoluteString, method: "GET",
                                         userAgent: config.userAgent, timeout: config.timeout)
        guard case .response(let response) = outcome,
              response.status == 200,
              let body = response.body
        else { return .allowAll }

        return RobotsRules.parse(String(decoding: body, as: UTF8.self))
    }

    /// Creates the database, seeds the frontier, fetches robots, and runs the crawl to completion.
    @discardableResult
    public static func start(
        dbPath: String?,
        config: CrawlConfig,
        client: HTTPClient,
        parser: PageParser,
        onProgress: (@Sendable (CrawlProgress) -> Void)?
    ) async throws -> Store {
        guard let seed = URLNormalizer.normalize(config.seedURL, relativeTo: nil) else {
            throw CrawlSessionError.invalidSeedURL(config.seedURL)
        }

        let store = try Store(path: dbPath)
        try store.migrate()
        try store.initializeCrawl(config: config, startedAt: Date())
        _ = try store.insertURLIfNew(seed, depth: 0, isInternal: true, discoveredAt: Date())

        let robots = await fetchRobots(for: seed, client: client, config: config)
        let engine = CrawlEngine(store: store, client: client, parser: parser, config: config, robots: robots)
        try await engine.run(onProgress: onProgress)
        return store
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CrawlSession`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/KodaCore/CrawlSession.swift Tests/KodaCoreTests/CrawlSessionTests.swift
git commit -m "feat: robots fetching and crawl session entry point"
```

---

### Task 11: Summary queries and CLI

**Files:**
- Create: `Sources/KodaCore/Store+Summary.swift`
- Create: `Tests/KodaCoreTests/SummaryTests.swift`
- Delete and recreate: `Sources/koda/main.swift`

**Interfaces:**
- Consumes: `Store`, `CrawlSession`, `CrawlConfig`
- Produces:
  - `public struct CrawlSummary: Sendable` with `totalURLs`, `internalURLs`, `externalURLs`, `byStatusClass: [String: Int]`, `transportErrors`, `missingTitles`, `duplicateTitles`, `missingDescriptions`, `missingH1`, `imagesMissingAlt`, `maxDepth`
  - `func summary() throws -> CrawlSummary`
  - CLI: `koda crawl <url> [--db <path>] [--workers <n>] [--limit <n>] [--max-depth <n>] [--ignore-robots]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/SummaryTests.swift`:

```swift
import Foundation
import Testing
@testable import KodaCore

private struct SummaryClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        let pages: [String: (Int, String)] = [
            "https://sum.test/": (200, "<html><head><title>Dup</title></head><body><h1>H</h1><a href='/a'>a</a><a href='/b'>b</a><a href='/c'>c</a></body></html>"),
            "https://sum.test/a": (200, "<html><head><title>Dup</title><meta name='description' content='d'></head><body><h1>H</h1><img src='/i.png'></body></html>"),
            "https://sum.test/b": (200, "<html><head></head><body><p>no title no h1</p></body></html>"),
            "https://sum.test/c": (404, ""),
        ]
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        guard let (status, body) = pages[url] else {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: status, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

private func summarizedCrawl() async throws -> CrawlSummary {
    var config = CrawlConfig(seedURL: "https://sum.test/")
    config.workers = 2
    let store = try await CrawlSession.start(dbPath: nil, config: config, client: SummaryClient(),
                                             parser: SwiftSoupParser(), onProgress: nil)
    return try store.summary()
}

@Test func countsInternalURLs() async throws {
    let s = try await summarizedCrawl()
    #expect(s.internalURLs == 4)
}

@Test func groupsStatusCodes() async throws {
    let s = try await summarizedCrawl()
    #expect(s.byStatusClass["2xx"] == 3)
    #expect(s.byStatusClass["4xx"] == 1)
}

@Test func countsMissingTitles() async throws {
    let s = try await summarizedCrawl()
    #expect(s.missingTitles == 1, "/b has no title; /c is a 404 with no facts")
}

@Test func countsDuplicateTitles() async throws {
    let s = try await summarizedCrawl()
    #expect(s.duplicateTitles == 2, "'Dup' appears on / and /a")
}

@Test func countsMissingDescriptionsAndH1() async throws {
    let s = try await summarizedCrawl()
    #expect(s.missingDescriptions == 2, "/ and /b lack descriptions")
    #expect(s.missingH1 == 1, "/b lacks an h1")
}

@Test func countsImagesMissingAlt() async throws {
    let s = try await summarizedCrawl()
    #expect(s.imagesMissingAlt == 1)
}

@Test func reportsMaxDepth() async throws {
    let s = try await summarizedCrawl()
    #expect(s.maxDepth == 1)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter Summary`
Expected: FAIL — `value of type 'Store' has no member 'summary'`.

- [ ] **Step 3: Write the summary queries**

Create `Sources/KodaCore/Store+Summary.swift`:

```swift
import Foundation
import GRDB

public struct CrawlSummary: Sendable {
    public let totalURLs: Int
    public let internalURLs: Int
    public let externalURLs: Int
    public let byStatusClass: [String: Int]
    public let transportErrors: Int
    public let missingTitles: Int
    public let duplicateTitles: Int
    public let missingDescriptions: Int
    public let missingH1: Int
    public let imagesMissingAlt: Int
    public let maxDepth: Int
}

extension Store {
    public func summary() throws -> CrawlSummary {
        try dbQueue.read { db in
            func count(_ sql: String) throws -> Int {
                try Int.fetchOne(db, sql: sql) ?? 0
            }

            var byClass: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT (status / 100) AS class, count(*) AS n FROM responses WHERE status > 0 GROUP BY class
                """) {
                let cls: Int = row["class"]
                byClass["\(cls)xx"] = row["n"]
            }

            return CrawlSummary(
                totalURLs: try count("SELECT count(*) FROM urls"),
                internalURLs: try count("SELECT count(*) FROM urls WHERE is_internal = 1"),
                externalURLs: try count("SELECT count(*) FROM urls WHERE is_internal = 0"),
                byStatusClass: byClass,
                transportErrors: try count("SELECT count(*) FROM responses WHERE status = 0"),
                missingTitles: try count("""
                    SELECT count(*) FROM page_facts f JOIN responses r ON r.url_id = f.url_id
                    WHERE (f.title IS NULL OR f.title = '') AND r.status = 200
                    """),
                duplicateTitles: try count("""
                    SELECT coalesce(sum(n), 0) FROM (
                      SELECT count(*) AS n FROM page_facts WHERE title IS NOT NULL AND title != ''
                      GROUP BY title HAVING count(*) > 1
                    )
                    """),
                missingDescriptions: try count("""
                    SELECT count(*) FROM page_facts f JOIN responses r ON r.url_id = f.url_id
                    WHERE (f.meta_description IS NULL OR f.meta_description = '') AND r.status = 200
                    """),
                missingH1: try count("""
                    SELECT count(*) FROM page_facts f JOIN responses r ON r.url_id = f.url_id
                    WHERE (f.h1 IS NULL OR f.h1 = '') AND r.status = 200
                    """),
                imagesMissingAlt: try count("SELECT count(*) FROM images WHERE alt IS NULL OR alt = ''"),
                maxDepth: try count("SELECT coalesce(max(u.depth), 0) FROM urls u JOIN responses r ON r.url_id = u.id")
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter Summary`
Expected: PASS, 7 tests.

- [ ] **Step 5: Write the CLI**

Replace `Sources/koda/main.swift` with `Sources/koda/Koda.swift`:

```swift
import ArgumentParser
import Foundation
import KodaCore

@main
struct Koda: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "koda",
        abstract: "Crawl a site and report on it.",
        version: KodaCoreInfo.versionString,
        subcommands: [Crawl.self],
        defaultSubcommand: Crawl.self
    )
}

struct Crawl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Crawl a site into a .koda database.")

    @Argument(help: "Seed URL, for example https://example.com/")
    var url: String

    @Option(name: .long, help: "Database path. Defaults to a file named after the host.")
    var db: String?

    @Option(name: .long, help: "Concurrent workers.")
    var workers: Int = 5

    @Option(name: .long, help: "Stop after this many URLs.")
    var limit: Int = 500_000

    @Option(name: .long, help: "Maximum crawl depth.")
    var maxDepth: Int?

    @Flag(name: .long, help: "Ignore robots.txt. Use only on sites you control.")
    var ignoreRobots = false

    mutating func run() async throws {
        var config = CrawlConfig(seedURL: url)
        config.workers = workers
        config.urlCap = limit
        config.maxDepth = maxDepth
        config.respectRobots = !ignoreRobots

        guard let host = config.seedHost else {
            throw ValidationError("Not a crawlable http(s) URL: \(url)")
        }
        let path = db ?? FileManager.default.currentDirectoryPath + "/\(host).koda"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        print("Crawling \(url) → \(path)")
        if ignoreRobots { print("WARNING: ignoring robots.txt") }

        let started = Date()
        let store = try await CrawlSession.start(
            dbPath: path, config: config,
            client: URLSessionHTTPClient(), parser: SwiftSoupParser(),
            onProgress: { progress in
                FileHandle.standardError.write(
                    Data("\rcrawled \(progress.crawled)  queued \(progress.queued)".utf8)
                )
            }
        )
        let elapsed = Date().timeIntervalSince(started)
        print("\n")
        Self.printSummary(try store.summary(), elapsed: elapsed)
    }

    static func printSummary(_ s: CrawlSummary, elapsed: TimeInterval) {
        func line(_ label: String, _ value: Any) {
            print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(value)")
        }
        print("Crawl finished in \(String(format: "%.1f", elapsed))s")
        print("\nURLs")
        line("Total discovered", s.totalURLs)
        line("Internal", s.internalURLs)
        line("External", s.externalURLs)
        line("Max depth", s.maxDepth)
        print("\nResponses")
        for key in s.byStatusClass.keys.sorted() {
            line(key, s.byStatusClass[key] ?? 0)
        }
        if s.transportErrors > 0 { line("Transport errors", s.transportErrors) }
        print("\nIssues")
        line("Missing titles", s.missingTitles)
        line("Duplicate titles", s.duplicateTitles)
        line("Missing meta descriptions", s.missingDescriptions)
        line("Missing H1", s.missingH1)
        line("Images missing alt", s.imagesMissingAlt)
    }
}
```

Delete the old entry point — `@main` and a top-level `main.swift` cannot coexist:

```bash
rm Sources/koda/main.swift
```

- [ ] **Step 6: Verify the CLI builds and shows help**

Run: `swift build && ./.build/debug/koda --help`
Expected: usage text listing the `crawl` subcommand.

- [ ] **Step 7: Commit**

```bash
git add Sources/KodaCore/Store+Summary.swift Sources/koda Tests/KodaCoreTests/SummaryTests.swift
git rm --cached Sources/koda/main.swift 2>/dev/null || true
git commit -m "feat: crawl summary queries and CLI"
```

---

### Task 12: End-to-end test over real HTTP

Every test so far stubs the network. This one runs the real `URLSessionHTTPClient` against a real HTTP server, which is the only way to catch redirect handling, header parsing, and timeout behaviour that stubs paper over. The server is `python3 -m http.server`, already present on macOS — no Swift server code and no new dependency.

**Files:**
- Create: `Tests/KodaCoreTests/EndToEndTests.swift`
- Create: `Tests/KodaCoreTests/Fixtures/site/index.html`
- Create: `Tests/KodaCoreTests/Fixtures/site/about.html`
- Create: `Tests/KodaCoreTests/Fixtures/site/dupe.html`
- Create: `Tests/KodaCoreTests/Fixtures/site/robots.txt`
- Modify: `Package.swift` (add fixture resources to the test target)

**Interfaces:**
- Consumes: `CrawlSession`, `URLSessionHTTPClient`, `SwiftSoupParser`, `Store.summary()`
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Create the fixture site**

`Tests/KodaCoreTests/Fixtures/site/index.html`:

```html
<!doctype html>
<html lang="en">
<head><title>Fixture Home</title><meta name="description" content="Home page"></head>
<body>
  <h1>Home</h1>
  <a href="about.html">About</a>
  <a href="dupe.html">Dupe</a>
  <a href="missing.html">Missing</a>
  <a href="blocked/secret.html">Blocked</a>
  <img src="pic.png" alt="A picture">
  <img src="noalt.png">
</body>
</html>
```

`Tests/KodaCoreTests/Fixtures/site/about.html`:

```html
<!doctype html>
<html lang="en">
<head><title>Shared Title</title><meta name="description" content="About page"></head>
<body><h1>About</h1><p>About the fixture site.</p></body>
</html>
```

`Tests/KodaCoreTests/Fixtures/site/dupe.html`:

```html
<!doctype html>
<html lang="en">
<head><title>Shared Title</title></head>
<body><p>No h1 and no description here.</p></body>
</html>
```

`Tests/KodaCoreTests/Fixtures/site/robots.txt`:

```
User-agent: *
Disallow: /blocked/
```

- [ ] **Step 2: Register the fixtures as test resources**

In `Package.swift`, change the test target to:

```swift
        .testTarget(
            name: "KodaCoreTests",
            dependencies: [
                "KodaCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            resources: [.copy("Fixtures")]
        ),
```

- [ ] **Step 3: Write the failing test**

Create `Tests/KodaCoreTests/EndToEndTests.swift`:

```swift
import Foundation
import Testing
@testable import KodaCore

/// Serves the fixture directory over real HTTP for the duration of a test.
private final class FixtureServer {
    private let process = Process()
    let port: Int

    init(directory: URL) throws {
        // A fixed high port keeps this simple; if it is busy the test fails loudly rather than hanging.
        port = 8137
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Polls until the server answers, so tests never race the process starting up.
    func waitUntilReady(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let client = URLSessionHTTPClient()
        while Date() < deadline {
            let outcome = await client.fetch(url: "http://127.0.0.1:\(port)/index.html", method: "GET",
                                             userAgent: "probe", timeout: 1)
            if case .response(let r) = outcome, r.status == 200 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "FixtureServer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "server did not start on port \(port)"])
    }

    func stop() {
        process.terminate()
    }
}

private func fixtureDirectory() throws -> URL {
    guard let url = Bundle.module.url(forResource: "Fixtures/site", withExtension: nil) else {
        throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture site not found"])
    }
    return url
}

@Test func crawlsRealHTTPServerEndToEnd() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 3
    config.retainBodies = true

    let store = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
    )
    let summary = try store.summary()

    #expect(summary.byStatusClass["2xx"] == 3, "index, about, dupe")
    #expect(summary.byStatusClass["4xx"] == 1, "missing.html")
    #expect(summary.duplicateTitles == 2, "'Shared Title' on about and dupe")
    #expect(summary.missingDescriptions == 1, "dupe.html")
    #expect(summary.missingH1 == 1, "dupe.html")
    #expect(summary.imagesMissingAlt == 1, "noalt.png")
    #expect(summary.transportErrors == 0)
}

@Test func robotsBlockedPathIsNotFetched() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/index.html")
    config.workers = 2

    let store = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
    )
    let fetched = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path LIKE '/blocked/%'
            """) ?? 0
    }
    #expect(fetched == 0, "robots.txt disallows /blocked/")
}

@Test func bodiesAreRetainedAndDecompressible() async throws {
    let server = try FixtureServer(directory: try fixtureDirectory())
    defer { server.stop() }
    try await server.waitUntilReady()

    var config = CrawlConfig(seedURL: "http://127.0.0.1:\(server.port)/about.html")
    config.workers = 1

    let store = try await CrawlSession.start(
        dbPath: nil, config: config,
        client: URLSessionHTTPClient(), parser: SwiftSoupParser(), onProgress: nil
    )
    let body = try store.dbQueue.read { db in
        try Data.fetchOne(db, sql: """
            SELECT r.body_gz FROM responses r JOIN urls u ON u.id = r.url_id WHERE u.path = '/about.html'
            """)
    }
    let decompressed = try #require(body.flatMap { Gzip.decompress($0) })
    #expect(String(decoding: decompressed, as: UTF8.self).contains("Shared Title"))
}
```

Add the GRDB import the test file needs — put `import GRDB` at the top alongside the others.

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift test --filter EndToEnd`
Expected: FAIL — fixture resources not found, until Step 2's `Package.swift` change is in place and the build is refreshed.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter EndToEnd`
Expected: PASS, 3 tests. If port 8137 is in use, change the port in `FixtureServer`.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: PASS, every test from Tasks 1–12.

- [ ] **Step 7: Crawl a real site as a manual smoke check**

Run: `swift build -c release && ./.build/release/koda crawl https://example.com/`
Expected: a summary printed, and `example.com.koda` written to the working directory. Inspect it with `sqlite3 example.com.koda "SELECT url, status FROM urls JOIN responses ON responses.url_id = urls.id"`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Tests/KodaCoreTests/EndToEndTests.swift Tests/KodaCoreTests/Fixtures
git commit -m "test: end-to-end crawl over real HTTP"
```

---

### Task 13: Redirect chain limit

URL deduplication stops simple redirect loops, but not a server that generates a
fresh URL each hop (`/a?1` → `/a?2` → …). Without a hop limit that walk only ends
when the 500k URL cap does. The spec requires chains over 10 hops to be recorded
and abandoned.

**Files:**
- Modify: `Sources/KodaCore/Store.swift` (add a v2 migration)
- Modify: `Sources/KodaCore/Store+Write.swift` (`upsertURL`, `resolveTarget`)
- Create: `Tests/KodaCoreTests/RedirectChainTests.swift`

**Interfaces:**
- Consumes: `Store`, `CrawlResult`, `CrawlConfig` from Tasks 3 and 8
- Produces: `urls.redirect_hops` column; `Store.upsertURL` gains a `redirectHops: Int = 0` parameter (defaulted, so existing call sites are unchanged)

- [ ] **Step 1: Write the failing tests**

Create `Tests/KodaCoreTests/RedirectChainTests.swift`:

```swift
import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Redirects forever, with a new URL each hop, so dedup can never stop it.
private struct InfiniteRedirectClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        let next = (Int(url.components(separatedBy: "?n=").last ?? "0") ?? 0) + 1
        return .response(HTTPResponse(status: 301,
                                      headers: ["Location": "https://loop.test/a?n=\(next)"],
                                      body: Data(), elapsedMs: 1))
    }
}

@Test func redirectHopsIncrementAlongChain() async throws {
    var config = CrawlConfig(seedURL: "https://loop.test/a?n=0")
    config.workers = 1
    config.maxRedirects = 3

    let store = try await CrawlSession.start(dbPath: nil, config: config,
                                             client: InfiniteRedirectClient(),
                                             parser: SwiftSoupParser(), onProgress: nil)
    let maxHops = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT max(redirect_hops) FROM urls") ?? 0
    }
    #expect(maxHops == config.maxRedirects + 1, "the chain stops one past the limit")
}

@Test func chainBeyondLimitIsRecordedButNotCrawled() async throws {
    var config = CrawlConfig(seedURL: "https://loop.test/a?n=0")
    config.workers = 1
    config.maxRedirects = 3

    let store = try await CrawlSession.start(dbPath: nil, config: config,
                                             client: InfiniteRedirectClient(),
                                             parser: SwiftSoupParser(), onProgress: nil)
    let fetched = try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM responses") ?? 0 }
    let recorded = try store.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0 }

    #expect(fetched == config.maxRedirects + 1, "hops 0 through maxRedirects are followed")
    #expect(recorded == config.maxRedirects + 2, "the abandoned target is still recorded")
    #expect(try store.urlCounts().queued == 0, "the crawl terminates")
}

@Test func shortChainCompletesNormally() async throws {
    struct ShortChain: HTTPClient {
        func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
            switch url {
            case "https://short.test/a":
                return .response(HTTPResponse(status: 301, headers: ["Location": "https://short.test/b"],
                                              body: Data(), elapsedMs: 1))
            case "https://short.test/b":
                return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                              body: Data("<html><head><title>End</title></head><body></body></html>".utf8),
                                              elapsedMs: 1))
            default:
                return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
            }
        }
    }
    var config = CrawlConfig(seedURL: "https://short.test/a")
    config.workers = 1

    let store = try await CrawlSession.start(dbPath: nil, config: config, client: ShortChain(),
                                             parser: SwiftSoupParser(), onProgress: nil)
    let title = try store.dbQueue.read { db in try String.fetchOne(db, sql: "SELECT title FROM page_facts") }
    #expect(title == "End")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RedirectChain`
Expected: FAIL — `no such column: redirect_hops`.

- [ ] **Step 3: Add the v2 migration**

In `Sources/KodaCore/Store.swift`, add to `migrator` after the `v1` registration:

```swift
        m.registerMigration("v2-redirect-hops") { db in
            try db.execute(sql: "ALTER TABLE urls ADD COLUMN redirect_hops INTEGER NOT NULL DEFAULT 0")
        }
```

- [ ] **Step 4: Track hops when resolving redirect targets**

In `Sources/KodaCore/Store+Write.swift`, change `upsertURL` to accept and persist hops. Replace its signature and INSERT with:

```swift
    static func upsertURL(
        _ db: Database, _ url: NormalizedURL, parentDepth: Int, config: CrawlConfig,
        seedHost: String?, now: Date, enqueue: Bool, discovered: inout Int,
        redirectHops: Int = 0
    ) throws -> Int64 {
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url_hash = ?", arguments: [url.sha256]) {
            return existing
        }
        let internalFlag = isInternal(url, seedHost: seedHost, config: config)
        let depth = parentDepth + 1

        var shouldQueue = enqueue
        if shouldQueue, let maxDepth = config.maxDepth, depth > maxDepth { shouldQueue = false }
        if shouldQueue, !passesFilters(url, config: config) { shouldQueue = false }
        if shouldQueue, redirectHops > config.maxRedirects { shouldQueue = false }
        if shouldQueue {
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
            if total >= config.urlCap { shouldQueue = false }
        }

        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, redirect_hops)
                VALUES (?,?,?,?,?,?,?,?,?)
                """,
            arguments: [url.absoluteString, url.sha256, url.host, url.path, depth,
                        internalFlag ? 1 : 0, now.timeIntervalSince1970, shouldQueue ? 0 : 3, redirectHops]
        )
        if shouldQueue { discovered += 1 }
        return db.lastInsertedRowID
    }
```

Then replace `resolveTarget` so a redirect target inherits its parent's hop count plus one. A redirect target keeps the parent's depth rather than descending a level, because a redirect is the same page, not a child of it:

```swift
    static func resolveTarget(
        _ db: Database, _ target: NormalizedURL?, parent: CrawlResult, config: CrawlConfig,
        seedHost: String?, now: Date, discovered: inout Int
    ) throws -> Int64? {
        guard let target else { return nil }
        let parentHops = try Int.fetchOne(
            db, sql: "SELECT redirect_hops FROM urls WHERE id = ?", arguments: [parent.urlID]
        ) ?? 0
        return try upsertURL(db, target, parentDepth: parent.depth - 1, config: config, seedHost: seedHost,
                             now: now, enqueue: isInternal(target, seedHost: seedHost, config: config),
                             discovered: &discovered, redirectHops: parentHops + 1)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter RedirectChain`
Expected: PASS, 3 tests.

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: PASS. The canonical-target call in `writeFacts` also routes through `resolveTarget`; confirm `StoreWriteTests` and `CrawlEngineTests` still pass, since canonical targets now inherit the parent's depth rather than depth + 1.

- [ ] **Step 7: Commit**

```bash
git add Sources/KodaCore/Store.swift Sources/KodaCore/Store+Write.swift Tests/KodaCoreTests/RedirectChainTests.swift
git commit -m "feat: abandon redirect chains past the hop limit"
```

---

## M1 Completion Criteria

- [x] `swift test` passes with every test from Tasks 1–13 — 113 tests
- [x] `koda crawl <url>` crawls a real site and prints a summary — verified against `https://example.com/`
- [x] Crawling the same site twice produces the same URL count — `crawlingTwiceProducesTheSameURLCount`
- [x] Interrupting a crawl and re-running against the same database resumes rather than restarting — `koda crawl <url> --resume`, covered by `rerunningAFinishedCrawlRefetchesNothing` and `inFlightURLsAreRequeuedOnTheNextRun`
- [x] `KodaCore` imports neither AppKit nor SwiftUI — verify with `grep -rE 'import (AppKit|SwiftUI)' Sources/KodaCore` returning nothing

## Deliberately deferred

Two spec items are not in M1. Each is deferred for a stated reason, not overlooked:

**Per-host concurrency cap.** `CrawlConfig.maxPerHost` exists but nothing enforces
it, because in M1 nothing needs it: external URLs are recorded but never fetched,
so every request in a crawl goes to the seed host and the global `workers` cap is
already the per-host cap. This becomes real the moment external status-checking
lands, and must be implemented then.

**Image HEAD requests.** The spec has internal images fetched with HEAD to record
status and byte size. M1 records images and their alt text — enough for the
missing-alt report — but does not fetch them. Size is only needed for the
"images over 100KB" filter, which is an M3 report tab; the fetch lands with it.

## Landed beyond the plan as written

**Frontier resume in the CLI.** Originally deferred to M2, but the completion
criteria required it and the store already supported it, so only the CLI's
unconditional database delete stood in the way. `koda crawl <url> --resume`
continues an existing database.

**Crawl-delay is applied per request, not per batch.** The engine as planned
claimed `workers` URLs, fetched them concurrently and slept once per batch, which
is `workers` times faster than a `Crawl-delay` directive allows. When a delay is
set the batch is serialised to one URL.

**Canonical targets do not count as redirect hops.** Task 13 as written routed
canonical links through the same resolver as redirect targets, so a canonical
inherited `parent hops + 1`. With a low `maxRedirects` that recorded canonical
targets as abandoned despite nothing ever having redirected to them.

**`CrawlSummary.crawledURLs`.** Internal URL counts include assets that are
recorded but never fetched, so without a separate crawled count the two headline
numbers looked inconsistent for no visible reason.
