import Foundation
import GRDB
@testable import KodaCore

/// A crawl containing one row per issue class the eleven reports can surface.
///
/// Built with direct SQL rather than by running a crawl: the crawler is not
/// under test here, a crawled fixture is slow, and adding "a page whose title
/// equals its H1" as a row is trivial where arranging for a fetcher to produce
/// one is not.
///
/// Report tests assert on **paths**, never on counts. A count assertion breaks
/// the moment an unrelated row is added, and says nothing about which rows were
/// meant; a set of paths states the intent and survives the fixture growing.
enum ReportFixture {

    struct Page {
        var path: String
        var status: Int? = 200
        var contentType: String? = "text/html; charset=utf-8"
        var contentLength: Int? = 2048
        var errorKind: String? = nil
        var depth: Int = 1
        var isInternal = true
        var checkOnly = false
        var redirectHops: Int = 0
        var redirectTo: String? = nil
        var hasFacts = true
        var title: String? = auto
        var titleCount = 1
        var desc: String? = auto
        var descCount = 1
        var h1: String? = auto
        var h1Count = 1
        var h2: String? = auto
        var h2Count = 2
        var canonicalTo: String? = "SELF"
        var metaRobots: String? = nil
        var xRobots: String? = nil
        var canonicalCount: Int = 1
        var wordCount: Int = 400
        /// What the content hash is derived from. Defaults to the path, so every
        /// page is unique unless two deliberately share a key.
        var contentKey: String? = nil
        /// Full URL, when the page is not `https://fx.test` + path — used for the
        /// http/https and www/non-www cases.
        var absoluteURL: String? = nil
        var hostOverride: String? = nil
        var ogTitle: String? = nil
        var ogImage: String? = nil
        var twitterCard: String? = nil
        var amphtml: String? = nil
        var relPrev: String? = nil
        var relNext: String? = nil
        var analytics: String? = "Google Analytics 4"
        /// (format, type) pairs written into `structured_data`.
        var schema: [(String, String)] = [("json-ld", "WebPage")]
        var headers: [String: String] = [
            "Content-Type": "text/html",
            "Strict-Transport-Security": "max-age=63072000",
            "Content-Security-Policy": "default-src 'self'",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "SAMEORIGIN",
            "Referrer-Policy": "strict-origin",
        ]
        var imageWidth: Int? = 100
        var imageHeight: Int? = 80
    }

    /// Titles of an exact length, so the over-60 / under-30 filters are tested
    /// at a stated boundary rather than a hopeful one.
    static func text(_ n: Int) -> String { String(repeating: "t", count: n) }

    /// Stands for "give this page its own value, derived from its path".
    ///
    /// A shared default would make every page that does not override its title a
    /// duplicate of every other, so the Duplicate filter would return 31 rows and
    /// the fixture would be testing the fixture rather than the report. Resolved
    /// in `make()`, where the path is known.
    static let auto = "\u{0}auto"

    /// Padded to a length that trips none of the length filters, so only the
    /// pages that deliberately opt into "too long" or "too short" are found.
    static func pad(_ base: String, to length: Int) -> String {
        base.count >= length ? base : base + String(repeating: ".", count: length - base.count)
    }
    static func autoTitle(_ path: String) -> String { pad("Title for \(path)", to: 45) }
    static func autoDesc(_ path: String) -> String { pad("Description for \(path)", to: 110) }
    static func autoH1(_ path: String) -> String { pad("Heading for \(path)", to: 40) }
    static func autoH2(_ path: String) -> String { pad("Subheading for \(path)", to: 42) }

