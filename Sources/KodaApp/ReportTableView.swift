import AppKit
import KodaCore
import KodaUI
import SwiftUI

/// The results table.
///
/// `NSTableView` rather than SwiftUI's `Table`: at hundreds of thousands of rows
/// SwiftUI's table wants the whole collection, and the entire point of the paged
/// cache behind this is that the full row set is never in memory. AppKit asks for
/// rows one at a time, which is exactly the shape the cache serves.
struct ReportTableView: NSViewRepresentable {
    let model: ReportTableModel
    let onSelectRow: (Int?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onSelectRow: onSelectRow)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KodaTableView()
        // Cmd-C arrives as `copy:` down the responder chain from the first
        // responder, which is the table. NSTableView does not implement it, so
        // without this the standard Edit menu item is permanently greyed out.
        table.onCopy = { [weak coordinator = context.coordinator] in coordinator?.copySelection(nil) }
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.rowSizeStyle = .default
        // Multiple selection, because the thing people do with a list of broken
        // links is select all of them and copy.
        table.allowsMultipleSelection = true
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelectedURLs)
        table.menu = context.coordinator.makeMenu()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.rebuildColumns(of: table)
        context.coordinator.remember(table)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        context.coordinator.model = model
        context.coordinator.onSelectRow = onSelectRow

        // Only rebuild columns when the report actually changed. Rebuilding on
        // every update would reset column widths the user had dragged.
        if context.coordinator.shownReportID != model.definition.id {
            context.coordinator.rebuildColumns(of: table)
            table.scrollRowToVisible(0)
        }
        context.coordinator.reloadPreservingSelection(table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: ReportTableModel
        var onSelectRow: (Int?) -> Void
        private(set) var shownReportID: String = ""
        private var isReloading = false

        init(model: ReportTableModel, onSelectRow: @escaping (Int?) -> Void) {
            self.model = model
            self.onSelectRow = onSelectRow
        }

        func rebuildColumns(of table: NSTableView) {
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (index, title) in model.definition.columns.enumerated() {
                let column = NSTableColumn(identifier: .init("col\(index)"))
                column.title = title
                column.width = title == "URL" || title == "Image" ? 340 : 140
                column.minWidth = 60
                // The key is the column index, so a sort can never carry a string
                // from the report into SQL.
                column.sortDescriptorPrototype = NSSortDescriptor(key: "\(index)", ascending: true)
                table.addTableColumn(column)
            }
            shownReportID = model.definition.id
            table.reloadData()
        }

        /// A reload drops the selection, which would otherwise clear the inspector
        /// every time the refresh timer fires mid-crawl.
        func reloadPreservingSelection(_ table: NSTableView) {
            let selected = table.selectedRowIndexes.filteredIndexSet { $0 < model.rowCount }
            isReloading = true
            table.reloadData()
            if !selected.isEmpty {
                table.selectRowIndexes(selected, byExtendingSelection: false)
            }
            isReloading = false
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            model.rowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn,
                  let index = Int(tableColumn.identifier.rawValue.dropFirst(3)),
                  let values = model.row(at: row)
            else { return nil }

            let identifier = tableColumn.identifier
            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingTail
                field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            }
            let value = index < values.count ? values[index] : nil
            field.stringValue = value ?? ""
            // A NULL and an empty string look the same otherwise, and for a report
            // like "missing title" the difference is the whole point.
            field.textColor = value == nil ? .tertiaryLabelColor : .labelColor
            if value == nil { field.stringValue = "—" }
            return field
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isReloading, let table = notification.object as? NSTableView else { return }
            onSelectRow(table.selectedRow >= 0 ? table.selectedRow : nil)
        }

        // MARK: Actions

        /// A right-click acts on the row under the pointer unless it is already
        /// part of the selection, which is how every AppKit table behaves.
        private func actionRows(_ table: NSTableView) -> IndexSet {
            let clicked = table.clickedRow
            if clicked >= 0, !table.selectedRowIndexes.contains(clicked) {
                return IndexSet(integer: clicked)
            }
            return table.selectedRowIndexes.isEmpty && clicked >= 0
                ? IndexSet(integer: clicked)
                : table.selectedRowIndexes
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            for (title, action) in [
                ("Copy", #selector(copySelection(_:))),
                ("Copy URL", #selector(copySelectedURLs(_:))),
                ("Open in Browser", #selector(openSelectedURLs(_:))),
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            return menu
        }

        @objc func copySelection(_ sender: Any?) {
            guard let table = tableView(for: sender) else { return }
            let text = model.clipboardText(for: actionRows(table))
            guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc func copySelectedURLs(_ sender: Any?) {
            guard let table = tableView(for: sender) else { return }
            let urls = model.urls(at: actionRows(table))
            guard !urls.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
        }

        /// Capped, because double-clicking with two hundred rows selected should
        /// not open two hundred tabs.
        @objc func openSelectedURLs(_ sender: Any?) {
            guard let table = tableView(for: sender) else { return }
            for url in model.urls(at: actionRows(table)).prefix(20) {
                guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true else { continue }
                NSWorkspace.shared.open(parsed)
            }
        }

        private var table: NSTableView?

        private func tableView(for sender: Any?) -> NSTableView? {
            if let sender = sender as? NSTableView { return sender }
            return table
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard let table else { return }
            let rows = actionRows(table)
            let hasURLs = !model.urls(at: rows).isEmpty
            menu.item(withTitle: "Copy")?.isEnabled = !rows.isEmpty
            menu.item(withTitle: "Copy URL")?.isEnabled = hasURLs
            menu.item(withTitle: "Open in Browser")?.isEnabled = hasURLs
        }

        func remember(_ table: NSTableView) { self.table = table }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let column = Int(key)
            else {
                model.setSort(column: nil, ascending: true)
                return
            }
            model.setSort(column: column, ascending: descriptor.ascending)
            tableView.reloadData()
            tableView.scrollRowToVisible(0)
        }
    }
}


/// An `NSTableView` that answers `copy:`.
///
/// Copy is a responder-chain action, and AppKit's table does not implement it,
/// so the standard Edit menu item stays greyed out no matter what the
/// contextual menu offers.
final class KodaTableView: NSTableView {
    var onCopy: (() -> Void)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}
