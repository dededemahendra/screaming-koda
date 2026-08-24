import Foundation
import KodaCore
import Observation

/// Top-level window state: the crawl, which report is showing, what is selected.
@MainActor
@Observable
public final class AppModel {
    public let controller: CrawlController

    public private(set) var table: ReportTableModel?
    public private(set) var reportCounts: [String: Int] = [:]
    public private(set) var summary: CrawlSummary?
    public private(set) var selectedReportID: String
    public private(set) var selectedDetail: URLDetail?
    public private(set) var inlinks: [LinkRow] = []
    public private(set) var outlinks: [LinkRow] = []
    public private(set) var selectedImages: [ImageRow] = []
    public private(set) var errorMessage: String?

    /// Frontier counts read from the database on the refresh timer.
    ///
    /// The engine reports progress once per chunk, which on a site of slow pages
    /// can be minutes apart and makes a working crawl look stalled. These come
    /// from the same 2Hz read the table uses, so the counters move even when the
    /// engine has nothing new to say.
    public private(set) var liveCounts: (queued: Int, inFlight: Int, done: Int, total: Int)?

    /// What the toolbar field holds. Not the crawl's seed until Start is pressed.
    public var seedURL: String = ""
    /// Hide reports with nothing in them, which is most of them on a healthy site.
    public var showsEmptyReports = false

    public init(controller: CrawlController = CrawlController()) {
        self.controller = controller
        self.selectedReportID = ReportCatalogue.all.first?.id ?? ""
    }

    public var store: Store? { controller.store }

    /// Groups that have at least one visible report, so the sidebar does not show
    /// eight empty headings on a clean site.
    public var visibleGroups: [(group: String, reports: [ReportDefinition])] {
        ReportCatalogue.groups.compactMap { group in
            let reports = ReportCatalogue.reports(in: group).filter {
                showsEmptyReports || (reportCounts[$0.id] ?? 0) > 0 || $0.id == selectedReportID
            }
            return reports.isEmpty ? nil : (group, reports)
        }
    }

    public func select(reportID: String) {
        guard let definition = ReportCatalogue.report(id: reportID) else { return }
        selectedReportID = reportID
        table?.show(definition)
        clearSelection()
    }

    public func selectRow(at index: Int) {
        guard let store, let url = table?.url(at: index) else {
            clearSelection()
            return
        }
        do {
            guard let id = try store.urlID(for: url), let detail = try store.urlDetail(id: id) else {
                clearSelection()
                return
            }
            selectedDetail = detail
            inlinks = try store.inlinks(to: id)
            outlinks = try store.outlinks(from: id)
            selectedImages = try store.images(on: id)
        } catch {
            errorMessage = String(describing: error)
            clearSelection()
        }
    }

    public func clearSelection() {
        selectedDetail = nil
        inlinks = []
        outlinks = []
        selectedImages = []
    }

    /// Re-reads counts and the visible table. Called on a throttled timer while a
    /// crawl is running: WAL means these reads never block the writer.
    public func refresh() {
        guard let store else { return }
        do {
            if table == nil, let definition = ReportCatalogue.report(id: selectedReportID) {
                table = ReportTableModel(store: store, definition: definition)
            }
            liveCounts = try store.urlCounts()
            reportCounts = try store.reportCounts()
            summary = try store.summary()
            table?.reload()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Called when a crawl is started so stale results do not linger on screen.
    public func reset() {
        table = nil
        reportCounts = [:]
        summary = nil
        liveCounts = nil
        clearSelection()
        errorMessage = nil
    }
}
