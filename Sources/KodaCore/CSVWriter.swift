import Foundation
import GRDB

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
    ///
    /// Holds the whole report in memory, so it is for the small ones and for
    /// tests. Anything that writes a file or a stream should use `streamCSV`:
    /// `internal-all` on a large crawl is every URL on the site, and rendering
    /// half a million rows into one String costs several times the database.
    public func csv(for definition: ReportDefinition) throws -> String {
        CSVWriter.document(columns: definition.columns, rows: try runReport(definition))
    }

    /// Renders a report as CSV with the table's sort and filter applied, so
    /// exporting what is on screen exports what is on screen.
    public func csv(for query: ReportQuery) throws -> String {
        CSVWriter.document(columns: query.definition.columns, rows: try rows(for: query))
    }

    /// Feeds a report to `sink` in chunks, never holding more than one chunk.
    ///
    /// A cursor rather than `LIMIT`/`OFFSET` paging: offset paging re-runs the
    /// query for every page, which turns one pass over the report into as many
    /// passes as it has pages.
    ///
    /// Returns how many data rows went past, so a caller can tell an empty report
    /// from one it has not read yet.
    @discardableResult
    public func streamCSV(for definition: ReportDefinition, chunkBytes: Int = Store.csvChunkBytes,
                          into sink: (Data) throws -> Void) throws -> Int {
        try streamCSV(sql: definition.sql, arguments: StatementArguments(),
                      columns: definition.columns, chunkBytes: chunkBytes, into: sink)
    }

    @discardableResult
    public func streamCSV(for query: ReportQuery, chunkBytes: Int = Store.csvChunkBytes,
                          into sink: (Data) throws -> Void) throws -> Int {
        let (sql, arguments) = query.sql(limit: nil, offset: 0)
        return try streamCSV(sql: sql, arguments: arguments, columns: query.definition.columns,
                             chunkBytes: chunkBytes, into: sink)
    }

    /// Roughly a page of output before each handoff. Small enough that memory
    /// stays flat, large enough that a half-million-row report is not a
    /// half-million writes.
    /// Overridable only so a test can prove the handoff happens without needing a
    /// fixture large enough to fill 64KB.
    public static let csvChunkBytes = 64 * 1024

    private func streamCSV(
        sql: String, arguments: StatementArguments, columns: [String],
        chunkBytes: Int, into sink: (Data) throws -> Void
    ) throws -> Int {
        var buffer = Data()
        buffer.reserveCapacity(chunkBytes * 2)
        buffer.append(contentsOf: Array((CSVWriter.row(columns) + CSVWriter.lineTerminator).utf8))

        var count = 0
        try dbQueue.read { db in
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try cursor.next() {
                let values = (0..<row.count).map { Self.text(row[$0]) }
                buffer.append(contentsOf: Array((CSVWriter.row(values) + CSVWriter.lineTerminator).utf8))
                count += 1
                if buffer.count >= chunkBytes {
                    try sink(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        if !buffer.isEmpty { try sink(buffer) }
        return count
    }

    /// Writes a report to a file, creating or replacing it.
    ///
    /// Written beside the target and moved into place, so a failure part way
    /// through leaves the previous export rather than half of a new one.
    @discardableResult
    public func writeCSV(for definition: ReportDefinition, to path: String) throws -> Int {
        try writingAtomically(to: path) { try streamCSV(for: definition, into: $0) }
    }

    @discardableResult
    public func writeCSV(for query: ReportQuery, to path: String) throws -> Int {
        try writingAtomically(to: path) { try streamCSV(for: query, into: $0) }
    }

    private func writingAtomically(to path: String, _ body: ((Data) throws -> Void) throws -> Int) throws -> Int {
        let target = URL(fileURLWithPath: path)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).partial")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: temporary.path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let count = try body { try handle.write(contentsOf: $0) }
            try handle.close()
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: temporary, to: target)
            return count
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Writes every report with at least one row into `directory`, named by report id.
    /// Empty reports are skipped: a directory of mostly header-only files makes the
    /// findings that do exist harder to spot, not easier.
    @discardableResult
    public func writeAllCSVs(to directory: String) throws -> [String] {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for definition in ReportCatalogue.all {
            let path = directory + "/\(definition.id).csv"
            // Written first and removed if it turns out to be empty, rather than
            // counted first and written second: counting means running every
            // report twice, and on a large crawl the second run is the expensive
            // one.
            if try writeCSV(for: definition, to: path) > 0 {
                written.append(path)
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        return written
    }
}
