import Foundation
import Testing
@testable import KodaUI

private let start = Date(timeIntervalSince1970: 1_000_000)

@Test func oneObservationIsNotYetARate() {
    var rate = CrawlRate()
    rate.observe(crawled: 10, at: start)
    #expect(rate.perSecond == nil)
    #expect(rate.summary == nil)
}

@Test func twoObservationsGiveTheRateBetweenThem() {
    var rate = CrawlRate()
    rate.observe(crawled: 0, at: start)
    rate.observe(crawled: 10, at: start.addingTimeInterval(1))
    #expect(rate.perSecond == 10)
}

/// Smoothed, because the raw figure between two two-second ticks swings wildly
/// on a site with a few slow pages, and a number that jumps between 3 and 40
/// is worse than no number.
@Test func theRateIsSmoothedRatherThanTheLastIntervalAlone() {
    var rate = CrawlRate()
    rate.observe(crawled: 0, at: start)
    rate.observe(crawled: 10, at: start.addingTimeInterval(1))
    rate.observe(crawled: 10, at: start.addingTimeInterval(2))
    let smoothed = try! #require(rate.perSecond)
    #expect(smoothed > 0 && smoothed < 10)
}

/// A paused crawl must not keep reporting the rate it had before it stopped.
@Test func aStalledCrawlDecaysTowardsZero() {
    var rate = CrawlRate()
    rate.observe(crawled: 0, at: start)
    rate.observe(crawled: 100, at: start.addingTimeInterval(1))
    for tick in 2...30 {
        rate.observe(crawled: 100, at: start.addingTimeInterval(Double(tick)))
    }
    #expect(try! #require(rate.perSecond) < 1)
}

/// The tick can fire twice inside the same instant, and dividing by that
/// interval would produce an infinity that renders as "inf/s".
@Test func aZeroLengthIntervalIsIgnored() {
    var rate = CrawlRate()
    rate.observe(crawled: 0, at: start)
    rate.observe(crawled: 10, at: start)
    #expect(rate.perSecond == nil)
}

/// Resume must not read the pause as a huge burst of progress.
@Test func resetClearsTheEstimate() {
    var rate = CrawlRate()
    rate.observe(crawled: 0, at: start)
    rate.observe(crawled: 10, at: start.addingTimeInterval(1))
    rate.reset()
    #expect(rate.perSecond == nil)
}

@Test func theSummaryRoundsToSomethingReadable() {
    var rate = CrawlRate()
    rate.observe(crawled: 0, at: start)
    rate.observe(crawled: 24, at: start.addingTimeInterval(2))
    #expect(rate.summary == "12/s")
}

/// Under one a second, "0/s" would read as stalled when it is merely slow.
///
/// The expected string is built through the same `.formatted()` call `summary`
/// uses, rather than a hardcoded "0.5", because the decimal separator is
/// locale-dependent (a comma, not a period, under many locales) — the same
/// reason `IssueSidebarTests` and `numericFieldsRoundTripUnderALocaleWithOtherSeparators`
/// avoid literal separators.
@Test func aSlowCrawlKeepsOneDecimal() {
    var rate = CrawlRate()
    rate.observe(crawled: 0, at: start)
    rate.observe(crawled: 1, at: start.addingTimeInterval(2))
    let half = 0.5.formatted(.number.precision(.fractionLength(1)))
    #expect(rate.summary == "\(half)/s")
}
