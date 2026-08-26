import Foundation

/// Where and how to log in before crawling.
public struct FormLogin: Codable, Sendable, Equatable {
    public var url: String
    /// CSS selectors for the fields and the button. Defaults cover the common
    /// shape — `input[type=password]` is a far more reliable way to find a
    /// password box than guessing at its name.
    public var usernameSelector: String
    public var passwordSelector: String
    public var submitSelector: String
    public var username: String
    public var password: String
    /// How long to wait after submitting before reading the session back.
    public var settleMs: Int

    public init(url: String, username: String, password: String,
                usernameSelector: String = "input[type=email], input[type=text], input[name*=user]",
                passwordSelector: String = "input[type=password]",
                submitSelector: String = "button[type=submit], input[type=submit], button",
                settleMs: Int = 2000) {
        self.url = url
        self.username = username
        self.password = password
        self.usernameSelector = usernameSelector
        self.passwordSelector = passwordSelector
        self.submitSelector = submitSelector
        self.settleMs = settleMs
    }
}

/// One named CSS-selector extraction.
public struct ExtractionRule: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var selector: String
    /// What to take from each matched element.
    public var value: ExtractionValue
    /// How `selector` should be interpreted. Defaults to CSS, so every rule
    /// written before XPath existed still means what it did.
    public var engine: ExtractionEngine
    public var id: String { name }

    public init(name: String, selector: String, value: ExtractionValue = .text,
                engine: ExtractionEngine = .css) {
        self.name = name
        self.selector = selector
        self.value = value
        self.engine = engine
    }

    /// Decoding tolerates a rule stored before `engine` existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        selector = try c.decode(String.self, forKey: .selector)
        value = try c.decodeIfPresent(ExtractionValue.self, forKey: .value) ?? .text
        engine = try c.decodeIfPresent(ExtractionEngine.self, forKey: .engine) ?? .css
    }
}

public enum ExtractionEngine: String, Codable, Sendable, CaseIterable {
    case css, xpath

    public var label: String {
        switch self {
        case .css: return "CSS selector"
        case .xpath: return "XPath"
        }
    }
}

public enum ExtractionValue: String, Codable, Sendable, CaseIterable {
    case text, html
    /// The value of a named attribute, given as `attr:href`.
    case attribute

    public var label: String {
        switch self {
        case .text: return "Text"
        case .html: return "Inner HTML"
        case .attribute: return "Attribute"
        }
    }
}

public struct CrawlConfig: Codable, Sendable, Equatable {
    public var seedURL: String
    public var workers: Int = 5
    /// Deliberately below `workers`: batch size is `max(workers, 1)` and
    /// `Store.claimNext` filters to `rn <= maxPerHost` before applying that
    /// limit, so when the two are equal a single dominant host absorbs every
    /// worker in every batch — identical to having no cap at all. 2 keeps the
    /// cap real for the motivating case (a page with hundreds of links to one
    /// domain) while `workers` stays at 5.
    public var maxPerHost: Int = 2
    public var userAgent: String = KodaCoreInfo.userAgent
    public var timeout: TimeInterval = 20
    public var maxRedirects: Int = 10
    public var respectRobots: Bool = true
    public var followInternalNofollow: Bool = false
    public var crawlSubdomains: Bool = false
    public var maxDepth: Int? = nil
    public var urlCap: Int = 500_000
    public var retainBodies: Bool = true
    /// Once `CrawlEngine` has crawled this many URLs, it stops retaining newly-fetched
    /// bodies even if `retainBodies` is still true — bodies already stored are untouched.
    public var retainBodyURLLimit: Int = 50_000
    public var include: [String] = []
    public var exclude: [String] = []
    /// Fetch external links with HEAD to record their status. On by default: a
    /// broken-outbound-links report is one of the genuinely useful things this
    /// tool does. Turn it off for a large site where the extra requests to third
    /// parties are not worth it.
    public var checkExternalLinks: Bool = true

    /// Fetch image sources with HEAD to record status and byte size. Needed for
    /// the "images over 100KB" report.
    public var checkImages: Bool = true

    /// Render pages in a real browser engine before parsing them.
    ///
    /// Off by default, and it is the most expensive switch in the tool: a
    /// rendered page costs a browser process and hundreds of milliseconds
    /// instead of one HTTP request and a parse. Rendering a 50,000-page site is
    /// a different proposition from crawling one. Turn it on for a site that
    /// renders its content client-side, where a static crawl reports empty
    /// titles and no links — which is a limitation of the crawl, not the site.
    public var renderJavaScript: Bool = false
    /// How long a single page may take to render before it is abandoned.
    public var renderTimeout: TimeInterval = 20
    /// How long to let a page's own scripts settle after load before reading the
    /// DOM. Hydration and lazy content usually land in the first few hundred ms.
    public var renderSettleMs: Int = 400
    /// How many pages may render at once. Each is a browser process, so this is
    /// memory rather than merely parallelism.
    public var renderConcurrency: Int = 2

