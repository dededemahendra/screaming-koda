import Foundation

/// The eleven report tabs. Adding a report is a new value in `all`, not new UI
/// code — the table, the sidebar, sorting, and the inspector all read from these
/// definitions.
public enum Reports {

    // MARK: - Shared predicates

    /// Rows a user should see as *pages*: not a status-checked image or external
    /// URL, and not a URL that exists only as an image source.
    /// `Store.visibleURLsFilter` is shared with `Store.summary()` so the two can
    /// never disagree about what the crawl contains.
    static let pageRows = "u.check_only = 0 AND \(Store.visibleURLsFilter)"

    /// The base for every content report. A page that 404s has no title problem
    /// worth reporting; its problem is the 404, which Response Codes owns.
    static let htmlPage = """
        u.is_internal = 1 AND r.status = 200
          AND coalesce(r.content_type, '') LIKE 'text/html%'
          AND \(pageRows)
        """

    /// "Some other internal 200 page has the identical value." Exact match, per
    /// the master spec's v1 position — two titles differing by a trailing space
    /// are not duplicates.
    static func duplicated(_ column: String) -> String {
        """
        f.\(column) IS NOT NULL AND trim(f.\(column)) != '' AND EXISTS (
          SELECT 1 FROM page_facts f2
          JOIN urls u2 ON u2.id = f2.url_id
          JOIN responses r2 ON r2.url_id = f2.url_id
          WHERE f2.\(column) = f.\(column) AND f2.url_id != u.id
            AND u2.is_internal = 1 AND r2.status = 200
        )
        """
    }

    static func missing(_ column: String) -> String {
        "f.\(column) IS NULL OR trim(f.\(column)) = ''"
    }

    /// Headers are stored as a JSON object, so this matches the *name* rather
    /// than parsing the blob: a response that never carried the header at all
    /// (`headers_json IS NULL`) counts as missing too, which is what a
    /// status-checked HEAD with no headers recorded looks like.
    static func missingHeader(_ name: String) -> String {
        "r.headers_json IS NULL OR lower(r.headers_json) NOT LIKE '%\"\(name)\"%'"
    }

    static func directive(_ token: String) -> String {
        "lower(coalesce(f.meta_robots, '') || ' ' || coalesce(f.x_robots_tag, '')) LIKE '%\(token)%'"
    }

    // MARK: - Shared columns

