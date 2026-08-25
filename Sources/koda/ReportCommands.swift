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

enum ExportFormat: String, ExpressibleByArgument, CaseIterable {
    /// One file per report. The format anything can read, and the default.
    case csv
    /// One workbook, one tab per report. For sending someone the whole crawl.
    case xlsx
}

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Write every report with findings to CSV files or one spreadsheet."
    )

    @Option(name: .long, help: "Database path. Defaults to the only .koda file here.")
    var db: String?

    @Option(name: .long, help: "csv writes a directory of files; xlsx writes one workbook.")
    var format: ExportFormat = .csv

    @Option(name: .long, help: "Output path. Defaults to koda-reports, or koda-reports.xlsx.")
    var out: String?

    mutating func run() async throws {
        let store = try Store(path: try DatabaseLocator.resolve(explicit: db))
        try store.migrate()

        switch format {
        case .csv:
            let directory = out ?? "koda-reports"
            let written = try store.writeAllCSVs(to: directory)
            if written.isEmpty {
                print("No findings to export.")
                return
            }
            print("Wrote \(written.count) \(written.count == 1 ? "report" : "reports") to \(directory)/")
            for path in written {
                print("  \((path as NSString).lastPathComponent)")
            }

        case .xlsx:
            let path = out ?? "koda-reports.xlsx"
            try store.writeXLSX(to: path)
            let tabs = try store.reportCounts().values.filter { $0 > 0 }.count
            print("Wrote \(tabs + 1) \(tabs == 0 ? "tab" : "tabs") to \(path)")
        }
    }
}
