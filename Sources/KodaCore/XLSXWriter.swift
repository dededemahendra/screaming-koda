import Foundation

/// Writes a workbook: one sheet per report, no styles, no shared strings.
///
/// CSV is the honest export format and stays the default. A workbook exists
/// because a crawl produces thirty related tables, and mailing someone thirty
/// files is worse than mailing them one — the tabs *are* the feature.
///
/// Values are written inline rather than through a shared string table. A shared
/// table is smaller when text repeats, and on a crawl it mostly does not: every
/// row leads with a distinct URL.
public enum XLSXWriter {
    public struct Sheet: Sendable {
        public let name: String
        public let columns: [String]
        public let rows: [[String?]]

        public init(name: String, columns: [String], rows: [[String?]]) {
            self.name = name
            self.columns = columns
            self.rows = rows
        }
    }

    public static func workbook(sheets: [Sheet]) -> Data {
        let sheets = namedUniquely(sheets)
        var entries: [ZIPArchive.Entry] = []

        entries.append(.init(path: "[Content_Types].xml", data: Data(contentTypes(count: sheets.count).utf8)))
        entries.append(.init(path: "_rels/.rels", data: Data(rootRelationships.utf8)))
        entries.append(.init(path: "xl/workbook.xml", data: Data(workbookXML(sheets: sheets).utf8)))
        entries.append(.init(path: "xl/_rels/workbook.xml.rels",
                             data: Data(workbookRelationships(count: sheets.count).utf8)))
        for (index, sheet) in sheets.enumerated() {
            entries.append(.init(path: "xl/worksheets/sheet\(index + 1).xml",
                                 data: Data(sheetXML(sheet).utf8)))
        }
        return ZIPArchive.archive(entries)
    }

    // MARK: Sheet names

    /// Excel rejects a workbook whose sheet names collide, exceed 31 characters,
    /// or contain `:\/?*[]`. Report ids are none of those things today, so this is
    /// insurance against a future report id rather than a live problem.
    static func namedUniquely(_ sheets: [Sheet]) -> [Sheet] {
        var taken: Set<String> = []
        return sheets.map { sheet in
            var name = sheet.name
                .replacingOccurrences(of: "[:\\\\/?*\\[\\]]", with: "-", options: .regularExpression)
            if name.isEmpty { name = "Sheet" }
            if name.count > 31 { name = String(name.prefix(31)) }

            var candidate = name
            var suffix = 2
            while taken.contains(candidate.lowercased()) {
                let tag = "~\(suffix)"
                candidate = String(name.prefix(31 - tag.count)) + tag
                suffix += 1
            }
            taken.insert(candidate.lowercased())
            return Sheet(name: candidate, columns: sheet.columns, rows: sheet.rows)
        }
    }

    // MARK: Parts

