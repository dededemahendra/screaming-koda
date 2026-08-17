import Foundation
import Testing
@testable import KodaCore

private let parser = SwiftSoupParser()

private let page = """
<!doctype html>
<html lang="en-GB">
<head>
  <title>Example Page</title>
  <meta name="description" content="A description here.">
  <link rel="canonical" href="https://example.com/canonical">
  <meta name="robots" content="noindex, follow">
  <link rel="alternate" hreflang="fr" href="https://example.com/fr">
  <link rel="alternate" hreflang="x-default" href="https://example.com/">
</head>
<body>
  <h1>Main Heading</h1>
  <h2>Sub one</h2><h2>Sub two</h2>
  <p>Some visible words here.</p>
  <a href="/internal">Internal link</a>
  <a href="https://other.com/x" rel="nofollow">External link</a>
  <img src="/img/a.png" alt="Alt text">
  <img src="/img/b.png">
  <script>var hidden = "script words";</script>
</body>
</html>
"""

@Test func extractsTitleAndLength() throws {
    let f = try parser.parse(html: page)
    #expect(f.title == "Example Page")
    #expect(f.titleLength == 12)
    #expect(f.titleCount == 1)
}

@Test func extractsMetaDescription() throws {
    let f = try parser.parse(html: page)
    #expect(f.metaDescription == "A description here.")
    #expect(f.metaDescriptionLength == 19)
    #expect(f.metaDescriptionCount == 1)
}

@Test func extractsHeadings() throws {
    let f = try parser.parse(html: page)
    #expect(f.h1 == "Main Heading")
    #expect(f.h1Count == 1)
    #expect(f.h2Count == 2)
}

@Test func extractsCanonicalAndRobotsAndLang() throws {
    let f = try parser.parse(html: page)
    #expect(f.canonical == "https://example.com/canonical")
    #expect(f.metaRobots == "noindex, follow")
    #expect(f.lang == "en-GB")
}

@Test func extractsLinksWithRelAndPosition() throws {
    let f = try parser.parse(html: page)
    #expect(f.links.count == 2)
    #expect(f.links[0].href == "/internal")
    #expect(f.links[0].anchor == "Internal link")
    #expect(f.links[0].position == 0)
    #expect(f.links[1].rel == "nofollow")
}

@Test func extractsImagesIncludingMissingAlt() throws {
    let f = try parser.parse(html: page)
    #expect(f.images.count == 2)
    #expect(f.images[0].alt == "Alt text")
    #expect(f.images[1].alt == nil)
}

@Test func extractsHreflang() throws {
    let f = try parser.parse(html: page)
    #expect(f.hreflang.count == 2)
    #expect(f.hreflang.contains { $0.lang == "fr" && $0.href == "https://example.com/fr" })
    #expect(f.hreflang.contains { $0.lang == "x-default" })
}

@Test func wordCountExcludesScriptContent() throws {
    let f = try parser.parse(html: page)
    #expect(f.wordCount > 0)
    #expect(f.wordCount < 20, "script text must not be counted, got \(f.wordCount)")
}

@Test func contentHashIgnoresScriptsAndWhitespace() throws {
    let a = try parser.parse(html: "<html><body><p>Same   words</p><script>x=1</script></body></html>")
    let b = try parser.parse(html: "<html><body>\n  <p>Same words</p>\n<script>x=2</script></body></html>")
    #expect(a.contentHash == b.contentHash)
}

@Test func contentHashDiffersForDifferentText() throws {
    let a = try parser.parse(html: "<html><body><p>One</p></body></html>")
    let b = try parser.parse(html: "<html><body><p>Two</p></body></html>")
    #expect(a.contentHash != b.contentHash)
}

@Test func handlesMissingElementsWithoutThrowing() throws {
    let f = try parser.parse(html: "<html><body></body></html>")
    #expect(f.title == nil)
    #expect(f.titleCount == 0)
    #expect(f.metaDescription == nil)
    #expect(f.h1 == nil)
    #expect(f.links.isEmpty)
}

@Test func countsDuplicateTitleAndDescriptionTags() throws {
    let html = """
    <html><head><title>A</title><title>B</title>
    <meta name="description" content="one"><meta name="description" content="two"></head><body></body></html>
    """
    let f = try parser.parse(html: html)
    #expect(f.titleCount == 2)
    #expect(f.title == "A", "the first tag wins, matching how browsers behave")
    #expect(f.metaDescriptionCount == 2)
}

@Test func survivesMalformedHTML() throws {
    let f = try parser.parse(html: "<html><head><title>Broken<body><p>text<a href=/x>link")
    #expect(f.title != nil)
    #expect(f.links.count == 1)
}
