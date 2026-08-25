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
                        try Self.resolveRedirectTarget(db, result.redirectTarget, parent: result,
                                                       config: config, seedHost: seedHost, now: now,
                                                       discovered: &discovered),
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
        // Every relative URL in the document resolves against <base href> when the
        // page declares one, and against the page's own address otherwise. Getting
        // this wrong does not fail loudly: it invents URLs that do not exist and
        // misses the ones that do. The base itself resolves against the page.
        let base = facts.baseHref
            .flatMap { URLNormalizer.normalize($0, relativeTo: result.url) } ?? result.url

        let canonicalNormalized = facts.canonical.flatMap { URLNormalizer.normalize($0, relativeTo: base) }
        let canonicalID = try Self.resolveCanonicalTarget(db, canonicalNormalized, parent: result,
                                                          config: config, seedHost: seedHost, now: now,
                                                          discovered: &discovered)

        try db.execute(
            sql: """
                INSERT INTO page_facts
                  (url_id, title, title_length, title_count,
                   meta_description, meta_description_length, meta_description_count,
                   h1, h1_count, h2_count, canonical_id, canonical_count, meta_robots, x_robots_tag,
                   lang, word_count, content_hash)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(url_id) DO UPDATE SET
                  title=excluded.title, title_length=excluded.title_length, title_count=excluded.title_count,
                  meta_description=excluded.meta_description,
                  meta_description_length=excluded.meta_description_length,
                  meta_description_count=excluded.meta_description_count,
                  h1=excluded.h1, h1_count=excluded.h1_count, h2_count=excluded.h2_count,
                  canonical_id=excluded.canonical_id, canonical_count=excluded.canonical_count,
                  meta_robots=excluded.meta_robots,
                  x_robots_tag=excluded.x_robots_tag, lang=excluded.lang,
                  word_count=excluded.word_count, content_hash=excluded.content_hash
                """,
            arguments: [
                result.urlID, facts.title, facts.titleLength, facts.titleCount,
                facts.metaDescription, facts.metaDescriptionLength, facts.metaDescriptionCount,
                facts.h1, facts.h1Count, facts.h2Count, canonicalID, facts.canonicalCount,
                facts.metaRobots, result.xRobotsTag,
                facts.lang, facts.wordCount, facts.contentHash,
            ]
        )

        try db.execute(sql: "DELETE FROM links WHERE from_url_id = ?", arguments: [result.urlID])
        for link in facts.links {
            guard let target = URLNormalizer.normalize(link.href, relativeTo: base) else { continue }
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
            guard let src = URLNormalizer.normalize(image.src, relativeTo: base) else { continue }
            let srcID = try Self.upsertURL(db, src, parentDepth: result.depth, config: config,
                                           seedHost: seedHost, now: now, enqueue: false, discovered: &discovered)
            try db.execute(sql: "INSERT INTO images (url_id, src_url_id, alt) VALUES (?,?,?)",
                           arguments: [result.urlID, srcID, image.alt])
        }

        try db.execute(sql: "DELETE FROM hreflang WHERE url_id = ?", arguments: [result.urlID])
        for entry in facts.hreflang {
            guard let href = URLNormalizer.normalize(entry.href, relativeTo: base) else { continue }
            let hrefID = try Self.upsertURL(db, href, parentDepth: result.depth, config: config,
                                            seedHost: seedHost, now: now,
                                            enqueue: Self.isInternal(href, seedHost: seedHost, config: config),
                                            discovered: &discovered)
            try db.execute(sql: "INSERT INTO hreflang (url_id, lang, href_url_id) VALUES (?,?,?)",
                           arguments: [result.urlID, entry.lang, hrefID])
        }
    }

    /// A redirect target inherits its parent's hop count plus one, and keeps the
    /// parent's depth rather than descending a level: a redirect is the same page
    /// at a new address, not a child of it, so a chain must not eat depth budget.
    static func resolveRedirectTarget(
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

    /// A canonical link is a declaration about the current page, not a hop along a
    /// redirect chain, so it starts a fresh hop count and is treated as an ordinary
    /// child link. Charging it a hop would let a long chain silently suppress
    /// canonical targets that were never redirected to at all.
    static func resolveCanonicalTarget(
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
        // URL dedup stops a redirect loop that revisits an address, but not a server
        // that mints a fresh URL each hop. Without this the walk only ends at the
        // 500k URL cap.
        if shouldQueue, redirectHops > config.maxRedirects { shouldQueue = false }
        if shouldQueue {
            // Only rows that still count against crawl budget — queued, in-flight, or done.
            // Skipped rows (state 3) are external links, images, and filtered targets that
            // will never be crawled, so they must not starve internal discovery of budget.
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE state != 3") ?? 0
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
