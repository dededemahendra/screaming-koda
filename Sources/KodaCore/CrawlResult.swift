import Foundation

/// What rendering a page produced, alongside the static fetch it replaced.
public struct RenderOutcome: Sendable, Equatable {
    public let elapsedMs: Int
    public let errors: [String]
    /// Word count of the rendered DOM against the static one. Their difference
    /// is what says whether a site needs rendering at all.
    public let renderedWords: Int
    public let staticWords: Int
    /// Timings the browser observed, when it produced any.
    public let metrics: PageMetrics?

    public init(elapsedMs: Int, errors: [String], renderedWords: Int, staticWords: Int,
                metrics: PageMetrics? = nil) {
        self.elapsedMs = elapsedMs
        self.errors = errors
        self.renderedWords = renderedWords
        self.staticWords = staticWords
        self.metrics = metrics
    }
}

public struct CrawlResult: Sendable {
    public let urlID: Int64
    public let url: NormalizedURL
    public let depth: Int
    public let status: Int
    public let errorKind: String?
    public let contentType: String?
    public let contentLength: Int?
    public let responseTimeMs: Int
    public let redirectTarget: NormalizedURL?
    public let bodyGz: Data?
    public let xRobotsTag: String?
    /// Every response header, for the Security tab and custom header extraction.
    public let headers: [String: String]
    /// Set when the page went through a browser engine.
    public let render: RenderOutcome?
    public let facts: PageFacts?

    public init(
        urlID: Int64, url: NormalizedURL, depth: Int, status: Int, errorKind: String?,
        contentType: String?, contentLength: Int?, responseTimeMs: Int,
        redirectTarget: NormalizedURL?, bodyGz: Data?, xRobotsTag: String?,
        headers: [String: String] = [:], render: RenderOutcome? = nil,
        facts: PageFacts?
    ) {
        self.urlID = urlID
        self.url = url
        self.depth = depth
        self.status = status
        self.errorKind = errorKind
        self.contentType = contentType
        self.contentLength = contentLength
        self.responseTimeMs = responseTimeMs
        self.redirectTarget = redirectTarget
        self.bodyGz = bodyGz
        self.xRobotsTag = xRobotsTag
        self.headers = headers
        self.render = render
        self.facts = facts
    }
}

public enum Gzip {
    public static func compress(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    public static func decompress(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }
}
