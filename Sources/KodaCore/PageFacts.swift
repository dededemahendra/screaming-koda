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

    public init(src: String, alt: String?) {
        self.src = src
        self.alt = alt
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
    public var h2Count: Int = 0
    public var canonical: String?
    public var canonicalCount: Int = 0
    public var metaRobots: String?
    public var lang: String?
    public var wordCount: Int = 0
    public var contentHash: Data = Data()
    public var links: [LinkFact] = []
    public var images: [ImageFact] = []
    public var hreflang: [HreflangFact] = []

    public var titleLength: Int? { title?.count }
    public var metaDescriptionLength: Int? { metaDescription?.count }

    public init() {}
}