    /// Fetch stylesheets and scripts with HEAD to record status and size.
    ///
    /// Off by default, unlike images. A broken stylesheet is a real finding, but
    /// a page typically loads far more scripts than images and most of them are
    /// third-party — so this roughly doubles a crawl's request count for a
    /// narrower payoff. Opt in when auditing resources specifically.
    public var checkResources: Bool = false

    /// User-defined CSS-selector extractions, applied to every HTML page.
    ///
    /// CSS rather than XPath because SwiftSoup already does CSS selectors, so
    /// this is a configuration feature rather than a new parser. XPath would
    /// mean a second engine for a strictly smaller audience.
    public var extractions: [ExtractionRule] = []

    /// HTTP Basic credentials, applied to every request to the seed host.
    ///
    /// Stored in the crawl's config JSON, which means they are written to the
    /// `.koda` file in plain text. That is a deliberate limit rather than an
    /// oversight: this is a local tool for sites you control, and a keychain
    /// round trip per crawl would be security theatre while the crawl database
    /// itself sits unencrypted next to it. Do not point it at credentials that
    /// matter beyond the site being crawled.
    public var basicAuthUser: String = ""
    public var basicAuthPassword: String = ""

    /// Extra request headers, for token auth, a staging bypass header, or
    /// anything else a protected environment needs.
    public var extraHeaders: [String: String] = [:]

    /// A form login, performed in a real browser before the crawl starts.
    ///
    /// Basic auth is a header; a form login is a page, a POST, a redirect and a
    /// session cookie, and reproducing that by hand means guessing at CSRF
    /// tokens and hidden fields. Driving the actual login page in a browser
    /// avoids all of that guessing — which is only possible because rendering
    /// already exists.
    public var login: FormLogin?

    /// Whether any authentication is configured at all.
    public var hasCredentials: Bool {
        !basicAuthUser.isEmpty || !extraHeaders.isEmpty
    }

    /// The headers every request carries: the configured extras, plus a Basic
    /// `Authorization` header when credentials are set.
    ///
    /// Built here rather than at each call site so the engine, the robots fetch
    /// and the sitemap fetch cannot drift — a crawl that authenticates its pages
    /// but not its robots.txt reads as "disallow all" and produces nothing.
    /// A current iPhone Safari string. Mobile-specific markup is usually chosen
    /// on the presence of "Mobile", so the exact version matters less than that.
    public static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// What the crawl actually sends, which is the mobile string when crawling
    /// as a phone unless the user has set their own.
    public var effectiveUserAgent: String {
        guard mobile else { return userAgent }
        return userAgent == KodaCoreInfo.userAgent ? Self.mobileUserAgent : userAgent
    }

    public var requestHeaders: [String: String] {
        var out = extraHeaders
        if !basicAuthUser.isEmpty {
            let pair = "\(basicAuthUser):\(basicAuthPassword)"
            let encoded = Data(pair.utf8).base64EncodedString()
            out["Authorization"] = "Basic \(encoded)"
        }
        return out
    }

    /// Response headers to pull into the Extraction tab, by name. Matched
    /// case-insensitively, since header case is not significant.
    public var headerExtractions: [String] = []

    /// Crawl as a phone: a mobile user agent, and a phone-sized viewport when
    /// rendering. Sites that serve different markup to mobile clients — still
    /// common — are otherwise crawled as the desktop version only.
    public var mobile: Bool = false

    /// Named JavaScript snippets evaluated in the rendered page.
    ///
    /// Only runs when rendering is on — there is no DOM to evaluate against
    /// otherwise. Each snippet's return value is stored as an extraction,
    /// beside the CSS-selector ones, so both kinds share the Extraction tab.
    public var javaScriptExtractions: [ExtractionRule] = []

    /// Sitemaps to seed the crawl from, beyond any that robots.txt announces.
    public var sitemapURLs: [String] = []
    /// Follow `Sitemap:` directives in robots.txt. On by default: it is where
    /// sitemaps are meant to be announced, and finding them costs one request
    /// the crawler already made.
    public var discoverSitemaps: Bool = true
    /// Crawl only what the sitemaps and seed list contain, following no links.
    /// This is "list mode": an audit of a known set rather than a discovery run.
    public var listModeOnly: Bool = false
    /// Extra URLs to crawl, alongside the seed.
    public var seedList: [String] = []
    /// How many sitemap documents to fetch in one crawl, counting children of an
    /// index. A bound, because a sitemap index can point at another index.
    public var maxSitemaps: Int = 50

    public init(seedURL: String) {
        self.seedURL = seedURL
    }

    /// Host of the seed URL; used to decide internal vs external.
    public var seedHost: String? {
        URLNormalizer.normalize(seedURL, relativeTo: nil)?.host
    }
}
