import AppKit
import KodaRender
import KodaUI
import SwiftUI

@main
struct KodaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller: CrawlController

    init() {
        let controller = CrawlController(
            crawlsDirectory: { CrawlDatabaseLocation.crawlsDirectory() },
            // Only the shipped app persists settings; a bare controller keeps
            // them in memory so tests never read or write real preferences.
            settings: CrawlSettings(),
            makeRenderer: { WebKitRenderer() }
        )
        _controller = State(initialValue: controller)
        // Wired up here, in `init`, rather than in an `.onAppear` inside `body`: this
        // must be set before any window-close can reach `AppDelegate`, and `body` isn't
        // guaranteed to have run its view-appear callbacks by the time that can happen.
        appDelegate.controller = controller
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: this is a single-crawl application (see Item 3
        // of the M2 final review) — one controller, one engine, one store. `WindowGroup`
        // hands out Cmd+N "New Window" for free, and each new window would build its own
        // independent `CrawlController`/`Store`/`CrawlEngine`, letting a user accumulate
        // several simultaneous crawls with no UI that lists or manages them. `Window`
        // is a single, unique window instance and does not offer "New Window".
        Window("Screaming Koda", id: "main") {
            ContentView(controller: controller)
        }
        .defaultSize(width: 1100, height: 650)
    }
}

/// Exists for one reason: a crawl must not keep running, invisibly, after the
/// user closes the window that was showing it.
///
/// Nothing else in `Sources/` observed window or app lifecycle before this —
/// on macOS a process survives its last window closing by default, and
/// `CrawlController.start()`'s run task holds strong references to the
/// engine and store for the crawl's entire duration regardless of what
/// SwiftUI does with the view. Combined, a user who closed the window mid-crawl
/// got a crawl that kept hitting the target site indefinitely with no way back
/// to it — only Force Quit stopped it. For a tool whose whole politeness
/// design (crawl delays, per-host worker caps, robots.txt) exists to avoid
/// hammering sites, silently continuing after the user believes they stopped
/// is the worst version of that bug.
///
/// The fix: closing the window (this is a single-`Window`-scene app, so that
/// is always the *last* window) asks the app to terminate, and termination is
/// held open with `.terminateLater` until the crawl has actually been asked
/// to stop and `CrawlEngine.cancel()` has returned — not just until the window
/// is gone.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: CrawlController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.state.isActive else { return .terminateNow }
        Task { @MainActor in
            await controller.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
