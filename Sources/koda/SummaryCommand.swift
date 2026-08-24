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
        print("")
        Crawl.printSummary(try store.summary(), elapsed: nil)
        Crawl.printFindings(try store.reportCounts())
    }
}
