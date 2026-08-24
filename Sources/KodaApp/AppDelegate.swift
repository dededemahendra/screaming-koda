import AppKit
import Observation
import SwiftUI

/// A database the app has been asked to open: from a launch argument, from
/// double-clicking a `.koda` file, or from dropping one on the Dock icon.
@MainActor
@Observable
final class OpenRequest {
    static let shared = OpenRequest()
    var path: String?

    private init() {
        // `open -a ScreamingKoda file.koda` and `ScreamingKoda file.koda` both
        // arrive here rather than through the delegate.
        if let argument = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".koda") }),
           FileManager.default.fileExists(atPath: argument) {
            path = argument
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        Task { @MainActor in OpenRequest.shared.path = url.path }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Launched from a script or a bare binary there is no bundle to activate, so
    /// the window would open behind whatever is in front.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