    static let pages: [Page] = [
        // Clean baseline. Depth 0, self-canonical, everything present.
        Page(path: "/", depth: 0, h1: "Welcome"),

        // Titles
        Page(path: "/no-title", title: nil, titleCount: 0),
        Page(path: "/dupe-a", title: "Shared title across two pages of the site"),
        Page(path: "/dupe-b", title: "Shared title across two pages of the site"),
        Page(path: "/long-title", title: text(75)),
        Page(path: "/short-title", title: text(12)),
        Page(path: "/multi-title", titleCount: 2),
        // 35 characters: long enough not to trip Under 30, short enough not to trip Over 60.
        Page(path: "/title-is-h1", title: "Identical text on both title and h1",
             h1: "Identical text on both title and h1"),

        // Meta description
        Page(path: "/no-desc", desc: nil, descCount: 0),
        Page(path: "/dupe-desc-a", desc: pad("Shared description text", to: 100)),
        Page(path: "/dupe-desc-b", desc: pad("Shared description text", to: 100)),
        Page(path: "/long-desc", desc: String(repeating: "d", count: 200)),
        Page(path: "/short-desc", desc: String(repeating: "d", count: 40)),
        Page(path: "/multi-desc", descCount: 2),

        // Headings
        Page(path: "/no-h1", h1: nil, h1Count: 0),
        Page(path: "/dupe-h1-a", h1: "Shared heading"),
        Page(path: "/dupe-h1-b", h1: "Shared heading"),
        Page(path: "/multi-h1", h1Count: 2),
        Page(path: "/long-h1", h1: String(repeating: "h", count: 80)),
        Page(path: "/no-h2", h2: nil, h2Count: 0),
        Page(path: "/long-h2", h2: String(repeating: "s", count: 80)),

        // Canonicals
        Page(path: "/canon-missing", canonicalTo: nil, canonicalCount: 0),
        Page(path: "/canon-multiple", canonicalCount: 3),
        Page(path: "/canonicalised", canonicalTo: "/"),
        Page(path: "/canon-to-404", canonicalTo: "/gone"),

        // Directives
        Page(path: "/noindex", metaRobots: "noindex, follow"),
        Page(path: "/nofollow", metaRobots: "index, nofollow"),
        Page(path: "/robots-conflict", metaRobots: "index", xRobots: "noindex"),

        // Hreflang. /hl-a and /hl-b reference each other and both carry
        // x-default, so they are the clean pair every filter should ignore.
        Page(path: "/hl-a"),
        Page(path: "/hl-b"),
        Page(path: "/hl-noreturn"),
        Page(path: "/hl-orphan"),
        Page(path: "/hl-404"),
        Page(path: "/hl-nodefault"),

        // Response codes
        Page(path: "/redirect-301", status: 301, contentType: nil, redirectTo: "/"),
        Page(path: "/chain-1", status: 301, contentType: nil, redirectTo: "/chain-2"),
        Page(path: "/chain-2", status: 301, contentType: nil, redirectHops: 1, redirectTo: "/chain-final"),
        Page(path: "/chain-final", redirectHops: 2),
        Page(path: "/loop-a", status: 301, contentType: nil, redirectTo: "/loop-b"),
        Page(path: "/loop-b", status: 301, contentType: nil, redirectTo: "/loop-a"),
        Page(path: "/loop-self", status: 301, contentType: nil, redirectTo: "/loop-self"),
        Page(path: "/gone", status: 404, contentType: nil, hasFacts: false),
        Page(path: "/boom", status: 500, contentType: nil, hasFacts: false),
        Page(path: "/dead", status: 0, contentType: nil, contentLength: nil,
             errorKind: "timed out", hasFacts: false),

        // A URL discovered but not yet fetched. Present in every live crawl and
        // must not read as an issue anywhere.
        Page(path: "/queued", status: nil, contentType: nil, contentLength: nil, hasFacts: false),

        // Depth and inlinks
        Page(path: "/deep/four", depth: 4),
        Page(path: "/one-inlink"),

        // Content: two pages with identical body text, plus the thin cases.
        Page(path: "/same-body-a", contentKey: "shared-body"),
        Page(path: "/same-body-b", contentKey: "shared-body"),
        Page(path: "/thin", wordCount: 30),
        Page(path: "/empty-body", wordCount: 0),

        // URL shape.
        Page(path: "/Upper/Case"),
        Page(path: "/has_underscore"),
        Page(path: "/percent%20encoded"),
        // Explicit text, because the auto values are derived from the path and
        // this path is long enough that they would trip the title and H1 length
        // filters — making this page a false positive in two other reports.
        Page(path: "/a-really-quite-long-path-that-goes-well-beyond-one-hundred-and-fifteen-"
                 + "characters-in-total-for-the-length-filter",
             title: "A page with a very long address indeed",
             desc: pad("A page whose address is long but whose text is not", to: 100),
             h1: "Long address, ordinary heading",
             h2: "Long address, ordinary subheading"),
        Page(path: "/pair"),
        Page(path: "/pair/"),
        Page(path: "/insecure", absoluteURL: "http://fx.test/insecure"),
        Page(path: "/on-www", absoluteURL: "https://www.fx.test/on-www", hostOverride: "www.fx.test"),

        // Anchor text targets.
        Page(path: "/anchor-empty"),
        Page(path: "/anchor-generic"),
        Page(path: "/anchor-many"),

        // Social.
        // og:title deliberately matches the page title, so it is the control for
        // the "og:title differs" filter rather than another hit.
        Page(path: "/social-full", title: "A shared title matching the page title",
             ogTitle: "A shared title matching the page title",
             ogImage: "https://fx.test/card.png",
             twitterCard: "summary_large_image", amphtml: "https://fx.test/amp/social"),
        Page(path: "/social-none"),
        Page(path: "/social-og-differs", ogTitle: "Different from the title",
             ogImage: "https://fx.test/c.png", twitterCard: "summary"),

        // Pagination.
        Page(path: "/page/1", relNext: "https://fx.test/page/2"),
        Page(path: "/page/2", relPrev: "https://fx.test/page/1",
             relNext: "https://fx.test/page/3"),
        Page(path: "/page/3", canonicalTo: "/page/1", relPrev: "https://fx.test/page/2"),

        // Structured data.
        Page(path: "/schema-none", schema: []),
        Page(path: "/schema-product", schema: [("json-ld", "Product")]),
        Page(path: "/schema-mixed", schema: [("json-ld", "Article"), ("microdata", "Recipe")]),

        // Tracking and headers.
        Page(path: "/no-tracking", analytics: nil),
        Page(path: "/no-security-headers", headers: ["Content-Type": "text/html"]),
    ]

