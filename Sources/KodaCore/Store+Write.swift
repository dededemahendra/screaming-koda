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
                           response_time_ms, redirect_target_id, fetched_at, body_gz, headers_json,
                           rendered, render_ms, js_errors, rendered_words, static_words,
                           perf_ttfb_ms, perf_fcp_ms, perf_lcp_ms, perf_dcl_ms, perf_load_ms,
                           perf_resources)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(url_id) DO UPDATE SET
                          status=excluded.status, error_kind=excluded.error_kind,
                          content_type=excluded.content_type, content_length=excluded.content_length,
                          response_time_ms=excluded.response_time_ms,
                          redirect_target_id=excluded.redirect_target_id,
                          fetched_at=excluded.fetched_at, body_gz=excluded.body_gz,
                          headers_json=excluded.headers_json,
                          rendered=excluded.rendered, render_ms=excluded.render_ms,
                          js_errors=excluded.js_errors,
                          rendered_words=excluded.rendered_words,
                          static_words=excluded.static_words,
                          perf_ttfb_ms=excluded.perf_ttfb_ms, perf_fcp_ms=excluded.perf_fcp_ms,
                          perf_lcp_ms=excluded.perf_lcp_ms, perf_dcl_ms=excluded.perf_dcl_ms,
                          perf_load_ms=excluded.perf_load_ms,
                          perf_resources=excluded.perf_resources
                        """,
                    arguments: [
                        result.urlID, result.status, result.errorKind, result.contentType,
                        result.contentLength, result.responseTimeMs,
                        try Self.resolveTarget(db, result.redirectTarget, parent: result,
                                               config: config, seedHost: seedHost, now: now, discovered: &discovered,
                                               inheritsParentDepth: true),
                        now.timeIntervalSince1970, result.bodyGz,
                        result.headers.isEmpty ? nil
                            : String(data: (try? JSONEncoder().encode(result.headers)) ?? Data(),
                                     encoding: .utf8),
                        result.render == nil ? 0 : 1,
                        result.render?.elapsedMs,
                        result.render.flatMap { $0.errors.isEmpty ? nil : $0.errors.joined(separator: "\n") },
                        result.render?.renderedWords,
                        result.render?.staticWords,
                        result.render?.metrics?.ttfb.map { Int($0.rounded()) },
                        result.render?.metrics?.fcp.map { Int($0.rounded()) },
                        result.render?.metrics?.lcp.map { Int($0.rounded()) },
                        result.render?.metrics?.dcl.map { Int($0.rounded()) },
                        result.render?.metrics?.load.map { Int($0.rounded()) },
                        result.render?.metrics?.resources,
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
                                                 seedHost: seedHost, now: now, discovered: &discovered,
                                                 inheritsParentDepth: false)

        try db.execute(
            sql: """
                INSERT INTO page_facts
                  (url_id, title, title_length, title_count,
                   meta_description, meta_description_length, meta_description_count,
                   h1, h1_count, h2, h2_count, canonical_id, canonical_count,
                   meta_robots, x_robots_tag, lang, word_count, text_length, content_hash,
                   title_pixels, meta_description_pixels,
                   simhash,
                   og_title, og_description, og_image, og_type,
                   twitter_card, twitter_title, twitter_image,
                   amphtml, rel_prev, rel_next, analytics)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(url_id) DO UPDATE SET
                  title=excluded.title, title_length=excluded.title_length, title_count=excluded.title_count,
                  meta_description=excluded.meta_description,
                  meta_description_length=excluded.meta_description_length,
                  meta_description_count=excluded.meta_description_count,
                  h1=excluded.h1, h1_count=excluded.h1_count,
                  h2=excluded.h2, h2_count=excluded.h2_count,
                  canonical_id=excluded.canonical_id, canonical_count=excluded.canonical_count,
                  meta_robots=excluded.meta_robots,
                  x_robots_tag=excluded.x_robots_tag, lang=excluded.lang,
                  word_count=excluded.word_count, text_length=excluded.text_length,
                  content_hash=excluded.content_hash,
                  simhash=excluded.simhash,
                  title_pixels=excluded.title_pixels,
                  meta_description_pixels=excluded.meta_description_pixels,
                  og_title=excluded.og_title, og_description=excluded.og_description,
                  og_image=excluded.og_image, og_type=excluded.og_type,
                  twitter_card=excluded.twitter_card, twitter_title=excluded.twitter_title,
                  twitter_image=excluded.twitter_image, amphtml=excluded.amphtml,
                  rel_prev=excluded.rel_prev, rel_next=excluded.rel_next,
                  analytics=excluded.analytics
                """,
            arguments: [
                result.urlID, facts.title, facts.titleLength, facts.titleCount,
                facts.metaDescription, facts.metaDescriptionLength, facts.metaDescriptionCount,
                facts.h1, facts.h1Count, facts.h2, facts.h2Count,
                canonicalID, facts.canonicalCount, facts.metaRobots, result.xRobotsTag,
                facts.lang, facts.wordCount, facts.textLength, facts.contentHash,
                SERPMetrics.titleWidth(facts.title).map { Int($0.rounded()) },
                SERPMetrics.descriptionWidth(facts.metaDescription).map { Int($0.rounded()) },
                facts.simHash,
                facts.ogTitle, facts.ogDescription, facts.ogImage, facts.ogType,
                facts.twitterCard, facts.twitterTitle, facts.twitterImage,
                facts.amphtml, facts.relPrev, facts.relNext,
                facts.analytics.isEmpty ? nil : facts.analytics.joined(separator: ", "),
            ]
        )

        try db.execute(sql: "DELETE FROM links WHERE from_url_id = ?", arguments: [result.urlID])
        for link in facts.links {
            guard let target = URLNormalizer.normalize(link.href, relativeTo: result.url) else { continue }
            let isInternal = Self.isInternal(target, seedHost: seedHost, config: config)
            let isNofollow = link.rel?.lowercased().contains("nofollow") == true
            // List mode audits a known set, so a link is recorded but never
            // followed. Status-checking external links still applies: that is
            // about the links on the listed pages, not about discovering more.
            let followInternal = !config.listModeOnly
                && isInternal && (!isNofollow || config.followInternalNofollow)
            // External links are not crawled, but we do want their status — a
            // broken outbound link is a real finding.
            let statusCheckExternal = !isInternal && config.checkExternalLinks
            let crawlable = followInternal || statusCheckExternal

            // nil means the URL was filtered out — skip just this link, never the transaction.
            guard let targetID = try Self.upsertURLOrSkip(db, target, parentDepth: result.depth, config: config,
                                                          seedHost: seedHost, now: now,
                                                          enqueue: crawlable, discovered: &discovered,
                                                          checkOnly: statusCheckExternal)
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
                                           seedHost: seedHost, now: now,
                                           enqueue: config.checkImages, discovered: &discovered,
                                           checkOnly: config.checkImages)
            try db.execute(
                sql: "INSERT INTO images (url_id, src_url_id, alt, width, height) VALUES (?,?,?,?,?)",
                arguments: [result.urlID, srcID, image.alt, image.width, image.height])
        }

        try db.execute(sql: "DELETE FROM simhash_bands WHERE url_id = ?", arguments: [result.urlID])
        if let simHash = facts.simHash {
            for (band, value) in SimHash.bands(simHash).enumerated() {
                try db.execute(
                    sql: "INSERT INTO simhash_bands (url_id, band, value) VALUES (?,?,?)",
                    arguments: [result.urlID, band, value])
            }
        }

        try db.execute(sql: "DELETE FROM resources WHERE url_id = ?", arguments: [result.urlID])
        for resource in facts.resources {
            guard let src = URLNormalizer.normalize(resource.src, relativeTo: result.url) else { continue }
            let srcID = try Self.upsertURL(db, src, parentDepth: result.depth, config: config,
                                           seedHost: seedHost, now: now,
                                           enqueue: config.checkResources, discovered: &discovered,
                                           checkOnly: config.checkResources)
            try db.execute(sql: "INSERT INTO resources (url_id, src_url_id, kind) VALUES (?,?,?)",
                           arguments: [result.urlID, srcID, resource.kind])
        }

        try db.execute(sql: "DELETE FROM extractions WHERE url_id = ?", arguments: [result.urlID])
        // Named response headers, pulled into the same table as the CSS and
        // JavaScript extractions: they answer the same question — "show me this
        // one value for every page" — so they belong in the same tab.
        for name in config.headerExtractions {
            let match = result.headers.first { $0.key.lowercased() == name.lowercased() }
            guard let match else { continue }
            try db.execute(
                sql: "INSERT INTO extractions (url_id, name, value, position) VALUES (?,?,?,0)",
                arguments: [result.urlID, name, match.value])
        }
        for entry in facts.extractions {
            try db.execute(
                sql: "INSERT INTO extractions (url_id, name, value, position) VALUES (?,?,?,?)",
                arguments: [result.urlID, entry.name, entry.value, entry.position])
        }

        try db.execute(sql: "DELETE FROM structured_data WHERE url_id = ?", arguments: [result.urlID])
        for entry in facts.structuredData {
            try db.execute(sql: "INSERT INTO structured_data (url_id, format, type) VALUES (?,?,?)",
                           arguments: [result.urlID, entry.format, entry.type])
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

    /// Resolves a redirect or canonical target discovered from `parent`, which route through this
    /// same function but must not be treated identically:
    ///
    /// - A redirect target is the *same logical page* as its parent, not a child of it, so it
    ///   inherits the parent's own depth. `inheritsParentDepth: true` passes `parent.depth - 1`
    ///   (offsetting `upsertURL`'s own `+ 1`), and the redirect hop count increments from the
    ///   parent's hop count, since this is another link in the same redirect chain.
    /// - A canonical target that was previously undiscovered genuinely is one level deeper than
    ///   the page declaring it, so `inheritsParentDepth: false` passes `parent.depth` and lets
    ///   `upsertURL` descend normally — which also means `config.maxDepth` correctly cuts it off.
    ///   It is not part of a redirect chain, so its hop count starts fresh at 0.
    static func resolveTarget(
        _ db: Database, _ target: NormalizedURL?, parent: CrawlResult, config: CrawlConfig,
        seedHost: String?, now: Date, discovered: inout Int, inheritsParentDepth: Bool
    ) throws -> Int64? {
        guard let target else { return nil }
        let parentDepth: Int
        let redirectHops: Int
        if inheritsParentDepth {
            let parentHops = try Int.fetchOne(
                db, sql: "SELECT redirect_hops FROM urls WHERE id = ?", arguments: [parent.urlID]
            ) ?? 0
            parentDepth = parent.depth - 1
            redirectHops = parentHops + 1
        } else {
            parentDepth = parent.depth
            redirectHops = 0
        }
        return try upsertURL(db, target, parentDepth: parentDepth, config: config, seedHost: seedHost,
                             now: now, enqueue: isInternal(target, seedHost: seedHost, config: config),
                             discovered: &discovered, redirectHops: redirectHops)
    }

    /// Inserts the URL if unseen. `enqueue` false means the row is recorded as skipped rather than queued.
    /// `redirectHops` is the number of redirect hops from the original request to this URL — 0 for
    /// URLs discovered any other way (links, images, hreflang, the seed). A chain that exceeds
    /// `config.maxRedirects` is still recorded (so it's visible in reports) but not queued, which
    /// is what stops a server generating a fresh URL every hop from running forever.
    static func upsertURL(
        _ db: Database, _ url: NormalizedURL, parentDepth: Int, config: CrawlConfig,
        seedHost: String?, now: Date, enqueue: Bool, discovered: inout Int,
        redirectHops: Int = 0,
        checkOnly: Bool = false
    ) throws -> Int64 {
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url_hash = ?", arguments: [url.sha256]) {
            return existing
        }
        let internalFlag = isInternal(url, seedHost: seedHost, config: config)
        let depth = parentDepth + 1

        var shouldQueue = enqueue
        // Recorded alongside the decision rather than inferred later: a crawl
        // that quietly stopped short used to be indistinguishable from one that
        // finished, because the row said "skipped" and nothing said why.
        var skipReason: String? = enqueue ? nil : (internalFlag ? "not followed" : "external")
        if shouldQueue, let maxDepth = config.maxDepth, depth > maxDepth {
            shouldQueue = false; skipReason = "beyond max depth"
        }
        if shouldQueue, !passesFilters(url, config: config) {
            shouldQueue = false; skipReason = "excluded by URL filters"
        }
        if shouldQueue, redirectHops > config.maxRedirects {
            shouldQueue = false; skipReason = "redirect chain too long"
        }
        if shouldQueue {
            // Only rows that still count against crawl budget — queued, in-flight, or done.
            // Skipped rows (state 3) are external links, images, and filtered targets that
            // will never be crawled, so they must not starve internal discovery of budget.
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE state != 3") ?? 0
            if total >= config.urlCap { shouldQueue = false; skipReason = "URL cap reached" }
        }

        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at,
                                  state, redirect_hops, check_only, skip_reason)
                VALUES (?,?,?,?,?,?,?,?,?,?,?)
                """,
            arguments: [url.absoluteString, url.sha256, url.host, url.path, depth,
                        internalFlag ? 1 : 0, now.timeIntervalSince1970, shouldQueue ? 0 : 3, redirectHops,
                        checkOnly ? 1 : 0, shouldQueue ? nil : skipReason]
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
        seedHost: String?, now: Date, enqueue: Bool, discovered: inout Int,
        checkOnly: Bool = false
    ) throws -> Int64? {
        if enqueue && !passesFilters(url, config: config) { return nil }
        return try upsertURL(db, url, parentDepth: parentDepth, config: config, seedHost: seedHost,
                             now: now, enqueue: enqueue, discovered: &discovered, checkOnly: checkOnly)
    }
}
