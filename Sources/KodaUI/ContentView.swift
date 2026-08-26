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
            NavigationSplitView {
                IssueSidebar(reports: controller.availableReports,
                             counts: controller.counts,
                             crawlName: controller.crawlHost,
                             selectedReportID: controller.selectedReportID,
                             selectedFilterID: controller.selectedFilterID,
                             onSelect: { report, filter in
                                 controller.select(reportID: report, filterID: filter)
                             })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            } detail: {
                Workspace(controller: controller, workspaceView: view)
            }
            .navigationSplitViewStyle(.balanced)
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

    /// Runs the export off the main actor, since a whole-crawl export at half a
    /// million URLs is real work, and reports any failure through the same
    /// notice banner everything else uses.
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

        do {
            let exports: [ReportExport] = try scope == .currentView
                ? [controller.exportCurrentView()].compactMap { $0 }
                : controller.exportEverything()
            guard !exports.isEmpty else {
                controller.report("Nothing to export yet.")
                return
            }
            let written = try ExportCommands.write(exports, format: format, to: destination,
                                                   host: host, date: Date())
            controller.report(written.count == 1
                ? "Exported to \(written[0].path)."
                : "Exported \(written.count) files to \(destination.path).")
        } catch {
            controller.report("Export failed: \(error.localizedDescription)")
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