    static let external: [Page] = [
        Page(path: "https://ext.test/ok", contentType: "text/html", depth: 1,
             isInternal: false, checkOnly: true, hasFacts: false),
        Page(path: "https://ext.test/broken", status: 404, contentType: nil, depth: 1,
             isInternal: false, checkOnly: true, hasFacts: false),
    ]

    static let images: [Page] = [
        Page(path: "/img/plain.png", contentType: "image/png", contentLength: 1_000,
             checkOnly: true, hasFacts: false),
        Page(path: "/img/noalt.png", contentType: "image/png", contentLength: 1_000,
             checkOnly: true, hasFacts: false),
        Page(path: "/img/longalt.png", contentType: "image/png", contentLength: 1_000,
             checkOnly: true, hasFacts: false),
        Page(path: "/img/big.png", contentType: "image/png", contentLength: 200_000,
             checkOnly: true, hasFacts: false),
    ]

    static func make() throws -> Store {
        let store = try Store(path: nil)
        try store.migrate()
        var ids: [String: Int64] = [:]

        try store.dbQueue.write { db in
            // Two passes: every URL row first, so redirect and canonical targets
            // can be resolved by path without caring about declaration order.
            for page in pages + external + images {
                let url = page.absoluteURL
                    ?? (page.isInternal ? "https://fx.test\(page.path)" : page.path)
                try db.execute(
                    sql: """
                        INSERT INTO urls (url, url_hash, host, path, depth, is_internal,
                                          discovered_at, state, redirect_hops, check_only)
                        VALUES (?,?,?,?,?,?,0,?,?,?)
                        """,
                    arguments: [url, Data(url.utf8),
                                page.hostOverride ?? (page.isInternal ? "fx.test" : "ext.test"),
                                page.path, page.depth, page.isInternal ? 1 : 0,
                                page.status == nil ? 0 : 2, page.redirectHops,
                                page.checkOnly ? 1 : 0])
                ids[page.path] = db.lastInsertedRowID
            }

            for page in pages + external + images {
                guard let id = ids[page.path] else { continue }
                if let status = page.status {
                    try db.execute(
                        sql: """
                            INSERT INTO responses (url_id, status, error_kind, content_type,
                                                   content_length, response_time_ms,
                                                   redirect_target_id, fetched_at, headers_json)
                            VALUES (?,?,?,?,?,?,?,0,?)
                            """,
                        arguments: [id, status, page.errorKind, page.contentType,
                                    page.contentLength, 12,
                                    page.redirectTo.flatMap { ids[$0] },
                                    String(data: (try? JSONEncoder().encode(page.headers)) ?? Data(),
                                           encoding: .utf8)])
                }
                guard page.hasFacts else { continue }
                let title = page.title == auto ? autoTitle(page.path) : page.title
                let desc = page.desc == auto ? autoDesc(page.path) : page.desc
                let h1 = page.h1 == auto ? autoH1(page.path) : page.h1
                let h2 = page.h2 == auto ? autoH2(page.path) : page.h2
                let canonical: Int64? = page.canonicalTo == "SELF" ? id : page.canonicalTo.flatMap { ids[$0] }
                try db.execute(
                    sql: """
                        INSERT INTO page_facts
                          (url_id, title, title_length, title_count,
                           meta_description, meta_description_length, meta_description_count,
                           h1, h1_count, h2, h2_count, canonical_id, canonical_count,
                           meta_robots, x_robots_tag, lang, word_count, content_hash,
                           og_title, og_image, twitter_card, amphtml, rel_prev, rel_next, analytics)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'en',?,?,?,?,?,?,?,?,?)
                        """,
                    arguments: [id, title, title?.count, page.titleCount,
                                desc, desc?.count, page.descCount,
                                h1, page.h1Count, h2, page.h2Count, canonical,
                                page.canonicalTo == nil ? 0 : page.canonicalCount,
                                page.metaRobots, page.xRobots, page.wordCount,
                                Data((page.contentKey ?? page.path).utf8),
                                page.ogTitle, page.ogImage, page.twitterCard, page.amphtml,
                                page.relPrev, page.relNext, page.analytics])
                for entry in page.schema {
                    try db.execute(
                        sql: "INSERT INTO structured_data (url_id, format, type) VALUES (?,?,?)",
                        arguments: [id, entry.0, entry.1])
                }
            }

            // Links. Only what the inlink-count filters need, plus enough to keep
            // /one-inlink honest — every other page has zero inlinks here.
            let links: [(String, String)] = [
                ("/", "/dupe-a"), ("/", "/dupe-b"), ("/dupe-a", "/dupe-b"),
                ("/", "/one-inlink"),
                ("/", "https://ext.test/ok"), ("/", "https://ext.test/broken"),
            ]
            // Anchor-text cases, which need control over the anchor itself.
            let anchored: [(String, String, String?)] = [
                ("/", "/anchor-empty", nil),
                ("/dupe-a", "/anchor-empty", "   "),
                ("/", "/anchor-generic", "Click here"),
                ("/", "/anchor-many", "alpha"), ("/dupe-a", "/anchor-many", "beta"),
                ("/dupe-b", "/anchor-many", "gamma"), ("/dupe-desc-a", "/anchor-many", "delta"),
                ("/one-inlink", "/anchor-many", "epsilon"),
            ]
            for (index, entry) in anchored.enumerated() {
                guard let from = ids[entry.0], let to = ids[entry.1] else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position)
                        VALUES (?,?,?,NULL,1,?)
                        """,
                    arguments: [from, to, entry.2, 100 + index])
            }
            for (index, link) in links.enumerated() {
                guard let from = ids[link.0], let to = ids[link.1] else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO links (from_url_id, to_url_id, anchor_text, rel, is_internal, position)
                        VALUES (?,?,?,?,?,?)
                        """,
                    arguments: [from, to, "link to \(link.1)", nil,
                                link.1.hasPrefix("http") ? 0 : 1, index])
            }

