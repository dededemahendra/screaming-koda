import Foundation

public enum CrawlState: Sendable, Equatable {
    case idle
    case running
    case paused
    case finished
    case cancelled
    case failed(String)

    /// True while a crawl is underway, whether or not it is currently paused.
    public var isActive: Bool {
        self == .running || self == .paused
    }
}
