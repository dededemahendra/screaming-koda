import Foundation
import KodaCore

/// Everything the crawl form holds, as a value.
///
/// A struct rather than another `@Observable` class so a SwiftUI form can bind
/// straight through `AppModel` to a single field, and so the whole thing
/// round-trips through `Codable` for both `UserDefaults` and the config a
/// finished crawl stored.
///
/// Free-text fields stay text. Parsing "3" out of a depth field the user is
/// halfway through typing, and writing the parse back, deletes characters under
/// the cursor. Validation happens when the form is submitted, which is also the
/// only moment at which a half-typed regex is worth complaining about.
public struct CrawlSettings: Codable, Equatable, Sendable {
    public var workers: Int = 5
    public var maxPerHost: Int = 5
    public var timeout: Double = 20
    public var userAgent: String = KodaCoreInfo.userAgent
    public var urlCap: Int = 500_000
    /// Empty means unlimited, which is the default and cannot be expressed as a number.
    public var maxDepthText: String = ""
    public var respectRobots = true
    public var followInternalNofollow = false
    public var crawlSubdomains = false
    public var checkExternalLinks = true
    public var checkImages = true
    public var retainBodies = true
    /// One regex per line. Blank lines are ignored so a trailing newline is harmless.
    public var includeText: String = ""
    public var excludeText: String = ""

    public init() {}

    /// Reads back what a crawl actually ran with, so resuming or reopening a
    /// database shows its settings rather than the app's defaults.
    public init(from config: CrawlConfig) {
        workers = config.workers
        maxPerHost = config.maxPerHost
        timeout = config.timeout
        userAgent = config.userAgent
        urlCap = config.urlCap
        maxDepthText = config.maxDepth.map(String.init) ?? ""
        respectRobots = config.respectRobots
        followInternalNofollow = config.followInternalNofollow
        crawlSubdomains = config.crawlSubdomains
        checkExternalLinks = config.checkExternalLinks
        checkImages = config.checkImages
        retainBodies = config.retainBodies
        includeText = config.include.joined(separator: "\n")
        excludeText = config.exclude.joined(separator: "\n")
    }

    public var include: [String] { Self.patterns(in: includeText) }
    public var exclude: [String] { Self.patterns(in: excludeText) }

    private static func patterns(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Everything wrong with the form, in the order a reader would meet it.
    /// Empty means `config(seedURL:)` will succeed.
    public func problems(seedURL: String) -> [String] {
        var problems: [String] = []
        let seed = seedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if seed.isEmpty {
            problems.append("Enter a URL to crawl.")
        } else if URLNormalizer.normalize(seed, relativeTo: nil) == nil {
            problems.append("Not a crawlable http(s) URL: \(seed)")
        }
        if !maxDepthText.trimmingCharacters(in: .whitespaces).isEmpty, maxDepth == nil {
            problems.append("Maximum depth must be a whole number, or blank for unlimited.")
        }
        for pattern in include + exclude where (try? NSRegularExpression(pattern: pattern)) == nil {
            problems.append("Not a valid regular expression: \(pattern)")
        }
        if userAgent.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("The user agent cannot be empty.")
        }
        return problems
    }

    private var maxDepth: Int? {
        let text = maxDepthText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Int(text), value >= 0 else { return nil }
        return value
    }

    /// The crawl these settings describe.
    ///
    /// Numeric fields are clamped rather than rejected: a stepper can reach zero
    /// workers, and refusing to start is a worse answer than running one.
    public func config(seedURL: String) throws -> CrawlConfig {
        let problems = problems(seedURL: seedURL)
        if let first = problems.first { throw CrawlSettingsError.invalid(problems, first: first) }

        var config = CrawlConfig(seedURL: seedURL.trimmingCharacters(in: .whitespacesAndNewlines))
        config.workers = max(1, workers)
        config.maxPerHost = max(1, maxPerHost)
        config.timeout = max(1, timeout)
        config.userAgent = userAgent
        config.urlCap = max(1, urlCap)
        config.maxDepth = maxDepth
        config.respectRobots = respectRobots
        config.followInternalNofollow = followInternalNofollow
        config.crawlSubdomains = crawlSubdomains
        config.checkExternalLinks = checkExternalLinks
        config.checkImages = checkImages
        config.retainBodies = retainBodies
        config.include = include
        config.exclude = exclude
        return config
    }

    // MARK: Persistence

    static let defaultsKey = "crawlSettings"

    /// Last-used settings. A crawler's settings are per-person, not per-crawl:
    /// someone who has to ignore robots.txt on their staging site has to do it
    /// every time.
    public static func load(from defaults: UserDefaults = .standard) -> CrawlSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(CrawlSettings.self, from: data)
        else { return CrawlSettings() }
        return settings
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

public enum CrawlSettingsError: Error, CustomStringConvertible {
    case invalid([String], first: String)

    public var description: String {
        switch self {
        case .invalid(let problems, _): return problems.joined(separator: "\n")
        }
    }
}
