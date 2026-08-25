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
    /// What the next crawl will run with. Persisted, because someone who has to
    /// ignore robots.txt on their staging site has to do it every time.
    public var settings: CrawlSettings
    /// What the open database was actually crawled with, from `crawl_meta`.
    public private(set) var openConfig: CrawlConfig?

    private let defaults: UserDefaults

    public init(controller: CrawlController = CrawlController(), defaults: UserDefaults = .standard) {
        self.controller = controller
        self.defaults = defaults
        self.settings = CrawlSettings.load(from: defaults)
        self.selectedReportID = ReportCatalogue.all.first?.id ?? ""
    }

    /// True when Start would continue the open crawl rather than begin a new one.
    /// Changing the URL means a new crawl: resuming into a different site's
    /// frontier is never what was meant.
    public var canResume: Bool {
        guard controller.phase == .stopped, controller.databasePath != nil,
              let openConfig else { return false }
        return Self.sameURL(openConfig.seedURL, seedURL)
    }

    /// Starts a crawl, or continues the open one.
    ///
    /// Resuming replays the config the crawl was started with rather than what
    /// the form currently says. The frontier has already been filtered by those
    /// include and exclude rules, so draining the rest under different ones would
    /// leave a database that no longer matches its own `crawl_meta`.
    @discardableResult
    public func startCrawl(databasePath: String? = nil) -> Bool {
        if canResume, let openConfig {
            controller.resume(config: openConfig)
            return true
        }
        do {
            let config = try settings.config(seedURL: seedURL)
            guard let path = databasePath ?? Self.defaultDatabasePath(for: config.seedURL) else {
                errorMessage = "Could not work out where to put the crawl for \(config.seedURL)."
                return false
            }
            settings.save(to: defaults)
            reset()
            openConfig = config
            controller.start(config: config, dbPath: path)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    /// Opens a finished crawl for browsing, and adopts the settings it ran with
    /// so the form describes what is on screen rather than the app's defaults.
    public func openDatabase(path: String) throws {
        reset()
        try controller.open(path: path)
        if let config = try store?.loadConfig() {
            openConfig = config
            seedURL = config.seedURL
            settings = CrawlSettings(from: config)
        }
        refresh()
    }

    /// Where a new crawl of `seed` goes by default: named after the host, beside
    /// the ones the CLI writes, so the two halves of the tool open each other's files.
    public static func defaultDatabasePath(for seed: String, in directory: URL? = nil) -> String? {
        guard let host = URLNormalizer.normalize(seed, relativeTo: nil)?.host else { return nil }
        let base = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent("\(host).koda").path
    }

    private static func sameURL(_ a: String, _ b: String) -> Bool {
        guard let left = URLNormalizer.normalize(a, relativeTo: nil),
              let right = URLNormalizer.normalize(b, relativeTo: nil) else { return false }
        return left.absoluteString == right.absoluteString
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

    public func clearError() {
        errorMessage = nil
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
