import ArgumentParser
import Foundation
import KodaCore

@main
struct Koda: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "koda",
        abstract: "Crawl a site and report on it.",
        version: KodaCoreInfo.versionString,
        subcommands: [Crawl.self, Report.self, Export.self, Summary.self],
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

    @Flag(name: .long, help: "Continue an existing database instead of starting over.")
    var resume = false

    @Option(name: .long, parsing: .singleValue,
            help: "Only crawl URLs matching this regex. Repeatable; any match qualifies.")
    var include: [String] = []

    @Option(name: .long, parsing: .singleValue,
            help: "Never crawl URLs matching this regex. Repeatable; wins over --include.")
    var exclude: [String] = []

    @Flag(name: .long, help: "Also crawl subdomains of the seed host.")
    var subdomains = false

    @Option(name: .long, help: "Maximum concurrent requests to any one host.")
    var maxPerHost: Int = 5

    @Option(name: .long, help: "Request timeout in seconds.")
    var timeout: Double = 20

    @Option(name: .long, help: "User agent to identify as.")
    var userAgent: String = KodaCoreInfo.userAgent

    @Flag(name: .long, help: "Follow internal links marked rel=nofollow.")
    var followNofollow = false

    @Flag(name: .long, help: "Skip status-checking external links.")
    var skipExternal = false

    @Flag(name: .long, help: "Skip status-checking images.")
    var skipImages = false

    @Flag(name: .long, help: "Do not store page bodies in the database.")
    var noBodies = false

    mutating func run() async throws {
        var config = CrawlConfig(seedURL: url)
        config.workers = workers
        config.urlCap = limit
        config.maxDepth = maxDepth
        config.respectRobots = !ignoreRobots
        config.include = include
        config.exclude = exclude
        config.crawlSubdomains = subdomains
        config.maxPerHost = maxPerHost
        config.timeout = timeout
        config.userAgent = userAgent
        config.followInternalNofollow = followNofollow
        config.checkExternalLinks = !skipExternal
        config.checkImages = !skipImages
        config.retainBodies = !noBodies

        for pattern in include + exclude {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw ValidationError("Not a valid regular expression: \(pattern)")
            }
        }

        guard let host = config.seedHost, let seed = config.normalizedSeedURL else {
            throw ValidationError("Not a crawlable http(s) URL: \(url)")
        }
        // Recorded and printed in the form it will be fetched in, so a seed typed
        // without a scheme does not leave crawl_meta disagreeing with the crawl.
        config.seedURL = seed

        let path = db ?? FileManager.default.currentDirectoryPath + "/\(host).koda"
        let existed = FileManager.default.fileExists(atPath: path)
        if existed && !resume {
            try Store.removeDatabase(at: path)
        }

        // Resuming is safe because the frontier lives in SQLite: URLs already done
        // are never reclaimed, and anything a crash left in-flight is requeued.
        if resume && existed {
            print("Resuming \(seed) → \(path)")
        } else {
            print("Crawling \(seed) → \(path)")
        }
        if ignoreRobots { print("WARNING: ignoring robots.txt") }

        let started = Date()
        let store = try await CrawlSession.start(
            dbPath: path, config: config,
            client: URLSessionHTTPClient(), parser: SwiftSoupParser(),
            onProgress: { progress in
                let text = progress.stage == .checking
                    ? "checking links and images  \(progress.checked) checked"
                    : "crawled \(progress.crawled)  queued \(progress.queued)  found \(progress.discovered)"
                FileHandle.standardError.write(Data(Progress.line(text).utf8))
            }
        )
        let elapsed = Date().timeIntervalSince(started)
        Progress.clear()
        print()
        Self.printSummary(try store.summary(), elapsed: elapsed)
        Self.printFindings(try store.reportCounts())
    }

    static func printSummary(_ s: CrawlSummary, elapsed: TimeInterval?) {
        func line(_ label: String, _ value: Any) {
            print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(value)")
        }
        if let elapsed {
            print("Crawl finished in \(String(format: "%.1f", elapsed))s")
        }
        print("\nURLs")
        line("Total discovered", s.totalURLs)
        line("Crawled", s.crawledURLs)
        line("Internal", s.internalURLs)
        line("External", s.externalURLs)
        line("Max depth", s.maxDepth)
        print("\nResponses")
        for key in s.byStatusClass.keys.sorted() {
            line(key, s.byStatusClass[key] ?? 0)
        }
        if s.transportErrors > 0 { line("Transport errors", s.transportErrors) }
    }

    /// Every report that found something, grouped as the tabs will be. Listing only
    /// non-empty reports keeps the tail of a crawl short on a clean site while still
    /// surfacing everything on a messy one.
    static func printFindings(_ counts: [String: Int]) {
        let found = ReportCatalogue.issues.filter { (counts[$0.id] ?? 0) > 0 }
        guard !found.isEmpty else {
            print("\nNo findings.")
            return
        }
        print("\nFindings")
        for group in ReportCatalogue.groups {
            let reports = found.filter { $0.group == group }
            guard !reports.isEmpty else { continue }
            print("  \(group)")
            for report in reports {
                let id = report.id.padding(toLength: 28, withPad: " ", startingAt: 0)
                print("    \(id) \(counts[report.id] ?? 0)")
            }
        }
        print("\nRun 'koda report <id>' to see one, or 'koda export' to write them all to CSV.")
    }
}
