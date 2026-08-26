import AppKit
import KodaCore
import SwiftUI

/// `NSTableView` paints its alternating background across the whole clip view,
/// so a table with nine rows in a tall pane shows nine rows of data followed by
/// forty empty stripes. That reads as a rendering fault rather than as empty
/// space, which is the opposite of what it should say.
final class KodaTableView: NSTableView {
    override func drawBackground(inClipRect clipRect: NSRect) {
        backgroundColor.setFill()
        clipRect.fill()
        guard usesAlternatingRowBackgroundColors, numberOfRows > 0 else { return }
        NSColor.alternatingContentBackgroundColors[1].setFill()
        // Only the rows this pass could actually paint, not every odd row in
        // the whole table: at the 500,000 URL cap, striding the full table on
        // every draw is 250,000 `rect(ofRow:)` calls per frame, and this
        // table reloads at 2 Hz during a live crawl.
        let visible = rows(in: clipRect)
        guard visible.length > 0 else { return }
        let firstOddRow = visible.location % 2 == 0 ? visible.location + 1 : visible.location
        let lastRow = min(visible.location + visible.length, numberOfRows)
        for row in stride(from: firstOddRow, to: lastRow, by: 2) {
            let rect = rect(ofRow: row)
            if rect.intersects(clipRect) { rect.fill() }
        }
    }
}

/// Bridges `RowStore` to `NSTableView`. Split out from the representable so it
/// can be unit-tested — SwiftUI view structs cannot be.
@MainActor
public final class URLTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public var rows: RowStore?
    /// Which report's columns are currently installed. The cell lookup is
    /// positional, so this must be the same report the rows were fetched for or
    /// every cell would come from the wrong column.
    public var report: Report

    /// Called when the user clicks a column header, with the column's id. The
    /// controller rebuilds the index and reloads; the coordinator does not sort.
    public var onSortChange: ((String, Bool) -> Void)?
    /// Called when the selected row changes, with the row's database id.
    public var onSelect: ((Int64?) -> Void)?

    public init(rows: RowStore?, report: Report) {
        self.rows = rows
        self.report = report
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows?.count ?? 0
    }

    /// Resolves a header click against the *current* report. A descriptor naming
    /// a column this report does not declare — a stale one left over from the
    /// previous tab — resolves to nil rather than reaching the ORDER BY.
    public func sort(from descriptor: NSSortDescriptor) -> (columnID: String, ascending: Bool)? {
        guard let key = descriptor.key, let column = report.column(id: key), column.sortable
        else { return nil }
        return (column.id, descriptor.ascending)
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first,
              let resolved = sort(from: descriptor)
        else { return }
        onSortChange?(resolved.columnID, resolved.ascending)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        let row = table.selectedRow
        onSelect?(row >= 0 ? rows?.row(at: row)?.id : nil)
    }

    /// The display string for a cell. A row that has not loaded yet, or a column
    /// index out of range, renders empty rather than crashing — a crawl in
    /// flight legitimately has rows with no response yet.
    public func value(columnIndex: Int, row index: Int) -> String {
        guard let row = rows?.row(at: index),
              columnIndex >= 0, columnIndex < row.cells.count
        else { return "" }
        return row.cells[columnIndex] ?? ""
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let columnIndex = report.columns.firstIndex(where: { $0.id == tableColumn.identifier.rawValue })
        else { return nil }

        let identifier = tableColumn.identifier
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.alignment = report.columns[columnIndex].alignment == .trailing ? .right : .left
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        configure(cell, columnIndex: columnIndex, row: row)
        return cell
    }

    /// Colour marks exceptions, so a 200 and an indexable page get none. This
    /// is the same mapping the sidebar and the inspector use — it lives in
    /// `Theme` and is reached from here so the three cannot drift apart.
    static func ink(for value: String, semantic: ColumnSemantic?) -> Theme.Ink? {
        switch semantic {
        case .status:
            return Theme.ink(forStatus: Int(value))
        case .indexability:
            // Anything but Indexability.indexable is a reason the page will not rank.
            return value.isEmpty || value == Indexability.indexable ? nil : .critical
        case nil:
            return nil
        }
    }

    /// The single assignment site for a cell's text, reachable from both the
    /// reused and freshly-created paths in `tableView(_:viewFor:row:)`. AppKit's
    /// reuse pool cannot be driven under `swift test` (it's populated only by
    /// real on-screen scrolling/display under a running `NSApplication`), so a
    /// stringValue assignment that lived directly in `viewFor` and got moved
    /// into only one branch could ship with the reuse branch never exercised in
    /// tests. Routing both branches through this one method removes that as a
    /// possible mistake, and makes the population step itself directly testable
    /// by handing it a pre-populated cell.
    func configure(_ cell: NSTableCellView, columnIndex: Int, row: Int) {
        let text = value(columnIndex: columnIndex, row: row)
        cell.textField?.stringValue = text
        let column = report.columns[columnIndex]
        cell.textField?.textColor =
            Self.ink(for: text, semantic: column.semantic)?.nsColor ?? .labelColor
        cell.textField?.font = column.alignment == .trailing
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
    }

    /// Replaces the table's columns with the current report's. Called only when
    /// the report actually changes — doing it on every update would drop the
    /// user's scroll position twice a second during a crawl.
    func installColumns(on table: NSTableView, paneWidth: CGFloat) {
        for column in table.tableColumns { table.removeTableColumn(column) }
        let widths = ColumnLayout.widths(for: report, paneWidth: paneWidth)
        for (index, column) in report.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: .init(column.id))
            tableColumn.title = column.header
            tableColumn.width = widths[index]
            if column.sortable {
                tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.id, ascending: true)
            }
            table.addTableColumn(tableColumn)
        }
        table.sortDescriptors = []
    }
}

