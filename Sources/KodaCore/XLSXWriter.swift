import Foundation

/// Writes an `.xlsx` workbook directly, with one sheet per report.
///
/// Cells use `inlineStr`, which puts each string in the cell rather than in a
/// shared-strings table. That makes the file larger and the writer far simpler —
/// the right trade for an export nobody diffs and everybody opens once.
public enum XLSXWriter {

    /// Throws `ZIPArchiveError.tooLarge` for a crawl that will not fit in the
    /// format's 32-bit size limit, rather than trapping on the `UInt32`
    /// conversion. `sizeLimit` is injectable so that path is testable.
    public static func encode(_ exports: [ReportExport],
                              sizeLimit: Int = Int(UInt32.max)) throws -> Data {
        let names = sheetNames(exports.map(\.name))
        var zip = ZIPArchive(sizeLimit: sizeLimit)

        try zip.add(path: "[Content_Types].xml", data: Data(contentTypes(count: exports.count).utf8))
        try zip.add(path: "_rels/.rels", data: Data(rootRels.utf8))
        try zip.add(path: "xl/workbook.xml", data: Data(workbook(names: names).utf8))
        try zip.add(path: "xl/_rels/workbook.xml.rels",
                    data: Data(workbookRels(count: exports.count).utf8))
        for (index, export) in exports.enumerated() {
            try zip.add(path: "xl/worksheets/sheet\(index + 1).xml", data: Data(sheet(export).utf8))
        }
        return try zip.finish()
    }

    // MARK: - Sheet naming

    /// Excel rejects `: \ / ? * [ ]` in a sheet name and caps it at 31
    /// characters. Truncation can make two different report names collide, so
    /// the result is de-duplicated as well as sanitised — a workbook with two
    /// sheets of the same name will not open.
    static func sheetNames(_ raw: [String]) -> [String] {
        let forbidden = CharacterSet(charactersIn: ":\\/?*[]")
        var used = Set<String>()
        return raw.map { name in
            var cleaned = name.components(separatedBy: forbidden).joined(separator: " ")
            if cleaned.count > 31 { cleaned = String(cleaned.prefix(31)) }
            if cleaned.isEmpty { cleaned = "Sheet" }
            var candidate = cleaned
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                let tag = " (\(suffix))"
                candidate = String(cleaned.prefix(31 - tag.count)) + tag
                suffix += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    // MARK: - Parts

    static func contentTypes(count: Int) -> String {
        let sheets = (1...max(count, 1)).map {
            """
            <Override PartName="/xl/worksheets/sheet\($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            """
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            \(sheets)</Types>
            """
    }

    static let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """

    static func workbook(names: [String]) -> String {
        let sheets = names.enumerated().map { index, name in
            "<sheet name=\"\(escape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets>\(sheets)</sheets></workbook>
            """
    }

    static func workbookRels(count: Int) -> String {
        let rels = (1...max(count, 1)).map {
            """
            <Relationship Id="rId\($0)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\($0).xml"/>
            """
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(rels)</Relationships>
            """
    }

    static func sheet(_ export: ReportExport) -> String {
        var body = ""
        body += row(export.headers.map { Optional($0) }, number: 1)
        for (index, cells) in export.rows.enumerated() {
            body += row(cells, number: index + 2)
        }
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetData>\(body)</sheetData></worksheet>
            """
    }

    static func row(_ cells: [String?], number: Int) -> String {
        var out = "<row r=\"\(number)\">"
        for (index, cell) in cells.enumerated() {
            // A NULL is written as no cell at all rather than an empty string,
            // which is how a spreadsheet distinguishes blank from "".
            guard let cell else { continue }
            out += "<c r=\"\(columnLetters(index))\(number)\" t=\"inlineStr\">"
                + "<is><t xml:space=\"preserve\">\(escape(cell))</t></is></c>"
        }
        return out + "</row>"
    }

    /// 0 → A, 25 → Z, 26 → AA. Reports have at most a dozen columns today, but
    /// getting this wrong past Z is a classic silent corruption.
    static func columnLetters(_ index: Int) -> String {
        var n = index
        var letters = ""
        repeat {
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n = n / 26 - 1
        } while n >= 0
        return letters
    }

    /// XML-escapes, and drops control characters.
    ///
    /// The control-character strip is not paranoia: a crawled page title can
    /// legally contain a form feed or a vertical tab, and those are illegal in
    /// XML 1.0 at any escaping. A single stray byte in one title would produce a
    /// workbook Excel refuses to open, with no indication which row caused it.
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
