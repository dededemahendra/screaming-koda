import Foundation

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
    public let facts: PageFacts?

    public init(
        urlID: Int64, url: NormalizedURL, depth: Int, status: Int, errorKind: String?,
        contentType: String?, contentLength: Int?, responseTimeMs: Int,
        redirectTarget: NormalizedURL?, bodyGz: Data?, xRobotsTag: String?, facts: PageFacts?
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
