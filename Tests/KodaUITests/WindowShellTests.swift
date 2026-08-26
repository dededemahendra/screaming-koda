import SwiftUI
import Testing
@testable import KodaCore
@testable import KodaUI

@MainActor
@Test func theToolbarDrawsItsControls() {
    let controller = CrawlController(dbPath: nil)
    let toolbar = CrawlToolbar(controller: controller,
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

/// The window must draw in *both* halves — the bar across the top and the
/// content below it.
///
/// This exists because a whole-view "not blank" assertion cannot catch a
/// missing region, and did not: the shipped layout nested a
/// `NavigationSplitView` under the toolbar, the split view laid itself out
/// against the whole window and drew over the bar, and the app went out with
/// no seed field, no Start button and no search field. Every capture test
/// stayed green, because the sidebar and the workspace underneath were drawing
/// perfectly well.
///
/// Measured across the three arrangements at 1200x800, top 60pt against the
/// body: `HStack` 143/130, `NavigationSplitView` 3/126, `HSplitView` 109/3.
/// Only one of them draws the whole window.
@MainActor
@Test func theWholeWindowDrawsItsBarAndItsBody() throws {
    let size = CGSize(width: 1200, height: 800)
    let rep = try #require(ViewCapture.bitmap(
        of: ContentView(controller: CrawlController(dbPath: nil))
            .frame(width: size.width, height: size.height),
        size: size))

    let bar = ViewCapture.distinctColours(rep, fromTop: 0, height: 60)
    let body = ViewCapture.distinctColours(rep, fromTop: 100, height: 600)

    #expect(bar > 20, "the toolbar drew \(bar) distinct colours; a missing bar reads as ~3")
    #expect(body > 20, "the content below the toolbar drew \(body) distinct colours")
}
