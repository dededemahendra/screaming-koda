import Foundation
import GRDB

/// One number or label about a URL that the crawl itself cannot know.
///
/// Backlinks, impressions, sessions and field performance data all come from
/// somewhere else, and they all have the same shape: a URL, a source, a name,
/// and a value. One table serves every provider, so adding one is a new
/// `MetricsProvider` rather than a migration.
public struct ExternalMetric: Sendable, Equatable {
    public let url: String
    /// Which provider it came from, so two sources reporting the same metric
    /// stay distinguishable.
    public let source: String
    public let metric: String
    public let value: Double?
    public let text: String?

    public init(url: String, source: String, metric: String,
                value: Double? = nil, text: String? = nil) {
        self.url = url
        self.source = source
        self.metric = metric
        self.value = value
        self.text = text
    }
}

public enum MetricSource: String, CaseIterable, Sendable {
    case pageSpeed = "pagespeed"
    case searchConsole = "gsc"
    case analytics = "ga4"
    case ahrefs, majestic, moz

    public var label: String {
        switch self {
        case .pageSpeed: return "PageSpeed Insights"
        case .searchConsole: return "Search Console"
        case .analytics: return "Google Analytics"
        case .ahrefs: return "Ahrefs"
        case .majestic: return "Majestic"
        case .moz: return "Moz"
        }
    }

    /// What the user has to supply. Stated here so the CLI and the settings
    /// sheet can say it rather than failing with an authorisation error.
    public var credentialHint: String {
        switch self {
        case .pageSpeed:
            return "an API key, or none for the keyless quota"
        case .searchConsole, .analytics:
            return "a Google OAuth client id, secret and refresh token"
        case .ahrefs:
            return "an Ahrefs API token"
        case .majestic:
            return "a Majestic API key"
        case .moz:
            return "a Moz access id and secret key"
        }
    }
}

/// Credentials and settings for the external providers.
///
/// Held apart from `CrawlConfig` because these belong to the person rather than
/// to a crawl: the same key enriches every crawl, and copying a crawl's config
/// to a colleague should not copy an API key with it.
public struct ProviderCredentials: Codable, Sendable, Equatable {
    public var pageSpeedKey: String = ""
    public var googleClientID: String = ""
    public var googleClientSecret: String = ""
    public var googleRefreshToken: String = ""
    /// `sc-domain:example.com` or `https://example.com/`, as Search Console
    /// spells it.
    public var searchConsoleSite: String = ""
    /// The numeric GA4 property id.
    public var analyticsProperty: String = ""
    public var ahrefsToken: String = ""
    public var majesticKey: String = ""
    public var mozAccessID: String = ""
    public var mozSecretKey: String = ""

    public init() {}

    public var hasGoogleOAuth: Bool {
        !googleClientID.isEmpty && !googleClientSecret.isEmpty && !googleRefreshToken.isEmpty
    }

    /// Which sources could run right now. The UI lists the rest with their
    /// `credentialHint` rather than offering a button that will fail.
    public var availableSources: [MetricSource] {
        MetricSource.allCases.filter { source in
            switch source {
            case .pageSpeed: return true   // works without a key, at a lower quota
            case .searchConsole: return hasGoogleOAuth && !searchConsoleSite.isEmpty
            case .analytics: return hasGoogleOAuth && !analyticsProperty.isEmpty
            case .ahrefs: return !ahrefsToken.isEmpty
            case .majestic: return !majesticKey.isEmpty
            case .moz: return !mozAccessID.isEmpty && !mozSecretKey.isEmpty
            }
        }
    }
}

public enum ProviderError: Error, CustomStringConvertible, Equatable {
    case missingCredentials(MetricSource)
    case transport(String)
    case http(status: Int, body: String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .missingCredentials(let source):
            return "\(source.label) needs \(source.credentialHint)."
        case .transport(let kind):
            return "Could not reach the provider: \(kind)"
        case .http(let status, let body):
            return "The provider returned HTTP \(status): \(body.prefix(200))"
        case .malformedResponse(let detail):
            return "The provider's response was not what was expected: \(detail)"
        }
    }
}

/// Fetches metrics for a batch of URLs.
///
/// Providers take the crawler's own `HTTPClient` rather than reaching for
/// URLSession themselves, so every one of them is testable against a stub — the
/// same way the crawler is, and the only way to test an integration whose live
/// service needs a paid account.
public protocol MetricsProvider: Sendable {
    var source: MetricSource { get }
    /// How many URLs one call can carry. Providers that take a single URL per
    /// request say 1 and get called repeatedly.
    var batchSize: Int { get }
    func fetch(urls: [String], credentials: ProviderCredentials,
               client: HTTPClient) async throws -> [ExternalMetric]
}

extension MetricsProvider {
    public var batchSize: Int { 1 }
}

extension Store {
    /// Writes metrics, replacing whatever that source previously said about
    /// those URLs. A second enrichment run updates rather than accumulates.
    @discardableResult
    public func write(metrics: [ExternalMetric], source: MetricSource) throws -> Int {
        guard !metrics.isEmpty else { return 0 }
        return try dbQueue.write { db in
            var written = 0
            for metric in metrics {
                guard let id = try Int64.fetchOne(
                    db, sql: "SELECT id FROM urls WHERE url = ?", arguments: [metric.url])
                else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO external_metrics (url_id, source, metric, value, text)
                        VALUES (?,?,?,?,?)
                        ON CONFLICT(url_id, source, metric) DO UPDATE SET
                          value = excluded.value, text = excluded.text
                        """,
                    arguments: [id, metric.source, metric.metric, metric.value, metric.text])
                written += 1
            }
            return written
        }
    }

    /// The URLs worth enriching: internal pages that were actually fetched.
    /// Sending a provider a URL the crawl never reached wastes quota that is
    /// often paid for by the request.
    public func urlsToEnrich(limit: Int) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT u.url \(ReportSQL.from)
                WHERE u.is_internal = 1 AND r.status = 200
                  AND coalesce(r.content_type, '') LIKE 'text/html%'
                  AND \(Reports.pageRows)
                ORDER BY u.id
                LIMIT \(max(limit, 0))
                """)
        }
    }

    public func metricCount(source: MetricSource) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM external_metrics WHERE source = ?",
                             arguments: [source.rawValue]) ?? 0
        }
    }
}
