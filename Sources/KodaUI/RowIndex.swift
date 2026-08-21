import Foundation
import GRDB
import KodaCore

public enum SortColumn: String, CaseIterable, Sendable {
    /// The default: the order URLs were discovered in. Not a clickable column —
    /// it is the state the table is in before the user sorts anything, and it
    /// matches how the table behaved before this milestone.
    case discoveryOrder
    case address, status, title, depth

    /// The SQL expression to order by. Kept here rather than at the call site so
    /// there is one place that decides what "sort by status" means.
    var orderExpression: String {
        switch self {
        case .discoveryOrder: return "u.id"
        case .address: return "u.url"
        case .status: return "r.status"
        case .title: return "f.title"
        case .depth: return "u.depth"
        }
    }

    /// Only discovery order can be appended to during a live crawl. New rows
    /// always get larger ids, so they belong at the end — but under any other
    /// sort a new row could belong anywhere, and appending it would put the
    /// table in a wrong order that looks plausible. Those sorts rebuild instead.
    var isAppendable: Bool { self == .discoveryOrder }

    /// The columns a user can actually click. `discoveryOrder` is excluded
    /// because there is no column header for it.
    public static var selectable: [SortColumn] { [.address, .status, .title, .depth] }
}

/// The ordered list of row ids behind the table.
///
/// `NSTableView` asks for arbitrary rows, so the table needs random access into
/// a sorted result. Holding the ordered ids gives that in O(1) — row `N` is
/// `ids[N]` — where `LIMIT`/`OFFSET` costs O(offset) and keyset pagination
/// cannot answer "row 40,000" at all. At 500,000 URLs the array is about 4MB.
@MainActor
public final class RowIndex {
    private let store: Store
    public private(set) var ids: [Int64] = []
    public private(set) var sort: SortColumn = .discoveryOrder
    public private(set) var ascending = true

    public init(store: Store) {
        self.store = store
    }

    public var count: Int { ids.count }

    public func id(at index: Int) -> Int64? {
        guard index >= 0, index < ids.count else { return nil }
        return ids[index]
    }

    /// Re-runs the ordering query. On failure the previous ordering is kept, so
    /// a transient read error leaves the table usable rather than empty.
    public func rebuild(sort: SortColumn, ascending: Bool) {
        let direction = ascending ? "ASC" : "DESC"
        // Nulls last in BOTH directions: a table sorted by status should open on
        // real statuses whichever way the arrow points.
        let sql = """
            SELECT u.id
            FROM urls u
            LEFT JOIN responses r ON r.url_id = u.id
            LEFT JOIN page_facts f ON f.url_id = u.id
            WHERE \(Store.visibleURLsFilter)
            ORDER BY (\(sort.orderExpression) IS NULL) ASC, \(sort.orderExpression) \(direction), u.id ASC
            """
        guard let fresh = try? store.dbQueue.read({ db in try Int64.fetchAll(db, sql: sql) }) else {
            return
        }
        self.ids = fresh
        self.sort = sort
        self.ascending = ascending
    }

    /// Fast path for a live crawl under the default sort: fetch only ids beyond
    /// the largest one already held, instead of re-sorting the whole crawl twice
    /// a second. Returns whether anything was added.
    @discardableResult
    public func appendNewIds() -> Bool {
        guard sort.isAppendable, ascending else { return false }
        let after = ids.last ?? 0
        let sql = """
            SELECT u.id FROM urls u
            WHERE u.id > ? AND \(Store.visibleURLsFilter)
            ORDER BY u.id ASC
            """
        guard let fresh = try? store.dbQueue.read({ db in
            try Int64.fetchAll(db, sql: sql, arguments: [after])
        }), !fresh.isEmpty else { return false }
        ids.append(contentsOf: fresh)
        return true
    }
}
