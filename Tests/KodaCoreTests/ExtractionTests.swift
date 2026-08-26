import Foundation
import GRDB
import Testing
@testable import KodaCore

private let page = """
    <html><head><title>Product</title></head><body>
      <h1>A widget</h1>
      <span class="price" data-cents="1299">£12.99</span>
      <span class="price" data-cents="999">£9.99</span>
      <div class="sku">WID-1</div>
      <a class="brand" href="/brands/acme">Acme</a>
    </body></html>
    """

@Test func aTextExtractionTakesTheElementsText() throws {
    let facts = try SwiftSoupParser().parse(
        html: page, extractions: [ExtractionRule(name: "SKU", selector: ".sku")])
    #expect(facts.extractions == [ExtractionFact(name: "SKU", value: "WID-1", position: 0)])
}

/// A selector matching several elements yields several values, positioned, so
/// "the first price" stays distinguishable from "the second".
@Test func aRuleMatchingSeveralElementsYieldsSeveralValues() throws {
    let facts = try SwiftSoupParser().parse(
        html: page, extractions: [ExtractionRule(name: "Price", selector: ".price")])
    #expect(facts.extractions.map(\.value) == ["£12.99", "£9.99"])
    #expect(facts.extractions.map(\.position) == [0, 1])
}

@Test func anAttributeExtractionReadsTheAttributeNamedInTheSelector() throws {
    let facts = try SwiftSoupParser().parse(html: page, extractions: [
        ExtractionRule(name: "Cents", selector: ".price[data-cents]", value: .attribute),
        ExtractionRule(name: "Brand URL", selector: "a.brand[href]", value: .attribute),
    ])
    #expect(facts.extractions.filter { $0.name == "Cents" }.map(\.value) == ["1299", "999"])
    #expect(facts.extractions.first { $0.name == "Brand URL" }?.value == "/brands/acme")
}

@Test func anHTMLExtractionKeepsTheMarkup() throws {
    let facts = try SwiftSoupParser().parse(
        html: "<html><body><div class=\"x\"><em>hi</em></div></body></html>",
        extractions: [ExtractionRule(name: "X", selector: ".x", value: .html)])
    #expect(facts.extractions.first?.value == "<em>hi</em>")
}

/// One bad rule must not cost the page. The crawler's governing rule — never die
/// from a bad page — extends to configuration the user typed.
@Test func anInvalidSelectorSkipsThatRuleAndKeepsTheRest() throws {
    let facts = try SwiftSoupParser().parse(html: page, extractions: [
        ExtractionRule(name: "Broken", selector: "((("),
        ExtractionRule(name: "SKU", selector: ".sku"),
    ])
    #expect(facts.extractions.map(\.name) == ["SKU"])
    #expect(facts.title == "Product", "the rest of the parse is unaffected")
}

@Test func aRuleThatMatchesNothingProducesNothing() throws {
    let facts = try SwiftSoupParser().parse(
        html: page, extractions: [ExtractionRule(name: "Missing", selector: ".nope")])
    #expect(facts.extractions.isEmpty)
}

@Test func anEmptyMatchIsNotRecorded() throws {
    let facts = try SwiftSoupParser().parse(
        html: "<html><body><div class=\"x\">   </div></body></html>",
        extractions: [ExtractionRule(name: "X", selector: ".x")])
    #expect(facts.extractions.isEmpty, "whitespace is not a value")
}

/// No rules configured must cost nothing and change nothing.
@Test func noRulesLeavesTheParseUntouched() throws {
    let withRules = try SwiftSoupParser().parse(html: page, extractions: [])
    let plain = try SwiftSoupParser().parse(html: page)
    #expect(withRules.extractions.isEmpty)
    #expect(withRules.title == plain.title)
}

@Test func attributeNamesAreReadOffASelector() {
    #expect(SwiftSoupParser.attributeName(from: ".price[data-cents]") == "data-cents")
    #expect(SwiftSoupParser.attributeName(from: "a[href]") == "href")
    #expect(SwiftSoupParser.attributeName(from: "img[src=\"x\"]") == "src")
    #expect(SwiftSoupParser.attributeName(from: ".no-attribute") == nil)
}

// MARK: - Through a crawl

private struct ProductClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(page.utf8), elapsedMs: 1))
    }
}

/// The rules have to survive config, the engine and the write path, not just the
/// parser.
@Test func extractionRulesReachTheDatabaseThroughARealCrawl() async throws {
    var config = CrawlConfig(seedURL: "https://shop.test/")
    config.workers = 1
    config.extractions = [
        ExtractionRule(name: "Price", selector: ".price"),
        ExtractionRule(name: "SKU", selector: ".sku"),
    ]
    let (store, _) = try await CrawlSession.start(
        dbPath: nil, config: config, client: ProductClient(),
        parser: SwiftSoupParser(), onProgress: nil)

    // Scoped to the seed: this client serves the same body for every URL, so the
    // brand link is crawled too and extracted from as well. That is correct —
    // the assertion just has to name which page it is about.
    let values = try await store.dbQueue.read { db in
        try Row.fetchAll(db, sql: """
            SELECT e.name, e.value, e.position FROM extractions e
            JOIN urls u ON u.id = e.url_id
            WHERE u.path = '/'
            ORDER BY e.name, e.position
            """)
    }
    #expect(values.map { $0["name"] as String? } == ["Price", "Price", "SKU"])
    #expect(values.map { $0["value"] as String? } == ["£12.99", "£9.99", "WID-1"])

    // And every crawled page got the same treatment, not just the seed.
    let pages = try await store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(DISTINCT url_id) FROM extractions") ?? 0
    }
    #expect(pages == 2, "the seed and the brand page it links to")
}

@Test func extractionRulesRoundTripThroughTheStoredConfig() throws {
    var config = CrawlConfig(seedURL: "https://shop.test/")
    config.extractions = [ExtractionRule(name: "Price", selector: ".price", value: .attribute)]
    let store = try Store(path: nil)
    try store.migrate()
    try store.initializeCrawl(config: config, startedAt: Date())

    let reloaded = try #require(try store.loadConfig())
    #expect(reloaded.extractions == config.extractions)
}
