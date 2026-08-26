import KodaCore
import SwiftUI

/// The right-hand column: what the crawl has to show right now — nothing yet,
/// in progress, clean, or failed — and once there are rows, one of three
/// answers to "what did the crawl find", over the inspector for whichever row
/// is selected.
public struct Workspace: View {
    private let controller: CrawlController
    private let workspaceView: WorkspaceView

    public init(controller: CrawlController, workspaceView: WorkspaceView) {
        self.controller = controller
        self.workspaceView = workspaceView
    }

    private var state: WorkspaceState {
        WorkspaceState.resolve(
            crawl: controller.state,
            hasStore: controller.canExport,
            urlsFound: controller.progress?.crawled ?? 0,
            findingTotal: SidebarModel.findingTotal(reports: controller.availableReports,
                                                    counts: controller.counts))
    }

    /// How many distinct problems Screaming Koda knows to check for, across
    /// every report the controller currently has open. Interpolated into the
    /// clean-state message rather than typed as a literal: a report gaining or
    /// losing a filter would otherwise make a hard-coded number quietly wrong.
    private var findingFilterCount: Int {
        controller.availableReports.flatMap(\.filters).filter(\.isFinding).count
    }

    public var body: some View {
        switch state {
        case .noCrawl:
            EmptyStatePanel(
                symbol: "magnifyingglass",
                title: "Crawl a site",
                message: "Enter a URL above and press Start. Screaming Koda follows "
                       + "every internal link, records what it finds, and ranks the "
                       + "problems by how much they cost.")
        case .failed(let reason):
            EmptyStatePanel(symbol: "exclamationmark.triangle.fill",
                            title: "The crawl could not run",
                            message: reason, ink: .critical)
        case .clean:
            EmptyStatePanel(
                symbol: "checkmark.circle",
                title: "No issues found",
                message: "\((controller.progress?.crawled ?? 0).formatted()) URLs "
                       + "checked against \(findingFilterCount.formatted()) findings. Browse the "
                       + "reports in the sidebar to see the data behind that.")
        case .crawling, .results:
            resultsBody
        }
    }

    /// The table, tree, or graph over the inspector for whichever row is
    /// selected. Unchanged from before this file had a state to switch on.
    private var resultsBody: some View {
        VSplitView {
            Group {
                switch workspaceView {
                case .tree:
                    SiteTreeView(root: controller.siteTree,
                                 onSelect: { controller.selectRow(id: $0) })
                case .graph:
                    LinkGraphView(graph: controller.linkGraph)
                case .table:
                    URLTableView(rows: controller.rows,
                                 report: controller.selectedReport,
                                 revision: controller.revision,
                                 onSortChange: { columnID, ascending in
                                     controller.applySort(columnID: columnID, ascending: ascending)
                                 },
                                 onSelect: { controller.selectRow(id: $0) })
                }
            }
            .frame(minHeight: 220)

            InspectorView(detail: controller.detail,
                          inlinks: controller.inlinks,
                          outlinks: controller.outlinks,
                          images: controller.images,
                          chain: controller.redirectChain)
        }
        .frame(minWidth: 640)
    }
}
