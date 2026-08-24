import AppKit
import KodaCore
import KodaUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct KodaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        // Window, not WindowGroup: there is one AppModel and one crawl, so a
        // second window would show the same state twice and opening a file while
        // the app was running spawned a duplicate.
        Window("Screaming Koda", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 620)
                .task { openPendingRequest() }
                .onChange(of: OpenRequest.shared.path) { _, _ in openPendingRequest() }
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Crawl…") { open() }
                    .keyboardShortcut("o")
                    .disabled(model.controller.phase.isRunning)
            }
            CommandGroup(after: .toolbar) {
                Button("Export Reports…") { export() }
                    .keyboardShortcut("e")
                    .disabled(model.store == nil)
            }
        }
    }

    /// Opens whatever a launch argument or a double-clicked file asked for.
    private func openPendingRequest() {
        guard let path = OpenRequest.shared.path else { return }
        OpenRequest.shared.path = nil
        load(path: path)
    }

    private func load(path: String) {
        do {
            model.reset()
            try model.controller.open(path: path)
            if let seed = try model.store?.loadConfig()?.seedURL { model.seedURL = seed }
            model.refresh()
        } catch {
            present(error: "Could not open \((path as NSString).lastPathComponent): \(error)")
        }
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "koda") ?? .database]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(path: url.path)
    }

    private func export() {
        guard let store = model.store else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let written = try store.writeAllCSVs(to: url.appendingPathComponent("koda-reports").path)
            present(error: "Exported \(written.count) reports.", style: .informational)
        } catch {
            present(error: "Export failed: \(error)")
        }
    }

    private func present(error message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
