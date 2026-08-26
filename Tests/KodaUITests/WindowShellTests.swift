import SwiftUI
import Testing
@testable import KodaCore
@testable import KodaUI

@MainActor
@Test func theToolbarDrawsItsControls() {
    let controller = CrawlController(dbPath: nil)
    let toolbar = CrawlToolbar(controller: controller,
                               showingSettings: .constant(false),
                               workspaceView: .constant(.table),
                               onExport: { _, _ in })
    ViewCapture.expectNotBlank(toolbar.frame(width: 1100, height: 52),
                               size: CGSize(width: 1100, height: 52),
                               "the crawl toolbar")
}

@MainActor
@Test func theWorkspaceDrawsBeforeAnyCrawlHasRun() {
    let controller = CrawlController(dbPath: nil)
    let workspace = Workspace(controller: controller, workspaceView: .table)
    ViewCapture.expectNotBlank(workspace.frame(width: 800, height: 600),
                               size: CGSize(width: 800, height: 600),
                               "the workspace with no crawl")
}

@MainActor
@Test func theWholeWindowDraws() {
    let controller = CrawlController(dbPath: nil)
    ViewCapture.expectNotBlank(ContentView(controller: controller)
                                 .frame(width: 1100, height: 660),
                               size: CGSize(width: 1100, height: 660),
                               "the whole window")
}
