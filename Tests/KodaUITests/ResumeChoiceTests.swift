import Foundation
import GRDB
import Testing
@testable import KodaCore
@testable import KodaUI

@MainActor
private func tempDirectory() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("koda-resume-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a real crawl database with `urls` rows so `existing` can count them.
@MainActor
private func makeCrawl(at path: URL, urls count: Int, finished: Bool) throws {
    let store = try Store(path: path.path)
    try store.migrate()
    try store.initializeCrawl(config: CrawlConfig(seedURL: "https://old.test/"), startedAt: Date())
    try store.dbQueue.write { db in
        for i in 0..<count {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,0,1,0,?)
                    """,
                arguments: ["https://old.test/\(i)", Data("h\(i)".utf8), "old.test", "/\(i)",
                            finished ? 2 : 0]
            )
        }
    }
    if finished { try store.markFinished(at: Date()) }
}

@MainActor
@Test func existingReturnsNilWhenThereIsNoDatabase() throws {
    let dir = try tempDirectory()
    #expect(CrawlDatabaseLocation.existing(forHost: "absent.test", in: dir) == nil)
}

@MainActor
@Test func existingDescribesWhatWasFound() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 12, finished: true)

    let found = try #require(CrawlDatabaseLocation.existing(forHost: "old.test", in: dir))
    #expect(found.host == "old.test")
    #expect(found.urlCount == 12, "the user needs to know how much they would lose")
    #expect(found.path == path)
}

@MainActor
@Test func replaceRemovesTheDatabaseAndItsSidecars() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 3, finished: true)
    // Simulate the WAL sidecars a live database leaves behind.
    let wal = URL(fileURLWithPath: path.path + "-wal")
    let shm = URL(fileURLWithPath: path.path + "-shm")
    FileManager.default.createFile(atPath: wal.path, contents: Data("stale".utf8))
    FileManager.default.createFile(atPath: shm.path, contents: Data("stale".utf8))

    try CrawlDatabaseLocation.replace(at: path)

    #expect(!FileManager.default.fileExists(atPath: path.path))
    #expect(!FileManager.default.fileExists(atPath: wal.path), "a stale -wal makes the next open fail")
    #expect(!FileManager.default.fileExists(atPath: shm.path))
}

@MainActor
@Test func replaceSucceedsWhenNoSidecarsExist() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 1, finished: true)
    try CrawlDatabaseLocation.replace(at: path)   // must not throw on absent sidecars
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

/// The other of the two things that matter most: a database `existing` cannot
/// read (garbage bytes, a permissions problem, a half-written file) must still
/// be reported — with a URL count of zero — rather than treated as though there
/// were nothing there. Treating "unreadable" as "absent" would let Replace
/// silently destroy a file the app never actually looked at, which is exactly
/// the data loss this whole flow exists to prevent.
@MainActor
@Test func anUnreadableDatabaseIsReportedRatherThanTreatedAsAbsent() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    // Not a SQLite file at all — opening or querying it must fail.
    try Data("this is not a sqlite database".utf8).write(to: path)

    let found = try #require(CrawlDatabaseLocation.existing(forHost: "old.test", in: dir),
        "an unreadable file must still be reported, not treated as though nothing were there")
    #expect(found.urlCount == 0, "an unreadable count must never be mistaken for a real, empty crawl")
}

@MainActor
@Test func aFinishedCrawlCanBeReopenedAndStillHasItsRows() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 9, finished: true)

    let reopened = try Store(path: path.path)
    try reopened.migrate()
    let count = try reopened.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
    }
    #expect(count == 9, "resuming a finished crawl means looking at it, not re-running it")
    #expect(try reopened.urlCounts().queued == 0, "nothing left to crawl")
}

@MainActor
@Test func anInterruptedCrawlStillHasAQueueToResume() throws {
    let dir = try tempDirectory()
    let path = CrawlDatabaseLocation.path(forHost: "old.test", in: dir)
    try makeCrawl(at: path, urls: 6, finished: false)

    let reopened = try Store(path: path.path)
    try reopened.migrate()
    #expect(try reopened.urlCounts().queued == 6, "resuming continues where it stopped")
}
