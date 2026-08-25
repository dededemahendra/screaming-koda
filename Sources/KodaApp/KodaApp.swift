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
                RecentCrawlsMenu(isEnabled: !model.controller.phase.isRunning, open: load(path:))
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Report") {
                    NotificationCenter.default.post(name: .kodaFocusFilter, object: nil)
                }
                .keyboardShortcut("f")
                .disabled(model.table == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Export Current Report…") { exportCurrentReport() }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(model.table == nil)
                Button("Export Workbook…") { exportWorkbook() }
                    .keyboardShortcut("e")
                    .disabled(model.store == nil)
                Button("Export CSVs…") { exportCSVs() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
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
            try model.openDatabase(path: path)
            // The system keeps this list, so it survives relaunches and shows up
            // under the Dock icon as well as in the menu.
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
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

    /// Just the report on screen, sorted and filtered as it is on screen. The
    /// whole-crawl exports ignore both, which is right for them and wrong here:
    /// someone who has just narrowed a report to eleven rows wants the eleven.
    private func exportCurrentReport() {
        guard let store = model.store, let table = model.table else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(table.definition.id).csv"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(try store.csv(for: table.query).utf8).write(to: url, options: .atomic)
            reveal(url)
        } catch {
            present(error: "Export failed: \(error)")
        }
    }

    /// One workbook, one tab per report with findings. What you send someone.
    private func exportWorkbook() {
        guard let store = model.store else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.nameFieldStringValue = "\(model.crawlName).xlsx"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.writeXLSX(to: url.path)
            reveal(url)
        } catch {
            present(error: "Export failed: \(error)")
        }
    }

    /// A directory of one CSV per report. What you feed a script.
    private func exportCSVs() {
        guard let store = model.store else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let directory = url.appendingPathComponent(model.crawlName)
        do {
            let written = try store.writeAllCSVs(to: directory.path)
            if written.isEmpty {
                present(error: "No findings to export.", style: .informational)
            } else {
                reveal(directory)
            }
        } catch {
            present(error: "Export failed: \(error)")
        }
    }

    /// Selecting the export in the Finder says "it worked" and says where, which
    /// is what an alert saying "exported 12 reports" was failing to do.
    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func present(error message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = style
        alert.runModal()
    }
}


/// The crawls opened recently.
///
/// Read at menu-build time from `NSDocumentController`, which is where macOS
/// keeps this list for every app whether or not it uses NSDocument. Files that
/// have since been deleted are dropped rather than offered and then failing.
struct RecentCrawlsMenu: View {
    let isEnabled: Bool
    let open: (String) -> Void

    var body: some View {
        Menu("Open Recent") {
            let recent = NSDocumentController.shared.recentDocumentURLs
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if recent.isEmpty {
                Text("No Recent Crawls")
            } else {
                ForEach(recent, id: \.self) { url in
                    Button(url.lastPathComponent) { open(url.path) }
                }
                Divider()
                Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
            }
        }
        .disabled(!isEnabled)
    }
}
