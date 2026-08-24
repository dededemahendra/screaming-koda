import KodaCore
import KodaUI
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isShowingCrawlError = false

    private var controller: CrawlController { model.controller }

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            HSplitView {
                tableSide
                InspectorView(model: model)
                    .frame(maxHeight: .infinity)
            }
        }
        .toolbar { toolbar }
        .navigationTitle("Screaming Koda")
        .navigationSubtitle(subtitle)
        // WAL means these reads never block the writer, so the table can be
        // browsed while the crawl is still running.
        .task(id: controller.phase) {
            while controller.phase.isRunning {
                model.refresh()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            model.refresh()
        }
    }

    private var tableSide: some View {
        VStack(spacing: 0) {
            if let table = model.table {
                filterBar(table)
                Divider()
                // An NSScrollView has no intrinsic height, so without this SwiftUI
                // gives it a token size and all but the first few rows sit
                // scrolled out of view behind an auto-hidden scroller.
                ReportTableView(model: table) { row in
                    if let row { model.selectRow(at: row) } else { model.clearSelection() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No crawl yet", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Enter a URL and press Start, or open an existing .koda file.")
                )
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func filterBar(_ table: ReportTableModel) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(table.definition.qualifiedName).font(.headline)
                Text(table.definition.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(table.rowCount) rows").font(.caption).foregroundStyle(.secondary)
            TextField("Filter", text: Binding(get: { table.filter }, set: { table.setFilter($0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .padding(8)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            TextField("https://example.com/", text: $model.seedURL)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .onSubmit(start)
                .disabled(controller.phase.isRunning)
        }
        ToolbarItem {
            if controller.phase.isRunning {
                Button("Stop", systemImage: "stop.fill") { controller.stop() }
                    .disabled(controller.phase == .stopping)
            } else {
                Button(startLabel, systemImage: "play.fill", action: start)
                    .disabled(model.seedURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        ToolbarItem { ProgressSummary(model: model) }
    }

    private var startLabel: String {
        controller.phase == .stopped ? "Resume" : "Start"
    }

    private func start() {
        let seed = model.seedURL.trimmingCharacters(in: .whitespaces)
        guard !seed.isEmpty else { return }
        if controller.phase == .stopped, let path = controller.databasePath {
            var config = CrawlConfig(seedURL: seed)
            config.workers = 5
            controller.start(config: config, dbPath: path)
            return
        }
        model.reset()
        controller.start(config: CrawlConfig(seedURL: seed), dbPath: defaultDatabasePath(for: seed))
    }

    /// Named after the host, in the same place the CLI writes it, so the two
    /// halves of the tool can open each other's files.
    private func defaultDatabasePath(for seed: String) -> String? {
        guard let host = URLNormalizer.normalize(seed, relativeTo: nil)?.host else { return nil }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return directory.appendingPathComponent("\(host).koda").path
    }

    private var subtitle: String {
        switch controller.phase {
        case .idle: return "Ready"
        case .preparing: return "Fetching robots.txt"
        case .crawling: return "Crawling"
        case .stopping: return "Stopping after in-flight requests"
        case .finished: return controller.databasePath.map { ($0 as NSString).lastPathComponent } ?? "Finished"
        case .stopped: return "Stopped. Press Resume to continue."
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

/// Live counts, read from the database on the refresh timer rather than from the
/// engine's per-chunk callback, which on a site of slow pages is far too
/// infrequent to look alive.
struct ProgressSummary: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if model.controller.phase.isRunning {
                ProgressView().controlSize(.small)
            }
            if let counts = model.liveCounts {
                metric("Crawled", counts.done)
                metric("Queued", counts.queued)
                metric("Found", counts.total)
                if model.controller.phase.isRunning {
                    metric("URL/s", Int(model.controller.urlsPerSecond.rounded()))
                }
            }
        }
        .font(.caption.monospacedDigit())
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(.caption.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