public struct URLTableView: NSViewRepresentable {
    private let rows: RowStore?
    private let report: Report
    /// Changes whenever the controller wants a reload — bumping it is how the
    /// 2 Hz tick reaches the table.
    private let revision: Int
    private let onSortChange: ((String, Bool) -> Void)?
    private let onSelect: ((Int64?) -> Void)?

    public init(rows: RowStore?, report: Report, revision: Int,
                onSortChange: ((String, Bool) -> Void)? = nil,
                onSelect: ((Int64?) -> Void)? = nil) {
        self.rows = rows
        self.report = report
        self.revision = revision
        self.onSortChange = onSortChange
        self.onSelect = onSelect
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let table = KodaTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .default
        table.allowsMultipleSelection = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false

        context.coordinator.installColumns(on: table, paneWidth: scrollView.contentSize.width)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        let reportChanged = context.coordinator.report.id != report.id
        context.coordinator.rows = rows
        context.coordinator.report = report
        context.coordinator.onSortChange = onSortChange
        context.coordinator.onSelect = onSelect

        let paneWidth = scrollView.contentSize.width
        if !reportChanged, let first = table.tableColumns.first {
            let widths = ColumnLayout.widths(for: report, paneWidth: paneWidth)
            if abs(first.width - widths[0]) > 0.5 { first.width = widths[0] }
        }

        if reportChanged {
            // Row 4 of Titles is not row 4 of Images, so keeping the selected
            // index across a tab change would silently select an unrelated URL.
            context.coordinator.installColumns(on: table, paneWidth: paneWidth)
            table.deselectAll(nil)
            table.reloadData()
            table.scroll(.zero)
            return
        }

        // A table that jumps to the top twice a second is unusable, so preserve
        // both selection and scroll position across the live-crawl reload.
        let selection = table.selectedRowIndexes
        let origin = scrollView.contentView.bounds.origin
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
        table.scroll(origin)
    }

    public func makeCoordinator() -> URLTableCoordinator {
        URLTableCoordinator(rows: rows, report: report)
    }
}
