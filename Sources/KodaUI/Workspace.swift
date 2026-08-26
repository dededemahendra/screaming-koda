import KodaCore
import SwiftUI

/// The right-hand column: one of three answers to "what did the crawl find",
/// over the inspector for whichever row is selected.
public struct Workspace: View {
    private let controller: CrawlController
    private let workspaceView: WorkspaceView

    public init(controller: CrawlController, workspaceView: WorkspaceView) {
        self.controller = controller
        self.workspaceView = workspaceView
    }

    public var body: some View {
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
