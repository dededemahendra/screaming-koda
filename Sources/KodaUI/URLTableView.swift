import AppKit
import KodaCore
import SwiftUI

public enum URLTableColumn: String, CaseIterable, Sendable {
    case address, status, title, depth

    public var title: String {
        switch self {
        case .address: return "Address"
        case .status: return "Status"
        case .title: return "Title"
        case .depth: return "Depth"
        }
    }

    var width: CGFloat {
        switch self {
        case .address: return 380
        case .status: return 70
        case .title: return 320
        case .depth: return 60
        }
    }
}

/// Bridges `RowStore` to `NSTableView`. Split out from the representable so it
/// can be unit-tested — SwiftUI view structs cannot be.
@MainActor
public final class URLTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    public var rows: RowStore?

    public init(rows: RowStore?) {
        self.rows = rows
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        rows?.count ?? 0
    }

    /// Returns the display string for a cell. Missing data renders empty rather
    /// than crashing — a crawl in flight legitimately has rows with no response yet.
    public func value(for column: URLTableColumn, row index: Int) -> String {
        guard let row = rows?.row(at: index) else { return "" }
        switch column {
        case .address: return row.address
        case .status: return row.status.map(String.init) ?? ""
        case .title: return row.title ?? ""
        case .depth: return String(row.depth)
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn,
              let column = URLTableColumn(rawValue: tableColumn.identifier.rawValue)
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
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = value(for: column, row: row)
        return cell
    }
}

public struct URLTableView: NSViewRepresentable {
    private let rows: RowStore?
    /// Changes whenever the controller wants a reload — bumping it is how the
    /// 2 Hz tick reaches the table.
    private let revision: Int

    public init(rows: RowStore?, revision: Int) {
        self.rows = rows
        self.revision = revision
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowSizeStyle = .default
        table.allowsMultipleSelection = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        for column in URLTableColumn.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = scrollView.documentView as? NSTableView else { return }
        context.coordinator.rows = rows

        // A table that jumps to the top twice a second is unusable, so preserve
        // both selection and scroll position across the live-crawl reload.
        let selection = table.selectedRowIndexes
        let origin = scrollView.contentView.bounds.origin
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
        table.scroll(origin)
    }

    public func makeCoordinator() -> URLTableCoordinator {
        URLTableCoordinator(rows: rows)
    }
}
