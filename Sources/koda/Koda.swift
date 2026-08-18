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
            // Resuming an existing crawl is deferred to M2 — for now, re-crawling into the
            // same path replaces whatever was there. That's an accepted M1 behavior, but it
            // must never be silent: a user re-running a crawl later to compare results would
            // otherwise lose the previous crawl with no indication it happened.
            Self.logLine("Existing crawl database found at \(path) — replacing it.")
            Self.logLine("(Resuming an existing crawl is not supported yet; the previous crawl's data will be lost.)")
            try FileManager.default.removeItem(atPath: path)
        }

        Self.logLine("Crawling \(url) → \(path)")
        if ignoreRobots { Self.logLine("WARNING: ignoring robots.txt") }

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
        // The progress line above ends with a bare `\r` and no trailing newline — leaving
        // the cursor mid-line. Terminate it on the SAME stream (stderr) it was written on,
        // before anything else prints, so the next thing to appear (a robots warning, or the
        // summary's first line) always starts on a fresh line rather than being appended to
        // — or, worse, visually overwritten by — the dangling progress text.
        FileHandle.standardError.write(Data("\n".utf8))

        if case .unreachable(let reason) = robotsOutcome {
            Self.printRobotsUnreachableWarning(reason: reason)
        }

        let summary = try store.summary()
        // robots.txt can be fetched and parsed just fine and simply say `Disallow: /`
        // for everyone — staging sites, or sites that allowlist only specific bots, do
        // this legitimately, and it's more common in practice than the unreachable case
        // above. That produces a crawl that fetched nothing, which looks identical to a
        // broken tool unless something says otherwise. A fetch was attempted for every
        // URL the engine processed (even a transport failure records a status = 0
        // response row), so zero rows in `responses` while robots.txt was reachable and
        // parsed is a reliable signal that robots itself is why nothing was crawled.
        let totalResponses = summary.byStatusClass.values.reduce(0, +) + summary.transportErrors
        if robotsOutcome == .parsed, totalResponses == 0 {
            Self.printRobotsDisallowedAllWarning()
        }

        Self.printSummary(summary, elapsed: elapsed)
    }

    /// Writes one diagnostic/commentary line to stderr, terminated with `\n`.
    ///
    /// All of the CLI's running commentary — the crawl header, the existing-database
    /// overwrite notice, the robots-ignored warning, the robots-unreachable warning — goes
    /// through here rather than `print` (stdout). Reasons, per Task 11 review finding 4:
    ///
    /// 1. It puts this text on the same stream, and through the same unbuffered
    ///    `FileHandle.write` call, as the progress line's `\r`-prefixed updates. `print` to
    ///    stdout is buffered — fully block-buffered whenever stdout isn't a live tty — so
    ///    mixing it with unbuffered stderr writes let a progress update land in front of
    ///    still-buffered warning text and visually erase it. Since the header/notices are
    ///    written strictly before the crawl (and its concurrent `onProgress` calls) starts,
    ///    routing them through the same stream and write mechanism as progress guarantees
    ///    they hit the terminal first, deterministically, regardless of buffering.
    /// 2. It keeps stdout reserved for the one thing meant to be redirected or piped: the
    ///    final summary. A caller who runs `koda crawl ... > report.txt` gets a clean report
    ///    with none of the running commentary mixed in.
    static func logLine(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// robots.txt being unreachable (a 5xx or a transport failure) is treated as
    /// disallow-all rather than as consent to crawl — see `RobotsFetchOutcome`. That means
    /// a crawl can legitimately come back with zero (or very few) pages, and a user seeing
    /// an empty summary with no explanation would reasonably conclude the tool is broken.
    /// This warning is what stands between "the site's robots.txt was down" and a bug report.
    static func printRobotsUnreachableWarning(reason: String) {
        Self.logLine("""
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

    /// A robots.txt that was fetched and parsed without any trouble can still disallow
    /// every path for this crawler — that's a legitimate, deliberate configuration (a
    /// staging site, or a site that allowlists only specific named bots), not a fetch
    /// failure. It produces exactly the same empty-looking summary as a broken crawl, so
    /// without this warning the user has no way to tell "the tool is broken" apart from
    /// "the site said no."
    static func printRobotsDisallowedAllWarning() {
        Self.logLine("""
        ============================================================
        WARNING: robots.txt was fetched and parsed successfully, but
        it disallows this crawler from every page on the site.

        No pages could be fetched as a result — that is expected
        given robots.txt, not a bug.

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
