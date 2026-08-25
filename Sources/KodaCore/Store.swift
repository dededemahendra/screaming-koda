import Foundation
import GRDB

/// Refusing to touch a file that is not ours.
///
/// `--db` is one typo away from an ordinary file. Both the crawl path and the
/// read-only commands used to write to whatever it named — a crawl deleted the
/// file outright, and `summary` migrated eight tables into it — so every path
/// that writes checks first.
public enum StoreError: Error, CustomStringConvertible {
    case notACrawl(String)

    public var description: String {
        switch self {
        case .notACrawl(let path):
            return "\(path) is not a Screaming Koda crawl, so it was left alone."
        }
    }
}

/// What is at a path, as far as this tool is concerned.
public enum DatabaseKind: Sendable {
    /// Nothing there, or an empty file. Free to become a crawl.
    case absent
    /// A crawl this tool wrote.
    case crawl
    /// Something else. Never written to, never removed.
    case foreign
}

public final class Store: @unchecked Sendable {
    public let dbQueue: DatabaseQueue

    /// - Parameter path: file path, or nil for an in-memory database (tests).
    public init(path: String?) throws {
        var config = Configuration()
        // Readers and the writer are separate connections, and often separate
        // processes: the app browses a database the CLI is still crawling into.
        // WAL lets them coexist, but only if a connection is willing to wait for
        // a lock. Without a busy timeout SQLite returns SQLITE_BUSY immediately
        // and the reader just fails, which defeats the live browsing the whole
        // design rests on.
        config.busyMode = .timeout(10)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        if let path {
            do {
                dbQueue = try DatabaseQueue(path: path, configuration: config)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
                // "SQLite error 26: file is not a database - while executing
                // `PRAGMA journal_mode=WAL`" is a true sentence about the wrong
                // subject. Every other failure — permissions, a full disk — is
                // its own problem and is passed through unchanged.
                throw StoreError.notACrawl(path)
            }
        } else {
            dbQueue = try DatabaseQueue(configuration: config)
        }
    }

    /// Creates the schema, or brings an older crawl up to date.
    ///
    /// Refuses a database holding tables that are not ours rather than adding
    /// eight more to it. An empty file is fair game — that is how a new crawl
    /// begins — and so is one that already has `crawl_meta`, which is how an
    /// older crawl gets upgraded.
    public func migrate() throws {
        try dbQueue.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                """)
            guard tables.isEmpty || tables.contains("crawl_meta") else {
                throw StoreError.notACrawl(dbQueue.path)
            }
        }
        try Self.migrator.migrate(dbQueue)
    }

    /// What is at `path`, without opening it for writing or creating anything.
    public static func kind(at path: String) -> DatabaseKind {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        if size == 0 { return .absent }

        var config = Configuration()
        config.readonly = true
        guard let queue = try? DatabaseQueue(path: path, configuration: config),
              let hasMeta = try? queue.read({ db in
                  try Bool.fetchOne(db, sql: """
                      SELECT count(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = 'crawl_meta'
                      """) ?? false
              })
        else { return .foreign }
        return hasMeta ? .crawl : .foreign
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
        m.registerMigration("v2-redirect-hops") { db in
            try db.execute(sql: "ALTER TABLE urls ADD COLUMN redirect_hops INTEGER NOT NULL DEFAULT 0")
        }
        m.registerMigration("v3-canonical-count") { db in
            try db.execute(sql: "ALTER TABLE page_facts ADD COLUMN canonical_count INTEGER NOT NULL DEFAULT 0")
        }
        // `links` is the largest table by an order of magnitude, and counting
        // internal inlinks reads all of it. On `(to_url_id)` alone that means
        // fetching every row to see one flag; on `(to_url_id, is_internal)` the
        // count is answered from the index. Widening the existing index rather
        // than adding one keeps the write cost where it was.
        m.registerMigration("v4-inlink-index") { db in
            try db.execute(sql: """
                DROP INDEX IF EXISTS idx_links_to;
                CREATE INDEX idx_links_to ON links(to_url_id, is_internal);
                """)
        }
        return m
    }

    /// Refreshes the query planner's statistics.
    ///
    /// Without them SQLite has to guess how big each table is, and it guesses
    /// that a join over `links` is as cheap as one over `responses`. On a crawl
    /// of any size that turns "which links point at a 404" from an index lookup
    /// into a scan of every link on the site — measured at sixty times slower.
    ///
    /// `PRAGMA optimize` rather than a bare `ANALYZE`: it only re-analyses tables
    /// whose statistics have gone stale, so calling it repeatedly during a long
    /// crawl costs almost nothing when nothing has changed much.
    public func optimize() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA optimize")
        }
    }

    /// Deletes a crawl, sidecars included.
    ///
    /// WAL mode leaves a `-wal` and a `-shm` beside the database. Removing only
    /// the database would leave the next crawl at that path replaying a
    /// write-ahead log belonging to a crawl that no longer exists.
    /// Deletes a crawl and its write-ahead log.
    ///
    /// Refuses anything that is not a crawl. Starting over replaces the database
    /// at the target path, and "replace whatever is there" is the wrong reading
    /// of that when the path came from a person typing `--db`.
    public static func removeDatabase(at path: String) throws {
        guard kind(at: path) != .foreign else { throw StoreError.notACrawl(path) }
        for suffix in ["", "-wal", "-shm"] {
            let sidecar = path + suffix
            if FileManager.default.fileExists(atPath: sidecar) {
                try FileManager.default.removeItem(atPath: sidecar)
            }
        }
    }

    public func initializeCrawl(config: CrawlConfig, startedAt: Date) throws {
        let json = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? "{}"
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO crawl_meta (id, seed_url, started_at, config_json, schema_version)
                    VALUES (1, ?, ?, ?, 1)
                    ON CONFLICT(id) DO UPDATE SET seed_url=excluded.seed_url,
                      config_json=excluded.config_json, finished_at=NULL
                    """,
                arguments: [config.seedURL, startedAt.timeIntervalSince1970, json]
            )
        }
    }

    /// When the crawl ran, and whether it ever finished.
    ///
    /// `finishedAt` is nil for a crawl that was stopped or died, which is how
    /// reopening a database can tell a completed crawl from a resumable one.
    public func crawlMeta() throws -> CrawlMeta? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT seed_url, started_at, finished_at FROM crawl_meta WHERE id = 1"
            ) else { return nil }
            return CrawlMeta(
                seedURL: row["seed_url"],
                startedAt: Date(timeIntervalSince1970: row["started_at"]),
                finishedAt: (row["finished_at"] as Double?).map(Date.init(timeIntervalSince1970:))
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
