import Foundation

// MARK: - Shared helpers

enum ProviderHTTP {
    /// One GET, decoded as JSON, with the provider's failures reported rather
    /// than collapsed into nil. A quota error and a network error need different
    /// responses from the user, so they stay distinguishable.
    static func json(_ url: String, headers: [String: String] = [:],
                     client: HTTPClient, timeout: TimeInterval = 30) async throws -> Any {
        let outcome = await client.fetch(url: url, method: "GET",
                                         userAgent: KodaCoreInfo.userAgent,
                                         timeout: timeout, headers: headers, body: nil)
        switch outcome {
        case .failure(let kind):
            throw ProviderError.transport(kind)
        case .response(let response):
            let body = response.body ?? Data()
            guard (200..<300).contains(response.status) else {
                throw ProviderError.http(status: response.status,
                                         body: String(decoding: body, as: UTF8.self))
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: body) else {
                throw ProviderError.malformedResponse("not JSON")
            }
            return parsed
        }
    }

    static func post(_ url: String, body: String, headers: [String: String] = [:],
                     client: HTTPClient, timeout: TimeInterval = 30) async throws -> Any {
        var all = headers
        all["Content-Type"] = all["Content-Type"] ?? "application/x-www-form-urlencoded"
        let outcome = await client.fetch(url: url, method: "POST",
                                         userAgent: KodaCoreInfo.userAgent,
                                         timeout: timeout, headers: all,
                                         body: Data(body.utf8))
        switch outcome {
        case .failure(let kind):
            throw ProviderError.transport(kind)
        case .response(let response):
            let data = response.body ?? Data()
            guard (200..<300).contains(response.status) else {
                throw ProviderError.http(status: response.status,
                                         body: String(decoding: data, as: UTF8.self))
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
                throw ProviderError.malformedResponse("not JSON")
            }
            return parsed
        }
    }

    static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// Digs a value out of a decoded JSON tree by key path.
    static func dig(_ root: Any, _ path: [String]) -> Any? {
        var current: Any? = root
        for key in path {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[key]
        }
        return current
    }

    static func number(_ root: Any, _ path: [String]) -> Double? {
        switch dig(root, path) {
        case let value as Double: return value
        case let value as Int: return Double(value)
        case let value as NSNumber: return value.doubleValue
        case let value as String: return Double(value)
        default: return nil
        }
    }

    static func string(_ root: Any, _ path: [String]) -> String? {
        dig(root, path) as? String
    }
}

/// Exchanges a refresh token for an access token.
///
/// A refresh token rather than an interactive sign-in on purpose: the browser
/// redirect dance needs a registered redirect URI and a window, and would make
/// the CLI unusable headlessly. A refresh token is obtained once, by hand, and
/// then works in a cron job — which is how anyone would want to run this.
public enum GoogleOAuth {
    public static func accessToken(_ credentials: ProviderCredentials,
                                   client: HTTPClient) async throws -> String {
        guard credentials.hasGoogleOAuth else {
            throw ProviderError.missingCredentials(.searchConsole)
        }
        let body = "client_id=\(ProviderHTTP.escaped(credentials.googleClientID))"
            + "&client_secret=\(ProviderHTTP.escaped(credentials.googleClientSecret))"
            + "&refresh_token=\(ProviderHTTP.escaped(credentials.googleRefreshToken))"
            + "&grant_type=refresh_token"
        let parsed = try await ProviderHTTP.post("https://oauth2.googleapis.com/token",
                                                 body: body, client: client)
        guard let token = ProviderHTTP.string(parsed, ["access_token"]) else {
            throw ProviderError.malformedResponse("no access_token in the token response")
        }
        return token
    }
}

// MARK: - PageSpeed Insights

/// PageSpeed Insights, which carries three of the listed features at once: the
/// Lighthouse lab audit, the Chrome UX Report field data, and Core Web Vitals.
///
/// Field data is what makes CWV real here. The renderer can measure TTFB, FCP
/// and LCP in a browser on this machine, but WebKit reports no layout-shift
/// entries and INP needs a real interaction — so CLS and INP can only come from
/// somewhere that watched actual visitors. That is CrUX, and it arrives in this
/// response.
public struct PageSpeedProvider: MetricsProvider {
    public let source = MetricSource.pageSpeed
    public let strategy: String

    public init(strategy: String = "mobile") { self.strategy = strategy }