    enum Col {
        static let address = ReportColumn(id: "address", header: "Address",
                                          expression: "u.url", width: 340)
        static let status = ReportColumn(id: "status", header: "Status",
                                         expression: "r.status", width: 60, alignment: .trailing,
                                         semantic: .status)
        static let contentType = ReportColumn(id: "contentType", header: "Content Type",
                                              expression: "r.content_type", width: 150)
        static let indexability = ReportColumn(id: "indexability", header: "Indexability",
                                               expression: Indexability.expression, width: 190,
                                               semantic: .indexability)
        static let title = ReportColumn(id: "title", header: "Title", expression: "f.title", width: 260)
        static let titleLength = ReportColumn(id: "titleLength", header: "Len",
                                              expression: "f.title_length", width: 50, alignment: .trailing)
        static let titleCount = ReportColumn(id: "titleCount", header: "Count",
                                             expression: "f.title_count", width: 55, alignment: .trailing)
        static let desc = ReportColumn(id: "desc", header: "Meta Description",
                                       expression: "f.meta_description", width: 300)
        static let descLength = ReportColumn(id: "descLength", header: "Len",
                                             expression: "f.meta_description_length",
                                             width: 50, alignment: .trailing)
        static let descCount = ReportColumn(id: "descCount", header: "Count",
                                            expression: "f.meta_description_count",
                                            width: 55, alignment: .trailing)
        static let h1 = ReportColumn(id: "h1", header: "H1", expression: "f.h1", width: 260)
        static let h1Length = ReportColumn(id: "h1Length", header: "Len",
                                           expression: "length(f.h1)", width: 50, alignment: .trailing)
        static let h1Count = ReportColumn(id: "h1Count", header: "H1s",
                                          expression: "f.h1_count", width: 50, alignment: .trailing)
        static let h2Count = ReportColumn(id: "h2Count", header: "H2s",
                                          expression: "f.h2_count", width: 50, alignment: .trailing)
        static let canonical = ReportColumn(
            id: "canonical", header: "Canonical",
            expression: "(SELECT cu.url FROM urls cu WHERE cu.id = f.canonical_id)", width: 300)
        static let metaRobots = ReportColumn(id: "metaRobots", header: "Meta Robots",
                                             expression: "f.meta_robots", width: 170)
        static let xRobots = ReportColumn(id: "xRobots", header: "X-Robots-Tag",
                                          expression: "f.x_robots_tag", width: 170)
        static let wordCount = ReportColumn(id: "wordCount", header: "Words",
                                            expression: "f.word_count", width: 60, alignment: .trailing)
        static let depth = ReportColumn(id: "depth", header: "Depth",
                                        expression: "u.depth", width: 55, alignment: .trailing)
        static let size = ReportColumn(id: "size", header: "Size (B)",
                                       expression: "r.content_length", width: 80, alignment: .trailing)
        static let responseTime = ReportColumn(id: "responseTime", header: "ms",
                                               expression: "r.response_time_ms",
                                               width: 55, alignment: .trailing)
        static let redirectTo = ReportColumn(
            id: "redirectTo", header: "Redirects To",
            expression: "(SELECT ru.url FROM urls ru WHERE ru.id = r.redirect_target_id)", width: 300)
        static let hops = ReportColumn(id: "hops", header: "Hops",
                                       expression: "u.redirect_hops", width: 50, alignment: .trailing)
        static let inlinks = ReportColumn(
            id: "inlinks", header: "Inlinks",
            expression: "(SELECT count(DISTINCT from_url_id) FROM links WHERE to_url_id = u.id)",
            width: 65, alignment: .trailing)
        static let referencedBy = ReportColumn(
            id: "referencedBy", header: "On Pages",
            expression: "(SELECT count(*) FROM images i WHERE i.src_url_id = u.id)",
            width: 75, alignment: .trailing)
        static let noAltOn = ReportColumn(
            id: "noAltOn", header: "No Alt On",
            expression: """
                (SELECT count(*) FROM images i
                 WHERE i.src_url_id = u.id AND (i.alt IS NULL OR trim(i.alt) = ''))
                """,
            width: 80, alignment: .trailing)
        static let lang = ReportColumn(id: "lang", header: "Lang", expression: "f.lang", width: 60)
        static let hreflangCount = ReportColumn(
            id: "hreflangCount", header: "Entries",
            expression: "(SELECT count(*) FROM hreflang h WHERE h.url_id = u.id)",
            width: 65, alignment: .trailing)
        static let errorKind = ReportColumn(id: "errorKind", header: "Error",
                                            expression: "r.error_kind", width: 180)
        static let h2 = ReportColumn(id: "h2", header: "H2", expression: "f.h2", width: 240)
        static let canonicalCount = ReportColumn(id: "canonicalCount", header: "Canonicals",
                                                 expression: "f.canonical_count",
                                                 width: 80, alignment: .trailing)
        static let urlLength = ReportColumn(id: "urlLength", header: "URL Len",
                                            expression: "length(u.url)",
                                            width: 70, alignment: .trailing)
        static let scheme = ReportColumn(
            id: "scheme", header: "Scheme",
            expression: "CASE WHEN u.url LIKE 'https://%' THEN 'https' ELSE 'http' END", width: 70)
        static let contentHash = ReportColumn(id: "contentHash", header: "Content Hash",
                                              expression: "f.content_hash", width: 110)
        static let sameContentAs = ReportColumn(
            id: "sameContentAs", header: "Identical To",
            expression: """
                (SELECT count(*) FROM page_facts f2
                 WHERE f2.content_hash = f.content_hash AND f2.url_id != u.id)
                """,
            width: 90, alignment: .trailing)
        static let distinctAnchors = ReportColumn(
            id: "distinctAnchors", header: "Anchors",
            expression: """
                (SELECT count(DISTINCT trim(lower(coalesce(l.anchor_text, ''))))
                 FROM links l WHERE l.to_url_id = u.id)
                """,
            width: 70, alignment: .trailing)
        static let ogTitle = ReportColumn(id: "ogTitle", header: "og:title",
                                          expression: "f.og_title", width: 240)
        static let ogImage = ReportColumn(id: "ogImage", header: "og:image",
                                          expression: "f.og_image", width: 240)
        static let ogType = ReportColumn(id: "ogType", header: "og:type",
                                         expression: "f.og_type", width: 100)
        static let twitterCard = ReportColumn(id: "twitterCard", header: "twitter:card",
                                              expression: "f.twitter_card", width: 140)
        static let amphtml = ReportColumn(id: "amphtml", header: "AMP Version",
                                          expression: "f.amphtml", width: 240)
        static let relPrev = ReportColumn(id: "relPrev", header: "rel=prev",
                                          expression: "f.rel_prev", width: 240)
        static let relNext = ReportColumn(id: "relNext", header: "rel=next",
                                          expression: "f.rel_next", width: 240)
        static let analytics = ReportColumn(id: "analytics", header: "Tracking",
                                            expression: "f.analytics", width: 200)
        static let schemaTypes = ReportColumn(
            id: "schemaTypes", header: "Types",
            expression: """
                (SELECT group_concat(DISTINCT sd.type) FROM structured_data sd
                 WHERE sd.url_id = u.id)
                """,
            width: 260)
        static let schemaFormats = ReportColumn(
            id: "schemaFormats", header: "Formats",
            expression: """
                (SELECT group_concat(DISTINCT sd.format) FROM structured_data sd
                 WHERE sd.url_id = u.id)
                """,
            width: 140)
        static let imageDimensions = ReportColumn(
            id: "dimensions", header: "Declared Size",
            // An image referenced by several pages can be declared with a size
            // on one and without on another. `LIMIT 1` with no ORDER BY would
            // show whichever row SQLite returned first, so the column would flip
            // between runs; a declared size always wins. The "no declared
            // dimensions" filter uses EXISTS, so it still flags the page that
            // omitted them.
            expression: """
                (SELECT CASE WHEN i.width IS NULL OR i.height IS NULL THEN NULL
                             ELSE i.width || ' x ' || i.height END
                 FROM images i WHERE i.src_url_id = u.id
                 ORDER BY (i.width IS NULL OR i.height IS NULL) ASC, i.url_id ASC
                 LIMIT 1)
                """,
            width: 110)
        static let extractionCount = ReportColumn(
            id: "extractionCount", header: "Values",
            expression: "(SELECT count(*) FROM extractions e WHERE e.url_id = u.id)",
            width: 60, alignment: .trailing)
        static let extractedNames = ReportColumn(
            id: "extractedNames", header: "Extracted",
            expression: """
                (SELECT group_concat(DISTINCT e.name) FROM extractions e WHERE e.url_id = u.id)
                """,
            width: 200)
        static let extractedValues = ReportColumn(
            id: "extractedValues", header: "Values Found",
            expression: """
                (SELECT group_concat(e.value, ' | ') FROM (
                   SELECT value FROM extractions WHERE url_id = u.id
                   ORDER BY name ASC, position ASC LIMIT 5) e)
                """,
            width: 380)
        static let resourceKind = ReportColumn(
            id: "kind", header: "Type",
            expression: "(SELECT res.kind FROM resources res WHERE res.src_url_id = u.id LIMIT 1)",
            width: 70)
        static let usedOnPages = ReportColumn(
            id: "usedOn", header: "Used On",
            expression: "(SELECT count(DISTINCT res.url_id) FROM resources res WHERE res.src_url_id = u.id)",
            width: 75, alignment: .trailing)
        static let renderedFlag = ReportColumn(
            id: "rendered", header: "Rendered",
            expression: "CASE WHEN r.rendered = 1 THEN 'Yes' ELSE 'No' END", width: 80)
        static let renderMs = ReportColumn(id: "renderMs", header: "Render ms",
                                           expression: "r.render_ms",
                                           width: 80, alignment: .trailing)
        static let jsErrors = ReportColumn(id: "jsErrors", header: "JavaScript Errors",
                                           expression: "r.js_errors", width: 320)
        static let renderedWords = ReportColumn(id: "renderedWords", header: "Rendered Words",
                                                expression: "r.rendered_words",
                                                width: 110, alignment: .trailing)
        static let staticWords = ReportColumn(id: "staticWords", header: "Static Words",
                                              expression: "r.static_words",
                                              width: 100, alignment: .trailing)
        /// One external metric as a column. Built rather than declared because
        /// there are dozens across six providers and they all have one shape.
        static func metric(_ source: MetricSource, _ name: String,
                           header: String, width: Double = 100) -> ReportColumn {
            ReportColumn(
                id: "\(source.rawValue)_\(name.replacingOccurrences(of: " ", with: "_"))",
                header: header,
                expression: """
                    (SELECT coalesce(m.text, CAST(round(m.value, 2) AS TEXT))
                     FROM external_metrics m
                     WHERE m.url_id = u.id AND m.source = '\(source.rawValue)'
                       AND m.metric = '\(name)')
                    """,
                width: width, alignment: .trailing)
        }

        static func hasMetrics(_ source: MetricSource) -> String {
            """
            EXISTS (SELECT 1 FROM external_metrics m
                    WHERE m.url_id = u.id AND m.source = '\(source.rawValue)')
            """
        }

        static func metricValue(_ source: MetricSource, _ name: String) -> String {
            """
            (SELECT m.value FROM external_metrics m
             WHERE m.url_id = u.id AND m.source = '\(source.rawValue)' AND m.metric = '\(name)')
            """
        }

