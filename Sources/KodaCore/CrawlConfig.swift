import Foundation

public struct CrawlConfig: Codable, Sendable {
    public var seedURL: String
    public var workers: Int = 5
    public var maxPerHost: Int = 5
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

    public init(seedURL: String) {
        self.seedURL = seedURL
    }

    /// Host of the seed URL; used to decide internal vs external.
    public var seedHost: String? {
        URLNormalizer.normalize(seedURL, relativeTo: nil)?.host
    }
}
