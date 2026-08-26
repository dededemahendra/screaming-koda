import KodaCore
import SwiftUI

public enum ToolbarAction: Hashable, Sendable {
    case start, pause, resume, stop

    /// Which controls make sense in a given crawl state. A running crawl must
    /// never offer Start, or a second crawl could stomp the first.
    public static func available(for state: CrawlState) -> Set<ToolbarAction> {
        switch state {
        case .idle, .finished, .cancelled, .failed:
            return [.start]
        case .running:
            return [.pause, .stop]
        case .paused:
            return [.resume, .stop]
        }
    }
}

/// How the workspace shows a crawl. The table answers "which pages", the tree
/// answers "what is this site made of", and the graph answers "how does it hang
/// together" — three different questions rather than three skins.
public enum WorkspaceView: String, CaseIterable, Identifiable, Sendable {
    case table, tree, graph
    public var id: String { rawValue }

    var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .tree: return "list.bullet.indent"
        case .graph: return "point.3.connected.trianglepath.dotted"
        }
    }
}

public struct CrawlToolbar: View {
    @Bindable private var controller: CrawlController
    @Binding private var workspaceView: WorkspaceView
    private let onExport: (ExportScope, ExportFormat) -> Void
    @FocusState private var seedFocused: Bool

    public init(controller: CrawlController,
                workspaceView: Binding<WorkspaceView>,
                onExport: @escaping (ExportScope, ExportFormat) -> Void) {
        self.controller = controller
        _workspaceView = workspaceView
        self.onExport = onExport
    }

    private var actions: Set<ToolbarAction> { ToolbarAction.available(for: controller.state) }

    public var body: some View {
        HStack(spacing: Theme.Space.medium) {
            TextField("https://example.com/", text: $controller.seedURL)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .onSubmit { if actions.contains(.start) { Task { await controller.start() } } }
                .focused($seedFocused)
                .onAppear { seedFocused = controller.state == .idle && !controller.canExport }

            if actions.contains(.start) {
                Button("Start") { Task { await controller.start() } }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(controller.seedURL.isEmpty)
            }
            if actions.contains(.pause) {
                Button("Pause") { Task { await controller.pause() } }
            }
            if actions.contains(.resume) {
                Button("Resume") { Task { await controller.resume() } }
            }
            if actions.contains(.stop) {
                Button("Stop") { Task { await controller.stop() } }
            }

            Spacer()
            statusText.foregroundStyle(.secondary).font(Theme.Numeral.label)

            SettingsLink {
                Image(systemName: "slider.horizontal.3")
            }
            .help("Crawl settings")

            Picker("", selection: $workspaceView) {
                ForEach(WorkspaceView.allCases) { mode in
                    Image(systemName: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
            .help("Table, folder tree, or link graph")

            Menu {
                Button("Current view as CSV…") { onExport(.currentView, .csv) }
                Button("Current view as Excel…") { onExport(.currentView, .xlsx) }
                Divider()
                Button("All reports as Excel…") { onExport(.everything, .xlsx) }
                Button("All reports as CSV…") { onExport(.everything, .csv) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .frame(width: 44)
            .help("Export")
            .disabled(!controller.canExport)
        }
        .padding(Theme.Space.small)
    }

    private var statusText: Text {
        switch controller.state {
        case .idle:
            return Text("Ready")
        case .running, .paused:
            let p = controller.progress
            let label = controller.state == .paused ? "Paused" : "Crawling"
            return Text("\(label) — \(p?.crawled ?? 0) crawled, \(p?.queued ?? 0) queued")
        case .finished:
            return Text("Finished — \(shownCount) in \(controller.selectedReport.name)")
        case .cancelled:
            return Text("Stopped — \(shownCount) in \(controller.selectedReport.name)")
        case .failed(let reason):
            return Text("Failed — \(reason)")
        }
    }

    /// What the table is currently showing, which is no longer the same thing as
    /// how many URLs the crawl found.
    private var shownCount: String {
        let n = controller.rows?.count ?? 0
        return "\(n) row\(n == 1 ? "" : "s")"
    }
}
