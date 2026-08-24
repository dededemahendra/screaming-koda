import CryptoKit
import Foundation
import SwiftSoup

public protocol PageParser: Sendable {
    func parse(html: String) throws -> PageFacts
    /// Parse, then apply the crawl's custom extraction rules. Default-implemented
    /// so existing parsers and every existing test keep working unchanged.
    func parse(html: String, extractions: [ExtractionRule]) throws -> PageFacts
}

extension PageParser {
    public func parse(html: String, extractions: [ExtractionRule]) throws -> PageFacts {
        try parse(html: html)
    }
}

public struct SwiftSoupParser: PageParser {
    public init() {}

    public func parse(html: String, extractions: [ExtractionRule]) throws -> PageFacts {
        var facts = try parse(html: html)
        guard !extractions.isEmpty else { return facts }
        let doc = try SwiftSoup.parse(html)
        for rule in extractions {
            // A selector that does not compile yields nothing for that rule and
            // leaves the rest of the page alone: one bad rule must not cost the
            // whole crawl, which is the same rule the fetcher and parser follow.
            guard let matched = try? doc.select(rule.selector).array() else { continue }
            for (index, element) in matched.enumerated() {
                let raw: String?
                switch rule.value {
                case .text: raw = try? element.text()
                case .html: raw = try? element.html()
                case .attribute:
                    // The selector carries the attribute, as `a[href]` does, so
                    // the last attribute named in it is the one wanted.
                    let attribute = Self.attributeName(from: rule.selector)
                    raw = attribute.flatMap { try? element.attr($0) }
                }
                guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { continue }
                facts.extractions.append(
                    ExtractionFact(name: rule.name, value: value, position: index))
            }
        }
        return facts
    }

