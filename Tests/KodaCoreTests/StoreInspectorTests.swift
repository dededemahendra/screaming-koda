import Foundation
import GRDB
import Testing
@testable import KodaCore

private func idOf(_ store: Store, _ path: String) throws -> Int64 {
    try store.dbQueue.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE path = ?", arguments: [path])!
    }
}

@Test func detailReturnsNilForAnUnknownID() throws {
    let store = try ReportFixture.make()
    #expect(try store.detail(id: 999_999) == nil)
}

@Test func detailCarriesFieldsNoColumnShows() throws {
    let store = try ReportFixture.make()
    let detail = try #require(try store.detail(id: idOf(store, "/robots-conflict")))
    #expect(detail.value("Meta Robots") == "index")
    #expect(detail.value("X-Robots-Tag") == "noindex")
    #expect(detail.value("Language") == "en")
    #expect(detail.value("Word Count") == "400")
    #expect(detail.value("Internal") == "Yes")
}

/// The Details pane and the Internal tab must agree about indexability, or the
/// same page reads as two different verdicts depending on where you look.
@Test func detailAgreesWithTheIndexabilityColumn() throws {
    let store = try ReportFixture.make()
    let detail = try #require(try store.detail(id: idOf(store, "/canonicalised")))
    #expect(detail.value("Indexability") == Indexability.canonicalised)
}

@Test func detailShowsNilForFieldsThePageDoesNotHave() throws {
    let store = try ReportFixture.make()
    let detail = try #require(try store.detail(id: idOf(store, "/no-title")))
    #expect(detail.value("Title") == nil)
    #expect(detail.value("Error") == nil, "a 200 has no transport error")
}

@Test func detailShowsATransportErrorKind() throws {
    let store = try ReportFixture.make()
    let detail = try #require(try store.detail(id: idOf(store, "/dead")))
    #expect(detail.value("Error") == "timed out")
    #expect(detail.value("Status") == "0")
}

@Test func inlinksFindThePagesThatLinkHere() throws {
    let store = try ReportFixture.make()
    let rows = try store.inlinks(id: idOf(store, "/dupe-b"))
    #expect(Set(rows.items.map(\.url)) == ["https://fx.test/", "https://fx.test/dupe-a"])
    #expect(rows.total == 2)
    #expect(!rows.isTruncated)
}

@Test func outlinksFindWhatThisPageLinksTo() throws {
    let store = try ReportFixture.make()
    let rows = try store.outlinks(id: idOf(store, "/"))
    #expect(Set(rows.items.map(\.url)) == [
        "https://fx.test/dupe-a", "https://fx.test/dupe-b", "https://fx.test/one-inlink",
        "https://ext.test/ok", "https://ext.test/broken",
        "https://fx.test/anchor-empty", "https://fx.test/anchor-generic",
        "https://fx.test/anchor-many",
    ])
}

/// Inlinks and outlinks must not be the same query with the join reversed by
/// accident: /dupe-a links to /dupe-b, not the other way round.
@Test func inlinksAndOutlinksPointOppositeWays() throws {
    let store = try ReportFixture.make()
    // /dupe-b links out once (to /anchor-many) and is linked to twice.
    #expect(try store.outlinks(id: idOf(store, "/dupe-b")).total == 1)
    #expect(try store.inlinks(id: idOf(store, "/dupe-b")).total == 2)
}

@Test func linkRowsCarryAnchorTextAndTargetStatus() throws {
    let store = try ReportFixture.make()
    let rows = try store.outlinks(id: idOf(store, "/"))
    let broken = try #require(rows.items.first { $0.url == "https://ext.test/broken" })
    #expect(broken.anchor == "link to https://ext.test/broken")
    #expect(broken.status == 404, "a broken outbound link is the whole point of this pane")
}

