import Testing
@testable import KodaCore
@testable import KodaUI

@Test func idleOffersOnlyStart() {
    #expect(ToolbarAction.available(for: .idle) == [.start])
}

@Test func runningOffersPauseAndStop() {
    #expect(ToolbarAction.available(for: .running) == [.pause, .stop])
}

@Test func pausedOffersResumeAndStop() {
    #expect(ToolbarAction.available(for: .paused) == [.resume, .stop])
}

@Test func finishedOffersStartAgain() {
    #expect(ToolbarAction.available(for: .finished) == [.start])
}

@Test func cancelledOffersStartAgain() {
    #expect(ToolbarAction.available(for: .cancelled) == [.start])
}

@Test func failedOffersStartAgain() {
    #expect(ToolbarAction.available(for: .failed("boom")) == [.start])
}

@Test func aRunningCrawlNeverOffersStart() {
    #expect(!ToolbarAction.available(for: .running).contains(.start))
    #expect(!ToolbarAction.available(for: .paused).contains(.start))
}
