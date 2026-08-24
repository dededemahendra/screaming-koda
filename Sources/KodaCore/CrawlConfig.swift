import Foundation

/// One named CSS-selector extraction.
public struct ExtractionRule: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var selector: String
    /// What to take from each matched element.
    public var value: ExtractionValue
    public var id: String { name }

    public init(name: String, selector: String, value: ExtractionValue = .text) {
        self.name = name
        self.selector = selector
        self.value = value
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

public struct CrawlConfig: Codable, Sendable {
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

    /// User-defined CSS-selector extractions, applied to every HTML page.
    ///
    /// CSS rather than XPath because SwiftSoup already does CSS selectors, so
    /// this is a configuration feature rather than a new parser. XPath would
    /// mean a second engine for a strictly smaller audience.
    public var extractions: [ExtractionRule] = []

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
