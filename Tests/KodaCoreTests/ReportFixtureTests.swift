import Foundation
import GRDB
import Testing
@testable import KodaCore

/// A broken fixture should fail once, here, with a clear reason — not as a dozen
/// confusing report failures that all look like bad SQL.
@Test func fixtureBuildsWithEveryTablePopulated() throws {
    let store = try ReportFixture.make()
    let counts = try store.dbQueue.read { db -> [String: Int] in
        var out: [String: Int] = [:]
        for table in ["urls", "responses", "page_facts", "links", "images", "hreflang"] {
            out[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
        }
        return out
    }
    #expect(counts["urls"] == ReportFixture.pages.count + ReportFixture.external.count
                              + ReportFixture.images.count)
    for table in ["responses", "page_facts", "links", "images", "hreflang"] {
        #expect((counts[table] ?? 0) > 0, "\(table) is empty")
    }
}

/// Every path must be distinct, or `paths(_:_:)` silently collapses two rows into
/// one and a filter that returns both looks like it returned one.
@Test func fixturePathsAreUnique() {
    let all = (ReportFixture.pages + ReportFixture.external + ReportFixture.images).map(\.path)
    #expect(Set(all).count == all.count)
}

/// Redirect and canonical targets are resolved by path lookup, so a typo would
/// quietly become a NULL rather than an error.
@Test func fixtureRedirectAndCanonicalTargetsAllResolved() throws {
    let store = try ReportFixture.make()
    let unresolved = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM responses r
            JOIN urls u ON u.id = r.url_id
            WHERE u.path IN ('/redirect-301','/chain-1','/chain-2','/loop-a','/loop-b','/loop-self')
              AND r.redirect_target_id IS NULL
            """) ?? 0
    }
    #expect(unresolved == 0, "a redirect target path did not resolve")

    let badCanonical = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: """
            SELECT count(*) FROM page_facts f
            JOIN urls u ON u.id = f.url_id
            WHERE u.path IN ('/canonicalised','/canon-to-404') AND f.canonical_id IS NULL
            """) ?? 0
    }
    #expect(badCanonical == 0, "a canonical target path did not resolve")
}
