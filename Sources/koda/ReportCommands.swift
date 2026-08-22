import ArgumentParser
import Foundation
import KodaCore

struct Report: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List reports, or run one against a crawled database."
    )

    @Argument(help: "Report id. Omit to list every report with its finding count.")
    var id: String?

    @Option(name: .long, help: "Database path. Defaults to the only .koda file here.")
    var db: String?

    @Option(name: .long, help: "Maximum rows to print.")
    var limit: Int = 50

    @Flag(name: .long, help: "Print CSV instead of a table.")
    var csv = false

    @Flag(name: .long, help: "When listing, include reports with no findings.")
    var all = false

    mutating func run() async throws {
        let store = try Store(path: try DatabaseLocator.resolve(explicit: db))
        try store.migrate()

        guard let id else {
            try listReports(store)
            return
        }
        guard let definition = ReportCatalogue.report(id: id) else {
            throw ValidationError("Unknown report '\(id)'. Run 'koda report' to list them.")
        }

        if csv {
            print(try store.csv(for: definition), terminator: "")
            return
        }

        let total = try store.reportCount(definition)
        let rows = try store.runReport(definition, limit: limit)
        print("\(definition.qualifiedName)  (\(total) \(total == 1 ? "row" : "rows"))")
        print(definition.summary)
        print("")
        if rows.isEmpty {
            print("Nothing found.")
        } else {
            print(TextTable.render(columns: definition.columns, rows: rows))
            if total > rows.count {
                print("\n… \(total - rows.count) more. Use --limit, or --csv for everything.")
            }
        }
    }

    private func listReports(_ store: Store) throws {
        let counts = try store.reportCounts()
        for group in ReportCatalogue.groups {
            let reports = ReportCatalogue.reports(in: group)
                .filter { all || (counts[$0.id] ?? 0) > 0 }
            guard !reports.isEmpty else { continue }
            print("\n\(group)")
            for report in reports {
                let count = counts[report.id] ?? 0
                let id = report.id.padding(toLength: 30, withPad: " ", startingAt: 0)
                print("  \(id) \(String(count).padding(toLength: 8, withPad: " ", startingAt: 0)) \(report.name)")
            }
        }
        if !all {
            print("\nOnly reports with rows are shown. Use --all to see every report.")
        }
        print("Run 'koda report <id>' to see one.")
    }
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write every report with findings to CSV files."
    )

    @Option(name: .long, help: "Database path. Defaults to the only .koda file here.")
    var db: String?

    @Option(name: .long, help: "Output directory.")
    var out: String = "koda-reports"

    mutating func run() async throws {
        let store = try Store(path: try DatabaseLocator.resolve(explicit: db))
        try store.migrate()

        let written = try store.writeAllCSVs(to: out)
        if written.isEmpty {
            print("No findings to export.")
            return
        }
        print("Wrote \(written.count) \(written.count == 1 ? "report" : "reports") to \(out)/")
        for path in written {
            print("  \((path as NSString).lastPathComponent)")
        }
    }
}
