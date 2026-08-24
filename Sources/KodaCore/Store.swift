import Foundation
import GRDB

public final class Store: @unchecked Sendable {
    public let dbQueue: DatabaseQueue

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
        AND u.id NOT IN (
          SELECT src_url_id FROM resources
          WHERE src_url_id NOT IN (SELECT to_url_id FROM links)
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
        m.registerMigration("v4-canonical-count-and-h2") { db in
            // Both close gaps that made a page look clean when it was not: a
            // page declaring two canonicals was indistinguishable from one
            // declaring a single canonical, and H2s could be counted but never
            // compared or measured.
            try db.execute(sql: """
                ALTER TABLE page_facts ADD COLUMN canonical_count INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE page_facts ADD COLUMN h2 TEXT;
                CREATE INDEX idx_facts_h2 ON page_facts(h2);
                """)
        }
        m.registerMigration("v5-headers-social-and-structured-data") { db in
            // Storing headers wholesale rather than picking out one more named
            // column each time: security headers, custom header extraction and
            // plain header inspection are all the same need, and a JSON blob
            // serves all three without a migration per header.
            try db.execute(sql: """
                ALTER TABLE responses ADD COLUMN headers_json TEXT;

                ALTER TABLE page_facts ADD COLUMN og_title TEXT;
                ALTER TABLE page_facts ADD COLUMN og_description TEXT;
                ALTER TABLE page_facts ADD COLUMN og_image TEXT;
                ALTER TABLE page_facts ADD COLUMN og_type TEXT;
                ALTER TABLE page_facts ADD COLUMN twitter_card TEXT;
                ALTER TABLE page_facts ADD COLUMN twitter_title TEXT;
                ALTER TABLE page_facts ADD COLUMN twitter_image TEXT;
                ALTER TABLE page_facts ADD COLUMN amphtml TEXT;
                ALTER TABLE page_facts ADD COLUMN rel_prev TEXT;
                ALTER TABLE page_facts ADD COLUMN rel_next TEXT;
                ALTER TABLE page_facts ADD COLUMN analytics TEXT;

                -- A page can declare many schema types, so this is a table
                -- rather than a column. Indexed on type so "every page with
                -- Product markup" is a lookup, not a scan.
                CREATE TABLE structured_data (
                  url_id INTEGER NOT NULL REFERENCES urls(id),
                  format TEXT NOT NULL,
                  type TEXT NOT NULL
                );
                CREATE INDEX idx_sd_url ON structured_data(url_id);
                CREATE INDEX idx_sd_type ON structured_data(type);

                ALTER TABLE images ADD COLUMN width INTEGER;
                ALTER TABLE images ADD COLUMN height INTEGER;
                """)
        }
        m.registerMigration("v6-extractions") { db in
            try db.execute(sql: """
                CREATE TABLE extractions (
                  url_id INTEGER NOT NULL REFERENCES urls(id),
                  name TEXT NOT NULL,
                  value TEXT NOT NULL,
                  position INTEGER NOT NULL
                );
                CREATE INDEX idx_extractions_url ON extractions(url_id);
                CREATE INDEX idx_extractions_name ON extractions(name);
                """)
        }
        m.registerMigration("v7-sitemaps") { db in
            // Which URLs a sitemap declared, independent of whether the crawl
            // reached them. This is what makes "in the sitemap but not linked"
            // — the only honest orphan signal a crawler has — expressible.
            try db.execute(sql: """
                ALTER TABLE urls ADD COLUMN in_sitemap INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX idx_urls_sitemap ON urls(in_sitemap);
                """)
        }
        m.registerMigration("v8-resources") { db in
            try db.execute(sql: """
                CREATE TABLE resources (
                  url_id INTEGER NOT NULL REFERENCES urls(id),
                  src_url_id INTEGER NOT NULL REFERENCES urls(id),
                  kind TEXT NOT NULL
                );
                CREATE INDEX idx_resources_url ON resources(url_id);
                CREATE INDEX idx_resources_src ON resources(src_url_id);
                """)
        }
        m.registerMigration("v9-rendering") { db in
            try db.execute(sql: """
                ALTER TABLE responses ADD COLUMN rendered INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE responses ADD COLUMN render_ms INTEGER;
                ALTER TABLE responses ADD COLUMN js_errors TEXT;
                -- How much of the page only exists after scripts run. The single
                -- most useful number a rendered crawl produces: it says whether
                -- rendering this site is necessary or merely expensive.
                ALTER TABLE responses ADD COLUMN rendered_words INTEGER;
                ALTER TABLE responses ADD COLUMN static_words INTEGER;
                """)
        }
        m.registerMigration("v10-performance") { db in
            // Only what WebKit can actually observe. There is deliberately no
            // CLS or INP column: `supportedEntryTypes` has no "layout-shift",
            // and INP needs a real interaction a crawler never makes. A column
            // that could only ever hold zero would read as a passing grade.
            try db.execute(sql: """
                ALTER TABLE responses ADD COLUMN perf_ttfb_ms INTEGER;
                ALTER TABLE responses ADD COLUMN perf_fcp_ms INTEGER;
                ALTER TABLE responses ADD COLUMN perf_lcp_ms INTEGER;
                ALTER TABLE responses ADD COLUMN perf_dcl_ms INTEGER;
                ALTER TABLE responses ADD COLUMN perf_load_ms INTEGER;
                ALTER TABLE responses ADD COLUMN perf_resources INTEGER;
                """)
        }
        m.registerMigration("v11-skip-reasons-and-text") { db in
            try db.execute(sql: """
                -- Why a URL was recorded but never crawled. Previously the state
                -- said "skipped" and nothing said why, so a crawl that quietly
                -- stopped short was indistinguishable from one that finished.
                ALTER TABLE urls ADD COLUMN skip_reason TEXT;
                -- Characters of visible text, so the text-to-HTML ratio is a real
                -- measurement rather than word count divided by byte count.
                ALTER TABLE page_facts ADD COLUMN text_length INTEGER;
                """)
        }
        return m
    }

    public func initializeCrawl(config: CrawlConfig, startedAt: Date) throws {
        let json = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? "{}"
        // Stored normalised so it can be compared against `urls.url`, which is
        // always normalised. The Sitemap report needs exactly that comparison to
        // tell an orphan from the page the crawl started on.
        let seed = URLNormalizer.normalize(config.seedURL, relativeTo: nil)?.absoluteString
            ?? config.seedURL
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO crawl_meta (id, seed_url, started_at, config_json, schema_version)
                    VALUES (1, ?, ?, ?, 1)
                    ON CONFLICT(id) DO UPDATE SET seed_url=excluded.seed_url, config_json=excluded.config_json
                    """,
                arguments: [seed, startedAt.timeIntervalSince1970, json]
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
