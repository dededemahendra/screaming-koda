import Foundation

public enum CSVWriter {
    /// RFC 4180: CRLF line endings, and a field is quoted when it contains a
    /// comma, a quote, or a line break, with internal quotes doubled.
    ///
    /// `includeBOM` defaults to true because without it Excel — on both
    /// platforms — reads a UTF-8 CSV as the system codepage and mangles every
    /// non-ASCII character. In a tool whose job includes finding mangled text
    /// that would be a poor joke. Anything reading the file programmatically
    /// has to skip three bytes; that is the lesser cost.
    public static func encode(_ export: ReportExport, includeBOM: Bool = true) -> Data {
        var text = ""
        text += export.headers.map(field).joined(separator: ",") + "\r\n"
        for row in export.rows {
            text += row.map { field($0 ?? "") }.joined(separator: ",") + "\r\n"
        }
        var data = Data()
        if includeBOM { data.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        data.append(Data(text.utf8))
        return data
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
