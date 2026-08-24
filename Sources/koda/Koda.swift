import ArgumentParser
import Foundation
import KodaCore
import KodaRender

@main
struct Koda: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "koda",
        abstract: "Crawl a site and report on it.",
        version: KodaCoreInfo.versionString,
        subcommands: [Crawl.self, Export.self, Compare.self],
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

    @Option(name: .long, help: "Sitemap URL to seed from. Repeatable.")
    var sitemap: [String] = []

    @Flag(name: .long, help: "Do not read Sitemap: directives from robots.txt.")
    var noSitemapDiscovery = false

    @Flag(name: .long, help: "Crawl only the seed and sitemap URLs, following no links.")
    var listMode = false

    @Flag(name: .long, help: "Status-check stylesheets and scripts too.")
    var checkResources = false

    @Option(name: .long, help: "HTTP Basic user for a protected site.")
    var user: String?

    @Option(name: .long, help: "HTTP Basic password.")
    var password: String?

    @Option(name: .long, help: "Extra request header as Name:Value. Repeatable.")
    var header: [String] = []

    @Flag(name: .long, help: "Render pages in a browser engine before parsing. Much slower.")
    var render = false

    @Flag(name: .long, help: "Crawl as a phone: mobile user agent and viewport.")
    var mobile = false

    @Option(name: .long, help: "Response header to record for every page. Repeatable.")
    var extractHeader: [String] = []

    @Option(name: .long, help: "How many pages may render at once.")
    var renderConcurrency: Int = 2

    @Option(name: .long, help: "JavaScript extraction as Name=expression. Needs --render. Repeatable.")
    var js: [String] = []

    mutating func run() async throws {
        var config = CrawlConfig(seedURL: url)
        config.workers = workers
        config.urlCap = limit
        config.maxDepth = maxDepth
        config.respectRobots = !ignoreRobots
        config.sitemapURLs = sitemap
        config.discoverSitemaps = !noSitemapDiscovery
        config.listModeOnly = listMode
        config.checkResources = checkResources
        config.renderJavaScript = render
        config.mobile = mobile
        config.headerExtractions = extractHeader
        config.renderConcurrency = max(1, renderConcurrency)
        for entry in js {
            guard let split = entry.firstIndex(of: "=") else {
                throw ValidationError("JavaScript extraction must be Name=expression, not \(entry)")
            }
            let name = String(entry[..<split]).trimmingCharacters(in: .whitespaces)
            let expression = String(entry[entry.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !expression.isEmpty else {
                throw ValidationError("JavaScript extraction must be Name=expression, not \(entry)")
            }
            config.javaScriptExtractions.append(ExtractionRule(name: name, selector: expression))
        }
        if !config.javaScriptExtractions.isEmpty && !render {
            throw ValidationError("--js needs --render: there is no rendered DOM to evaluate against.")
        }
        config.basicAuthUser = user ?? ""
        config.basicAuthPassword = password ?? ""
        for entry in header {
            // Split on the first colon only: header values legitimately contain
            // colons, as any URL-valued header does.
            guard let split = entry.firstIndex(of: ":") else {
                throw ValidationError("Header must be Name:Value, not \(entry)")
            }
            let name = String(entry[..<split]).trimmingCharacters(in: .whitespaces)
            let value = String(entry[entry.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw ValidationError("Header name is empty in \(entry)") }
            config.extraHeaders[name] = value
        }

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
            // Constructed here, in the executable, and injected: KodaCore has no
            // WebKit dependency and cannot build one itself.
            renderer: render ? WebKitRenderer(poolSize: config.renderConcurrency,
                                              mobile: config.mobile,
                                              userAgent: config.effectiveUserAgent) : nil,
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


struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export a finished crawl to CSV or Excel.")

    @Argument(help: "Path to a .koda database.")
    var db: String

    @Option(name: .long, help: "Output path. A file for xlsx, a directory for csv.")
    var out: String?

    @Option(name: .long, help: "csv or xlsx.")
    var format: String = "xlsx"

    @Option(name: .long, help: "Export one report by id. Omit for all eleven.")
    var report: String?

    mutating func run() async throws {
        guard FileManager.default.fileExists(atPath: db) else {
            throw ValidationError("No crawl database at \(db)")
        }
        guard ["csv", "xlsx"].contains(format) else {
            throw ValidationError("Format must be csv or xlsx, not \(format)")
        }

        let store = try Store(path: db)
        try store.migrate()

        let reports: [Report]
        if let report {
            guard let match = Reports.all.first(where: { $0.id == report }) else {
                throw ValidationError("Unknown report \(report). "
                    + "Choose from: " + Reports.all.map(\.id).joined(separator: ", "))
            }
            reports = [match]
        } else {
            reports = Reports.all
        }

        // exportAll rather than mapping the reports: it leads with the crawl
        // overview, which is what a whole-crawl export should open on. Asking
        // for a single report skips it, since an overview of one report is just
        // that report.
        let exports = report == nil
            ? try store.exportAll(reports: reports)
            : try reports.map { try store.export(report: $0, filter: $0.defaultFilter) }
        let base = (db as NSString).deletingPathExtension
        let destination = out ?? (format == "xlsx" ? base + ".xlsx" : base + "-csv")

        if format == "xlsx" {
            try XLSXWriter.encode(exports).write(to: URL(fileURLWithPath: destination), options: .atomic)
            Crawl.logLine("Wrote \(exports.count) sheet(s) to \(destination)")
        } else if exports.count == 1 {
            try CSVWriter.encode(exports[0]).write(to: URL(fileURLWithPath: destination), options: .atomic)
            Crawl.logLine("Wrote \(destination)")
        } else {
            let directory = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for export in exports {
                let name = export.name.lowercased().replacingOccurrences(of: " ", with: "-")
                let url = directory.appendingPathComponent(name + ".csv")
                try CSVWriter.encode(export).write(to: url, options: .atomic)
            }
            Crawl.logLine("Wrote \(exports.count) files to \(destination)")
        }

        for export in exports {
            Crawl.logLine("  \(export.name): \(export.rows.count) rows")
        }
    }
}


struct Compare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare a crawl against an earlier one.")

    @Argument(help: "The current crawl.")
    var current: String

    @Argument(help: "The earlier crawl to compare it against.")
    var previous: String

    @Option(name: .long, help: "How many of each kind of change to list.")
    var limit: Int = 500

    @Flag(name: .long, help: "Write the changes as CSV to stdout instead of a summary.")
    var csv = false

    mutating func run() async throws {
        guard FileManager.default.fileExists(atPath: current) else {
            throw ValidationError("No crawl database at \(current)")
        }
        let store = try Store(path: current)
        try store.migrate()
        let diff = try store.compare(against: previous, limit: limit)

        if csv {
            let export = ReportExport(
                name: "Changes",
                headers: ["URL", "Field", "Before", "After"],
                rows: diff.changes.map { [$0.url, $0.field, $0.before, $0.after] }
                    + diff.added.map { [$0, "Added", nil, nil] }
                    + diff.removed.map { [$0, "Removed", nil, nil] })
            FileHandle.standardOutput.write(CSVWriter.encode(export, includeBOM: false))
            return
        }

        Crawl.logLine("Comparing \(current)")
        Crawl.logLine("     against \(previous)")
        Crawl.logLine("")
        if diff.isEmpty {
            Crawl.logLine("No differences.")
            return
        }
        Crawl.logLine("  Added    \(diff.addedTotal)")
        Crawl.logLine("  Removed  \(diff.removedTotal)")
        Crawl.logLine("  Changed  \(diff.changesTotal)")
        Crawl.logLine("")

        // Grouped by field, because "eleven titles changed" is the shape of the
        // answer people want before any individual URL is.
        let byField = Dictionary(grouping: diff.changes, by: \.field)
        for field in byField.keys.sorted() {
            Crawl.logLine("\(field): \(byField[field]?.count ?? 0)")
            for change in (byField[field] ?? []).prefix(5) {
                Crawl.logLine("  \(change.url)")
                Crawl.logLine("    was: \(change.before ?? "—")")
                Crawl.logLine("    now: \(change.after ?? "—")")
            }
            if (byField[field]?.count ?? 0) > 5 { Crawl.logLine("  …") }
        }
        for (label, list, total) in [("Added", diff.added, diff.addedTotal),
                                     ("Removed", diff.removed, diff.removedTotal)]
        where total > 0 {
            Crawl.logLine("")
            Crawl.logLine("\(label): \(total)")
            for url in list.prefix(10) { Crawl.logLine("  \(url)") }
            if total > 10 { Crawl.logLine("  …") }
        }
    }
}
