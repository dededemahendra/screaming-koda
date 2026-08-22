import CryptoKit
import Foundation
import SwiftSoup

public protocol PageParser: Sendable {
    func parse(html: String) throws -> PageFacts
}

public struct SwiftSoupParser: PageParser {
    public init() {}

    public func parse(html: String) throws -> PageFacts {
        let doc = try SwiftSoup.parse(html)
        var facts = PageFacts()

        let titles = try doc.select("head title")
        facts.titleCount = titles.array().count
        facts.title = try titles.first()?.text().trimmed()

        let descriptions = try doc.select("meta[name=description]")
        facts.metaDescriptionCount = descriptions.array().count
        facts.metaDescription = try descriptions.first()?.attr("content").trimmed()

        let h1s = try doc.select("h1")
        facts.h1Count = h1s.array().count
        facts.h1 = try h1s.first()?.text().trimmed()
        facts.h2Count = try doc.select("h2").array().count

        let canonicals = try doc.select("link[rel=canonical]")
        facts.canonicalCount = canonicals.array().count
        facts.canonical = try canonicals.first()?.attr("href").trimmed()
        facts.metaRobots = try doc.select("meta[name=robots]").first()?.attr("content").trimmed()
        facts.lang = try doc.select("html").first()?.attr("lang").trimmed()

        // `.array()` is used throughout: SwiftSoup's Elements is not reliably a Sequence across versions.
        for (index, element) in try doc.select("a[href]").array().enumerated() {
            let href = try element.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else { continue }
            let rel = try element.attr("rel").trimmed()
            let anchor = try element.text().trimmed() ?? ""
            facts.links.append(LinkFact(href: href, anchor: anchor, rel: rel, position: index))
        }

        for element in try doc.select("img[src]").array() {
            let src = try element.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !src.isEmpty else { continue }
            let alt: String?
            if element.hasAttr("alt") {
                alt = try element.attr("alt")
            } else {
                alt = nil
            }
            facts.images.append(ImageFact(src: src, alt: alt))
        }

        for element in try doc.select("link[rel=alternate][hreflang]").array() {
            let lang = try element.attr("hreflang").trimmed()
            let href = try element.attr("href").trimmed()
            if let lang, let href {
                facts.hreflang.append(HreflangFact(lang: lang, href: href))
            }
        }

        let text = try Self.visibleText(doc)
        facts.wordCount = text.split(whereSeparator: { $0 == " " }).count
        facts.contentHash = Data(SHA256.hash(data: Data(text.utf8)))

        return facts
    }

    /// Visible text with script, style, and noscript removed and whitespace collapsed.
    static func visibleText(_ doc: Document) throws -> String {
        let copy = doc.copy() as! Document
        try copy.select("script, style, noscript").remove()
        let raw = try copy.body()?.text() ?? ""
        return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

extension String {
    /// Trimmed, or nil when empty — attributes that are absent and attributes that are blank mean the same thing here.
    func trimmed() -> String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
