import Foundation
import Testing
@testable import KodaCore

private func parse(_ xml: String) -> SitemapDocument {
    SitemapParser.parse(Data(xml.utf8))
}

@Test func aUrlsetYieldsPageURLs() {
    let doc = parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>https://x.test/</loc><lastmod>2026-01-01</lastmod></url>
          <url><loc>https://x.test/about</loc></url>
        </urlset>
        """)
    #expect(doc.urls == ["https://x.test/", "https://x.test/about"])
    #expect(doc.sitemaps.isEmpty)
    #expect(!doc.isIndex)
}

@Test func aSitemapIndexYieldsChildSitemaps() {
    let doc = parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>https://x.test/sitemap-pages.xml</loc></sitemap>
          <sitemap><loc>https://x.test/sitemap-posts.xml</loc></sitemap>
        </sitemapindex>
        """)
    #expect(doc.sitemaps.count == 2)
    #expect(doc.urls.isEmpty)
    #expect(doc.isIndex)
}

/// The element name is what distinguishes a page from a child sitemap, so a
/// document using a different namespace prefix must still parse.
@Test func aPrefixedNamespaceStillParses() {
    let doc = parse("""
        <?xml version="1.0"?>
        <sm:urlset xmlns:sm="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sm:url><sm:loc>https://x.test/prefixed</sm:loc></sm:url>
        </sm:urlset>
        """)
    #expect(doc.urls == ["https://x.test/prefixed"])
}

@Test func cdataAndEntitiesAreDecoded() {
    let doc = parse("""
        <?xml version="1.0"?>
        <urlset>
          <url><loc><![CDATA[https://x.test/cdata?a=1&b=2]]></loc></url>
          <url><loc>https://x.test/entity?a=1&amp;b=2</loc></url>
        </urlset>
        """)
    #expect(doc.urls == ["https://x.test/cdata?a=1&b=2", "https://x.test/entity?a=1&b=2"])
}

@Test func whitespaceAroundALocationIsTrimmed() {
    let doc = parse("<urlset><url><loc>\n   https://x.test/padded  \n</loc></url></urlset>")
    #expect(doc.urls == ["https://x.test/padded"])
}

@Test func anEmptyLocationIsSkipped() {
    let doc = parse("<urlset><url><loc></loc></url><url><loc>https://x.test/real</loc></url></urlset>")
    #expect(doc.urls == ["https://x.test/real"])
}

/// A truncated sitemap listing most of its URLs is far more useful than
/// nothing, and the crawl was never going to be exhaustive anyway.
@Test func aTruncatedDocumentKeepsWhatItManagedToRead() {
    let doc = parse("""
        <urlset>
          <url><loc>https://x.test/one</loc></url>
          <url><loc>https://x.test/two</loc></url>
          <url><loc>https://x.tes
        """)
    #expect(doc.urls == ["https://x.test/one", "https://x.test/two"])
}

@Test func somethingThatIsNotASitemapYieldsNothing() {
    #expect(parse("<html><body><p>Not a sitemap</p></body></html>").isEmpty)
    #expect(SitemapParser.parse(Data()).isEmpty)
    #expect(parse("this is not xml at all").isEmpty)
}
