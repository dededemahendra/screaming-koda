import Foundation
import Testing
@testable import KodaCore

private struct DetailSite: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        func page(_ body: String) -> FetchOutcome {
            .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html", "X-Robots-Tag": "noarchive"],
                                   body: Data(body.utf8), elapsedMs: 7))
        }
        switch url {
        case "https://d.test/robots.txt":
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        case "https://d.test/":
            return page("""
                <html lang="en-GB"><head><title>Home</title>
                <meta name="description" content="Home desc">
                <meta name="robots" content="index, follow">
                <link rel="canonical" href="https://d.test/">
                <link rel="alternate" hreflang="fr" href="https://d.test/fr">
                </head><body><h1>Home</h1><h2>A</h2><h2>B</h2>
                <a href="/target">To target</a>
                <img src="/i.png" alt="Pic">
                <p>one two three</p></body></html>
                """)
        case "https://d.test/target":
            return page("""
                <html><head><title>Target</title></head><body><h1>T</h1>
                <a href="/" rel="nofollow">Back home</a>
                <a href="https://out.test/x">Out</a></body></html>
                """)
        case "https://d.test/fr":
            return page("<html><head><title>FR</title></head><body><h1>FR</h1></body></html>")
        default:
            return .response(HTTPResponse(status: 200, headers: ["Content-Length": "4096"], body: Data(), elapsedMs: 1))
        }
    }
}

private func detailStore() async throws -> Store {
    var config = CrawlConfig(seedURL: "https://d.test/")
    config.workers = 2
    return try await CrawlSession.start(dbPath: nil, config: config, client: DetailSite(),
                                        parser: SwiftSoupParser(), onProgress: nil)
}

@Test func detailCarriesResponseAndPageFacts() async throws {
    let store = try await detailStore()
    let id = try #require(try store.urlID(for: "https://d.test/"))
    let detail = try #require(try store.urlDetail(id: id))

    #expect(detail.url == "https://d.test/")
    #expect(detail.status == 200)
    #expect(detail.depth == 0)
    #expect(detail.isInternal)
    #expect(detail.title == "Home")
    #expect(detail.metaDescription == "Home desc")
    #expect(detail.h1 == "Home")
    #expect(detail.h2Count == 2)
    #expect(detail.canonical == "https://d.test/")
    #expect(detail.metaRobots == "index, follow")
    #expect(detail.xRobotsTag == "noarchive")
    #expect(detail.lang == "en-GB")
    #expect(detail.wordCount == 8, "all visible body text: Home A B To target one two three")
    #expect(detail.responseTimeMs == 7)
}

@Test func detailIsNilForAnUnknownID() async throws {
    let store = try await detailStore()
    #expect(try store.urlDetail(id: 99_999) == nil)
    #expect(try store.urlID(for: "https://d.test/nope") == nil)
    #expect(try store.urlID(for: "not a url") == nil)
}

@Test func inlinksReportWhoPointsHere() async throws {
    let store = try await detailStore()
    let id = try #require(try store.urlID(for: "https://d.test/target"))
    let inlinks = try store.inlinks(to: id)
    #expect(inlinks.count == 1)
    #expect(inlinks[0].url == "https://d.test/")
    #expect(inlinks[0].anchor == "To target")
    #expect(inlinks[0].status == 200)
}

@Test func outlinksKeepDocumentOrderAndCarryRel() async throws {
    let store = try await detailStore()
    let id = try #require(try store.urlID(for: "https://d.test/target"))
    let outlinks = try store.outlinks(from: id)
    #expect(outlinks.map(\.url) == ["https://d.test/", "https://out.test/x"])
    #expect(outlinks[0].rel == "nofollow")
    #expect(outlinks[0].isInternal)
    #expect(outlinks[1].isInternal == false)
    #expect(outlinks[1].status == 200, "external links are status-checked")
}

@Test func imagesCarryAltStatusAndSize() async throws {
    let store = try await detailStore()
    let id = try #require(try store.urlID(for: "https://d.test/"))
    let images = try store.images(on: id)
    #expect(images.count == 1)
    #expect(images[0].url == "https://d.test/i.png")
    #expect(images[0].alt == "Pic")
    #expect(images[0].status == 200)
    #expect(images[0].bytes == 4096, "size comes from the HEAD Content-Length")
}

@Test func hreflangCarriesTargetStatus() async throws {
    let store = try await detailStore()
    let id = try #require(try store.urlID(for: "https://d.test/"))
    let alternates = try store.hreflang(on: id)
    #expect(alternates.count == 1)
    #expect(alternates[0].lang == "fr")
    #expect(alternates[0].url == "https://d.test/fr")
    #expect(alternates[0].status == 200)
}

@Test func inlinkLimitIsRespected() async throws {
    let store = try await detailStore()
    let id = try #require(try store.urlID(for: "https://d.test/"))
    #expect(try store.inlinks(to: id, limit: 0).isEmpty, "a site-wide link can have far more sources than a pane shows")
}