            let imageRefs: [(String, String, String?)] = [
                ("/", "/img/plain.png", "A perfectly good alt text"),
                ("/", "/img/noalt.png", nil),
                ("/", "/img/longalt.png", String(repeating: "a", count: 120)),
                ("/", "/img/big.png", "Big"),
            ]
            for ref in imageRefs {
                guard let page = ids[ref.0], let src = ids[ref.1] else { continue }
                // The big image deliberately declares no dimensions, so the
                // layout-shift filter has exactly one row to find.
                let declared = ref.1.hasSuffix("big.png") ? (nil as Int?, nil as Int?) : (100, 80)
                try db.execute(
                    sql: "INSERT INTO images (url_id, src_url_id, alt, width, height) VALUES (?,?,?,?,?)",
                    arguments: [page, src, ref.2, declared.0, declared.1])
            }

            let hreflang: [(String, String, String)] = [
                ("/hl-a", "en", "/hl-a"), ("/hl-a", "de", "/hl-b"), ("/hl-a", "x-default", "/hl-a"),
                ("/hl-b", "en", "/hl-a"), ("/hl-b", "de", "/hl-b"), ("/hl-b", "x-default", "/hl-a"),
                ("/hl-noreturn", "en", "/hl-orphan"), ("/hl-noreturn", "x-default", "/hl-noreturn"),
                ("/hl-404", "es", "/gone"), ("/hl-404", "x-default", "/hl-404"),
                ("/hl-nodefault", "en", "/hl-nodefault"),
            ]
            for entry in hreflang {
                guard let page = ids[entry.0], let href = ids[entry.2] else { continue }
                try db.execute(sql: "INSERT INTO hreflang (url_id, lang, href_url_id) VALUES (?,?,?)",
                               arguments: [page, entry.1, href])
            }
        }
        return store
    }

    /// Turns a result set back into the paths it names, so an assertion reads as
    /// the intent it is testing.
    static func paths(_ store: Store, _ ids: [Int64]) throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try store.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT path FROM urls WHERE id IN (\(placeholders))",
                                    arguments: StatementArguments(ids)))
        }
    }
}