    public func fetch(urls: [String], credentials: ProviderCredentials,
                      client: HTTPClient) async throws -> [ExternalMetric] {
        guard let url = urls.first else { return [] }
        var endpoint = "https://www.googleapis.com/pagespeedonline/v5/runPagespeed"
            + "?url=\(ProviderHTTP.escaped(url))&strategy=\(strategy)"
        // The key is optional: the API serves a lower quota without one, which
        // is enough to try the feature before paying attention to quotas.
        if !credentials.pageSpeedKey.isEmpty {
            endpoint += "&key=\(ProviderHTTP.escaped(credentials.pageSpeedKey))"
        }
        for category in ["performance", "seo", "accessibility"] {
            endpoint += "&category=\(category)"
        }

        let parsed = try await ProviderHTTP.json(endpoint, client: client, timeout: 60)
        var out: [ExternalMetric] = []
        func add(_ metric: String, _ value: Double?, _ text: String? = nil) {
            guard value != nil || text != nil else { return }
            out.append(ExternalMetric(url: url, source: source.rawValue,
                                      metric: metric, value: value, text: text))
        }

        // Lighthouse category scores, 0 to 1 in the response.
        for (name, key) in [("Performance", "performance"), ("SEO", "seo"),
                            ("Accessibility", "accessibility")] {
            if let score = ProviderHTTP.number(parsed,
                ["lighthouseResult", "categories", key, "score"]) {
                add("Lighthouse \(name)", score * 100)
            }
        }

        // Lab metrics from the audit.
        for (name, audit) in [("Lab LCP", "largest-contentful-paint"),
                              ("Lab FCP", "first-contentful-paint"),
                              ("Lab CLS", "cumulative-layout-shift"),
                              ("Lab TBT", "total-blocking-time"),
                              ("Lab Speed Index", "speed-index")] {
            if let value = ProviderHTTP.number(parsed,
                ["lighthouseResult", "audits", audit, "numericValue"]) {
                add(name, value)
            }
        }

        // Field data: real Core Web Vitals, including the two no browser on this
        // machine can produce.
        for (name, key) in [("CWV LCP", "LARGEST_CONTENTFUL_PAINT_MS"),
                            ("CWV INP", "INTERACTION_TO_NEXT_PAINT"),
                            ("CWV CLS", "CUMULATIVE_LAYOUT_SHIFT_SCORE"),
                            ("CWV FCP", "FIRST_CONTENTFUL_PAINT_MS"),
                            ("CWV TTFB", "EXPERIMENTAL_TIME_TO_FIRST_BYTE")] {
            let base = ["loadingExperience", "metrics", key]
            if let percentile = ProviderHTTP.number(parsed, base + ["percentile"]) {
                // CLS arrives multiplied by 100 so it can be an integer.
                add(name, key.contains("LAYOUT_SHIFT") ? percentile / 100 : percentile,
                    ProviderHTTP.string(parsed, base + ["category"]))
            }
        }
        if let overall = ProviderHTTP.string(parsed, ["loadingExperience", "overall_category"]) {
            add("CWV Assessment", nil, overall)
        }
        return out
    }
}

// MARK: - Google Search Console

/// Clicks, impressions, CTR and average position per page.
public struct SearchConsoleProvider: MetricsProvider {
    public let source = MetricSource.searchConsole
    /// The API returns rows for the whole site in one call, so every URL in the
    /// crawl is served by a single request.
    public var batchSize: Int { 25_000 }
    public let days: Int

    public init(days: Int = 28) { self.days = days }

    public func fetch(urls: [String], credentials: ProviderCredentials,
                      client: HTTPClient) async throws -> [ExternalMetric] {
        guard credentials.hasGoogleOAuth, !credentials.searchConsoleSite.isEmpty else {
            throw ProviderError.missingCredentials(.searchConsole)
        }
        let token = try await GoogleOAuth.accessToken(credentials, client: client)
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let body = """
            {"startDate":"\(formatter.string(from: start))",\
            "endDate":"\(formatter.string(from: end))",\
            "dimensions":["page"],"rowLimit":25000}
            """
        let endpoint = "https://www.googleapis.com/webmasters/v3/sites/"
            + "\(ProviderHTTP.escaped(credentials.searchConsoleSite))/searchAnalytics/query"
        let parsed = try await ProviderHTTP.post(
            endpoint, body: body,
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            client: client)

        guard let rows = ProviderHTTP.dig(parsed, ["rows"]) as? [[String: Any]] else { return [] }
        // Only URLs this crawl actually found: Search Console reports pages that
        // may no longer exist, and inventing rows for them would misrepresent
        // the crawl.
        let known = Set(urls)
        var out: [ExternalMetric] = []
        for row in rows {
            guard let keys = row["keys"] as? [String], let page = keys.first,
                  known.contains(page) else { continue }
            for (name, key) in [("Clicks", "clicks"), ("Impressions", "impressions"),
                                ("CTR", "ctr"), ("Position", "position")] {
                if let value = ProviderHTTP.number(row, [key]) {
                    out.append(ExternalMetric(url: page, source: source.rawValue,
                                              metric: name, value: value))
                }
            }
        }
        return out
    }
}

