import Foundation
import GRDB

/// A report, flattened for writing to a file. One shape, two encoders — CSV and
/// XLSX cannot disagree about what a report contains because neither has its own
/// query path.
public struct ReportExport: Sendable, Equatable {
    /// The report's name; becomes the sheet name or the file's basename.
    public let name: String
    public let headers: [String]
    /// nil is a genuine NULL, and stays distinguishable from an empty string all
    /// the way to the file.
    public let rows: [[String?]]

    public init(name: String, headers: [String], rows: [[String?]]) {
        self.name = name
        self.headers = headers
        self.rows = rows
    }
}

extension Store {
    /// How many rows to fetch per round trip. The same page size the table uses:
    /// a whole-crawl export at 500,000 URLs across eleven reports must not
    /// materialise one enormous result set.
    static let exportPageSize = 200

    /// Reads through `ids` and `rows` — the same two functions the table uses —
    /// so an exported file and the table it came from cannot disagree.
    public func export(report: Report, filter: ReportFilter,
                       sortBy: ReportColumn? = nil, ascending: Bool = true,
                       limit: Int? = nil) throws -> ReportExport {
        var ids = try ids(for: report, filter: filter, sortBy: sortBy, ascending: ascending)
        if let limit, ids.count > limit { ids = Array(ids.prefix(limit)) }

        var out: [[String?]] = []
        out.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: Self.exportPageSize) {
            let page = Array(ids[start..<min(start + Self.exportPageSize, ids.count)])
            out.append(contentsOf: try rows(ids: page, columns: report.columns).map(\.cells))
        }
        return ReportExport(name: report.name,
                            headers: report.columns.map(\.header),
                            rows: out)
    }

    /// Every report, each under its default filter, led by an overview.
    ///
    /// This is the "hand the whole audit to someone" path, and the person it
    /// gets handed to opens the first sheet. An overview that names the crawl
    /// and counts every issue is a far better first sheet than a list of every
    /// internal URL.
    public func exportAll(reports: [Report] = Reports.all) throws -> [ReportExport] {
        try [overview(reports: reports)] + reports.map {
            try export(report: $0, filter: $0.defaultFilter)
        }
    }

    /// A summary sheet: what was crawled, and how many rows each issue filter
    /// found. Built from the same `counts` the sidebar uses, so the workbook and
    /// the window can never disagree.
    public func overview(reports: [Report] = Reports.all) throws -> ReportExport {
        var rows: [[String?]] = []
        let meta = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT seed_url, started_at, finished_at FROM crawl_meta WHERE id = 1")
        }
        func date(_ value: Double?) -> String? {
            guard let value, value > 0 else { return nil }
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: value))
        }
        rows.append(["Crawl", "Seed URL", meta?["seed_url"]])
        rows.append(["Crawl", "Started", date(meta?["started_at"])])
        rows.append(["Crawl", "Finished", date(meta?["finished_at"]) ?? "did not finish"])

        let summary = try summary()
        rows.append(["URLs", "Total", String(summary.totalURLs)])
        rows.append(["URLs", "Internal", String(summary.internalURLs)])
        rows.append(["URLs", "External", String(summary.externalURLs)])
        rows.append(["URLs", "Max depth", String(summary.maxDepth)])
        for key in summary.byStatusClass.keys.sorted() {
            rows.append(["Responses", key, String(summary.byStatusClass[key] ?? 0)])
        }
        rows.append(["Responses", "Transport errors", String(summary.transportErrors)])

        // Only findings, only the ones that found something, in the same order
        // the window ranks them: a summary listing 150 rows of zero is not a
        // summary, and one in report order buries the 5xx under the alt text.
        let counts = try counts(for: reports)
        for band in Severity.allCases {
            for report in reports {
                for filter in report.filters where filter.severity == band {
                    let found = counts["\(report.id).\(filter.id)"] ?? 0
                    if found > 0 {
                        rows.append([band.title, "\(report.name): \(filter.name)", String(found)])
                    }
                }
            }
        }
        return ReportExport(name: "Overview",
                            headers: ["Section", "Item", "Value"], rows: rows)
    }
}
