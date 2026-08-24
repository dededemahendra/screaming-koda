import Foundation
import Testing
@testable import KodaCore

private func fixturePDF() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/site", withExtension: nil))
    return try Data(contentsOf: url.appendingPathComponent("report.pdf"))
}

@Test func aPDFIsRecognisedByItsContentType() throws {
    #expect(PDFFacts.isPDF(contentType: "application/pdf", body: nil))
    #expect(PDFFacts.isPDF(contentType: "application/pdf; charset=binary", body: nil))
}

/// Plenty of servers send `application/octet-stream` for a PDF. Trusting the
/// header alone would record those as untitled binaries.
@Test func aMislabelledPDFIsRecognisedByItsSignature() throws {
    let body = try fixturePDF()
    #expect(PDFFacts.isPDF(contentType: "application/octet-stream", body: body))
    #expect(PDFFacts.isPDF(contentType: nil, body: body))
}

@Test func anHTMLPageIsNotAPDF() {
    #expect(!PDFFacts.isPDF(contentType: "text/html", body: Data("<html>".utf8)))
    #expect(!PDFFacts.isPDF(contentType: nil, body: Data()))
    #expect(!PDFFacts.isPDF(contentType: nil, body: nil))
}

@Test func pdfMetadataBecomesPageFacts() throws {
    let facts = try #require(PDFFacts.parse(try fixturePDF()))
    #expect(facts.title == "The Fixture Report")
    #expect(facts.titleCount == 1)
    #expect(facts.metaDescription == "A PDF served by the fixture site")
    #expect(facts.wordCount > 0, "the text layer is read, not just the metadata")
}

/// A PDF with no title has no title. Substituting the filename would turn a real
/// finding into a fabricated pass.
@Test func aPDFWithNoTitleReportsNoTitle() throws {
    var untitled = try fixturePDF()
    // Blank out the /Title entry, leaving the rest of the document intact.
    if let range = untitled.range(of: Data("/Title (The Fixture Report)".utf8)) {
        untitled.replaceSubrange(range, with: Data("/Title ()                  ".utf8))
    }
    let facts = try #require(PDFFacts.parse(untitled))
    #expect(facts.title == nil)
    #expect(facts.titleCount == 0)
}

@Test func aCorruptPDFReturnsNilRatherThanCrashing() {
    #expect(PDFFacts.parse(Data("%PDF-1.4 and then nonsense".utf8)) == nil)
    #expect(PDFFacts.parse(Data()) == nil)
}
