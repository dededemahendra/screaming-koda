import ArgumentParser
import Foundation
import KodaCore

@main
struct Koda: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "koda",
        abstract: "Crawl a site and report on it.",
        version: KodaCoreInfo.versionString,
        subcommands: [Crawl.self],
        defaultSubcommand: Crawl.self
    )
}

struct Crawl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Crawl a site into a .koda database.")

    @Argument(help: "Seed URL, for example https://example.com/")
    var url: String

    @Option(name: .long, help: "Database path. Defaults to a file named after the host.")
    var db: String?

    @Option(name: .long, help: "Concurrent workers.")
    var workers: Int = 5

    @Option(name: .long, help: "Stop after this many URLs.")
    var limit: Int = 500_000

    @Option(name: .long, help: "Maximum crawl depth.")
    var maxDepth: Int?

    @Flag(name: .long, help: "Ignore robots.txt. Use only on sites you control.")
    var ignoreRobots = false

    mutating func run() async throws {
        var config = CrawlConfig(seedURL: url)
        config.workers = workers
        config.urlCap = limit
        config.maxDepth = maxDepth
        config.respectRobots = !ignoreRobots

        guard let host = config.seedHost else {
            throw ValidationError("Not a crawlable http(s) URL: \(url)")
        }
        let path = db ?? FileManager.default.currentDirectoryPath + "/\(host).koda"
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }

        print("Crawling \(url) → \(path)")
        if ignoreRobots { print("WARNING: ignoring robots.txt") }

        let started = Date()
        let (store, robotsOutcome) = try await CrawlSession.start(
            dbPath: path, config: config,
            client: URLSessionHTTPClient(), parser: SwiftSoupParser(),
            onProgress: { progress in
                FileHandle.standardError.write(
                    Data("\rcrawled \(progress.crawled)  queued \(progress.queued)".utf8)
                )
            }
        )
        let elapsed = Date().timeIntervalSince(started)
        print("\n")

        if case .unreachable(let reason) = robotsOutcome {
            Self.printRobotsUnreachableWarning(reason: reason)
        }

        Self.printSummary(try store.summary(), elapsed: elapsed)
    }

    /// robots.txt being unreachable (a 5xx or a transport failure) is treated as
    /// disallow-all rather than as consent to crawl — see `RobotsFetchOutcome`. That means
    /// a crawl can legitimately come back with zero (or very few) pages, and a user seeing
    /// an empty summary with no explanation would reasonably conclude the tool is broken.
    /// This warning is what stands between "the site's robots.txt was down" and a bug report.
    static func printRobotsUnreachableWarning(reason: String) {
        print("""
        ============================================================
        WARNING: robots.txt could not be fetched (\(reason)).

        Per RFC 9309, a robots.txt fetch failure is not treated as
        permission to crawl. This crawl was therefore restricted to
        disallow-all, and likely returned zero (or very few) pages —
        that is expected given the failure, not a bug.

        If you own this site and want to crawl anyway, rerun with
        --ignore-robots.
        ============================================================

        """)
    }

    static func printSummary(_ s: CrawlSummary, elapsed: TimeInterval) {
        func line(_ label: String, _ value: Any) {
            print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(value)")
        }
        print("Crawl finished in \(String(format: "%.1f", elapsed))s")
        print("\nURLs")
        line("Total discovered", s.totalURLs)
        line("Internal", s.internalURLs)
        line("External", s.externalURLs)
        line("Max depth", s.maxDepth)
        print("\nResponses")
        for key in s.byStatusClass.keys.sorted() {
            line(key, s.byStatusClass[key] ?? 0)
        }
        if s.transportErrors > 0 { line("Transport errors", s.transportErrors) }
        print("\nIssues")
        line("Missing titles", s.missingTitles)
        line("Duplicate titles", s.duplicateTitles)
        line("Missing meta descriptions", s.missingDescriptions)
        line("Missing H1", s.missingH1)
        line("Images missing alt", s.imagesMissingAlt)
    }
}
