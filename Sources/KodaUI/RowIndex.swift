import Foundation
import GRDB
import KodaCore

/// The ordered list of row ids behind the table, for one report and filter.
///
/// `NSTableView` asks for arbitrary rows, so the table needs random access into
/// a sorted result. Holding the ordered ids gives that in O(1) — row `N` is
/// `ids[N]` — where `LIMIT`/`OFFSET` costs O(offset) and keyset pagination
/// cannot answer "row 40,000" at all. At 500,000 URLs the array is about 4MB.
@MainActor
public final class RowIndex {
    private let store: Store
    public private(set) var ids: [Int64] = []
    public private(set) var report: Report
    public private(set) var filter: ReportFilter
    /// nil means discovery order, which is the state the table is in before the
    /// user clicks any header. There is no header for it, so it cannot be chosen.
    public private(set) var sortColumnID: String?
    public private(set) var ascending = true

    public init(store: Store, report: Report = Reports.internalURLs) {
        self.store = store
        self.report = report
        self.filter = report.defaultFilter
    }

    public var count: Int { ids.count }

    public func id(at index: Int) -> Int64? {
        guard index >= 0, index < ids.count else { return nil }
        return ids[index]
    }

    /// The resolved sort column, or nil for discovery order. Resolution against
    /// the report's own columns is the allow-list: an id this report does not
    /// declare has no expression, so it cannot reach the ORDER BY.
    public var sortColumn: ReportColumn? {
        sortColumnID.flatMap { report.column(id: $0) }
    }

    /// Re-runs the ordering query. On failure the previous ordering is kept, so
    /// a transient read error leaves the table usable rather than empty.
    public func rebuild(report: Report, filter: ReportFilter,
                        sortColumnID: String?, ascending: Bool) {
        let column = sortColumnID.flatMap { report.column(id: $0) }
        guard let fresh = try? store.ids(for: report, filter: filter,
                                         sortBy: column, ascending: ascending)
        else { return }
        self.ids = fresh
        self.report = report
        self.filter = filter
        // Only remember a sort the report actually accepted, so a stale id left
        // over from another tab cannot silently persist as the current sort.
        self.sortColumnID = column?.id
        self.ascending = ascending
    }

    /// Re-runs the current query, for the periodic refresh during a live crawl.
    public func rebuild() {
        rebuild(report: report, filter: filter, sortColumnID: sortColumnID, ascending: ascending)
    }

    /// Whether the cheap per-tick append is sound for the current view.
    ///
    /// It requires two things. Discovery order ascending, because new rows get
    /// larger ids and so genuinely belong at the end — under any other sort a
    /// new row could belong anywhere, and appending it would produce a wrong
    /// order that looks plausible. And the unfiltered Internal report, because
    /// appending can only ever *add*: on a filtered report a row can stop
    /// matching (a page missing a title gains one, so it leaves Titles →
    /// Missing) and no append will ever remove it. Nothing leaves Internal → All.
    var isAppendable: Bool {
        sortColumnID == nil && ascending
            && report.id == Reports.internalURLs.id
            && filter.id == report.defaultFilter.id
    }

    /// Fast path for a live crawl: fetch only ids beyond the largest one already
    /// held, instead of re-sorting the whole crawl twice a second. Returns
    /// whether anything was added.
    @discardableResult
    public func appendNewIds() -> Bool {
        guard isAppendable else { return false }
        let after = ids.last ?? 0
        let sql = """
            SELECT u.id
            \(ReportSQL.from)
            WHERE u.id > \(after) AND (\(report.predicate)) AND (\(filter.predicate))
            ORDER BY u.id ASC
            """
        guard let fresh = try? store.dbQueue.read({ db in try Int64.fetchAll(db, sql: sql) }),
              !fresh.isEmpty
        else { return false }
        ids.append(contentsOf: fresh)
        return true
    }
}
