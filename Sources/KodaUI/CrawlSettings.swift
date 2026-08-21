import Foundation
import KodaCore

/// The crawl configuration the window edits, persisted between launches.
///
/// A user who turned off image checking for a large site means it, so the
/// setting outlives the crawl. The seed URL is deliberately *not* part of what
/// persists — it is the one field that changes every time, and it lives in the
/// toolbar.
public final class CrawlSettings: @unchecked Sendable {
    static let key = "crawlConfig"
    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests never touch the real domain.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Reading always succeeds. Stored JSON that will not decode — a truncated
    /// write, or a config from an older schema — falls back to defaults rather
    /// than leaving the app unable to start a crawl, which would be
    /// unrecoverable without knowing to clear a preference by hand.
    public var config: CrawlConfig {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(CrawlConfig.self, from: data)
            else { return CrawlConfig(seedURL: "") }
            return Self.clamped(decoded)
        }
        set {
            var stored = Self.clamped(newValue)
            stored.seedURL = ""
            guard let data = try? JSONEncoder().encode(stored) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Numeric bounds, applied on the way in and out. Clamping rather than
    /// rejecting: these come from steppers and text fields where a nonsense
    /// value means a typo, and the useful response is to pin it to the nearest
    /// sane value rather than refuse to start.
    public static func clamped(_ config: CrawlConfig) -> CrawlConfig {
        var out = config
        out.workers = min(max(config.workers, 1), 50)
        // maxPerHost above workers is the same as no cap at all, because a batch
        // is only `workers` long. Silently allowing it would make the politeness
        // setting a lie.
        out.maxPerHost = min(max(config.maxPerHost, 1), out.workers)
        out.timeout = min(max(config.timeout, 1), 300)
        out.maxRedirects = min(max(config.maxRedirects, 0), 50)
        out.urlCap = max(config.urlCap, 1)
        out.retainBodyURLLimit = max(config.retainBodyURLLimit, 0)
        if let depth = config.maxDepth { out.maxDepth = max(depth, 0) }
        if out.userAgent.trimmingCharacters(in: .whitespaces).isEmpty {
            out.userAgent = KodaCoreInfo.userAgent
        }
        return out
    }

    /// Problems that cannot be clamped away, phrased for a person.
    ///
    /// The regex check is the one that matters. `Store.passesFilters` uses
    /// `range(of:options:.regularExpression)`, which returns nil for a pattern
    /// that does not compile — indistinguishable from "did not match". An
    /// invalid exclude pattern would therefore exclude nothing and an invalid
    /// include pattern would include nothing, and in the second case the crawl
    /// would silently fetch a single page and stop, looking like a broken tool.
    public static func problems(in config: CrawlConfig) -> [String] {
        var out: [String] = []
        for (label, patterns) in [("Include", config.include), ("Exclude", config.exclude)] {
            for pattern in patterns {
                if pattern.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append("\(label): an empty pattern matches nothing useful. Remove the blank row.")
                    continue
                }
                if (try? NSRegularExpression(pattern: pattern)) == nil {
                    out.append("\(label): \"\(pattern)\" is not a valid regular expression.")
                }
            }
        }
        return out
    }
}
