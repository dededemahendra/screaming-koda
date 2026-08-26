import Foundation

/// How fast the crawl is going, smoothed.
///
/// The raw figure between two ticks swings wildly — a handful of slow pages
/// drops it to three, a burst of cached ones takes it to forty — and a number
/// that jumps around that much is worse than no number, because a person reads
/// it as instability in the tool rather than in the site.
public struct CrawlRate: Equatable, Sendable {
    /// How much of each new reading to believe. Low enough to smooth a slow
    /// page, high enough that a stall shows within a few ticks.
    private static let alpha = 0.3

    public private(set) var perSecond: Double?
    private var lastCrawled: Int?
    private var lastAt: Date?

    public init() {}

    public mutating func observe(crawled: Int, at now: Date) {
        defer { lastCrawled = crawled; lastAt = now }
        guard let previousCount = lastCrawled, let previousAt = lastAt else { return }
        let interval = now.timeIntervalSince(previousAt)
        // Two ticks in the same instant would divide by zero and render as
        // "inf/s"; a clock that went backwards is not a measurement either.
        guard interval > 0 else { return }
        let instant = Double(max(crawled - previousCount, 0)) / interval
        perSecond = perSecond.map { Self.alpha * instant + (1 - Self.alpha) * $0 } ?? instant
    }

    /// Called on pause and on resume, so the gap is not read as a burst.
    public mutating func reset() {
        perSecond = nil
        lastCrawled = nil
        lastAt = nil
    }

    /// One decimal below one a second: "0/s" reads as stalled when the crawl is
    /// merely being polite to a slow server.
    public var summary: String? {
        guard let perSecond else { return nil }
        return perSecond < 1
            ? "\(perSecond.formatted(.number.precision(.fractionLength(1))))/s"
            : "\(perSecond.rounded().formatted(.number.precision(.fractionLength(0))))/s"
    }
}
