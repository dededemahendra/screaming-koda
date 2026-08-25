import Foundation
import KodaCore
import Observation

/// The state behind one report table: which report, how it is sorted and
/// filtered, and how to get a row.
@MainActor
@Observable
public final class ReportTableModel {
    public private(set) var definition: ReportDefinition
    public private(set) var sortColumn: Int?
    public private(set) var direction: ReportQuery.Direction = .ascending
    public private(set) var filter: String = ""
    public private(set) var rowCount: Int = 0
    /// Set when a query fails, so the table can say so instead of showing empty.
    public private(set) var errorMessage: String?

    private let store: Store
    private var cache: RowWindowCache?

    public init(store: Store, definition: ReportDefinition) {
        self.store = store
        self.definition = definition
        reload()
    }

    public func show(_ definition: ReportDefinition) {
        guard definition.id != self.definition.id else { return }
        self.definition = definition
        // Sort is an index into this report's columns, so it cannot carry over.
        sortColumn = nil
        direction = .ascending
        reload()
    }

    /// Clicking the same header again reverses; a different header sorts ascending.
    public func toggleSort(column: Int) {
        guard definition.columns.indices.contains(column) else { return }
        if sortColumn == column {
            direction = direction.reversed
        } else {
            sortColumn = column
            direction = .ascending
        }
        reload()
    }

    /// Applies a specific order. The table header decides the direction itself,
    /// so it sets rather than toggles.
    public func setSort(column: Int?, ascending: Bool) {
        if let column, !definition.columns.indices.contains(column) { return }
        guard column != sortColumn || (direction == .ascending) != ascending else { return }
        sortColumn = column
        direction = ascending ? .ascending : .descending
        reload()
    }

    public func setFilter(_ text: String) {
        guard text != filter else { return }
        filter = text
        reload()
    }

    public func row(at index: Int) -> [String?]? {
        guard let cache else { return nil }
        do {
            return try cache.row(at: index)
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// The URL a row refers to, for the inspector. Every report leads with it
    /// except the aggregate ones, which have no single URL.
    public func url(at index: Int) -> String? {
        guard definition.columns.first == "URL" || definition.columns.first == "Image" else { return nil }
        return row(at: index)?.first ?? nil
    }

    /// The rows at these indices, in table order, skipping any that have scrolled
    /// out of the cache's reach. For copying a selection.
    public func rows(at indices: IndexSet) -> [[String?]] {
        indices.sorted().compactMap { row(at: $0) }
    }

    /// A selection as tab-separated text.
    ///
    /// Tabs rather than commas: this goes to the clipboard, and every spreadsheet
    /// pastes TSV into cells while CSV lands in one. A tab inside a value would
    /// break that, so tabs and newlines within a cell become spaces.
    public func clipboardText(for indices: IndexSet, includingHeader: Bool = true) -> String {
        var lines: [String] = []
        if includingHeader { lines.append(definition.columns.joined(separator: "\t")) }
        for values in rows(at: indices) {
            lines.append(definition.columns.indices.map { index in
                let value = index < values.count ? values[index] : nil
                return (value ?? "").replacingOccurrences(
                    of: "[\t\r\n]", with: " ", options: .regularExpression
                )
            }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// The URLs among a selection, for opening them in a browser. Aggregate
    /// reports have no URL column and yield nothing.
    public func urls(at indices: IndexSet) -> [String] {
        indices.sorted().compactMap { url(at: $0) }
    }

    public var query: ReportQuery {
        ReportQuery(definition: definition, sortColumn: sortColumn, direction: direction, filter: filter)
    }

    /// Rebuilds the cache and row count. Called on every state change and on the
    /// refresh timer while a crawl writes underneath.
    public func reload() {
        do {
            cache = try RowWindowCache(store: store, query: query)
            rowCount = cache?.count ?? 0
            errorMessage = nil
        } catch {
            cache = nil
            rowCount = 0
            errorMessage = String(describing: error)
        }
    }
}