    private static func contentTypes(count: Int) -> String {
        let sheets = (1...max(count, 1)).map {
            """
            <Override PartName="/xl/worksheets/sheet\($0).xml" \
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            """
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" \
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            \(sheets)</Types>
            """
    }

    private static let rootRelationships = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="xl/workbook.xml"/></Relationships>
        """

    private static func workbookXML(sheets: [Sheet]) -> String {
        let entries = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(escape(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
            xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets>\(entries)</sheets></workbook>
            """
    }

    private static func workbookRelationships(count: Int) -> String {
        let entries = (1...max(count, 1)).map {
            """
            <Relationship Id="rId\($0)" \
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
            Target="worksheets/sheet\($0).xml"/>
            """
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            \(entries)</Relationships>
            """
    }

    private static func sheetXML(_ sheet: Sheet) -> String {
        var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" \
            activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
            \(columnWidths(sheet))<sheetData>
            """
        xml += row(number: 1, values: sheet.columns.map { $0 }, forceText: true)
        for (index, values) in sheet.rows.enumerated() {
            xml += row(number: index + 2, values: values, forceText: false)
        }
        xml += "</sheetData>"
        // An autofilter over the used range, so the header row gets Excel's
        // sort and filter controls without any styling machinery.
        if !sheet.columns.isEmpty {
            let last = "\(column(sheet.columns.count - 1))\(sheet.rows.count + 1)"
            xml += "<autoFilter ref=\"A1:\(last)\"/>"
        }
        return xml + "</worksheet>"
    }

    /// Widths, because the default column is narrow enough to truncate every URL
    /// in the export and a spreadsheet nobody can read is not an export.
    ///
    /// Measured over the header and the first rows rather than all of them: on a
    /// 500k-row report the widest cell is an outlier nobody wants a column sized to,
    /// and walking every row to find it is not free.
    private static func columnWidths(_ sheet: Sheet) -> String {
        guard !sheet.columns.isEmpty else { return "" }
        let sample = sheet.rows.prefix(200)
        let widths = sheet.columns.indices.map { index -> Int in
            let longest = sample.reduce(sheet.columns[index].count) { widest, row in
                max(widest, index < row.count ? (row[index]?.count ?? 0) : 0)
            }
            return min(max(longest + 2, 9), 64)
        }
        let entries = widths.enumerated().map { index, width in
            "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }.joined()
        return "<cols>\(entries)</cols>"
    }

    private static func row(number: Int, values: [String?], forceText: Bool) -> String {
        var xml = "<row r=\"\(number)\">"
        for (index, value) in values.enumerated() {
            // A NULL is written as no cell at all, which is how a spreadsheet
            // spells "nothing here" — an empty string would read as a value.
            guard let value else { continue }
            let reference = "\(column(index))\(number)"
            if !forceText, let number = numeric(value) {
                xml += "<c r=\"\(reference)\"><v>\(number)</v></c>"
            } else {
                xml += "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">"
                    + escape(value) + "</t></is></c>"
            }
        }
        return xml + "</row>"
    }

    /// A value worth storing as a number rather than text: status codes, byte
    /// counts, lengths. Only when the digits round-trip, so an ID like `007`
    /// or a version like `1.10` stays the text it was.
    static func numeric(_ value: String) -> String? {
        if let int = Int(value), String(int) == value { return value }
        if let double = Double(value), String(double) == value, double.isFinite { return value }
        return nil
    }

    /// A1-style column reference: A, B, … Z, AA, AB, …
    static func column(_ index: Int) -> String {
        var index = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + index % 26))) + name
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    /// XML 1.0 has no way to represent most control characters, not even as an
    /// entity, and a crawled `<title>` can contain anything at all. Dropping them
    /// is the only option that still produces a file that opens.
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
            case let s where s.value < 0x20 || (0x7F...0x9F).contains(s.value): continue
            case let s where (0xFFFE...0xFFFF).contains(s.value): continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

extension Store {
    /// Every report with findings as one workbook, plus an overview sheet naming
    /// the crawl and counting each report. Reports with nothing in them are left
    /// out for the same reason the CSV export leaves them out: thirty empty tabs
    /// hide the two that matter.
    public func xlsx() throws -> Data {
        var sheets: [XLSXWriter.Sheet] = []
        var index: [[String?]] = []

        for definition in ReportCatalogue.all {
            let rows = try runReport(definition)
            guard !rows.isEmpty else { continue }
            index.append([definition.group, definition.name, definition.kind.rawValue,
                          String(rows.count), definition.summary])
            sheets.append(XLSXWriter.Sheet(name: definition.id, columns: definition.columns, rows: rows))
        }

        let overview = try overviewSheet(reportIndex: index)
        return XLSXWriter.workbook(sheets: [overview] + sheets)
    }

    public func writeXLSX(to path: String) throws {
        try xlsx().write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func overviewSheet(reportIndex: [[String?]]) throws -> XLSXWriter.Sheet {
        let summary = try summary()
        let config = try loadConfig()
        var rows: [[String?]] = [
            ["Crawl", "Seed", nil, nil, config?.seedURL],
            ["Crawl", "Exported", nil, nil, ISO8601DateFormatter().string(from: Date())],
            ["URLs", "Discovered", nil, String(summary.totalURLs), nil],
            ["URLs", "Crawled", nil, String(summary.crawledURLs), nil],
            ["URLs", "Internal", nil, String(summary.internalURLs), nil],
            ["URLs", "External", nil, String(summary.externalURLs), nil],
            ["URLs", "Maximum depth", nil, String(summary.maxDepth), nil],
        ]
        for key in summary.byStatusClass.keys.sorted() {
            rows.append(["Responses", key, nil, String(summary.byStatusClass[key] ?? 0), nil])
        }
        if summary.transportErrors > 0 {
            rows.append(["Responses", "Transport errors", nil, String(summary.transportErrors), nil])
        }
        rows += reportIndex
        return XLSXWriter.Sheet(
            name: "Overview",
            columns: ["Group", "Name", "Kind", "Count", "Detail"],
            rows: rows
        )
    }
}
