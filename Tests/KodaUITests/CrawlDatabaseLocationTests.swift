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

@Test func prepareCreatesTheDirectoryAndReturnsCreatedForANewHost() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let result = try CrawlDatabaseLocation.prepare(forHost: "example.com", appSupport: root)
    #expect(result.outcome == .created)
    #expect(result.path.hasSuffix("/ScreamingKoda/Crawls/example.com.koda"))

    var isDir: ObjCBool = false
    let dirExists = FileManager.default.fileExists(
        atPath: root.appendingPathComponent("ScreamingKoda/Crawls").path, isDirectory: &isDir
    )
    #expect(dirExists)
    #expect(isDir.boolValue)
}

@Test func prepareReplacesAnExistingDatabaseForTheSameHost() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let first = try CrawlDatabaseLocation.prepare(forHost: "example.com", appSupport: root)
    #expect(first.outcome == .created)
    try Data("stale crawl data".utf8).write(to: URL(fileURLWithPath: first.path))
    #expect(FileManager.default.fileExists(atPath: first.path))

    let second = try CrawlDatabaseLocation.prepare(forHost: "example.com", appSupport: root)
    #expect(second.outcome == .replacedExisting)
    #expect(second.path == first.path, "the same host must always resolve to the same file")
    #expect(!FileManager.default.fileExists(atPath: first.path),
            "prepare must actually remove the stale file, not just report that it should be replaced")
}

@Test func differentHostsGetDifferentFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }

    let a = try CrawlDatabaseLocation.prepare(forHost: "a.example.com", appSupport: root)
    let b = try CrawlDatabaseLocation.prepare(forHost: "b.example.com", appSupport: root)
    #expect(a.path != b.path)
    #expect(a.outcome == .created)
    #expect(b.outcome == .created)
}
