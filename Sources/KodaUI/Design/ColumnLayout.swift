import KodaCore

/// How a report's columns divide the pane.
///
/// Every column but the address keeps the width its definition asked for —
/// those widths were chosen for their content and a status code does not need
/// more room on a wide monitor. The address takes the rest, because a URL is
/// the one value that is never long enough.
public enum ColumnLayout {
    /// The flexible column is the first one, which in every report is the
    /// address or the resource URL — the value that is never long enough.
    public static func widths(for report: Report, paneWidth: Double,
                              minimumFirstColumn: Double = 220) -> [Double] {
        guard !report.columns.isEmpty else { return [] }
        let rest = report.columns.dropFirst()
        let fixed = rest.reduce(0) { $0 + $1.width }
        // Below this the address would be squeezed to something unreadable, so
        // it stops shrinking and the table scrolls sideways instead.
        return [max(minimumFirstColumn, paneWidth - fixed)] + rest.map(\.width)
    }
}
