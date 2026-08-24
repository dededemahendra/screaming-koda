import Foundation
import GRDB
import Testing
@testable import KodaCore

/// The one that matters: the fast single-scan path and the slow per-filter path
/// must never disagree, or the sidebar advertises findings the tab does not show.
@Test func oneScanAgreesWithRunningEveryFilterSeparately() throws {
    let store = try ReportFixture.make()
    let counts = try store.counts(for: Reports.all)
    var checked = 0
    for report in Reports.all {
        for filter in report.filters {
            let direct = try store.ids(for: report, filter: filter,
                                       sortBy: nil, ascending: true).count
            #expect(counts["\(report.id).\(filter.id)"] == direct,
                    "\(report.id).\(filter.id) disagrees")
            checked += 1
        }
    }
    // Hard-coded on purpose: a filter silently disappearing from a report would
    // otherwise make this test pass by comparing fewer things.
    #expect(checked == 122, "every filter should have been compared")
}

@Test func everyFilterGetsAKeyEvenWhenItMatchesNothing() throws {
    let store = try ReportFixture.make()
    let counts = try store.counts(for: Reports.all)
    // noarchive appears nowhere in the fixture, so it exercises the zero case.
    #expect(counts["directives.noarchive"] == 0)
    for report in Reports.all {
        for filter in report.filters {
            #expect(counts["\(report.id).\(filter.id)"] != nil,
                    "\(report.id).\(filter.id) is missing, not zero")
        }
    }
}

/// sum() over no rows is NULL, not 0. Without the coalesce every count on a
/// fresh crawl would come back missing rather than zero.
@Test func countsOnAnEmptyDatabaseAreAllZero() throws {
    let store = try Store(path: nil)
    try store.migrate()
    let counts = try store.counts(for: Reports.all)
    #expect(counts.count == 122)
    #expect(counts.values.allSatisfy { $0 == 0 })
}

@Test func countsForNoReportsIsEmpty() throws {
    let store = try ReportFixture.make()
    #expect(try store.counts(for: []).isEmpty)
}

/// Chunking has to stitch results back together correctly. Forcing many chunks
/// by asking for the same reports repeatedly keeps the keys stable but pushes
/// the pair count well past the per-statement limit.
@Test func chunkingDoesNotLoseOrMisalignCounts() throws {
    let store = try ReportFixture.make()
    let single = try store.counts(for: Reports.all)
    let repeated = try store.counts(for: Array(repeating: Reports.all, count: 6).flatMap { $0 })
    #expect(repeated == single, "repeating the same reports must not change any count")
}
