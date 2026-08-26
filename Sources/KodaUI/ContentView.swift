import AppKit
import KodaCore
import SwiftUI

public struct ContentView: View {
    @State private var controller: CrawlController
    @State private var view: WorkspaceView = .table

    public init(controller: CrawlController = CrawlController()) {
        _controller = State(initialValue: controller)
    }

    public var body: some View {
        VStack(spacing: 0) {
            CrawlToolbar(controller: controller,
                         workspaceView: $view,
                         onExport: { scope, format in export(scope: scope, format: format) })
            Divider()
            if let notice = controller.notice {
                noticeBanner(notice)
                Divider()
            }
            // A plain `HStack` with a fixed-width sidebar. Both split views were
            // tried and both drop half the window, which is measured rather than
            // guessed — distinct colours in the top 60pt (the bar) against the
            // body below it:
            //
            //   HStack               bar 143   body 130
            //   NavigationSplitView  bar   3   body 126
            //   HSplitView           bar 109   body   3
            //
            // `NavigationSplitView` expects to be the window's root and lays
            // itself out against the whole window, so nested under a bar it drew
            // straight over it and the app shipped with no seed field to type
            // into. `HSplitView` leaves the bar alone but renders nothing in its
            // own panes here. The `HStack` is the only arrangement where the
            // whole window draws.
            //
            // The original sidebar complaint was never the container's fault
            // either: the old frame was `minWidth: 210, idealWidth: 240` with no
            // maximum, so nothing capped it and it took half the window. A fixed
            // width is what the design asked for, and it costs a draggable
            // divider — worth it for a window that renders.
            HStack(spacing: 0) {
                IssueSidebar(reports: controller.availableReports,
                             counts: controller.counts,
                             crawlName: controller.crawlHost,
                             selectedReportID: controller.selectedReportID,
                             selectedFilterID: controller.selectedFilterID,
                             onSelect: { report, filter in
                                 controller.select(reportID: report, filterID: filter)
                             })
                .frame(width: 260)
                Divider()
                Workspace(controller: controller, workspaceView: view)
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
                Text("\(existing.urlCount.formatted()) URLs, last updated \(existing.modifiedAt.formatted(date: .abbreviated, time: .shortened)).")
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

    /// Runs the export off the main actor, since a whole-crawl export at half a
    /// million URLs is real work, and reports any failure through the same
    /// notice banner everything else uses.
    ///
    /// The save panel and the plan capture stay on the main actor — the panel
    /// because `NSSavePanel` demands it, the capture because it only reads
    /// `CrawlController`'s main-actor state. The queries and the file write
    /// happen in `ExportPlan.run`, off the main actor, which is the part that
    /// is actually slow at half a million URLs.
    private func export(scope: ExportScope, format: ExportFormat) {
        let host = controller.crawlHost
        let reportName = scope == .currentView ? controller.selectedReport.name : nil
        let suggested = ExportCommands.suggestedFilename(host: host, reportName: reportName,
                                                         format: format, date: Date())
        let wantsDirectory = (scope == .everything && format == .csv)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = wantsDirectory
            ? suggested.replacingOccurrences(of: ".csv", with: "")
            : suggested
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        guard let plan = controller.exportPlan(scope: scope) else {
            controller.report("Nothing to export yet.")
            return
        }

        // Re-entrancy guard: once the work below is off the main actor, nothing
        // else stops the user opening the menu again mid-export, against the
        // same store and possibly the same destination.
        controller.isExporting = true
        let controller = self.controller
        Task.detached(priority: .userInitiated) {
            do {
                let written = try plan.run(format: format, to: destination, host: host, date: Date())
                await MainActor.run {
                    controller.isExporting = false
                    guard !written.isEmpty else {
                        controller.report("Nothing to export yet.")
                        return
                    }
                    controller.report(written.count == 1
                        ? "Exported to \(written[0].path)."
                        : "Exported \(written.count) files to \(destination.path).")
                }
            } catch {
                await MainActor.run {
                    controller.isExporting = false
                    controller.report("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.small) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.Ink.warning.color)
            Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Theme.Space.small)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