// MARK: - Google Analytics 4

/// Sessions, users and engagement per page path.
public struct AnalyticsProvider: MetricsProvider {
    public let source = MetricSource.analytics
    public var batchSize: Int { 25_000 }
    public let days: Int

    public init(days: Int = 28) { self.days = days }

    public func fetch(urls: [String], credentials: ProviderCredentials,
                      client: HTTPClient) async throws -> [ExternalMetric] {
        guard credentials.hasGoogleOAuth, !credentials.analyticsProperty.isEmpty else {
            throw ProviderError.missingCredentials(.analytics)
        }
        let token = try await GoogleOAuth.accessToken(credentials, client: client)
        let body = """
            {"dateRanges":[{"startDate":"\(days)daysAgo","endDate":"today"}],\
            "dimensions":[{"name":"pagePath"}],\
            "metrics":[{"name":"sessions"},{"name":"activeUsers"},{"name":"screenPageViews"}],\
            "limit":25000}
            """
        let endpoint = "https://analyticsdata.googleapis.com/v1beta/properties/"
            + "\(ProviderHTTP.escaped(credentials.analyticsProperty)):runReport"
        let parsed = try await ProviderHTTP.post(
            endpoint, body: body,
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            client: client)

        guard let rows = ProviderHTTP.dig(parsed, ["rows"]) as? [[String: Any]] else { return [] }
        // GA4 reports a path, not a URL, so each one is matched back to the
        // crawled URL that has it. A path that matches nothing is skipped rather
        // than guessed at.
        var byPath: [String: String] = [:]
        for url in urls {
            guard let components = URLComponents(string: url) else { continue }
            byPath[components.path.isEmpty ? "/" : components.path] = url
        }

        var out: [ExternalMetric] = []
        let names = ["Sessions", "Users", "Page views"]
        for row in rows {
            guard let dimensions = row["dimensionValues"] as? [[String: Any]],
                  let path = dimensions.first?["value"] as? String,
                  let url = byPath[path],
                  let values = row["metricValues"] as? [[String: Any]] else { continue }
            for (index, name) in names.enumerated() where index < values.count {
                if let raw = values[index]["value"] as? String, let value = Double(raw) {
                    out.append(ExternalMetric(url: url, source: source.rawValue,
                                              metric: name, value: value))
                }
            }
        }
        return out
    }
}

// MARK: - Backlink providers

/// Ahrefs: backlinks, referring domains and URL rating.
public struct AhrefsProvider: MetricsProvider {
    public let source = MetricSource.ahrefs
    public init() {}

    public func fetch(urls: [String], credentials: ProviderCredentials,
                      client: HTTPClient) async throws -> [ExternalMetric] {
        guard !credentials.ahrefsToken.isEmpty else {
            throw ProviderError.missingCredentials(.ahrefs)
        }
        guard let url = urls.first else { return [] }
        let endpoint = "https://api.ahrefs.com/v3/site-explorer/metrics"
            + "?target=\(ProviderHTTP.escaped(url))&mode=exact&volume_mode=monthly"
        let parsed = try await ProviderHTTP.json(
            endpoint, headers: ["Authorization": "Bearer \(credentials.ahrefsToken)"],
            client: client)

        var out: [ExternalMetric] = []
        for (name, key) in [("Backlinks", "backlinks"),
                            ("Referring domains", "refdomains"),
                            ("URL rating", "url_rating"),
                            ("Domain rating", "domain_rating"),
                            ("Organic traffic", "org_traffic")] {
            if let value = ProviderHTTP.number(parsed, ["metrics", key])
                ?? ProviderHTTP.number(parsed, [key]) {
                out.append(ExternalMetric(url: url, source: source.rawValue,
                                          metric: name, value: value))
            }
        }
        return out
    }
}

/// Majestic: trust flow and citation flow.
public struct MajesticProvider: MetricsProvider {
    public let source = MetricSource.majestic
    public var batchSize: Int { 100 }
    public init() {}

