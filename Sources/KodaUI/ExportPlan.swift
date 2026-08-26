import Foundation
import KodaCore

/// Everything an export needs, captured on the main actor so the work itself
/// does not have to run there.
///
/// `Store` is `@unchecked Sendable` and `ReportExport` is `Sendable`, so both
/// can cross actor boundaries safely — the only thing that genuinely belongs
/// on the main actor is reading what the user is currently looking at, which
/// is why `CrawlController.exportPlan(scope:)` resolves that up front and
/// hands back a value this can run anywhere.
public struct ExportPlan: Sendable {
    private enum Query: Sendable {
        /// The report, filter, sort column and direction resolved from
        /// `RowIndex` at capture time — the same view the user is looking at.
        case currentView(report: Report, filter: ReportFilter, sortColumn: ReportColumn?, ascending: Bool)
        /// Every report, under its default filter, as `Store.exportAll` builds it.
        case everything(reports: [Report])
    }

    private let store: Store
    private let query: Query

    init(store: Store, report: Report, filter: ReportFilter, sortColumn: ReportColumn?, ascending: Bool) {
        self.store = store
        self.query = .currentView(report: report, filter: filter, sortColumn: sortColumn, ascending: ascending)
    }

    init(store: Store, reports: [Report]) {
        self.store = store
        self.query = .everything(reports: reports)
    }

    /// Runs the queries and writes the files. Returns what it wrote; an empty
    /// result means there was nothing to export. Never call this on the main actor.
    public func run(format: ExportFormat, to destination: URL,
                    host: String?, date: Date) throws -> [URL] {
        let exports: [ReportExport]
        switch query {
        case .currentView(let report, let filter, let sortColumn, let ascending):
            exports = [try store.export(report: report, filter: filter,
                                        sortBy: sortColumn, ascending: ascending)]
        case .everything(let reports):
            exports = try store.exportAll(reports: reports)
        }
        guard !exports.isEmpty else { return [] }
        return try ExportCommands.write(exports, format: format, to: destination, host: host, date: date)
    }
}
