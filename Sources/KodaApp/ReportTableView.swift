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
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.rowSizeStyle = .default
        table.allowsMultipleSelection = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.rebuildColumns(of: table)

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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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
            let selected = table.selectedRow
            isReloading = true
            table.reloadData()
            if selected >= 0 && selected < model.rowCount {
                table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
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
