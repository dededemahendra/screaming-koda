import Foundation

/// RFC 4180 CSV. Fields are quoted only when they have to be, which keeps diffs
/// between exports of the same report readable.
public enum CSVWriter {
    /// RFC 4180 specifies CRLF. Excel and Numbers both accept LF, but a spec-
    /// compliant file is the safer default for something users will mail around.
    public static let lineTerminator = "\r\n"

    public static func field(_ value: String?) -> String {
        guard let value else { return "" }
        let mustQuote = value.contains(",") || value.contains("\"")
            || value.contains("\n") || value.contains("\r")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard mustQuote else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func row(_ fields: [String?]) -> String {
        fields.map(field).joined(separator: ",")
    }

    public static func document(columns: [String], rows: [[String?]]) -> String {
        var out = row(columns.map { $0 })
        for r in rows {
            out += lineTerminator + row(r)
        }
        return out + lineTerminator
    }
}

extension Store {
    /// Renders a report as CSV text.
    public func csv(for definition: ReportDefinition) throws -> String {
        CSVWriter.document(columns: definition.columns, rows: try runReport(definition))
    }

    /// Writes a report to a file, creating or replacing it.
    public func writeCSV(for definition: ReportDefinition, to path: String) throws {
        try Data(try csv(for: definition).utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Writes every report with at least one row into `directory`, named by report id.
    /// Empty reports are skipped: a directory of mostly header-only files makes the
    /// findings that do exist harder to spot, not easier.
    @discardableResult
    public func writeAllCSVs(to directory: String) throws -> [String] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for definition in ReportCatalogue.all {
            let rows = try runReport(definition)
            guard !rows.isEmpty else { continue }
            let path = directory + "/\(definition.id).csv"
            let text = CSVWriter.document(columns: definition.columns, rows: rows)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            written.append(path)
        }
        return written
    }
}
