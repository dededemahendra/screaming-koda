import ArgumentParser
import Foundation
import KodaCore

struct Summary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the summary and findings for an already-crawled database."
    )

    @Option(name: .long, help: "Database path. Defaults to the only .koda file here.")
    var db: String?

    mutating func run() async throws {
        let path = try DatabaseLocator.resolve(explicit: db)
        let store = try Store(path: path)
        try store.migrate()

        print("\(path)")
        if let config = try store.loadConfig() {
            print("Seed: \(config.seedURL)")
        }
        // Whether the crawl ran to the end is the first thing worth knowing about
        // a stored file: every count below is a floor rather than a total if it
        // did not, and reading a partial crawl as the whole site is the mistake
        // this line exists to prevent.
        if let meta = try store.crawlMeta() {
            let when = meta.startedAt.formatted(date: .abbreviated, time: .shortened)
            if let duration = meta.duration {
                print("Ran:  \(when), finished in \(String(format: "%.1f", duration))s")
            } else {
                print("Ran:  \(when), stopped before it finished")
                let counts = try store.urlCounts()
                let outstanding = counts.queued + counts.inFlight
                if outstanding > 0 {
                    print("      \(outstanding) URLs never fetched. Crawl again with --resume to continue.")
                }
            }
        }
        print("")
        Crawl.printSummary(try store.summary(), elapsed: nil)
        Crawl.printFindings(try store.reportCounts())
    }
}
