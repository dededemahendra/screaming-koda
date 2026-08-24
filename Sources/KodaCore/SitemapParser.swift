import Foundation

/// What a sitemap document turned out to be.
public struct SitemapDocument: Sendable, Equatable {
    /// Page URLs, from a `<urlset>`.
    public let urls: [String]
    /// Child sitemap URLs, from a `<sitemapindex>`.
    public let sitemaps: [String]

    public var isIndex: Bool { !sitemaps.isEmpty && urls.isEmpty }
    public var isEmpty: Bool { urls.isEmpty && sitemaps.isEmpty }

    public init(urls: [String], sitemaps: [String]) {
        self.urls = urls
        self.sitemaps = sitemaps
    }
}

/// Reads `<urlset>` and `<sitemapindex>` documents.
///
/// `XMLParser` rather than a regex, because sitemaps are real XML with
/// namespaces, CDATA and entities, and because a malformed one has to fail
/// cleanly rather than half-match. It is a Foundation type, so this stays
/// headless.
///
/// Deliberately tolerant about which element a `<loc>` sits in: the element name
/// is what distinguishes a `<url>` from a `<sitemap>`, and a document that uses
/// an unexpected namespace prefix still parses because only the local name is
/// compared.
public enum SitemapParser {
    public static func parse(_ data: Data) -> SitemapDocument {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            // A partially-read document keeps whatever it managed to read: a
            // truncated sitemap listing 40,000 of 50,000 URLs is far more useful
            // than nothing, and the crawl was never going to be exhaustive.
            return SitemapDocument(urls: delegate.urls, sitemaps: delegate.sitemaps)
        }
        return SitemapDocument(urls: delegate.urls, sitemaps: delegate.sitemaps)
    }

    /// Google's stated limit is 50,000 URLs and 50MB per sitemap. Nothing here
    /// enforces the byte limit — the fetcher already caps what it downloads —
    /// but a document claiming far more entries than that is worth not
    /// following into memory unbounded.
    public static let maxEntries = 50_000

    private final class Delegate: NSObject, XMLParserDelegate {
        var urls: [String] = []
        var sitemaps: [String] = []
        private var inSitemapIndex = false
        private var capturing = false
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            switch name.lowercased() {
            case "sitemapindex": inSitemapIndex = true
            case "loc": capturing = true; buffer = ""
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { buffer += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if capturing, let text = String(data: CDATABlock, encoding: .utf8) { buffer += text }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            guard name.lowercased() == "loc", capturing else { return }
            capturing = false
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            if inSitemapIndex {
                if sitemaps.count < SitemapParser.maxEntries { sitemaps.append(value) }
            } else if urls.count < SitemapParser.maxEntries {
                urls.append(value)
            }
        }
    }
}
