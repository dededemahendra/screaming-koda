import Foundation
import KodaCore

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, xlsx
    public var id: String { rawValue }

    public var fileExtension: String { rawValue }

    public var title: String {
        switch self {
        case .csv: return "CSV"
        case .xlsx: return "Excel workbook"
        }
    }
}

public enum ExportScope: Sendable {
    /// The report and filter currently on screen, in its current sort.
    case currentView
    /// Every report under its default filter.
    case everything
}

/// Names files and writes them. Split out from the window so the naming and the
/// writing are testable; `NSSavePanel` is not, and stays in the view.
public enum ExportCommands {

    /// `example-com-titles-2026-08-21.csv`. Includes the host and the date
    /// because these files end up in a downloads folder next to five others
    /// from different crawls, and "report.csv" helps nobody.
    public static func suggestedFilename(host: String?, reportName: String?,
                                         format: ExportFormat, date: Date) -> String {
        let stamp = exportDateString(date)
        let parts = [host, reportName, stamp].compactMap { $0 }.map(safe)
        return parts.filter { !$0.isEmpty }.joined(separator: "-") + "." + format.fileExtension
    }

    /// Lowercased, with anything that is not alphanumeric collapsed to a single
    /// hyphen. Covers the filesystem's objections (`/`, `:`) and the ones that
    /// merely make a filename annoying to type.
    static func safe(_ value: String) -> String {
        var out = ""
        var lastWasSeparator = true
        for character in value.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append("-")
                lastWasSeparator = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// Writes one file for `.xlsx` (all sheets in one workbook), and one file
    /// per report for `.csv` into `directory`, since CSV has no notion of
    /// sheets. Returns what it wrote.
    @discardableResult
    public static func write(_ exports: [ReportExport], format: ExportFormat,
                             to destination: URL, host: String?, date: Date) throws -> [URL] {
        switch format {
        case .xlsx:
            try XLSXWriter.encode(exports).write(to: destination, options: .atomic)
            return [destination]
        case .csv where exports.count == 1:
            try CSVWriter.encode(exports[0]).write(to: destination, options: .atomic)
            return [destination]
        case .csv:
            // `destination` is a directory for a multi-report CSV export.
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            return try exports.map { export in
                let name = suggestedFilename(host: host, reportName: export.name,
                                             format: .csv, date: date)
                let url = destination.appendingPathComponent(name)
                try CSVWriter.encode(export).write(to: url, options: .atomic)
                return url
            }
        }
    }
}

/// Date only. A filename does not need a timestamp to the second, and a colon
/// in one is a filesystem problem waiting to happen.
///
/// Built per call rather than shared: `ISO8601DateFormatter` is not `Sendable`,
/// and a shared mutable instance is rejected under Swift 6 strict concurrency.
/// Naming a file is not a hot path.
func exportDateString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    return formatter.string(from: date)
}
