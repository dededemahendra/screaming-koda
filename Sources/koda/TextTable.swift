import Foundation

/// Fixed-width column output for the terminal.
enum TextTable {
    /// Columns wider than this are truncated. URLs and titles routinely run past
    /// any sane terminal width, and a wrapped table is unreadable.
    static let maxColumnWidth = 60

    static func render(columns: [String], rows: [[String?]]) -> String {
        let cells = rows.map { row in
            (0..<columns.count).map { index -> String in
                let raw = index < row.count ? (row[index] ?? "") : ""
                return truncate(raw.replacingOccurrences(of: "\n", with: " "))
            }
        }

        var widths = columns.map { min($0.count, maxColumnWidth) }
        for row in cells {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }

        var lines = [zip(columns, widths).map { pad(truncate($0), to: $1) }.joined(separator: "  ")]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        for row in cells {
            lines.append(zip(row, widths).map { pad($0, to: $1) }.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    private static func truncate(_ value: String) -> String {
        guard value.count > maxColumnWidth else { return value }
        return String(value.prefix(maxColumnWidth - 1)) + "…"
    }

    private static func pad(_ value: String, to width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }
}
