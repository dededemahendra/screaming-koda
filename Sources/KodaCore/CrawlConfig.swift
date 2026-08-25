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
    /// External links are status-checked with HEAD, never crawled or parsed.
    public var checkExternalLinks: Bool = true
    /// Internal images are status-checked with HEAD to record status and size.
    public var checkImages: Bool = true
    public var maxDepth: Int? = nil
    public var urlCap: Int = 500_000
    public var retainBodies: Bool = true
    public var retainBodyURLLimit: Int = 50_000
    public var include: [String] = []
    public var exclude: [String] = []

    public init(seedURL: String) {
        self.seedURL = seedURL
    }

    /// Host of the seed URL; used to decide internal vs external.
    public var seedHost: String? { URLNormalizer.seed(seedURL)?.host }

    /// The seed as it will actually be crawled, with a scheme supplied when the
    /// person who typed it left one out.
    public var normalizedSeedURL: String? { URLNormalizer.seed(seedURL)?.absoluteString }
}

/// What `crawl_meta` records about the run itself, as opposed to its settings.
public struct CrawlMeta: Sendable, Equatable {
    public let seedURL: String
    public let startedAt: Date
    /// Nil while a crawl is running, and for one that was stopped or died.
    public let finishedAt: Date?

    public init(seedURL: String, startedAt: Date, finishedAt: Date?) {
        self.seedURL = seedURL
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var isFinished: Bool { finishedAt != nil }

    /// How long the crawl took, or nil if it never finished.
    ///
    /// Not measured against the clock when `finishedAt` is missing: a crawl
    /// stopped last week did not take a week, and the database has no record of
    /// when it actually stopped. A running crawl's elapsed time comes from
    /// whatever is running it, which is the only thing that knows.
    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }
}