        static let nearDuplicates = ReportColumn(
            id: "nearDuplicates", header: "Near Dupes",
            expression: """
                (SELECT count(DISTINCT f2.url_id) FROM simhash_bands mine
                 JOIN simhash_bands theirs
                   ON theirs.band = mine.band AND theirs.value = mine.value
                 JOIN page_facts f2 ON f2.url_id = theirs.url_id
                 WHERE mine.url_id = u.id AND theirs.url_id != u.id
                   AND koda_hamming(f.simhash, f2.simhash) <= \(SimHash.nearThreshold))
                """,
            width: 90, alignment: .trailing)
        static let titlePixels = ReportColumn(id: "titlePixels", header: "Title px",
                                              expression: "f.title_pixels",
                                              width: 75, alignment: .trailing)
        static let descPixels = ReportColumn(id: "descPixels", header: "Desc px",
                                             expression: "f.meta_description_pixels",
                                             width: 75, alignment: .trailing)
        static let query = ReportColumn(
            id: "query", header: "Query String",
            expression: """
                CASE WHEN instr(u.url, '?') > 0
                     THEN substr(u.url, instr(u.url, '?') + 1) END
                """,
            width: 240)
        static let setCookie = ReportColumn(
            id: "setCookie", header: "Set-Cookie",
            expression: "json_extract(r.headers_json, '$.\"Set-Cookie\"')", width: 320)
        static let skipReason = ReportColumn(id: "skipReason", header: "Why Not Crawled",
                                             expression: "u.skip_reason", width: 200)
        static let textRatio = ReportColumn(
            id: "textRatio", header: "Text %",
            expression: """
                CASE WHEN coalesce(r.content_length, 0) > 0 AND f.text_length IS NOT NULL
                     THEN round(100.0 * f.text_length / r.content_length, 1) END
                """,
            width: 65, alignment: .trailing)
        static let textLength = ReportColumn(id: "textLength", header: "Text Chars",
                                             expression: "f.text_length",
                                             width: 85, alignment: .trailing)
        static let ttfb = ReportColumn(id: "ttfb", header: "TTFB ms",
                                       expression: "r.perf_ttfb_ms", width: 75, alignment: .trailing)
        static let fcp = ReportColumn(id: "fcp", header: "FCP ms",
                                      expression: "r.perf_fcp_ms", width: 70, alignment: .trailing)
        static let lcp = ReportColumn(id: "lcp", header: "LCP ms",
                                      expression: "r.perf_lcp_ms", width: 70, alignment: .trailing)
        static let loadMs = ReportColumn(id: "loadMs", header: "Load ms",
                                         expression: "r.perf_load_ms", width: 75, alignment: .trailing)
        static let subresources = ReportColumn(id: "subresources", header: "Requests",
                                               expression: "r.perf_resources",
                                               width: 75, alignment: .trailing)
        static let inSitemap = ReportColumn(
            id: "inSitemap", header: "In Sitemap",
            expression: "CASE WHEN u.in_sitemap = 1 THEN 'Yes' ELSE 'No' END", width: 90)
        static let topAnchor = ReportColumn(
            id: "topAnchor", header: "Most Common Anchor",
            expression: """
                (SELECT l.anchor_text FROM links l WHERE l.to_url_id = u.id
                 GROUP BY trim(lower(coalesce(l.anchor_text, '')))
                 ORDER BY count(*) DESC, l.anchor_text ASC LIMIT 1)
                """,
            width: 260)
    }

    static let allFilter = ReportFilter(id: "all", name: "All", predicate: "1")

    // MARK: - The eleven

    public static let all: [Report] = [
        internalURLs, external, responseCodes, titles, metaDescription, headings,
        images, canonicals, directives, hreflang, pageDepth,
        content, urlStructure, anchorText,
        social, structuredData, pagination, security, extraction, sitemap, resources,
        javascript, performance, crawlability, serp, externalData,
    ]

    public static let internalURLs = Report(
        id: "internal", name: "Internal",
        predicate: "u.is_internal = 1 AND \(pageRows)",
        columns: [Col.address, Col.status, Col.contentType, Col.indexability,
                  Col.title, Col.titleLength, Col.h1, Col.wordCount, Col.depth,
                  Col.inlinks, Col.analytics, Col.responseTime],
        filters: [
            allFilter,
            ReportFilter(id: "nonIndexable", name: "Non-indexable",
                         predicate: Indexability.isNonIndexable, severity: .breaksIndexing),
            // Detected from markup, so a tag injected at runtime by another
            // script is invisible here — the same blind spot the crawler has
            // everywhere without a rendering step.
            ReportFilter(id: "noAnalytics", name: "No tracking detected", predicate: """
                (\(htmlPage)) AND (f.analytics IS NULL OR trim(f.analytics) = '')
                """, severity: .hygiene),
        ])

    public static let external = Report(
        id: "external", name: "External",
        predicate: "u.is_internal = 0",
        columns: [Col.address, Col.status, Col.contentType, Col.inlinks, Col.responseTime],
        filters: [
            allFilter,
            ReportFilter(id: "broken", name: "Broken",
                         predicate: "r.status = 0 OR r.status >= 400", severity: .breaksIndexing),
        ])

    public static let responseCodes = Report(
        id: "responseCodes", name: "Response Codes",
        predicate: "r.status IS NOT NULL",
        columns: [Col.address, Col.status, Col.contentType, Col.errorKind,
                  Col.redirectTo, Col.hops, Col.size, Col.responseTime],
        filters: [
            allFilter,
            ReportFilter(id: "success", name: "Success (2xx)",
                         predicate: "r.status BETWEEN 200 AND 299"),
            ReportFilter(id: "redirection", name: "Redirection (3xx)",
                         predicate: "r.status BETWEEN 300 AND 399"),
            ReportFilter(id: "clientError", name: "Client error (4xx)",
                         predicate: "r.status BETWEEN 400 AND 499", severity: .breaksIndexing),
            ReportFilter(id: "serverError", name: "Server error (5xx)",
                         predicate: "r.status >= 500", severity: .breaksIndexing),
            ReportFilter(id: "transportError", name: "No response",
                         predicate: "r.status = 0", severity: .breaksIndexing),
            // The row is the *destination*, not the chain: "you reached this URL
            // through two or more redirects, so the links pointing at it are stale."
            ReportFilter(id: "viaChain", name: "Reached via 2+ redirects",
                         predicate: "u.redirect_hops >= 2", severity: .breaksIndexing),
            // Catches a URL redirecting to itself, and a pair redirecting to each
            // other. A longer cycle is not detected here — it exceeds the hop cap
            // and is abandoned by the engine, so it surfaces under "Reached via
            // 2+ redirects" instead. Detecting it properly needs recursion this
            // predicate cannot express.
            ReportFilter(id: "loop", name: "Redirect loop", predicate: """
                r.redirect_target_id IS NOT NULL AND (
                  r.redirect_target_id = u.id
                  OR EXISTS (SELECT 1 FROM responses r2
                             WHERE r2.url_id = r.redirect_target_id AND r2.redirect_target_id = u.id)
                )
                """, severity: .breaksIndexing),
        ])

