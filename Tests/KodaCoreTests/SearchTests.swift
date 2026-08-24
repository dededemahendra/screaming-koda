import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Pages with real retained bodies, since search is the one feature that reads
/// them back rather than only writing them.
@MainActor
private func searchableStore() throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    let pages = [
        ("/alpha", "<html><body><p>The quick brown fox jumps over the lazy dog.</p></body></html>"),
        ("/beta", "<html><body><p>A dog, another dog, and a third dog walk in.</p></body></html>"),
        ("/gamma", "<html><body><p>No animals are mentioned on this page at all.</p></body></html>"),
    ]
    try store.dbQueue.write { db in
        for (index, page) in pages.enumerated() {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,1,1,0,2)
                    """,
                arguments: ["https://s.test\(page.0)", Data(page.0.utf8), "s.test", page.0])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO responses (url_id, status, content_type, fetched_at, body_gz)
                    VALUES (?, 200, 'text/html; charset=utf-8', 0, ?)
                    """,
                arguments: [id, Gzip.compress(Data(page.1.utf8))])
            _ = index
        }
        // A page whose body was not retained: it must be absent, not a false negative.
        try db.execute(sql: """
            INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
            VALUES ('https://s.test/nobody', x'FF', 's.test', '/nobody', 1, 1, 0, 2)
            """)
        try db.execute(sql: """
            INSERT INTO responses (url_id, status, content_type, fetched_at)
            VALUES (last_insert_rowid(), 200, 'text/html', 0)
            """)
    }
    return store
}

@MainActor
@Test func searchFindsThePagesContainingATerm() throws {
    let store = try searchableStore()
    let hits = try store.search("dog")
    #expect(Set(hits.map(\.url)) == ["https://s.test/alpha", "https://s.test/beta"])
}

/// "Does it appear" is much less useful than "how often": three mentions on one
/// page and one on another are different findings.
@MainActor
@Test func searchCountsEveryOccurrenceNotJustTheFirst() throws {
    let store = try searchableStore()
    let hits = try store.search("dog")
    #expect(hits.first { $0.url.hasSuffix("/beta") }?.count == 3)
    #expect(hits.first { $0.url.hasSuffix("/alpha") }?.count == 1)
}

@MainActor
@Test func searchIsCaseInsensitive() throws {
    let store = try searchableStore()
    #expect(try store.search("QUICK BROWN").count == 1)
}

@MainActor
@Test func searchReturnsAReadableSnippet() throws {
    let store = try searchableStore()
    let hit = try #require(try store.search("jumps").first)
    #expect(hit.snippet.contains("quick brown fox jumps"))
    #expect(!hit.snippet.contains("\n"), "a snippet is one line")
}

@MainActor
@Test func regexSearchMatchesAPattern() throws {
    let store = try searchableStore()
    let hits = try store.search("\\bfox\\b|\\bthird\\b", regex: true)
    #expect(Set(hits.map(\.url)) == ["https://s.test/alpha", "https://s.test/beta"])
}

/// The search box is a text field someone is still typing into, so a
/// half-written pattern must find nothing rather than throw.
@MainActor
@Test func anInvalidRegexFindsNothingRatherThanFailing() throws {
    let store = try searchableStore()
    #expect(try store.search("[unclosed", regex: true).isEmpty)
}

@MainActor
@Test func anEmptyTermFindsNothing() throws {
    let store = try searchableStore()
    #expect(try store.search("   ").isEmpty)
}

/// A page crawled past `retainBodyURLLimit` has no body to search. It is absent
/// rather than reported as not matching, which is why the UI has to say how many
/// pages were searchable.
@MainActor
@Test func aPageWithNoRetainedBodyIsSimplyNotSearched() throws {
    let store = try searchableStore()
    #expect(try store.search("s.test").allSatisfy { !$0.url.hasSuffix("/nobody") })
}

@MainActor
@Test func searchStopsAtItsLimit() throws {
    let store = try searchableStore()
    #expect(try store.search("a", limit: 1).count == 1)
}

// MARK: - Headers

@MainActor
@Test func headersComeBackSortedByName() throws {
    let store = try ReportFixture.make()
    let id = try store.dbQueue.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE path = '/'")!
    }
    let headers = try store.headers(id: id)
    #expect(headers.map(\.label) == headers.map(\.label).sorted())
    #expect(headers.contains { $0.label == "Strict-Transport-Security" })
}

@MainActor
@Test func aResponseWithNoStoredHeadersHasNone() throws {
    let store = try ReportFixture.make()
    try store.dbQueue.write { db in
        try db.execute(sql: "UPDATE responses SET headers_json = NULL")
    }
    let id = try store.dbQueue.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE path = '/'")!
    }
    #expect(try store.headers(id: id).isEmpty)
}

// MARK: - Snippet edges
//
// `firstMatch` walks String.Index by an offset in both directions, which is the
// one piece of index arithmetic in this feature. These pin its boundaries:
// a match at position zero, a match at the very end, a match longer than the
// window, and multi-byte characters where a byte offset would be wrong.

@Test func aMatchAtTheVeryStartDoesNotWalkOffTheFront() {
    let result = Store.firstMatch(in: "needle at the start of the string",
                                  needle: "needle", expression: nil)
    #expect(result?.snippet.hasPrefix("needle") == true)
    #expect(result?.count == 1)
}

@Test func aMatchAtTheVeryEndDoesNotWalkOffTheBack() {
    let result = Store.firstMatch(in: "the string ends with needle",
                                  needle: "needle", expression: nil)
    #expect(result?.snippet.hasSuffix("needle") == true)
}

@Test func aMatchIsFoundInASingleCharacterString() {
    #expect(Store.firstMatch(in: "x", needle: "x", expression: nil)?.count == 1)
}

@Test func aMatchLongerThanTheSnippetWindowStillReturns() {
    let long = String(repeating: "abcdef", count: 200)
    let result = Store.firstMatch(in: long, needle: long, expression: nil)
    #expect(result != nil)
    #expect(result?.count == 1)
}

/// Multi-byte characters are where an offset measured in bytes rather than
/// Characters goes wrong, and going wrong there means a crash, not a bad result.
@Test func multiByteCharactersDoNotBreakTheSnippet() {
    let text = "Ça commence ici. Le mot recherché est naïve, entouré d'accents et d'émoji 🎯 partout."
    let result = Store.firstMatch(in: text, needle: "naïve", expression: nil)
    #expect(result?.snippet.contains("naïve") == true)
    #expect(result?.count == 1)
}

@Test func aTermThatIsAbsentReturnsNil() {
    #expect(Store.firstMatch(in: "nothing to see", needle: "absent", expression: nil) == nil)
}

@Test func anEmptyDocumentReturnsNil() {
    #expect(Store.firstMatch(in: "", needle: "x", expression: nil) == nil)
}

/// A zero-width regex match would make a naive count loop run forever; the
/// regex path uses `matches(in:)` rather than a loop, so it terminates.
@Test func aZeroWidthRegexMatchTerminates() throws {
    let expression = try NSRegularExpression(pattern: "(?=needle)")
    let result = Store.firstMatch(in: "a needle here", needle: "(?=needle)", expression: expression)
    #expect(result != nil)
}

@Test func overlappingLiteralMatchesAreCountedWithoutLooping() {
    // "aa" in "aaaa" counts as two non-overlapping matches, and must terminate.
    #expect(Store.firstMatch(in: "aaaa", needle: "aa", expression: nil)?.count == 2)
}
