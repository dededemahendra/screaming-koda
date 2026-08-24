import Foundation
import Testing
@testable import KodaCore

/// These validate the produced workbook with Python's `zipfile` and
/// `xml.etree`, not with a reader written alongside the writer. The question is
/// whether a real OOXML consumer accepts the file; only a real parser answers it.
@MainActor
private func validate(_ data: Data, script: String) throws -> String {
    let xlsx = FileManager.default.temporaryDirectory
        .appendingPathComponent("book-\(UUID().uuidString).xlsx")
    try data.write(to: xlsx)
    defer { try? FileManager.default.removeItem(at: xlsx) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, xlsx.path]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdout = out.fileHandleForReading.readDataToEndOfFile()
    let stderr = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        Issue.record("python failed: \(String(decoding: stderr, as: UTF8.self))")
        return ""
    }
    return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private let sample = [
    ReportExport(name: "Internal",
                 headers: ["Address", "Status", "Title"],
                 rows: [["https://x.test/", "200", "Home & \"quoted\" <tag>"],
                        ["https://x.test/b", "404", nil]]),
    ReportExport(name: "Titles", headers: ["Address"], rows: [["https://x.test/"]]),
]

/// Every part must be present and must parse as XML. A zip that opens but holds
/// malformed XML is exactly the failure Excel reports as "unreadable content".
@MainActor
@Test func producesAWorkbookEveryPartOfWhichParsesAsXML() throws {
    let script = """
        import sys, zipfile, xml.etree.ElementTree as ET
        z = zipfile.ZipFile(sys.argv[1])
        bad = z.testzip()
        assert bad is None, bad
        names = set(z.namelist())
        required = {'[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml',
                    'xl/_rels/workbook.xml.rels', 'xl/worksheets/sheet1.xml',
                    'xl/worksheets/sheet2.xml'}
        assert required <= names, sorted(required - names)
        for n in names:
            ET.fromstring(z.read(n))
        print(len(names))
        """
    #expect(try validate(try XLSXWriter.encode(sample), script: script) == "6")
}

/// A sheet the workbook does not list is invisible; a listed sheet with no part
/// is a corrupt file. Both directions are checked.
@MainActor
@Test func everySheetIsListedInTheWorkbookAndEveryListedSheetExists() throws {
    let script = """
        import sys, zipfile, xml.etree.ElementTree as ET
        NS = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
        R = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
        PR = '{http://schemas.openxmlformats.org/package/2006/relationships}'
        z = zipfile.ZipFile(sys.argv[1])
        wb = ET.fromstring(z.read('xl/workbook.xml'))
        rels = {r.get('Id'): r.get('Target')
                for r in ET.fromstring(z.read('xl/_rels/workbook.xml.rels'))}
        names = []
        for sheet in wb.find(NS + 'sheets'):
            target = rels[sheet.get(R + 'id')]
            assert 'xl/' + target in z.namelist(), target
            names.append(sheet.get('name'))
        print(','.join(names))
        """
    #expect(try validate(try XLSXWriter.encode(sample), script: script) == "Internal,Titles")
}

@MainActor
@Test func aKnownCellHoldsItsKnownValueIncludingEscapedCharacters() throws {
    let script = """
        import sys, zipfile, xml.etree.ElementTree as ET
        NS = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
        z = zipfile.ZipFile(sys.argv[1])
        sheet = ET.fromstring(z.read('xl/worksheets/sheet1.xml'))
        cells = {}
        for row in sheet.find(NS + 'sheetData'):
            for c in row:
                t = c.find(NS + 'is/' + NS + 't')
                cells[c.get('r')] = t.text if t is not None else None
        print('|'.join([cells.get('A1',''), cells.get('C2',''),
                        cells.get('B3',''), str('C3' in cells)]))
        """
    // A1 header, C2 the escaped title, B3 the 404, and C3 absent because that
    // cell is a genuine NULL rather than an empty string.
    #expect(try validate(try XLSXWriter.encode(sample), script: script)
            == "Address|Home & \"quoted\" <tag>|404|False")
}

/// The end-to-end shape a user actually gets: eleven sheets from a real crawl.
@MainActor
@Test func awholeCrawlExportsToAValidWorkbookWithEverySheet() throws {
    let store = try ReportFixture.make()
    let data = try XLSXWriter.encode(try store.exportAll())
    let script = """
        import sys, zipfile, xml.etree.ElementTree as ET
        NS = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
        z = zipfile.ZipFile(sys.argv[1])
        assert z.testzip() is None
        for n in z.namelist():
            ET.fromstring(z.read(n))
        wb = ET.fromstring(z.read('xl/workbook.xml'))
        print(len(wb.find(NS + 'sheets')))
        """
    #expect(try validate(data, script: script) == "24")
}