    public func fetch(urls: [String], credentials: ProviderCredentials,
                      client: HTTPClient) async throws -> [ExternalMetric] {
        guard !credentials.majesticKey.isEmpty else {
            throw ProviderError.missingCredentials(.majestic)
        }
        guard !urls.isEmpty else { return [] }
        var endpoint = "https://api.majestic.com/api/json?app_api_key="
            + "\(ProviderHTTP.escaped(credentials.majesticKey))&cmd=GetIndexItemInfo"
            + "&datasource=fresh&items=\(urls.count)"
        for (index, url) in urls.enumerated() {
            endpoint += "&item\(index)=\(ProviderHTTP.escaped(url))"
        }
        let parsed = try await ProviderHTTP.json(endpoint, client: client)
        guard let rows = ProviderHTTP.dig(parsed, ["DataTables", "Results", "Data"])
            as? [[String: Any]] else { return [] }

        var out: [ExternalMetric] = []
        for row in rows {
            guard let item = row["Item"] as? String else { continue }
            for (name, key) in [("Trust flow", "TrustFlow"),
                                ("Citation flow", "CitationFlow"),
                                ("Backlinks", "ExtBackLinks"),
                                ("Referring domains", "RefDomains")] {
                if let value = ProviderHTTP.number(row, [key]) {
                    out.append(ExternalMetric(url: item, source: source.rawValue,
                                              metric: name, value: value))
                }
            }
        }
        return out
    }
}

/// Moz: domain and page authority.
public struct MozProvider: MetricsProvider {
    public let source = MetricSource.moz
    public var batchSize: Int { 50 }
    public init() {}

    public func fetch(urls: [String], credentials: ProviderCredentials,
                      client: HTTPClient) async throws -> [ExternalMetric] {
        guard !credentials.mozAccessID.isEmpty, !credentials.mozSecretKey.isEmpty else {
            throw ProviderError.missingCredentials(.moz)
        }
        guard !urls.isEmpty else { return [] }
        let targets = urls.map { "\"\($0)\"" }.joined(separator: ",")
        let auth = Data("\(credentials.mozAccessID):\(credentials.mozSecretKey)".utf8)
            .base64EncodedString()
        let parsed = try await ProviderHTTP.post(
            "https://lsapi.seomoz.com/v2/url_metrics",
            body: "{\"targets\":[\(targets)]}",
            headers: ["Authorization": "Basic \(auth)", "Content-Type": "application/json"],
            client: client)

        guard let results = ProviderHTTP.dig(parsed, ["results"]) as? [[String: Any]] else {
            return []
        }
        var out: [ExternalMetric] = []
        for row in results {
            guard let page = row["page"] as? String else { continue }
            for (name, key) in [("Page authority", "page_authority"),
                                ("Domain authority", "domain_authority"),
                                ("Spam score", "spam_score"),
                                ("Linking domains", "root_domains_to_page")] {
                if let value = ProviderHTTP.number(row, [key]) {
                    out.append(ExternalMetric(url: page, source: source.rawValue,
                                              metric: name, value: value))
                }
            }
        }
        return out
    }
}

// MARK: - Running them

public enum Enrichment {
    public static func provider(for source: MetricSource) -> MetricsProvider {
        switch source {
        case .pageSpeed: return PageSpeedProvider()
        case .searchConsole: return SearchConsoleProvider()
        case .analytics: return AnalyticsProvider()
        case .ahrefs: return AhrefsProvider()
        case .majestic: return MajesticProvider()
        case .moz: return MozProvider()
        }
    }

    /// Runs a provider over a crawl's URLs and stores what comes back.
    ///
    /// A batch that fails does not stop the run: quota limits and per-URL errors
    /// are ordinary for these APIs, and losing an entire enrichment because one
    /// URL upset a provider would be the same mistake as letting one bad page
    /// kill a crawl. Failures are returned so the caller can report them.
    @discardableResult
    public static func run(source: MetricSource, store: Store,
                           credentials: ProviderCredentials, client: HTTPClient,
                           limit: Int = 100,
                           onProgress: (@Sendable (Int, Int) -> Void)? = nil)
        async throws -> (stored: Int, failures: [String]) {
        let provider = provider(for: source)
        let urls = try store.urlsToEnrich(limit: limit)
        guard !urls.isEmpty else { return (0, []) }

        var stored = 0
        var failures: [String] = []
        var done = 0
        for start in stride(from: 0, to: urls.count, by: max(provider.batchSize, 1)) {
            let batch = Array(urls[start..<min(start + max(provider.batchSize, 1), urls.count)])
            do {
                let metrics = try await provider.fetch(urls: batch, credentials: credentials,
                                                       client: client)
                stored += try store.write(metrics: metrics, source: source)
            } catch {
                failures.append("\(batch.first ?? "?"): \(error)")
            }
            done += batch.count
            onProgress?(done, urls.count)
        }
        return (stored, failures)
    }
}
