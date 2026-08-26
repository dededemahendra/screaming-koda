import Foundation

/// "Would a search engine index this, and if not, why" — defined once, in SQL,
/// because the Internal, Canonicals, and Directives reports all need it and
/// three hand-written variants would drift apart.
public enum Indexability {
    public static let notCrawled = "Not crawled"
    public static let indexable = "Indexable"
    public static let redirected = "Non-indexable: redirected"
    public static let clientError = "Non-indexable: client error"
    public static let serverError = "Non-indexable: server error"
    public static let noindex = "Non-indexable: noindex"
    public static let canonicalised = "Non-indexable: canonicalised"

    /// Branch order *is* the precedence rule. Status outranks directives so a
    /// 404 that also carries `noindex` reports the 404, which is the problem to
    /// fix; the noindex on a page that does not exist is noise.
    ///
    /// `status = 0` is the schema's transport-error marker, so it is grouped
    /// with the 5xx branch rather than left to fall through — it matches none of
    /// the numeric ranges on its own and would otherwise read as indexable.
    public static let expression = """
        CASE
          WHEN r.status IS NULL THEN '\(notCrawled)'
          WHEN r.status >= 300 AND r.status < 400 THEN '\(redirected)'
          WHEN r.status >= 400 AND r.status < 500 THEN '\(clientError)'
          WHEN r.status = 0 OR r.status >= 500 THEN '\(serverError)'
          WHEN lower(coalesce(f.meta_robots, '')) LIKE '%noindex%'
            OR lower(coalesce(f.x_robots_tag, '')) LIKE '%noindex%' THEN '\(noindex)'
          WHEN f.canonical_id IS NOT NULL AND f.canonical_id != u.id THEN '\(canonicalised)'
          ELSE '\(indexable)'
        END
        """

    /// The predicate form, for filters that want "everything that isn't
    /// indexable" without repeating the ladder. Uncrawled rows are excluded:
    /// they are not yet a finding.
    public static let isNonIndexable = """
        (\(expression)) NOT IN ('\(indexable)', '\(notCrawled)')
        """
}
