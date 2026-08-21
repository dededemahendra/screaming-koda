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

    static func directive(_ token: String) -> String {
        "lower(coalesce(f.meta_robots, '') || ' ' || coalesce(f.x_robots_tag, '')) LIKE '%\(token)%'"
    }

    // MARK: - Shared columns

    enum Col {
        static let address = ReportColumn(id: "address", header: "Address",
                                          expression: "u.url", width: 340)
        static let status = ReportColumn(id: "status", header: "Status",
                                         expression: "r.status", width: 60, alignment: .trailing)
        static let contentType = ReportColumn(id: "contentType", header: "Content Type",
                                              expression: "r.content_type", width: 150)
        static let indexability = ReportColumn(id: "indexability", header: "Indexability",
                                               expression: Indexability.expression, width: 190)
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
    }

    static let allFilter = ReportFilter(id: "all", name: "All", predicate: "1")

    // MARK: - The eleven

    public static let all: [Report] = [
        internalURLs, external, responseCodes, titles, metaDescription, headings,
        images, canonicals, directives, hreflang, pageDepth,
    ]

    public static let internalURLs = Report(
        id: "internal", name: "Internal",
        predicate: "u.is_internal = 1 AND \(pageRows)",
        columns: [Col.address, Col.status, Col.contentType, Col.indexability,
                  Col.title, Col.titleLength, Col.h1, Col.wordCount, Col.depth,
                  Col.inlinks, Col.responseTime],
        filters: [
            allFilter,
            ReportFilter(id: "nonIndexable", name: "Non-indexable",
                         predicate: Indexability.isNonIndexable, isIssue: true),
        ])

    public static let external = Report(
        id: "external", name: "External",
        predicate: "u.is_internal = 0",
        columns: [Col.address, Col.status, Col.contentType, Col.inlinks, Col.responseTime],
        filters: [
            allFilter,
            ReportFilter(id: "broken", name: "Broken",
                         predicate: "r.status = 0 OR r.status >= 400", isIssue: true),
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
                         predicate: "r.status BETWEEN 400 AND 499", isIssue: true),
            ReportFilter(id: "serverError", name: "Server error (5xx)",
                         predicate: "r.status >= 500", isIssue: true),
            ReportFilter(id: "transportError", name: "No response",
                         predicate: "r.status = 0", isIssue: true),
            // The row is the *destination*, not the chain: "you reached this URL
            // through two or more redirects, so the links pointing at it are stale."
            ReportFilter(id: "viaChain", name: "Reached via 2+ redirects",
                         predicate: "u.redirect_hops >= 2", isIssue: true),
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
                """, isIssue: true),
        ])

    public static let titles = Report(
        id: "titles", name: "Titles",
        predicate: htmlPage,
        columns: [Col.address, Col.title, Col.titleLength, Col.titleCount,
                  Col.h1, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "missing", name: "Missing", predicate: missing("title"), isIssue: true),
            ReportFilter(id: "duplicate", name: "Duplicate",
                         predicate: duplicated("title"), isIssue: true),
            ReportFilter(id: "over60", name: "Over 60 characters",
                         predicate: "f.title_length > 60", isIssue: true),
            ReportFilter(id: "under30", name: "Under 30 characters",
                         predicate: "f.title_length IS NOT NULL AND f.title_length < 30", isIssue: true),
            ReportFilter(id: "multiple", name: "Multiple", predicate: "f.title_count > 1", isIssue: true),
            ReportFilter(id: "sameAsH1", name: "Same as H1", predicate: """
                f.title IS NOT NULL AND f.h1 IS NOT NULL AND trim(f.title) = trim(f.h1)
                """, isIssue: true),
        ])

    public static let metaDescription = Report(
        id: "metaDescription", name: "Meta Description",
        predicate: htmlPage,
        columns: [Col.address, Col.desc, Col.descLength, Col.descCount, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "missing", name: "Missing",
                         predicate: missing("meta_description"), isIssue: true),
            ReportFilter(id: "duplicate", name: "Duplicate",
                         predicate: duplicated("meta_description"), isIssue: true),
            ReportFilter(id: "over155", name: "Over 155 characters",
                         predicate: "f.meta_description_length > 155", isIssue: true),
            ReportFilter(id: "under70", name: "Under 70 characters", predicate: """
                f.meta_description_length IS NOT NULL AND f.meta_description_length < 70
                """, isIssue: true),
            ReportFilter(id: "multiple", name: "Multiple",
                         predicate: "f.meta_description_count > 1", isIssue: true),
        ])

    public static let headings = Report(
        id: "headings", name: "Headings",
        predicate: htmlPage,
        columns: [Col.address, Col.h1, Col.h1Length, Col.h1Count, Col.h2Count, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "missingH1", name: "Missing H1", predicate: missing("h1"), isIssue: true),
            ReportFilter(id: "duplicateH1", name: "Duplicate H1",
                         predicate: duplicated("h1"), isIssue: true),
            ReportFilter(id: "multipleH1", name: "Multiple H1",
                         predicate: "f.h1_count > 1", isIssue: true),
            ReportFilter(id: "longH1", name: "H1 over 70 characters",
                         predicate: "length(f.h1) > 70", isIssue: true),
            ReportFilter(id: "missingH2", name: "Missing H2",
                         predicate: "coalesce(f.h2_count, 0) = 0", isIssue: true),
        ])

    public static let images = Report(
        id: "images", name: "Images",
        predicate: "u.id IN (SELECT src_url_id FROM images)",
        columns: [Col.address, Col.status, Col.contentType, Col.size,
                  Col.referencedBy, Col.noAltOn],
        filters: [
            allFilter,
            ReportFilter(id: "missingAlt", name: "Missing alt text", predicate: """
                EXISTS (SELECT 1 FROM images i
                        WHERE i.src_url_id = u.id AND (i.alt IS NULL OR trim(i.alt) = ''))
                """, isIssue: true),
            ReportFilter(id: "longAlt", name: "Alt over 100 characters", predicate: """
                EXISTS (SELECT 1 FROM images i WHERE i.src_url_id = u.id AND length(i.alt) > 100)
                """, isIssue: true),
            ReportFilter(id: "over100kb", name: "Over 100KB",
                         predicate: "r.content_length > 102400", isIssue: true),
        ])

    public static let canonicals = Report(
        id: "canonicals", name: "Canonicals",
        predicate: htmlPage,
        columns: [Col.address, Col.canonical, Col.indexability, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "missing", name: "Missing",
                         predicate: "f.canonical_id IS NULL", isIssue: true),
            ReportFilter(id: "self", name: "Self-referencing",
                         predicate: "f.canonical_id = u.id"),
            ReportFilter(id: "canonicalised", name: "Canonicalised",
                         predicate: "f.canonical_id IS NOT NULL AND f.canonical_id != u.id",
                         isIssue: true),
            ReportFilter(id: "toNon200", name: "To a non-200", predicate: """
                f.canonical_id IS NOT NULL AND f.canonical_id != u.id AND EXISTS (
                  SELECT 1 FROM responses cr WHERE cr.url_id = f.canonical_id AND cr.status != 200
                )
                """, isIssue: true),
        ])

    public static let directives = Report(
        id: "directives", name: "Directives",
        predicate: htmlPage,
        columns: [Col.address, Col.metaRobots, Col.xRobots, Col.indexability, Col.title],
        filters: [
            allFilter,
            ReportFilter(id: "noindex", name: "noindex",
                         predicate: directive("noindex"), isIssue: true),
            ReportFilter(id: "nofollow", name: "nofollow",
                         predicate: directive("nofollow"), isIssue: true),
            ReportFilter(id: "noarchive", name: "noarchive",
                         predicate: directive("noarchive"), isIssue: true),
            // Both present and disagreeing about indexing. Google takes the most
            // restrictive, so the page is non-indexable and the markup says
            // otherwise — which is how these ship unnoticed.
            ReportFilter(id: "conflict", name: "X-Robots conflict", predicate: """
                f.meta_robots IS NOT NULL AND f.x_robots_tag IS NOT NULL
                AND (lower(f.meta_robots) LIKE '%noindex%') != (lower(f.x_robots_tag) LIKE '%noindex%')
                """, isIssue: true),
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
                """, isIssue: true),
            ReportFilter(id: "non200", name: "Non-200 target", predicate: """
                EXISTS (
                  SELECT 1 FROM hreflang h
                  LEFT JOIN responses hr ON hr.url_id = h.href_url_id
                  WHERE h.url_id = u.id AND (hr.status IS NULL OR hr.status != 200)
                )
                """, isIssue: true),
            ReportFilter(id: "noXDefault", name: "Missing x-default", predicate: """
                NOT EXISTS (
                  SELECT 1 FROM hreflang h WHERE h.url_id = u.id AND lower(h.lang) = 'x-default'
                )
                """, isIssue: true),
        ])

    public static let pageDepth = Report(
        id: "pageDepth", name: "Page Depth",
        predicate: "u.is_internal = 1 AND r.status IS NOT NULL AND \(pageRows)",
        columns: [Col.address, Col.depth, Col.inlinks, Col.status, Col.title, Col.indexability],
        filters: [
            allFilter,
            ReportFilter(id: "deep", name: "Deeper than 3", predicate: "u.depth > 3", isIssue: true),
            // The closest honest signal to an orphan a crawl-only tool can give:
            // every discovered URL has an inlink by definition, so "only one" is
            // the weakest internal linking a crawl can actually observe.
            ReportFilter(id: "singleInlink", name: "One inlink only", predicate: """
                (SELECT count(DISTINCT from_url_id) FROM links WHERE to_url_id = u.id) = 1
                """, isIssue: true),
        ])
}
