import CryptoKit
import Foundation
import PDFKit

/// Reads title, author and page count out of a fetched PDF.
///
/// PDFKit rather than a hand-rolled `/Info` parser: it is in the SDK, it handles
/// the encodings and compressed cross-reference streams real PDFs use, and it
/// works entirely headless — verified under Command Line Tools with no display
/// and no `NSApplication`. It is a Quartz framework, not an AppKit one, so
/// `KodaCore` keeps its property of building and testing without a UI.
public enum PDFFacts {
    /// Whether a response looks like a PDF, by content type or by signature.
    ///
    /// The signature check matters: plenty of servers send `application/octet-stream`
    /// for a PDF, and a crawler that trusted the header alone would record those
    /// as untitled binaries.
    public static func isPDF(contentType: String?, body: Data?) -> Bool {
        if contentType?.lowercased().contains("application/pdf") == true { return true }
        guard let body, body.count >= 5 else { return false }
        return body.prefix(5).elementsEqual(Data("%PDF-".utf8))
    }

    /// Maps a PDF into the same `PageFacts` shape an HTML page produces, so
    /// every existing report keeps working without knowing what a PDF is.
    ///
    /// Title comes from the document's own metadata; where that is absent the
    /// page has no title, which is a real SEO finding rather than something to
    /// paper over with a filename.
    public static func parse(_ body: Data) -> PageFacts? {
        guard let document = PDFDocument(data: body) else { return nil }
        var facts = PageFacts()
        let attributes = document.documentAttributes ?? [:]

        func attribute(_ key: PDFDocumentAttribute) -> String? {
            (attributes[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty
        }
        facts.title = attribute(.titleAttribute)
        facts.titleCount = facts.title == nil ? 0 : 1
        facts.metaDescription = attribute(.subjectAttribute)
        facts.metaDescriptionCount = facts.metaDescription == nil ? 0 : 1
        // Author and keywords have no HTML equivalent, so they ride in the
        // fields that mean the closest thing rather than earning new columns.
        facts.lang = attribute(.creatorAttribute)

        let text = (document.string ?? "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        facts.wordCount = text.isEmpty ? 0 : text.split(separator: " ").count
        facts.contentHash = Data(SHA256.hash(data: Data(text.utf8)))
        return facts
    }
}

private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
