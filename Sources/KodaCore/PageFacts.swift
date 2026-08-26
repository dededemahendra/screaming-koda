import Foundation

public struct LinkFact: Sendable {
    public let href: String
    public let anchor: String
    public let rel: String?
    public let position: Int

    public init(href: String, anchor: String, rel: String?, position: Int) {
        self.href = href
        self.anchor = anchor
        self.rel = rel
        self.position = position
    }
}

public struct ImageFact: Sendable {
    public let src: String
    public let alt: String?
    /// The declared `width`/`height` attributes, when present. Undeclared
    /// dimensions are the usual cause of layout shift, so their *absence* is
    /// the finding — this is not the decoded size of the image.
    public let width: Int?
    public let height: Int?

    public init(src: String, alt: String?, width: Int? = nil, height: Int? = nil) {
        self.src = src
        self.alt = alt
        self.width = width
        self.height = height
    }
}

/// A stylesheet or script the page loads.
public struct ResourceFact: Sendable, Equatable {
    public let src: String
    /// `css` or `js`.
    public let kind: String

    public init(src: String, kind: String) {
        self.src = src
        self.kind = kind
    }
}

/// One extracted value. A rule that matches several elements produces several
/// of these, which is why `position` exists.
public struct ExtractionFact: Sendable, Equatable {
    public let name: String
    public let value: String
    public let position: Int

    public init(name: String, value: String, position: Int) {
        self.name = name
        self.value = value
        self.position = position
    }
}

/// One structured-data declaration. A page can carry many.
public struct StructuredDataFact: Sendable, Equatable {
    /// `json-ld`, `microdata` or `rdfa`.
    public let format: String
    /// The schema type, e.g. `Product`, `Article`, `BreadcrumbList`.
    public let type: String

    public init(format: String, type: String) {
        self.format = format
        self.type = type
    }
}

public struct HreflangFact: Sendable {
    public let lang: String
    public let href: String

    public init(lang: String, href: String) {
        self.lang = lang
        self.href = href
    }
}

public struct PageFacts: Sendable {
    public var title: String?
    public var titleCount: Int = 0
    public var metaDescription: String?
    public var metaDescriptionCount: Int = 0
    public var h1: String?
    public var h1Count: Int = 0
    /// First H2 text. Counted since M1; stored from v4, because a count alone
    /// cannot answer "is this H2 duplicated" or "is it too long".
    public var h2: String?
    public var h2Count: Int = 0
    /// The document's `<base href>`, if it declared one. Relative URLs in the
    /// page resolve against this rather than against the page's own address.
    /// Reported rather than applied: the parser is not told where the page came
    /// from, so it cannot resolve anything.
    public var baseHref: String?
    public var canonical: String?
    /// How many `<link rel=canonical>` elements the page declares. Only the
    /// first is followed, but a page declaring two is a real finding that was
    /// invisible while only the first was recorded.
    public var canonicalCount: Int = 0
    public var metaRobots: String?
    public var lang: String?
    public var wordCount: Int = 0
    /// Characters of visible text, for the text-to-HTML ratio.
    public var textLength: Int = 0
    public var contentHash: Data = Data()
    /// Near-duplicate fingerprint. nil for text too short to fingerprint.
    public var simHash: Int64?
    public var ogTitle: String?
    public var ogDescription: String?
    public var ogImage: String?
    public var ogType: String?
    public var twitterCard: String?
    public var twitterTitle: String?
    public var twitterImage: String?
    /// `<link rel="amphtml">` target, when the page declares an AMP version.
    public var amphtml: String?
    public var relPrev: String?
    public var relNext: String?
    /// Names of analytics or tag-manager scripts detected in the markup.
    public var analytics: [String] = []
    public var structuredData: [StructuredDataFact] = []
    public var extractions: [ExtractionFact] = []
    public var resources: [ResourceFact] = []
    public var links: [LinkFact] = []
    public var images: [ImageFact] = []
    public var hreflang: [HreflangFact] = []

    public var titleLength: Int? { title?.count }
    public var metaDescriptionLength: Int? { metaDescription?.count }

    public init() {}
}
