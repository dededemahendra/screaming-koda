import Foundation
import Testing
@testable import KodaCore

private let page = """
    <!doctype html><html><head><title>Shop</title></head>
    <body>
      <div class="product" data-sku="A1"><span class="price">£10.99</span></div>
      <div class="product" data-sku="B2"><span class="price">£20.50</span></div>
      <ul id="nav"><li>Home</li><li>Products</li><li>Contact</li></ul>
      <p class="note">A note with naïve accents and 日本語.</p>
    </body></html>
    """

private func extract(_ selector: String, value: ExtractionValue = .text) throws -> [String] {
    let rule = ExtractionRule(name: "X", selector: selector, value: value, engine: .xpath)
    return try SwiftSoupParser().parse(html: page, extractions: [rule]).extractions.map(\.value)
}

@Test func xpathSelectsElementsByPredicate() throws {
    #expect(try extract("//span[@class='price']") == ["£10.99", "£20.50"])
}

@Test func xpathSelectsAttributes() throws {
    #expect(try extract("//div[@class='product']/@data-sku") == ["A1", "B2"])
}

@Test func xpathSelectsByPosition() throws {
    #expect(try extract("//ul[@id='nav']/li[2]") == ["Products"])
}

@Test func xpathCanReturnMarkup() throws {
    let html = try extract("//ul[@id='nav']/li[1]", value: .html)
    #expect(html.first?.contains("<li>") == true)
}

/// The reason this is built on the string initialiser rather than the data one:
/// `XMLDocument(data:)` with tidyHTML silently drops or double-encodes non-ASCII,
/// turning "£10.99" into "10.99". Every extraction with a currency symbol or an
/// accent would have been quietly wrong.
@Test func xpathPreservesNonASCIICharacters() throws {
    #expect(try extract("//p[@class='note']")
            == ["A note with naïve accents and 日本語."])
    #expect(try extract("//span[@class='price']").first == "£10.99")
}

/// An XPath function returns a number rather than nodes, which the node API
/// reports as an error. It yields nothing for that rule rather than failing the
/// page — the same rule a bad CSS selector follows.
@Test func anXPathFunctionYieldsNothingRatherThanFailing() throws {
    #expect(try extract("count(//div)").isEmpty)
    let facts = try SwiftSoupParser().parse(html: page, extractions: [
        ExtractionRule(name: "Broken", selector: "count(//div)", engine: .xpath),
        ExtractionRule(name: "Good", selector: "//title", engine: .xpath),
    ])
    #expect(facts.extractions.map(\.name) == ["Good"])
    #expect(facts.title == "Shop", "the rest of the parse is unaffected")
}

@Test func aMalformedXPathIsSkipped() throws {
    #expect(try extract("//[[[").isEmpty)
}

@Test func anXPathMatchingNothingProducesNothing() throws {
    #expect(try extract("//div[@class='nonexistent']").isEmpty)
}

/// XPath and CSS rules coexist, and both land in the same tab.
@Test func cssAndXPathRulesRunTogether() throws {
    let facts = try SwiftSoupParser().parse(html: page, extractions: [
        ExtractionRule(name: "By CSS", selector: ".note"),
        ExtractionRule(name: "By XPath", selector: "//div[@class='product']/@data-sku",
                       engine: .xpath),
    ])
    let byName = Dictionary(grouping: facts.extractions, by: \.name)
    #expect(byName["By CSS"]?.count == 1)
    #expect(byName["By XPath"]?.map(\.value) == ["A1", "B2"])
}

/// Real pages are not well-formed XML, and an XPath engine that needs them to be
/// would be useless on the web.
@Test func xpathWorksOnMalformedHTML() throws {
    let messy = "<html><body><p>unclosed<div class=x>text<span>more</body>"
    let facts = try SwiftSoupParser().parse(html: messy, extractions: [
        ExtractionRule(name: "X", selector: "//div[@class='x']", engine: .xpath),
    ])
    #expect(facts.extractions.first?.value.contains("text") == true)
}

/// A rule stored before the engine field existed must still mean CSS.
@Test func aRuleWithoutAnEngineDecodesAsCSS() throws {
    let json = Data(#"{"name":"Old","selector":".price","value":"text"}"#.utf8)
    let rule = try JSONDecoder().decode(ExtractionRule.self, from: json)
    #expect(rule.engine == .css)
    #expect(rule.name == "Old")
}
