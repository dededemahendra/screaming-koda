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

public struct ContentView: View {
    @State private var controller: CrawlController

    public init(controller: CrawlController = CrawlController()) {
        _controller = State(initialValue: controller)
    }

    private var actions: Set<ToolbarAction> { ToolbarAction.available(for: controller.state) }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let notice = controller.notice {
                noticeBanner(notice)
                Divider()
            }
            HSplitView {
                SidebarView(counts: controller.counts,
                            selectedReportID: controller.selectedReportID,
                            selectedFilterID: controller.selectedFilterID,
                            onSelect: { report, filter in
                                controller.select(reportID: report, filterID: filter)
                            })
                VSplitView {
                    URLTableView(rows: controller.rows,
                                 report: controller.selectedReport,
                                 revision: controller.revision,
                                 onSortChange: { columnID, ascending in
                                     controller.applySort(columnID: columnID, ascending: ascending)
                                 },
                                 onSelect: { controller.selectRow(id: $0) })
                        .frame(minHeight: 220)
                    InspectorView(detail: controller.detail,
                                  inlinks: controller.inlinks,
                                  outlinks: controller.outlinks,
                                  images: controller.images)
                }
                .frame(minWidth: 640)
            }
        }
        .frame(minWidth: 1100, minHeight: 660)
        .sheet(item: Binding(
            get: { controller.pendingExistingCrawl },
            set: { if $0 == nil { controller.cancelPending() } }
        )) { existing in
            VStack(alignment: .leading, spacing: 14) {
                Text("A crawl of \(existing.host) already exists")
                    .font(.headline)
                Text("\(existing.urlCount) URLs, last updated \(existing.modifiedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .foregroundStyle(.secondary)
                Text("Resuming continues where it stopped. A finished crawl simply opens for browsing. Replacing deletes it permanently.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { controller.cancelPending() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Replace") { Task { await controller.replacePending() } }
                    Button("Resume") { Task { await controller.resumePending() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("https://example.com/", text: $controller.seedURL)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
                .onSubmit { if actions.contains(.start) { Task { await controller.start() } } }

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
            statusText.foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(10)
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

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
