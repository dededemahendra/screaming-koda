import Foundation
import GRDB

public final class Store: @unchecked Sendable {
    public let dbQueue: DatabaseQueue

    /// A URL counts as "found" unless it exists *solely* as an image source: `<img src>`
    /// targets get their own row in `urls` (see `Store+Write`'s `upsertURL(..., enqueue:
    /// false)` for images), but they are resources, not pages — they must not inflate the
    /// URL counts a report or the crawl table shows for the site. A URL is only excluded
    /// when it was never actually fetched (no `responses` row) and is never a normal link
    /// target (`links.to_url_id`); if either is true, it's a real page that happens to also
    /// be embedded as an image somewhere, and must still be counted. `urls` is deduplicated
    /// by `url_hash`, so such a URL collapses to a single row — excluding by identity alone
    /// would drop it entirely.
    ///
    /// Shared by `Store.summary()` and `KodaUI.RowStore` so the summary report and the crawl
    /// table can never disagree about how many URLs a crawl found — the two had a single
    /// hand-maintained-twice divergence in M1 that this constant exists to prevent from
    /// recurring. References `u` as the alias for `urls` in the enclosing query.
    public static let visibleURLsFilter = """
        u.id NOT IN (
          SELECT src_url_id FROM images
          WHERE src_url_id NOT IN (SELECT url_id FROM responses)
            AND src_url_id NOT IN (SELECT to_url_id FROM links)
        )
        """

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
        m.registerMigration("v2-redirect-hops") { db in
            try db.execute(sql: "ALTER TABLE urls ADD COLUMN redirect_hops INTEGER NOT NULL DEFAULT 0")
        }
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