    public static let titles = Report(
        id: "titles", name: "Titles",
        predicate: htmlPage,
        columns: [Col.address, Col.title, Col.titleLength, Col.titlePixels, Col.titleCount,
                  Col.h1, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "missing", name: "Missing", predicate: missing("title"), severity: .costsClicks),
            ReportFilter(id: "duplicate", name: "Duplicate",
                         predicate: duplicated("title"), severity: .costsClicks),
            ReportFilter(id: "over60", name: "Over 60 characters",
                         predicate: "f.title_length > 60", severity: .costsClicks),
            ReportFilter(id: "under30", name: "Under 30 characters",
                         predicate: "f.title_length IS NOT NULL AND f.title_length < 30", severity: .costsClicks),
            ReportFilter(id: "multiple", name: "Multiple", predicate: "f.title_count > 1", severity: .costsClicks),
            ReportFilter(id: "sameAsH1", name: "Same as H1", predicate: """
                f.title IS NOT NULL AND f.h1 IS NOT NULL AND trim(f.title) = trim(f.h1)
                """, severity: .costsClicks),
            // Pixels, not characters: twenty W's is four times the width of
            // twenty i's, and it is width that gets truncated.
            ReportFilter(id: "tooWide", name: "Wider than a result snippet",
                         predicate: "f.title_pixels > \(Int(SERPMetrics.titleLimit))",
                         severity: .costsClicks),
        ])

    public static let metaDescription = Report(
        id: "metaDescription", name: "Meta Description",
        predicate: htmlPage,
        columns: [Col.address, Col.desc, Col.descLength, Col.descPixels, Col.descCount,
                  Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "missing", name: "Missing",
                         predicate: missing("meta_description"), severity: .costsClicks),
            ReportFilter(id: "duplicate", name: "Duplicate",
                         predicate: duplicated("meta_description"), severity: .costsClicks),
            ReportFilter(id: "over155", name: "Over 155 characters",
                         predicate: "f.meta_description_length > 155", severity: .costsClicks),
            ReportFilter(id: "under70", name: "Under 70 characters", predicate: """
                f.meta_description_length IS NOT NULL AND f.meta_description_length < 70
                """, severity: .costsClicks),
            ReportFilter(id: "multiple", name: "Multiple",
                         predicate: "f.meta_description_count > 1", severity: .costsClicks),
            ReportFilter(id: "tooWide", name: "Wider than a result snippet",
                         predicate: "f.meta_description_pixels > \(Int(SERPMetrics.descriptionLimit))",
                         severity: .costsClicks),
        ])

    public static let headings = Report(
        id: "headings", name: "Headings",
        predicate: htmlPage,
        columns: [Col.address, Col.h1, Col.h1Length, Col.h1Count, Col.h2, Col.h2Count, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "missingH1", name: "Missing H1", predicate: missing("h1"), severity: .hygiene),
            ReportFilter(id: "duplicateH1", name: "Duplicate H1",
                         predicate: duplicated("h1"), severity: .hygiene),
            ReportFilter(id: "multipleH1", name: "Multiple H1",
                         predicate: "f.h1_count > 1", severity: .hygiene),
            ReportFilter(id: "longH1", name: "H1 over 70 characters",
                         predicate: "length(f.h1) > 70", severity: .hygiene),
            ReportFilter(id: "missingH2", name: "Missing H2",
                         predicate: "coalesce(f.h2_count, 0) = 0", severity: .hygiene),
            ReportFilter(id: "duplicateH2", name: "Duplicate H2",
                         predicate: duplicated("h2"), severity: .hygiene),
            ReportFilter(id: "longH2", name: "H2 over 70 characters",
                         predicate: "length(f.h2) > 70", severity: .hygiene),
        ])

    public static let images = Report(
        id: "images", name: "Images",
        predicate: "u.id IN (SELECT src_url_id FROM images)",
        columns: [Col.address, Col.status, Col.contentType, Col.size,
                  Col.imageDimensions, Col.referencedBy, Col.noAltOn],
        filters: [
            allFilter,
            ReportFilter(id: "missingAlt", name: "Missing alt text", predicate: """
                EXISTS (SELECT 1 FROM images i
                        WHERE i.src_url_id = u.id AND (i.alt IS NULL OR trim(i.alt) = ''))
                """, severity: .hygiene),
            ReportFilter(id: "longAlt", name: "Alt over 100 characters", predicate: """
                EXISTS (SELECT 1 FROM images i WHERE i.src_url_id = u.id AND length(i.alt) > 100)
                """, severity: .hygiene),
            ReportFilter(id: "over100kb", name: "Over 100KB",
                         predicate: "r.content_length > 102400", severity: .hygiene),
            // Undeclared dimensions are the usual cause of layout shift.
            ReportFilter(id: "noDimensions", name: "No declared dimensions", predicate: """
                EXISTS (SELECT 1 FROM images i WHERE i.src_url_id = u.id
                        AND (i.width IS NULL OR i.height IS NULL))
                """, severity: .hygiene),
        ])

    public static let canonicals = Report(
        id: "canonicals", name: "Canonicals",
        predicate: htmlPage,
        columns: [Col.address, Col.canonical, Col.canonicalCount, Col.indexability, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "missing", name: "Missing",
                         predicate: "f.canonical_id IS NULL", severity: .hygiene),
            ReportFilter(id: "self", name: "Self-referencing",
                         predicate: "f.canonical_id = u.id"),
            ReportFilter(id: "canonicalised", name: "Canonicalised",
                         predicate: "f.canonical_id IS NOT NULL AND f.canonical_id != u.id",
                         severity: .breaksIndexing),
            ReportFilter(id: "toNon200", name: "To a non-200", predicate: """
                f.canonical_id IS NOT NULL AND f.canonical_id != u.id AND EXISTS (
                  SELECT 1 FROM responses cr WHERE cr.url_id = f.canonical_id AND cr.status != 200
                )
                """, severity: .breaksIndexing),
            // Only the first canonical is followed, so a page declaring two is
            // silently having one of them ignored by every search engine.
            ReportFilter(id: "multiple", name: "Multiple",
                         predicate: "f.canonical_count > 1", severity: .breaksIndexing),
        ])

    public static let directives = Report(
        id: "directives", name: "Directives",
        predicate: htmlPage,
        columns: [Col.address, Col.metaRobots, Col.xRobots, Col.indexability, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "noindex", name: "noindex",
                         predicate: directive("noindex"), severity: .breaksIndexing),
            ReportFilter(id: "nofollow", name: "nofollow",
                         predicate: directive("nofollow"), severity: .hygiene),
            ReportFilter(id: "noarchive", name: "noarchive",
                         predicate: directive("noarchive"), severity: .hygiene),
            // Both present and disagreeing about indexing. Google takes the most
            // restrictive, so the page is non-indexable and the markup says
            // otherwise — which is how these ship unnoticed.
            ReportFilter(id: "conflict", name: "X-Robots conflict", predicate: """
                f.meta_robots IS NOT NULL AND f.x_robots_tag IS NOT NULL
                AND (lower(f.meta_robots) LIKE '%noindex%') != (lower(f.x_robots_tag) LIKE '%noindex%')
                """, severity: .breaksIndexing),
        ])

    public static let hreflang = Report(
        id: "hreflang", name: "Hreflang",
        predicate: "u.id IN (SELECT url_id FROM hreflang)",
        columns: [Col.address, Col.lang, Col.hreflangCount, Col.status, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "noReturn", name: "Missing return link", predicate: """
                EXISTS (
                  SELECT 1 FROM hreflang h WHERE h.url_id = u.id AND NOT EXISTS (
                    SELECT 1 FROM hreflang h2
                    WHERE h2.url_id = h.href_url_id AND h2.href_url_id = u.id
                  )
                )
                """, severity: .hygiene),
            ReportFilter(id: "non200", name: "Non-200 target", predicate: """
                EXISTS (
                  SELECT 1 FROM hreflang h
                  LEFT JOIN responses hr ON hr.url_id = h.href_url_id
                  WHERE h.url_id = u.id AND (hr.status IS NULL OR hr.status != 200)
                )
                """, severity: .breaksIndexing),
            ReportFilter(id: "noXDefault", name: "Missing x-default", predicate: """
                NOT EXISTS (
                  SELECT 1 FROM hreflang h WHERE h.url_id = u.id AND lower(h.lang) = 'x-default'
                )
                """, severity: .hygiene),
        ])

    /// What the crawler already knew and never said.
    ///
    /// `content_hash` — SHA-256 of each page's normalised visible text — has been
    /// computed, stored and indexed since M1, and until now no report queried it.
    /// Duplicate content was paid for on every crawl and never collected.
    public static let content = Report(
        id: "content", name: "Content",
        predicate: htmlPage,
        columns: [Col.address, Col.wordCount, Col.textLength, Col.textRatio,
                  Col.sameContentAs, Col.nearDuplicates, Col.title, Col.indexability],
        filters: [
            allFilter,
            // Exact match on the hash, per the master spec's v1 position. Two
            // pages differing by one character are not duplicates here.
            ReportFilter(id: "duplicate", name: "Duplicate content", predicate: """
                f.content_hash IS NOT NULL AND length(f.content_hash) > 0 AND EXISTS (
                  SELECT 1 FROM page_facts f2
                  JOIN urls u2 ON u2.id = f2.url_id
                  JOIN responses r2 ON r2.url_id = f2.url_id
                  WHERE f2.content_hash = f.content_hash AND f2.url_id != u.id
                    AND u2.is_internal = 1 AND r2.status = 200
                )
                """, severity: .breaksIndexing),
            ReportFilter(id: "thin", name: "Under 200 words",
                         predicate: "coalesce(f.word_count, 0) < 200", severity: .costsClicks),
            ReportFilter(id: "veryThin", name: "Under 50 words",
                         predicate: "coalesce(f.word_count, 0) < 50", severity: .costsClicks),
            ReportFilter(id: "empty", name: "No content at all",
                         predicate: "coalesce(f.word_count, 0) = 0", severity: .costsClicks),
            // Similar but not identical: two product pages differing by a price,
            // or a paginated series where only a heading changes. The exact-match
            // filter above cannot see these at all.
            //
            // The band comparison is a prefilter, not the answer: two
            // fingerprints within the threshold must share a band intact, so an
            // indexed band match narrows the candidates without being able to
            // miss a real pair, and koda_hamming then decides. Comparing every
            // page against every other would be quadratic.
            ReportFilter(id: "nearDuplicate", name: "Near-duplicate content", predicate: """
                f.simhash IS NOT NULL AND EXISTS (
                  SELECT 1 FROM simhash_bands mine
                  JOIN simhash_bands theirs
                    ON theirs.band = mine.band AND theirs.value = mine.value
                  JOIN page_facts f2 ON f2.url_id = theirs.url_id
                  JOIN urls u2 ON u2.id = f2.url_id
                  JOIN responses r2 ON r2.url_id = f2.url_id
                  WHERE mine.url_id = u.id AND theirs.url_id != u.id
                    AND u2.is_internal = 1 AND r2.status = 200
                    AND koda_hamming(f.simhash, f2.simhash) <= \(SimHash.nearThreshold)
                    AND f2.content_hash IS NOT f.content_hash
                )
                """, severity: .breaksIndexing),
            // Mostly markup. A low ratio is a smell rather than a verdict — a
            // heavily componentised page can be fine — but it is where bloated
            // templates and content-free pages both show up.
            ReportFilter(id: "lowTextRatio", name: "Under 10% text", predicate: """
                coalesce(r.content_length, 0) > 0 AND f.text_length IS NOT NULL
                AND (100.0 * f.text_length / r.content_length) < 10
                """, severity: .hygiene),
        ])

    /// The shape of the URLs themselves, which is where a surprising share of
    /// duplicate-content and canonicalisation trouble actually starts.
    public static let urlStructure = Report(
        id: "urls", name: "URLs",
        predicate: "u.is_internal = 1 AND \(pageRows)",
        columns: [Col.address, Col.urlLength, Col.scheme, Col.query, Col.status,
                  Col.indexability, Col.depth],
        filters: [
            allFilter,
            ReportFilter(id: "insecure", name: "Not HTTPS",
                         predicate: "u.url NOT LIKE 'https://%'", severity: .hygiene),
            // Only a finding when the crawl contains both forms: a site that is
            // consistently one or the other is fine, whichever it picked.
            ReportFilter(id: "mixedWWW", name: "Mixed www and non-www", predicate: """
                EXISTS (SELECT 1 FROM urls u2 WHERE u2.is_internal = 1 AND (
                  (u.host LIKE 'www.%' AND u2.host = substr(u.host, 5))
                  OR (u.host NOT LIKE 'www.%' AND u2.host = 'www.' || u.host)))
                """, severity: .hygiene),
            ReportFilter(id: "params", name: "Contains parameters",
                         predicate: "u.url LIKE '%?%'"),
            // Tracking parameters create an endless supply of distinct URLs for
            // the same page, which is where crawl budget and duplicate content
            // problems usually start.
            ReportFilter(id: "trackingParams", name: "Tracking parameters", predicate: """
                lower(u.url) LIKE '%utm\\_%' ESCAPE '\\' OR lower(u.url) LIKE '%gclid=%'
                OR lower(u.url) LIKE '%fbclid=%' OR lower(u.url) LIKE '%mc\\_cid=%' ESCAPE '\\'
                OR lower(u.url) LIKE '%msclkid=%'
                """, severity: .hygiene),
            ReportFilter(id: "sessionParams", name: "Session parameters", predicate: """
                lower(u.url) LIKE '%sessionid=%' OR lower(u.url) LIKE '%phpsessid=%'
                OR lower(u.url) LIKE '%jsessionid=%' OR lower(u.url) LIKE '%?sid=%'
                OR lower(u.url) LIKE '%&sid=%'
                """, severity: .hygiene),
            ReportFilter(id: "manyParams", name: "Three or more parameters", predicate: """
                length(u.url) - length(replace(u.url, '&', '')) >= 2 AND u.url LIKE '%?%'
                """, severity: .hygiene),
            // The pair that says a migration is unfinished: an http URL whose
            // https twin the crawl also found.
            ReportFilter(id: "httpWithHTTPSTwin", name: "HTTP page that also exists on HTTPS",
                         predicate: """
                u.url LIKE 'http://%' AND EXISTS (
                  SELECT 1 FROM urls u2
                  WHERE u2.url = 'https://' || substr(u.url, 8)
                )
                """, severity: .hygiene),
            ReportFilter(id: "httpNoRedirect", name: "HTTP page that does not redirect",
                         predicate: """
                u.url LIKE 'http://%' AND r.status IS NOT NULL
                AND (r.status < 300 OR r.status >= 400)
                """, severity: .hygiene),
            ReportFilter(id: "long", name: "Over 115 characters",
                         predicate: "length(u.url) > 115", severity: .hygiene),
            // Uppercase in a path is a duplicate-content risk because most
            // servers treat paths case-sensitively and most links do not.
            ReportFilter(id: "uppercase", name: "Uppercase in path",
                         predicate: "u.path != lower(u.path)", severity: .hygiene),
            ReportFilter(id: "underscore", name: "Underscores in path",
                         predicate: "u.path LIKE '%\\_%' ESCAPE '\\'", severity: .hygiene),
            ReportFilter(id: "encoded", name: "Percent-encoded",
                         predicate: "u.url LIKE '%\\%%' ESCAPE '\\'"),
            // The normaliser deliberately preserves trailing slashes, since they
            // can be semantically significant. That makes both forms reachable,
            // so a site serving both is worth knowing about.
            ReportFilter(id: "slashPair", name: "Same URL with and without a trailing slash",
                         predicate: """
                EXISTS (SELECT 1 FROM urls u2 WHERE u2.is_internal = 1 AND u2.id != u.id
                        AND u2.url = CASE WHEN u.url LIKE '%/' THEN substr(u.url, 1, length(u.url) - 1)
                                          ELSE u.url || '/' END)
                """, severity: .hygiene),
        ])

    /// Keyed on the URL being linked *to*, so a row answers "how is this page
    /// described by the pages that link to it" — which is the question anchor
    /// text is actually asked.
    public static let anchorText = Report(
        id: "anchorText", name: "Anchor Text",
        predicate: "u.id IN (SELECT to_url_id FROM links)",
        columns: [Col.address, Col.inlinks, Col.distinctAnchors, Col.topAnchor, Col.status],
        filters: [
            allFilter,
            ReportFilter(id: "empty", name: "Linked with no anchor text", predicate: """
                EXISTS (SELECT 1 FROM links l WHERE l.to_url_id = u.id
                        AND (l.anchor_text IS NULL OR trim(l.anchor_text) = ''))
                """, severity: .hygiene),
            // Anchors that describe nothing. Cheap to spot and worth fixing,
            // because they waste the strongest on-page relevance signal a link has.
            ReportFilter(id: "generic", name: "Generic anchor text", predicate: """
                EXISTS (SELECT 1 FROM links l WHERE l.to_url_id = u.id
                        AND trim(lower(coalesce(l.anchor_text, ''))) IN
                          ('click here','here','read more','more','link','this','learn more',
                           'find out more','continue','details','go','download','click'))
                """, severity: .hygiene),
            ReportFilter(id: "inconsistent", name: "Five or more different anchors", predicate: """
                (SELECT count(DISTINCT trim(lower(coalesce(l.anchor_text, ''))))
                 FROM links l WHERE l.to_url_id = u.id) >= 5
                """, severity: .hygiene),
        ])

    /// How a page presents itself when it is shared. Every field here is markup
    /// the crawler already fetched and, until now, threw away.
    public static let social = Report(
        id: "social", name: "Social",
        predicate: htmlPage,
        columns: [Col.address, Col.ogTitle, Col.ogImage, Col.ogType,
                  Col.twitterCard, Col.amphtml, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "noOG", name: "No Open Graph tags", predicate: """
                f.og_title IS NULL AND f.og_description IS NULL AND f.og_image IS NULL
                """, severity: .hygiene),
            ReportFilter(id: "noOGImage", name: "No og:image",
                         predicate: missing("og_image"), severity: .hygiene),
            // A share card with no title falls back to whatever the network
            // scrapes, which is rarely what anyone intended.
            ReportFilter(id: "noOGTitle", name: "No og:title",
                         predicate: missing("og_title"), severity: .hygiene),
            ReportFilter(id: "noTwitterCard", name: "No twitter:card",
                         predicate: missing("twitter_card"), severity: .hygiene),
            ReportFilter(id: "ogTitleDiffers", name: "og:title differs from title", predicate: """
                f.og_title IS NOT NULL AND f.title IS NOT NULL AND trim(f.og_title) != trim(f.title)
                """),
            ReportFilter(id: "hasAMP", name: "Has an AMP version",
                         predicate: "f.amphtml IS NOT NULL AND trim(f.amphtml) != ''"),
        ])

    /// Which pages carry which schema types. Deliberately types only: validating
    /// a payload against schema.org is a much larger feature than finding out
    /// which pages have markup at all.
    public static let structuredData = Report(
        id: "structuredData", name: "Structured Data",
        predicate: htmlPage,
        columns: [Col.address, Col.schemaFormats, Col.schemaTypes, Col.title, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "none", name: "No structured data", predicate: """
                NOT EXISTS (SELECT 1 FROM structured_data sd WHERE sd.url_id = u.id)
                """, severity: .hygiene),
            ReportFilter(id: "jsonLD", name: "JSON-LD", predicate: """
                EXISTS (SELECT 1 FROM structured_data sd
                        WHERE sd.url_id = u.id AND sd.format = 'json-ld')
                """),
            ReportFilter(id: "microdata", name: "Microdata", predicate: """
                EXISTS (SELECT 1 FROM structured_data sd
                        WHERE sd.url_id = u.id AND sd.format = 'microdata')
                """),
            ReportFilter(id: "rdfa", name: "RDFa", predicate: """
                EXISTS (SELECT 1 FROM structured_data sd
                        WHERE sd.url_id = u.id AND sd.format = 'rdfa')
                """),
            // Mixing formats is usually two plugins disagreeing rather than a
            // deliberate choice, and it is how contradictory markup ships.
            ReportFilter(id: "mixedFormats", name: "More than one format", predicate: """
                (SELECT count(DISTINCT sd.format) FROM structured_data sd
                 WHERE sd.url_id = u.id) > 1
                """, severity: .hygiene),
        ])

    public static let pagination = Report(
        id: "pagination", name: "Pagination",
        predicate: "\(htmlPage) AND (f.rel_prev IS NOT NULL OR f.rel_next IS NOT NULL)",
        columns: [Col.address, Col.relPrev, Col.relNext, Col.canonical, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "firstPage", name: "First page (next only)",
                         predicate: "f.rel_prev IS NULL AND f.rel_next IS NOT NULL"),
            ReportFilter(id: "lastPage", name: "Last page (prev only)",
                         predicate: "f.rel_next IS NULL AND f.rel_prev IS NOT NULL"),
            // A paginated page that canonicalises to page one removes itself,
            // and everything only reachable through it, from the index.
            ReportFilter(id: "canonicalised", name: "Canonicalised away", predicate: """
                f.canonical_id IS NOT NULL AND f.canonical_id != u.id
                """, severity: .hygiene),
            ReportFilter(id: "noindexed", name: "Paginated and noindexed",
                         predicate: directive("noindex"), severity: .hygiene),
        ])

    /// Response headers, stored wholesale so a new check is a filter rather than
    /// a migration. Matching is on the JSON blob, which is why each predicate
    /// looks for the header name rather than parsing it.
    public static let security = Report(
        id: "security", name: "Security",
        predicate: "u.is_internal = 1 AND r.status IS NOT NULL AND \(pageRows)",
        columns: [Col.address, Col.status, Col.scheme, Col.contentType,
                  Col.setCookie, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "noHSTS", name: "No HSTS",
                         predicate: missingHeader("strict-transport-security"), severity: .hygiene),
            ReportFilter(id: "noCSP", name: "No Content-Security-Policy",
                         predicate: missingHeader("content-security-policy"), severity: .hygiene),
            ReportFilter(id: "noNosniff", name: "No X-Content-Type-Options",
                         predicate: missingHeader("x-content-type-options"), severity: .hygiene),
            ReportFilter(id: "noFrameOptions", name: "No X-Frame-Options",
                         predicate: missingHeader("x-frame-options"), severity: .hygiene),
            ReportFilter(id: "noReferrerPolicy", name: "No Referrer-Policy",
                         predicate: missingHeader("referrer-policy"), severity: .hygiene),
            ReportFilter(id: "insecure", name: "Served over HTTP",
                         predicate: "u.url NOT LIKE 'https://%'", severity: .hygiene),
            // Cookie flags, read from the stored headers.
            //
            // A caveat worth knowing: URLSession collapses repeated Set-Cookie
            // headers into one comma-joined value, so a response setting three
            // cookies arrives as one string. These filters therefore answer "is
            // any cookie missing this flag", which is the useful question, but
            // cannot say which one.
            ReportFilter(id: "setsCookies", name: "Sets cookies",
                         predicate: "json_extract(r.headers_json, '$.\"Set-Cookie\"') IS NOT NULL"),
            ReportFilter(id: "cookieNoSecure", name: "Cookie without Secure", predicate: """
                json_extract(r.headers_json, '$."Set-Cookie"') IS NOT NULL
                AND lower(json_extract(r.headers_json, '$."Set-Cookie"')) NOT LIKE '%secure%'
                """, severity: .hygiene),
            ReportFilter(id: "cookieNoHttpOnly", name: "Cookie without HttpOnly", predicate: """
                json_extract(r.headers_json, '$."Set-Cookie"') IS NOT NULL
                AND lower(json_extract(r.headers_json, '$."Set-Cookie"')) NOT LIKE '%httponly%'
                """, severity: .hygiene),
            ReportFilter(id: "cookieNoSameSite", name: "Cookie without SameSite", predicate: """
                json_extract(r.headers_json, '$."Set-Cookie"') IS NOT NULL
                AND lower(json_extract(r.headers_json, '$."Set-Cookie"')) NOT LIKE '%samesite%'
                """, severity: .hygiene),
        ])

    /// Whatever the crawl was configured to pull out of each page.
    ///
    /// Empty until extraction rules are set, and deliberately still a tab in
    /// that state: an empty Extraction tab is how someone discovers the feature
    /// exists, where a hidden one is not.
    public static let extraction = Report(
        id: "extraction", name: "Extraction",
        predicate: htmlPage,
        columns: [Col.address, Col.extractionCount, Col.extractedNames,
                  Col.extractedValues, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "extracted", name: "Something was extracted", predicate: """
                EXISTS (SELECT 1 FROM extractions e WHERE e.url_id = u.id)
                """),
            // With rules configured, a page matching none of them is usually a
            // template that changed, which is exactly what you want to find.
            ReportFilter(id: "none", name: "Nothing matched", predicate: """
                NOT EXISTS (SELECT 1 FROM extractions e WHERE e.url_id = u.id)
                """, severity: .hygiene),
        ])

    /// What the sitemap claims against what the crawl found.
    ///
    /// This is the tab that makes orphan detection possible at all. A crawl on
    /// its own cannot find an orphan — every URL it discovers has an inlink by
    /// definition. A sitemap is an external list of URLs the site says exist, so
    /// "declared in the sitemap and linked from nowhere" is a real orphan rather
    /// than the "one inlink only" approximation Page Depth has to settle for.
    public static let sitemap = Report(
        id: "sitemap", name: "Sitemap",
        predicate: "u.is_internal = 1 AND (u.in_sitemap = 1 OR r.status IS NOT NULL) AND \(pageRows)",
        columns: [Col.address, Col.inSitemap, Col.status, Col.indexability,
                  Col.inlinks, Col.depth, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "inSitemap", name: "In the sitemap", predicate: "u.in_sitemap = 1"),
            // The page the crawl started from is never an orphan, however few
            // pages link to it — it is the entry point by definition. Without
            // this a homepage that nothing links back to is reported as
            // unreachable, which is the opposite of true.
            ReportFilter(id: "orphans", name: "Orphans: in the sitemap, linked from nowhere",
                         predicate: """
                u.in_sitemap = 1
                AND NOT EXISTS (SELECT 1 FROM links l WHERE l.to_url_id = u.id)
                AND u.url != coalesce((SELECT seed_url FROM crawl_meta WHERE id = 1), '')
                """, severity: .breaksIndexing),
            ReportFilter(id: "notInSitemap", name: "Crawled but not in the sitemap", predicate: """
                u.in_sitemap = 0 AND r.status = 200
                AND coalesce(r.content_type, '') LIKE 'text/html%'
                """, severity: .hygiene),
            // A sitemap is a list of URLs the site wants indexed, so a
            // non-indexable one in it is the site contradicting itself.
            ReportFilter(id: "nonIndexable", name: "In the sitemap but non-indexable",
                         predicate: "u.in_sitemap = 1 AND (\(Indexability.isNonIndexable))",
                         severity: .breaksIndexing),
            ReportFilter(id: "uncrawled", name: "In the sitemap but never reached",
                         predicate: "u.in_sitemap = 1 AND r.status IS NULL", severity: .breaksIndexing),
        ])

    /// Stylesheets and scripts, keyed on the resource URL — the same shape the
    /// Images tab uses, for the same reason: the question is "is this file
    /// broken", not "which page mentioned it".
    ///
    /// Empty unless `checkResources` is on, since a resource that was never
    /// fetched has no status to report.
    public static let resources = Report(
        id: "resources", name: "Resources",
        predicate: "u.id IN (SELECT src_url_id FROM resources)",
        columns: [Col.address, Col.resourceKind, Col.status, Col.contentType,
                  Col.size, Col.usedOnPages],
        filters: [
            allFilter,
            ReportFilter(id: "css", name: "Stylesheets", predicate: """
                EXISTS (SELECT 1 FROM resources res WHERE res.src_url_id = u.id AND res.kind = 'css')
                """),
            ReportFilter(id: "js", name: "Scripts", predicate: """
                EXISTS (SELECT 1 FROM resources res WHERE res.src_url_id = u.id AND res.kind = 'js')
                """),
            ReportFilter(id: "broken", name: "Broken",
                         predicate: "r.status = 0 OR r.status >= 400", severity: .breaksIndexing),
            ReportFilter(id: "over100kb", name: "Over 100KB",
                         predicate: "r.content_length > 102400", severity: .hygiene),
            ReportFilter(id: "insecure", name: "Loaded over HTTP",
                         predicate: "u.url NOT LIKE 'https://%'", severity: .hygiene),
        ])

    /// What rendering changed, and what it cost.
    ///
    /// Empty unless `renderJavaScript` is on. The column worth looking at is the
    /// gap between rendered and static word counts: it answers the only question
    /// that matters here, which is whether this site needs rendering or whether
    /// rendering it is merely expensive.
    public static let javascript = Report(
        id: "javascript", name: "JavaScript",
        predicate: "u.is_internal = 1 AND r.status IS NOT NULL AND \(pageRows)",
        columns: [Col.address, Col.renderedFlag, Col.renderMs, Col.staticWords,
                  Col.renderedWords, Col.jsErrors, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "rendered", name: "Rendered", predicate: "r.rendered = 1"),
            ReportFilter(id: "errors", name: "JavaScript errors",
                         predicate: "r.js_errors IS NOT NULL AND trim(r.js_errors) != ''",
                         severity: .hygiene),
            // A page whose content only exists after scripts run is invisible to
            // any crawler that does not render — including, historically, this one.
            ReportFilter(id: "contentNeedsJS", name: "Content only appears after rendering",
                         predicate: """
                r.rendered = 1 AND r.rendered_words > coalesce(r.static_words, 0) * 2
                AND r.rendered_words > 50
                """, severity: .breaksIndexing),
            ReportFilter(id: "emptyWithoutJS", name: "Nothing at all without JavaScript",
                         predicate: "r.rendered = 1 AND coalesce(r.static_words, 0) < 10",
                         severity: .breaksIndexing),
            ReportFilter(id: "slow", name: "Slow to render (over 3s)",
                         predicate: "r.render_ms > 3000", severity: .hygiene),
            ReportFilter(id: "notRendered", name: "Not rendered",
                         predicate: "r.rendered = 0"),
        ])

    /// What the browser observed while loading each page.
    ///
    /// Empty unless rendering is on, since these come from the browser's own
    /// performance timeline. Deliberately not "Core Web Vitals": WebKit's
    /// `supportedEntryTypes` has no `layout-shift`, so CLS cannot be measured
    /// here at all, and INP needs a real interaction a crawler never makes.
    /// Calling four of the six metrics Core Web Vitals would imply the other two
    /// passed.
    public static let performance = Report(
        id: "performance", name: "Performance",
        predicate: "u.is_internal = 1 AND r.rendered = 1 AND \(pageRows)",
        columns: [Col.address, Col.ttfb, Col.fcp, Col.lcp, Col.loadMs,
                  Col.subresources, Col.renderMs, Col.title],
        filters: [
            allFilter,
            // Google's own "needs improvement" boundary for LCP is 2.5s. This is
            // a rendered measurement on one machine with a warm cache, not a
            // field metric, so treat it as a smell rather than a verdict.
            ReportFilter(id: "slowLCP", name: "LCP over 2.5s",
                         predicate: "r.perf_lcp_ms > 2500", severity: .costsClicks),
            ReportFilter(id: "slowTTFB", name: "TTFB over 800ms",
                         predicate: "r.perf_ttfb_ms > 800", severity: .costsClicks),
            ReportFilter(id: "slowLoad", name: "Load over 3s",
                         predicate: "r.perf_load_ms > 3000", severity: .costsClicks),
            ReportFilter(id: "manyRequests", name: "Over 50 subresources",
                         predicate: "r.perf_resources > 50", severity: .hygiene),
            ReportFilter(id: "noMetrics", name: "No timings reported",
                         predicate: "r.perf_ttfb_ms IS NULL AND r.perf_fcp_ms IS NULL"),
        ])

    /// URLs the crawl recorded but never fetched, and why.
    ///
    /// The reason is written at the moment the decision is made rather than
    /// inferred afterwards: before this, a row said "skipped" and nothing said
    /// why, so a crawl that quietly stopped short — a URL cap hit, a filter too
    /// broad, a depth limit — looked exactly like one that had finished.
    public static let crawlability = Report(
        id: "crawlability", name: "Crawlability",
        predicate: "u.state = 3 AND u.check_only = 0",
        columns: [Col.address, Col.skipReason, Col.depth, Col.inlinks, Col.inSitemap],
        filters: [
            allFilter,
            ReportFilter(id: "robots", name: "Blocked by robots.txt",
                         predicate: "u.skip_reason = 'blocked by robots.txt'", severity: .breaksIndexing),
            ReportFilter(id: "filters", name: "Excluded by URL filters",
                         predicate: "u.skip_reason = 'excluded by URL filters'"),
            ReportFilter(id: "depth", name: "Beyond max depth",
                         predicate: "u.skip_reason = 'beyond max depth'"),
            ReportFilter(id: "cap", name: "URL cap reached",
                         predicate: "u.skip_reason = 'URL cap reached'", severity: .breaksIndexing),
            ReportFilter(id: "redirects", name: "Redirect chain too long",
                         predicate: "u.skip_reason = 'redirect chain too long'", severity: .breaksIndexing),
            // A URL the sitemap declares that the crawl then refused to fetch is
            // the site contradicting itself twice over.
            ReportFilter(id: "sitemapBlocked", name: "In the sitemap but not crawlable",
                         predicate: "u.in_sitemap = 1", severity: .breaksIndexing),
        ])

    /// How each page would appear as a search result.
    ///
    /// Widths are measured with a font engine rather than estimated from
    /// character counts, because width is what gets truncated and characters are
    /// a poor proxy for it. The thresholds are observed conventions that Google
    /// changes without notice — a guide, not a contract.
    public static let serp = Report(
        id: "serp", name: "SERP",
        predicate: htmlPage,
        columns: [Col.address, Col.title, Col.titlePixels, Col.desc, Col.descPixels,
                  Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "titleTruncated", name: "Title would be truncated",
                         predicate: "f.title_pixels > \(Int(SERPMetrics.titleLimit))",
                         severity: .costsClicks),
            ReportFilter(id: "descTruncated", name: "Description would be truncated",
                         predicate: "f.meta_description_pixels > \(Int(SERPMetrics.descriptionLimit))",
                         severity: .costsClicks),
            // Under half the available width is a wasted snippet: there was room
            // to say more and the page did not.
            ReportFilter(id: "titleShort", name: "Title uses under half the width",
                         predicate: "f.title_pixels IS NOT NULL AND f.title_pixels < \(Int(SERPMetrics.titleLimit / 2))",
                         severity: .costsClicks),
            ReportFilter(id: "noSnippet", name: "Nothing to show in a snippet",
                         predicate: "(\(missing("title"))) OR (\(missing("meta_description")))",
                         severity: .costsClicks),
        ])

    /// Everything the crawl could not know on its own.
    ///
    /// Empty until a provider has been run. The filters that matter are the
    /// comparisons — a page with impressions and no crawl problems is working; a
    /// page with traffic that the crawl found non-indexable is losing it.
    public static let externalData = Report(
        // Not "external": the External links tab already owns that id, and two
        // reports sharing one collide in the counts dictionary, which is keyed
        // "reportID.filterID". Caught by everyReportIDAndFilterIDIsUnique.
        id: "externalData", name: "External Data",
        predicate: htmlPage,
        columns: [Col.address,
                  Col.metric(.searchConsole, "Clicks", header: "Clicks", width: 70),
                  Col.metric(.searchConsole, "Impressions", header: "Impressions", width: 95),
                  Col.metric(.searchConsole, "Position", header: "Position", width: 80),
                  Col.metric(.analytics, "Sessions", header: "Sessions", width: 80),
                  Col.metric(.pageSpeed, "CWV Assessment", header: "CWV", width: 110),
                  Col.metric(.pageSpeed, "Lighthouse Performance", header: "Perf", width: 65),
                  Col.metric(.ahrefs, "Referring domains", header: "Ref Domains", width: 100),
                  Col.metric(.moz, "Domain authority", header: "DA", width: 55),
                  Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "enriched", name: "Has external data", predicate: """
                EXISTS (SELECT 1 FROM external_metrics m WHERE m.url_id = u.id)
                """),
            ReportFilter(id: "notEnriched", name: "No external data yet", predicate: """
                NOT EXISTS (SELECT 1 FROM external_metrics m WHERE m.url_id = u.id)
                """),

            // The comparisons. These are the point: a crawl finding on its own
            // is a guess about what matters, and traffic tells you which guesses
            // were right.
            ReportFilter(id: "trafficButNonIndexable",
                         name: "Getting clicks but non-indexable", predicate: """
                \(Col.metricValue(.searchConsole, "Clicks")) > 0
                AND (\(Indexability.isNonIndexable))
                """, severity: .breaksIndexing),
            ReportFilter(id: "impressionsNoClicks",
                         name: "Impressions but no clicks", predicate: """
                \(Col.metricValue(.searchConsole, "Impressions")) > 100
                AND coalesce(\(Col.metricValue(.searchConsole, "Clicks")), 0) = 0
                """, severity: .costsClicks),
            ReportFilter(id: "strikingDistance",
                         name: "Ranking just off page one", predicate: """
                \(Col.metricValue(.searchConsole, "Position")) BETWEEN 11 AND 20
                """),
            ReportFilter(id: "noTraffic",
                         name: "Indexable but no clicks at all", predicate: """
                \(Col.hasMetrics(.searchConsole))
                AND coalesce(\(Col.metricValue(.searchConsole, "Clicks")), 0) = 0
                AND NOT (\(Indexability.isNonIndexable))
                """, severity: .costsClicks),
            ReportFilter(id: "sessionsButThin",
                         name: "Has sessions but under 200 words", predicate: """
                \(Col.metricValue(.analytics, "Sessions")) > 0
                AND coalesce(f.word_count, 0) < 200
                """, severity: .costsClicks),
            ReportFilter(id: "cwvFailing", name: "Fails Core Web Vitals", predicate: """
                (SELECT m.text FROM external_metrics m
                 WHERE m.url_id = u.id AND m.source = 'pagespeed'
                   AND m.metric = 'CWV Assessment') = 'SLOW'
                """, severity: .costsClicks),
            ReportFilter(id: "slowLighthouse", name: "Lighthouse performance under 50",
                         predicate: "\(Col.metricValue(.pageSpeed, "Lighthouse Performance")) < 50",
                         severity: .costsClicks),
        ])

    public static let pageDepth = Report(
        id: "pageDepth", name: "Page Depth",
        predicate: "u.is_internal = 1 AND r.status IS NOT NULL AND \(pageRows)",
        columns: [Col.address, Col.depth, Col.inlinks, Col.status, Col.title, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "deep", name: "Deeper than 3", predicate: "u.depth > 3", severity: .hygiene),
            // The closest honest signal to an orphan a crawl-only tool can give:
            // every discovered URL has an inlink by definition, so "only one" is
            // the weakest internal linking a crawl can actually observe.
            ReportFilter(id: "singleInlink", name: "One inlink only", predicate: """
                (SELECT count(DISTINCT from_url_id) FROM links WHERE to_url_id = u.id) = 1
                """, severity: .hygiene),
        ])
}
