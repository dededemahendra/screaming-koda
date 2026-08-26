import SwiftUI
import Testing
@testable import KodaCore
@testable import KodaUI

@Test func nothingHasBeenCrawledYet() {
    #expect(WorkspaceState.resolve(crawl: .idle, hasStore: false,
                                   urlsFound: 0, findingTotal: 0) == .noCrawl)
}

@Test func aCrawlInFlightSaysSo() {
    #expect(WorkspaceState.resolve(crawl: .running, hasStore: true,
                                   urlsFound: 12, findingTotal: 3) == .crawling)
    #expect(WorkspaceState.resolve(crawl: .paused, hasStore: true,
                                   urlsFound: 12, findingTotal: 3) == .crawling)
}

/// The state this whole task exists for. A finished crawl with nothing wrong
/// used to render exactly like a crawl that fell over.
@Test func aFinishedCrawlWithNoFindingsIsClean() {
    #expect(WorkspaceState.resolve(crawl: .finished, hasStore: true,
                                   urlsFound: 40, findingTotal: 0) == .clean)
}

@Test func aFinishedCrawlWithFindingsShowsResults() {
    #expect(WorkspaceState.resolve(crawl: .finished, hasStore: true,
                                   urlsFound: 40, findingTotal: 9) == .results)
}

/// "No issues found" after crawling nothing would be a lie: the crawl did not
/// get far enough to have an opinion.
@Test func aFinishedCrawlThatReachedNothingIsNotClean() {
    #expect(WorkspaceState.resolve(crawl: .finished, hasStore: true,
                                   urlsFound: 0, findingTotal: 0) == .results)
}

/// A stopped crawl has not checked everything, so it cannot claim to be clean.
@Test func aStoppedCrawlIsNeverClean() {
    #expect(WorkspaceState.resolve(crawl: .cancelled, hasStore: true,
                                   urlsFound: 40, findingTotal: 0) == .results)
}

@Test func aFailedCrawlCarriesItsReason() {
    #expect(WorkspaceState.resolve(crawl: .failed("no such host"), hasStore: false,
                                   urlsFound: 0, findingTotal: 0) == .failed("no such host"))
}

/// Opening an existing .koda file for browsing leaves the state idle but there
/// is a crawl to show, so this must not fall back to the first-run panel.
@Test func anOpenedCrawlShowsItsResultsRatherThanTheFirstRunPanel() {
    #expect(WorkspaceState.resolve(crawl: .idle, hasStore: true,
                                   urlsFound: 40, findingTotal: 9) == .results)
}

@MainActor
@Test func everyStatePanelDraws() {
    let size = CGSize(width: 700, height: 400)
    ViewCapture.expectNotBlank(
        EmptyStatePanel(symbol: "magnifyingglass", title: "Crawl a site",
                        message: "Enter a URL above.").frame(width: 700, height: 400),
        size: size, "the first-run panel")
    ViewCapture.expectNotBlank(
        EmptyStatePanel(symbol: "checkmark.circle", title: "No issues found",
                        message: "40 URLs checked.").frame(width: 700, height: 400),
        size: size, "the clean panel")
}
