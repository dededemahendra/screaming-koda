import Foundation
import Testing
@testable import KodaUI

@Test func crawlsDirectoryNestsUnderScreamingKodaCrawls() {
    let root = URL(fileURLWithPath: "/tmp/appsupport-fixture")
    let dir = CrawlDatabaseLocation.crawlsDirectory(appSupport: root)
    #expect(dir.path == "/tmp/appsupport-fixture/ScreamingKoda/Crawls")
}

@Test func pathIsNamedAfterTheHostMirroringTheCLIConvention() {
    let dir = URL(fileURLWithPath: "/tmp/appsupport-fixture/ScreamingKoda/Crawls")
    let path = CrawlDatabaseLocation.path(forHost: "example.com", in: dir)
    #expect(path.path == "/tmp/appsupport-fixture/ScreamingKoda/Crawls/example.com.koda")
}

@Test func differentHostsGetDifferentFiles() {
    let dir = URL(fileURLWithPath: "/tmp/appsupport-fixture/ScreamingKoda/Crawls")
    let a = CrawlDatabaseLocation.path(forHost: "a.example.com", in: dir)
    let b = CrawlDatabaseLocation.path(forHost: "b.example.com", in: dir)
    #expect(a != b)
}

// `prepare(forHost:...)` and `PreparationOutcome` — the auto-replace-and-notify
// behaviour — were removed in favour of the Resume/Replace/Cancel choice.
// `CrawlDatabaseLocation.existing(forHost:in:)` and `.replace(at:)` are exercised
// in `ResumeChoiceTests.swift`.