@Test func imageRowsCarryAltAndSize() throws {
    let store = try ReportFixture.make()
    let rows = try store.imageRows(id: idOf(store, "/"))
    #expect(rows.total == 4)
    let noAlt = try #require(rows.items.first { $0.url.hasSuffix("noalt.png") })
    #expect(noAlt.alt == nil)
    let big = try #require(rows.items.first { $0.url.hasSuffix("big.png") })
    #expect(big.bytes == 200_000)
    #expect(big.status == 200)
}

/// The cap has to be observable, or the pane silently lies about how many
/// inlinks a page has.
@Test func theLimitIsHonouredAndTheTrueTotalIsStillReported() throws {
    let store = try ReportFixture.make()
    let target = try idOf(store, "/dupe-b")
    let capped = try store.inlinks(id: target, limit: 1)
    #expect(capped.items.count == 1)
    #expect(capped.total == 2)
    #expect(capped.isTruncated)
}

@Test func aPageWithNothingToShowReturnsEmptyNotNil() throws {
    let store = try ReportFixture.make()
    let lonely = try idOf(store, "/queued")
    #expect(try store.inlinks(id: lonely).items.isEmpty)
    #expect(try store.outlinks(id: lonely).items.isEmpty)
    #expect(try store.imageRows(id: lonely).items.isEmpty)
    #expect(try store.inlinks(id: lonely).isTruncated == false)
}

// MARK: - Redirect chains

/// A URL that does not redirect still has a chain: itself. Returning an empty
/// list would make the pane look broken for the common case.
@Test func aPageThatDoesNotRedirectIsAChainOfOne() throws {
    let store = try ReportFixture.make()
    let chain = try store.redirectChain(from: idOf(store, "/"))
    #expect(chain.count == 1)
    #expect(chain[0].url == "https://fx.test/")
    #expect(chain[0].status == 200)
}

/// The whole point of the feature: "reached via 2+ redirects" told you a chain
/// existed; this shows you what it was.
@Test func aChainIsWalkedToItsDestination() throws {
    let store = try ReportFixture.make()
    let chain = try store.redirectChain(from: idOf(store, "/chain-1"))
    #expect(chain.map(\.url) == [
        "https://fx.test/chain-1", "https://fx.test/chain-2", "https://fx.test/chain-final",
    ])
    #expect(chain.map(\.status) == [301, 301, 200])
    #expect(chain.allSatisfy { !$0.isLoop })
}

@Test func aSingleHopRedirectIsAChainOfTwo() throws {
    let store = try ReportFixture.make()
    let chain = try store.redirectChain(from: idOf(store, "/redirect-301"))
    #expect(chain.map(\.url) == ["https://fx.test/redirect-301", "https://fx.test/"])
}

/// A cycle must terminate and be reported as a cycle, not silently truncated at
/// the limit — which would read identically to a very long chain.
@Test func aTwoStepLoopClosesAndIsMarked() throws {
    let store = try ReportFixture.make()
    let chain = try store.redirectChain(from: idOf(store, "/loop-a"))
    #expect(chain.map(\.url) == [
        "https://fx.test/loop-a", "https://fx.test/loop-b", "https://fx.test/loop-a",
    ])
    #expect(chain.last?.isLoop == true)
    #expect(chain.dropLast().allSatisfy { !$0.isLoop })
}

@Test func aSelfRedirectIsMarkedAsALoopImmediately() throws {
    let store = try ReportFixture.make()
    let chain = try store.redirectChain(from: idOf(store, "/loop-self"))
    #expect(chain.count == 2)
    #expect(chain[1].isLoop)
}

@Test func theChainWalkHonoursItsLimit() throws {
    let store = try ReportFixture.make()
    #expect(try store.redirectChain(from: idOf(store, "/chain-1"), limit: 2).count == 2)
}

@Test func anUnknownIDHasNoChain() throws {
    let store = try ReportFixture.make()
    #expect(try store.redirectChain(from: 999_999).isEmpty)
}