    /// `div.price[data-value]` -> `data-value`.
    static func attributeName(from selector: String) -> String? {
        guard let open = selector.lastIndex(of: "["),
              let close = selector[open...].firstIndex(of: "]") else { return nil }
        let inner = selector[selector.index(after: open)..<close]
        let name = inner.split(separator: "=").first.map(String.init) ?? String(inner)
        let cleaned = name.trimmingCharacters(in: CharacterSet(charactersIn: " ^$*~|"))
        return cleaned.isEmpty ? nil : cleaned
    }

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
        let h2s = try doc.select("h2")
        facts.h2Count = h2s.array().count
        facts.h2 = try h2s.first()?.text().trimmed()

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
            // Declared attributes only. A width of "100%" or "auto" is not a
            // pixel dimension and is treated as undeclared, which is what it
            // means for layout shift.
            let width = Int(try element.attr("width").trimmingCharacters(in: .whitespaces))
            let height = Int(try element.attr("height").trimmingCharacters(in: .whitespaces))
            facts.images.append(ImageFact(src: src, alt: alt, width: width, height: height))
        }

        for element in try doc.select("link[rel=alternate][hreflang]").array() {
            let lang = try element.attr("hreflang").trimmed()
            let href = try element.attr("href").trimmed()
            if let lang, let href {
                facts.hreflang.append(HreflangFact(lang: lang, href: href))
            }
        }

        facts.ogTitle = try Self.metaProperty(doc, "og:title")
        facts.ogDescription = try Self.metaProperty(doc, "og:description")
        facts.ogImage = try Self.metaProperty(doc, "og:image")
        facts.ogType = try Self.metaProperty(doc, "og:type")
        // Twitter's own tags use name=, not property=, but plenty of sites emit
        // them the other way round, so both are accepted.
        facts.twitterCard = try Self.metaProperty(doc, "twitter:card")
        facts.twitterTitle = try Self.metaProperty(doc, "twitter:title")
        facts.twitterImage = try Self.metaProperty(doc, "twitter:image")

        facts.amphtml = try doc.select("link[rel=amphtml]").first()?.attr("href").trimmed()
        facts.relPrev = try doc.select("link[rel=prev]").first()?.attr("href").trimmed()
        facts.relNext = try doc.select("link[rel=next]").first()?.attr("href").trimmed()

        for element in try doc.select("link[rel=stylesheet][href]").array() {
            let href = try element.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
            if !href.isEmpty { facts.resources.append(ResourceFact(src: href, kind: "css")) }
        }
        for element in try doc.select("script[src]").array() {
            let src = try element.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
            if !src.isEmpty { facts.resources.append(ResourceFact(src: src, kind: "js")) }
        }

        facts.structuredData = try Self.structuredData(doc)
        facts.analytics = try Self.analytics(doc)

        let text = try Self.visibleText(doc)
        facts.textLength = text.count
        facts.wordCount = text.split(whereSeparator: { $0 == " " }).count
        facts.contentHash = Data(SHA256.hash(data: Data(text.utf8)))
        facts.simHash = SimHash.compute(text)

        return facts
    }

    /// Reads a meta tag by `property` or by `name`. The Open Graph spec says
    /// `property` and the Twitter spec says `name`, and real pages use both for
    /// both, so asking for either is the only way to find them reliably.
    static func metaProperty(_ doc: Document, _ key: String) throws -> String? {
        for selector in ["meta[property=\(key)]", "meta[name=\(key)]"] {
            if let value = try doc.select(selector).first()?.attr("content").trimmed() {
                return value
            }
        }
        return nil
    }

    /// Schema types declared on the page, in all three markup formats.
    ///
    /// Only the *types* are kept, not the whole graph: the question a crawler is
    /// asked is "which pages carry Product markup", not "what is in it".
    /// Validating the payload is a different feature and a much larger one.
    static func structuredData(_ doc: Document) throws -> [StructuredDataFact] {
        var out: [StructuredDataFact] = []
        var seen = Set<String>()
        func add(_ format: String, _ type: String) {
            let cleaned = type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            // A schema.org URL and its bare name are the same type.
            let name = cleaned.components(separatedBy: CharacterSet(charactersIn: "/#")).last ?? cleaned
            guard !name.isEmpty, seen.insert("\(format)|\(name)").inserted else { return }
            out.append(StructuredDataFact(format: format, type: name))
        }

        for script in try doc.select("script[type=application/ld+json]").array() {
            let raw = try script.html()
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            for type in Self.jsonLDTypes(parsed) { add("json-ld", type) }
        }
        for element in try doc.select("[itemscope][itemtype]").array() {
            add("microdata", try element.attr("itemtype"))
        }
        for element in try doc.select("[typeof]").array() {
            for type in try element.attr("typeof").split(separator: " ") { add("rdfa", String(type)) }
        }
        return out
    }

    /// Walks a decoded JSON-LD payload for `@type`, which can be a string or an
    /// array, at the top level or nested inside `@graph` or any object value.
    static func jsonLDTypes(_ value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var out: [String] = []
            if let type = dictionary["@type"] as? String { out.append(type) }
            if let types = dictionary["@type"] as? [Any] {
                out.append(contentsOf: types.compactMap { $0 as? String })
            }
            for (key, nested) in dictionary where key != "@type" {
                out.append(contentsOf: jsonLDTypes(nested))
            }
            return out
        }
        if let array = value as? [Any] { return array.flatMap { jsonLDTypes($0) } }
        return []
    }

    /// Analytics and tag managers, detected by the script URLs and globals they
    /// install. Matched against markup rather than executed, so a tag injected
    /// at runtime by another script is invisible — the same limitation the whole
    /// crawler has without a rendering step.
    static let analyticsSignatures: [(name: String, needles: [String])] = [
        ("Google Tag Manager", ["googletagmanager.com/gtm.js", "gtm.start"]),
        ("Google Analytics 4", ["googletagmanager.com/gtag/js", "gtag(\'config\'"]),
        ("Universal Analytics", ["google-analytics.com/analytics.js", "ga(\'create\'"]),
        ("Meta Pixel", ["connect.facebook.net", "fbq(\'init\'"]),
        ("Hotjar", ["static.hotjar.com", "hjSiteSettings"]),
        ("Plausible", ["plausible.io/js"]),
        ("Matomo", ["matomo.js", "piwik.js"]),
        ("Segment", ["cdn.segment.com"]),
        ("PostHog", ["posthog.com/static/array.js", "posthog.init"]),
        ("HubSpot", ["js.hs-scripts.com", "js.hsforms.net"]),
    ]

    static func analytics(_ doc: Document) throws -> [String] {
        let haystack = try doc.select("script").array()
            .map { try $0.attr("src") + " " + $0.html() }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return [] }
        return analyticsSignatures
            .filter { signature in signature.needles.contains { haystack.contains($0.lowercased()) } }
            .map(\.name)
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
