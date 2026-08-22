import ArgumentParser
import Foundation
import KodaCore

@main
struct Koda: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "koda",
        abstract: "Crawl a site and report on it.",
        version: KodaCoreInfo.versionString,
        subcommands: [Crawl.self, Report.self, Export.self],
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
        let existed = FileManager.default.fileExists(atPath: path)
        if existed && !resume {
            try FileManager.default.removeItem(atPath: path)
        }

        // Resuming is safe because the frontier lives in SQLite: URLs already done
        // are never reclaimed, and anything a crash left in-flight is requeued.
        if resume && existed {
            print("Resuming \(url) → \(path)")
        } else {
            print("Crawling \(url) → \(path)")
        }
        if ignoreRobots { print("WARNING: ignoring robots.txt") }

        let started = Date()
        let store = try await CrawlSession.start(
            dbPath: path, config: config,
            client: URLSessionHTTPClient(), parser: SwiftSoupParser(),
            onProgress: { progress in
                // Padded so a shorter update fully overwrites a longer one; \r alone
                // leaves the tail of the previous line on screen.
                let text = "crawled \(progress.crawled)  queued \(progress.queued)  found \(progress.discovered)"
                FileHandle.standardError.write(
                    Data("\r\(text.padding(toLength: max(text.count, 60), withPad: " ", startingAt: 0))".utf8)
                )
            }
        )
        let elapsed = Date().timeIntervalSince(started)
        FileHandle.standardError.write(Data("\r\(String(repeating: " ", count: 60))\r".utf8))
        print()
        Self.printSummary(try store.summary(), elapsed: elapsed)
        Self.printFindings(try store.reportCounts())
    }

    static func printSummary(_ s: CrawlSummary, elapsed: TimeInterval) {
        func line(_ label: String, _ value: Any) {
            print("  \(label.padding(toLength: 26, withPad: " ", startingAt: 0)) \(value)")
        }
        print("Crawl finished in \(String(format: "%.1f", elapsed))s")
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
