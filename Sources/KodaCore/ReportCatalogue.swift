import Foundation

/// Every report the tool can run. There is no `issues` table: each entry is a
/// query over `urls`, `responses`, `page_facts`, `links`, `images` and
/// `hreflang`, so changing a rule takes effect on an existing crawl immediately.
///
/// Content rules are restricted to `status = 200`. A missing title on a 404 is
/// not a finding, and letting error pages into these reports is the fastest way
/// to make the whole set untrustworthy.
public enum ReportCatalogue {
    public static func report(id: String) -> ReportDefinition? {
        all.first { $0.id == id }
    }

    /// Group names in presentation order, deduplicated.
    public static var groups: [String] {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    public static func reports(in group: String) -> [ReportDefinition] {
        all.filter { $0.group == group }
    }

    /// Reports that represent something to fix, as opposed to an inventory of
    /// what the crawl found.
    public static var issues: [ReportDefinition] {
        all.filter { $0.kind == .issue }
    }

    public static let all: [ReportDefinition] = [

        // MARK: - Internal

        ReportDefinition(
            id: "internal-all",
            group: "Internal",
            name: "All",
            kind: .inventory,
            summary: "Every crawled URL on the seed host.",
            columns: ["URL", "Status", "Type", "Title", "Words", "Depth", "Time (ms)"],
            sql: """
                SELECT u.url AS "URL", r.status AS "Status", r.content_type AS "Type",
                       f.title AS "Title", f.word_count AS "Words", u.depth AS "Depth",
                       r.response_time_ms AS "Time (ms)"
                FROM urls u
                JOIN responses r ON r.url_id = u.id
                LEFT JOIN page_facts f ON f.url_id = u.id
                WHERE u.is_internal = 1
                ORDER BY u.depth, u.url
                """
        ),

        ReportDefinition(
            id: "internal-duplicate-content",
            group: "Internal",
            name: "Duplicate content",
            summary: "Pages whose visible text is byte-identical to another page's.",
            columns: ["URL", "Title", "Words"],
            sql: """
                SELECT u.url AS "URL", f.title AS "Title", f.word_count AS "Words"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND f.content_hash IS NOT NULL
                  AND f.content_hash IN (
                    SELECT content_hash FROM page_facts
                    WHERE content_hash IS NOT NULL GROUP BY content_hash HAVING count(*) > 1
                  )
                ORDER BY f.content_hash, u.url
                """
        ),

        // MARK: - External

        ReportDefinition(
            id: "external-all",
            group: "External",
            name: "All",
            kind: .inventory,
            summary: "Every URL discovered on another host. Status only, never parsed.",
            columns: ["URL", "Host", "Status", "Linked from"],
            sql: """
                SELECT u.url AS "URL", u.host AS "Host", r.status AS "Status",
                       count(DISTINCT l.from_url_id) AS "Linked from"
                FROM urls u
                LEFT JOIN responses r ON r.url_id = u.id
                LEFT JOIN links l ON l.to_url_id = u.id
                WHERE u.is_internal = 0
                GROUP BY u.id
                ORDER BY u.host, u.url
                """
        ),

        // MARK: - Response Codes

        statusClassReport(id: "response-2xx", name: "2xx Success", low: 200, high: 299, kind: .inventory),
        statusClassReport(id: "response-3xx", name: "3xx Redirection", low: 300, high: 399),
        statusClassReport(id: "response-4xx", name: "4xx Client error", low: 400, high: 499),
        statusClassReport(id: "response-5xx", name: "5xx Server error", low: 500, high: 599),

        ReportDefinition(
            id: "response-errors",
            group: "Response Codes",
            name: "Transport errors",
            summary: "URLs that never produced an HTTP response: DNS, TLS, timeout, refused.",
            columns: ["URL", "Error"],
            sql: """
                SELECT u.url AS "URL", r.error_kind AS "Error"
                FROM responses r JOIN urls u ON u.id = r.url_id
                WHERE r.status = 0
                ORDER BY u.url
                """
        ),

        ReportDefinition(
            id: "response-redirect-chains",
            group: "Response Codes",
            name: "Redirect chains",
            summary: "Every redirect hop and where it points, with its position in the chain.",
            columns: ["URL", "Status", "Redirects to", "Hop"],
            sql: """
                SELECT u.url AS "URL", r.status AS "Status", t.url AS "Redirects to",
                       t.redirect_hops AS "Hop"
                FROM responses r
                JOIN urls u ON u.id = r.url_id
                JOIN urls t ON t.id = r.redirect_target_id
                ORDER BY t.redirect_hops, u.url
                """
        ),

        ReportDefinition(
            id: "response-redirect-loops",
            group: "Response Codes",
            name: "Redirect loops",
            summary: "URLs whose redirect chain arrives back at itself.",
            columns: ["URL", "Status"],
            sql: """
                WITH RECURSIVE chain(start_id, current_id, hops) AS (
                  SELECT r.url_id, r.redirect_target_id, 1
                  FROM responses r WHERE r.redirect_target_id IS NOT NULL
                  UNION ALL
                  SELECT c.start_id, r.redirect_target_id, c.hops + 1
                  FROM chain c
                  JOIN responses r ON r.url_id = c.current_id
                  WHERE r.redirect_target_id IS NOT NULL AND c.hops < 25
                )
                SELECT DISTINCT u.url AS "URL", r.status AS "Status"
                FROM chain c
                JOIN urls u ON u.id = c.start_id
                JOIN responses r ON r.url_id = c.start_id
                WHERE c.current_id = c.start_id
                ORDER BY u.url
                """
        ),

        ReportDefinition(
            id: "response-broken-links",
            group: "Response Codes",
            name: "Broken links",
            summary: "Links pointing at a 4xx, 5xx or transport error, with the page they sit on.",
            columns: ["From", "To", "Status", "Anchor text"],
            sql: """
                SELECT src.url AS "From", dst.url AS "To", r.status AS "Status",
                       l.anchor_text AS "Anchor text"
                FROM links l
                JOIN urls src ON src.id = l.from_url_id
                JOIN urls dst ON dst.id = l.to_url_id
                JOIN responses r ON r.url_id = dst.id
                WHERE r.status = 0 OR r.status >= 400
                ORDER BY src.url, dst.url
                """
        ),

        // MARK: - Titles

        pageReport(
            id: "titles-missing", group: "Titles", name: "Missing",
            summary: "200 pages with no title element, or an empty one.",
            where: "(f.title IS NULL OR f.title = '')"
        ),
        ReportDefinition(
            id: "titles-duplicate",
            group: "Titles",
            name: "Duplicate",
            summary: "Titles that appear on more than one page.",
            columns: ["URL", "Title", "Length"],
            sql: """
                SELECT u.url AS "URL", f.title AS "Title", f.title_length AS "Length"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND f.title IS NOT NULL AND f.title != ''
                  AND f.title IN (
                    SELECT title FROM page_facts
                    WHERE title IS NOT NULL AND title != '' GROUP BY title HAVING count(*) > 1
                  )
                ORDER BY f.title, u.url
                """
        ),
        titleLengthReport(id: "titles-over-60", name: "Over 60 characters", comparison: "> 60"),
        titleLengthReport(id: "titles-under-30", name: "Under 30 characters", comparison: "< 30"),
        pageReport(
            id: "titles-multiple", group: "Titles", name: "Multiple",
            summary: "Pages with more than one title element. Search engines pick one, unpredictably.",
            where: "f.title_count > 1"
        ),
        pageReport(
            id: "titles-same-as-h1", group: "Titles", name: "Same as H1",
            summary: "Title identical to the H1, which wastes one of the two strongest signals.",
            where: "f.title IS NOT NULL AND f.title != '' AND f.title = f.h1"
        ),

        // MARK: - Meta Description

        pageReport(
            id: "meta-missing", group: "Meta Description", name: "Missing",
            summary: "200 pages with no meta description.",
            where: "(f.meta_description IS NULL OR f.meta_description = '')"
        ),
        ReportDefinition(
            id: "meta-duplicate",
            group: "Meta Description",
            name: "Duplicate",
            summary: "Meta descriptions reused across pages.",
            columns: ["URL", "Meta description", "Length"],
            sql: """
                SELECT u.url AS "URL", f.meta_description AS "Meta description",
                       f.meta_description_length AS "Length"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND f.meta_description IS NOT NULL AND f.meta_description != ''
                  AND f.meta_description IN (
                    SELECT meta_description FROM page_facts
                    WHERE meta_description IS NOT NULL AND meta_description != ''
                    GROUP BY meta_description HAVING count(*) > 1
                  )
                ORDER BY f.meta_description, u.url
                """
        ),
        metaLengthReport(id: "meta-over-155", name: "Over 155 characters", comparison: "> 155"),
        metaLengthReport(id: "meta-under-70", name: "Under 70 characters", comparison: "< 70"),
        pageReport(
            id: "meta-multiple", group: "Meta Description", name: "Multiple",
            summary: "Pages declaring more than one meta description.",
            where: "f.meta_description_count > 1"
        ),

        // MARK: - Headings

        pageReport(
            id: "h1-missing", group: "Headings", name: "Missing H1",
            summary: "200 pages with no H1.",
            where: "(f.h1 IS NULL OR f.h1 = '')"
        ),
        ReportDefinition(
            id: "h1-duplicate",
            group: "Headings",
            name: "Duplicate H1",
            summary: "The same H1 text on more than one page.",
            columns: ["URL", "H1", "Length"],
            sql: """
                SELECT u.url AS "URL", f.h1 AS "H1", length(f.h1) AS "Length"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND f.h1 IS NOT NULL AND f.h1 != ''
                  AND f.h1 IN (
                    SELECT h1 FROM page_facts
                    WHERE h1 IS NOT NULL AND h1 != '' GROUP BY h1 HAVING count(*) > 1
                  )
                ORDER BY f.h1, u.url
                """
        ),
        pageReport(
            id: "h1-multiple", group: "Headings", name: "Multiple H1",
            summary: "Pages with more than one H1.",
            where: "f.h1_count > 1"
        ),
        ReportDefinition(
            id: "h1-over-70",
            group: "Headings",
            name: "H1 over 70 characters",
            summary: "H1s long enough to read as a paragraph rather than a heading.",
            columns: ["URL", "H1", "Length"],
            sql: """
                SELECT u.url AS "URL", f.h1 AS "H1", length(f.h1) AS "Length"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND f.h1 IS NOT NULL AND length(f.h1) > 70
                ORDER BY length(f.h1) DESC, u.url
                """
        ),
        pageReport(
            id: "h2-missing", group: "Headings", name: "Missing H2",
            summary: "200 pages with no H2 at all.",
            where: "f.h2_count = 0"
        ),

        // MARK: - Images

        ReportDefinition(
            id: "images-missing-alt",
            group: "Images",
            name: "Missing alt text",
            summary: "Image references with no alt attribute, or an empty one.",
            columns: ["Image", "On page"],
            sql: """
                SELECT src.url AS "Image", page.url AS "On page"
                FROM images i
                JOIN urls src ON src.id = i.src_url_id
                JOIN urls page ON page.id = i.url_id
                WHERE i.alt IS NULL OR i.alt = ''
                ORDER BY page.url, src.url
                """
        ),
        ReportDefinition(
            id: "images-alt-over-100",
            group: "Images",
            name: "Alt text over 100 characters",
            summary: "Alt text long enough that screen readers read it as prose.",
            columns: ["Image", "On page", "Alt", "Length"],
            sql: """
                SELECT src.url AS "Image", page.url AS "On page", i.alt AS "Alt",
                       length(i.alt) AS "Length"
                FROM images i
                JOIN urls src ON src.id = i.src_url_id
                JOIN urls page ON page.id = i.url_id
                WHERE i.alt IS NOT NULL AND length(i.alt) > 100
                ORDER BY length(i.alt) DESC
                """
        ),

        ReportDefinition(
            id: "images-over-100kb",
            group: "Images",
            name: "Over 100KB",
            summary: "Images large enough to hurt page load. Size comes from the HEAD status check.",
            columns: ["Image", "Bytes", "On pages"],
            sql: """
                SELECT src.url AS "Image", r.content_length AS "Bytes",
                       count(DISTINCT i.url_id) AS "On pages"
                FROM images i
                JOIN urls src ON src.id = i.src_url_id
                JOIN responses r ON r.url_id = src.id
                WHERE r.content_length > 102400
                GROUP BY src.id
                ORDER BY r.content_length DESC
                """
        ),

        ReportDefinition(
            id: "images-broken",
            group: "Images",
            name: "Broken",
            summary: "Image references that do not return 200.",
            columns: ["Image", "Status", "On page"],
            sql: """
                SELECT src.url AS "Image", r.status AS "Status", page.url AS "On page"
                FROM images i
                JOIN urls src ON src.id = i.src_url_id
                JOIN urls page ON page.id = i.url_id
                JOIN responses r ON r.url_id = src.id
                WHERE r.status = 0 OR r.status >= 400
                ORDER BY page.url, src.url
                """
        ),

        // MARK: - Canonicals

        pageReport(
            id: "canonical-missing", group: "Canonicals", name: "Missing",
            summary: "200 pages declaring no canonical.",
            where: "f.canonical_id IS NULL"
        ),
        pageReport(
            id: "canonical-self", group: "Canonicals", name: "Self-referencing", kind: .inventory,
            summary: "Pages whose canonical points at themselves. Usually correct.",
            where: "f.canonical_id = f.url_id"
        ),
        ReportDefinition(
            id: "canonical-canonicalised",
            group: "Canonicals",
            name: "Canonicalised",
            summary: "Pages pointing their canonical at a different URL, so they ask not to be indexed themselves.",
            columns: ["URL", "Canonical to"],
            sql: """
                SELECT u.url AS "URL", c.url AS "Canonical to"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN urls c ON c.id = f.canonical_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND f.canonical_id != f.url_id
                ORDER BY u.url
                """
        ),
        pageReport(
            id: "canonical-multiple", group: "Canonicals", name: "Multiple",
            summary: "Pages declaring more than one canonical, which search engines ignore entirely.",
            where: "f.canonical_count > 1"
        ),
        ReportDefinition(
            id: "canonical-non-200",
            group: "Canonicals",
            name: "To a non-200",
            summary: "Canonicals pointing at a URL that redirects, errors, or was never crawled.",
            columns: ["URL", "Canonical to", "Target status"],
            sql: """
                SELECT u.url AS "URL", c.url AS "Canonical to", cr.status AS "Target status"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN urls c ON c.id = f.canonical_id
                LEFT JOIN responses cr ON cr.url_id = c.id
                WHERE cr.status IS NULL OR cr.status != 200
                ORDER BY u.url
                """
        ),

        // MARK: - Directives

        directiveReport(id: "directives-noindex", name: "noindex", token: "noindex",
                        summary: "Pages asking not to be indexed, via meta robots or X-Robots-Tag."),
        directiveReport(id: "directives-nofollow", name: "nofollow", token: "nofollow",
                        summary: "Pages asking that their links not be followed."),
        directiveReport(id: "directives-noarchive", name: "noarchive", token: "noarchive",
                        summary: "Pages asking not to be cached."),

        ReportDefinition(
            id: "directives-conflict",
            group: "Directives",
            name: "X-Robots-Tag conflicts",
            summary: "The header and the meta tag disagree about noindex, so which one wins is not obvious.",
            columns: ["URL", "Meta robots", "X-Robots-Tag"],
            sql: """
                SELECT u.url AS "URL", f.meta_robots AS "Meta robots", f.x_robots_tag AS "X-Robots-Tag"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                WHERE (lower(coalesce(f.meta_robots, '')) LIKE '%noindex%')
                   != (lower(coalesce(f.x_robots_tag, '')) LIKE '%noindex%')
                  AND (f.meta_robots IS NOT NULL AND f.x_robots_tag IS NOT NULL)
                ORDER BY u.url
                """
        ),

        // MARK: - Hreflang

        ReportDefinition(
            id: "hreflang-missing-return",
            group: "Hreflang",
            name: "Missing return link",
            summary: "A page declares an alternate that does not declare it back. Google ignores one-way hreflang.",
            columns: ["URL", "Language", "Target"],
            sql: """
                SELECT src.url AS "URL", h.lang AS "Language", dst.url AS "Target"
                FROM hreflang h
                JOIN urls src ON src.id = h.url_id
                JOIN urls dst ON dst.id = h.href_url_id
                WHERE h.href_url_id != h.url_id
                  AND NOT EXISTS (
                    SELECT 1 FROM hreflang back
                    WHERE back.url_id = h.href_url_id AND back.href_url_id = h.url_id
                  )
                ORDER BY src.url, h.lang
                """
        ),
        ReportDefinition(
            id: "hreflang-non-200",
            group: "Hreflang",
            name: "Non-200 target",
            summary: "Alternates pointing at a URL that redirects, errors, or was never crawled.",
            columns: ["URL", "Language", "Target", "Target status"],
            sql: """
                SELECT src.url AS "URL", h.lang AS "Language", dst.url AS "Target",
                       r.status AS "Target status"
                FROM hreflang h
                JOIN urls src ON src.id = h.url_id
                JOIN urls dst ON dst.id = h.href_url_id
                LEFT JOIN responses r ON r.url_id = dst.id
                WHERE r.status IS NULL OR r.status != 200
                ORDER BY src.url, h.lang
                """
        ),
        ReportDefinition(
            id: "hreflang-missing-x-default",
            group: "Hreflang",
            name: "Missing x-default",
            summary: "Pages with hreflang annotations but no x-default fallback.",
            columns: ["URL", "Alternates"],
            sql: """
                SELECT u.url AS "URL", count(*) AS "Alternates"
                FROM hreflang h
                JOIN urls u ON u.id = h.url_id
                GROUP BY h.url_id
                HAVING sum(CASE WHEN lower(h.lang) = 'x-default' THEN 1 ELSE 0 END) = 0
                ORDER BY u.url
                """
        ),

        // MARK: - Page Depth

        ReportDefinition(
            id: "depth-distribution",
            group: "Page Depth",
            name: "Distribution",
            kind: .inventory,
            summary: "How many crawled URLs sit at each click depth from the seed.",
            columns: ["Depth", "URLs"],
            sql: """
                SELECT u.depth AS "Depth", count(*) AS "URLs"
                FROM urls u JOIN responses r ON r.url_id = u.id
                GROUP BY u.depth
                ORDER BY u.depth
                """
        ),
        ReportDefinition(
            id: "depth-over-3",
            group: "Page Depth",
            name: "Deeper than 3",
            summary: "Pages more than three clicks from the seed, where crawl budget thins out.",
            columns: ["URL", "Depth", "Status"],
            sql: """
                SELECT u.url AS "URL", u.depth AS "Depth", r.status AS "Status"
                FROM urls u JOIN responses r ON r.url_id = u.id
                WHERE u.is_internal = 1 AND u.depth > 3
                ORDER BY u.depth DESC, u.url
                """
        ),
        ReportDefinition(
            id: "depth-single-inlink",
            group: "Page Depth",
            name: "Single inlink",
            summary: "Internal pages reachable by exactly one internal link. The closest honest signal to an orphan a crawl-only tool can give.",
            columns: ["URL", "Depth", "Inlinks"],
            sql: """
                SELECT u.url AS "URL", u.depth AS "Depth", count(l.from_url_id) AS "Inlinks"
                FROM urls u
                JOIN responses r ON r.url_id = u.id
                LEFT JOIN links l ON l.to_url_id = u.id AND l.is_internal = 1
                WHERE u.is_internal = 1
                GROUP BY u.id
                HAVING count(l.from_url_id) = 1
                ORDER BY u.url
                """
        ),
    ]

    // MARK: - Builders for the repetitive shapes

    /// The standard page projection, filtered by one predicate over `page_facts`.
    private static func pageReport(
        id: String, group: String, name: String, kind: ReportKind = .issue,
        summary: String, where predicate: String
    ) -> ReportDefinition {
        ReportDefinition(
            id: id, group: group, name: name, kind: kind, summary: summary,
            columns: ["URL", "Title", "H1", "Words", "Depth"],
            sql: """
                SELECT u.url AS "URL", f.title AS "Title", f.h1 AS "H1",
                       f.word_count AS "Words", u.depth AS "Depth"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND \(predicate)
                ORDER BY u.url
                """
        )
    }

    private static func statusClassReport(
        id: String, name: String, low: Int, high: Int, kind: ReportKind = .issue
    ) -> ReportDefinition {
        ReportDefinition(
            id: id, group: "Response Codes", name: name, kind: kind,
            summary: "URLs answering with a status between \(low) and \(high).",
            columns: ["URL", "Status", "Type", "Time (ms)"],
            sql: """
                SELECT u.url AS "URL", r.status AS "Status", r.content_type AS "Type",
                       r.response_time_ms AS "Time (ms)"
                FROM responses r JOIN urls u ON u.id = r.url_id
                WHERE r.status BETWEEN \(low) AND \(high)
                ORDER BY r.status, u.url
                """
        )
    }

    private static func titleLengthReport(id: String, name: String, comparison: String) -> ReportDefinition {
        ReportDefinition(
            id: id, group: "Titles", name: name,
            summary: "Titles whose length is \(comparison) characters.",
            columns: ["URL", "Title", "Length"],
            sql: """
                SELECT u.url AS "URL", f.title AS "Title", f.title_length AS "Length"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND f.title IS NOT NULL AND f.title != ''
                  AND f.title_length \(comparison)
                ORDER BY f.title_length DESC, u.url
                """
        )
    }

    private static func metaLengthReport(id: String, name: String, comparison: String) -> ReportDefinition {
        ReportDefinition(
            id: id, group: "Meta Description", name: name,
            summary: "Meta descriptions whose length is \(comparison) characters.",
            columns: ["URL", "Meta description", "Length"],
            sql: """
                SELECT u.url AS "URL", f.meta_description AS "Meta description",
                       f.meta_description_length AS "Length"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                JOIN responses r ON r.url_id = f.url_id
                WHERE r.status = 200 AND f.meta_description IS NOT NULL AND f.meta_description != ''
                  AND f.meta_description_length \(comparison)
                ORDER BY f.meta_description_length DESC, u.url
                """
        )
    }

    /// A directive is set if either the meta tag or the header carries the token.
    private static func directiveReport(
        id: String, name: String, token: String, summary: String
    ) -> ReportDefinition {
        ReportDefinition(
            id: id, group: "Directives", name: name, summary: summary,
            columns: ["URL", "Meta robots", "X-Robots-Tag"],
            sql: """
                SELECT u.url AS "URL", f.meta_robots AS "Meta robots", f.x_robots_tag AS "X-Robots-Tag"
                FROM page_facts f
                JOIN urls u ON u.id = f.url_id
                WHERE lower(coalesce(f.meta_robots, '')) LIKE '%\(token)%'
                   OR lower(coalesce(f.x_robots_tag, '')) LIKE '%\(token)%'
                ORDER BY u.url
                """
        )
    }
}
