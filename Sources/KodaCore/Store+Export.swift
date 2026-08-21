import Foundation

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

    /// Every report, each under its default filter. This is the "hand the whole
    /// audit to someone" path.
    public func exportAll(reports: [Report] = Reports.all) throws -> [ReportExport] {
        try reports.map { try export(report: $0, filter: $0.defaultFilter) }
    }
}
