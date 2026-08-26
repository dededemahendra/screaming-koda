import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Evaluates the shipped SQL expression against a real row, rather than a Swift
/// re-implementation of the same rules. A `CASE` expression that is wrong in a
/// way a parallel Swift version is not is exactly the bug worth catching.
private struct Verdicts {
    let store: Store

    init() throws {
        store = try Store(path: nil)
        try store.migrate()
    }

    @discardableResult
    func insert(
        path: String, status: Int? = 200, metaRobots: String? = nil,
        xRobots: String? = nil, canonicalToSelf: Bool = false, canonicalTo: Int64? = nil
    ) throws -> Int64 {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,?,1,0,2)
                    """,
                arguments: ["https://x.test\(path)", Data(path.utf8), "x.test", path, 1])
            let id = db.lastInsertedRowID
            if let status {
                try db.execute(sql: "INSERT INTO responses (url_id, status, fetched_at) VALUES (?,?,0)",
                               arguments: [id, status])
            }
            let canonical: Int64? = canonicalToSelf ? id : canonicalTo
            try db.execute(
                sql: """
                    INSERT INTO page_facts (url_id, meta_robots, x_robots_tag, canonical_id)
                    VALUES (?,?,?,?)
                    """,
                arguments: [id, metaRobots, xRobots, canonical])
            return id
        }
    }

    func verdict(_ id: Int64) throws -> String {
        try store.dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT \(Indexability.expression) \(ReportSQL.from) WHERE u.id = ?
                """, arguments: [id]) ?? "<none>"
        }
    }
}

@Test func anOrdinary200IsIndexable() throws {
    let v = try Verdicts()
    #expect(try v.verdict(v.insert(path: "/ok")) == Indexability.indexable)
}

@Test func aRedirectIsNonIndexable() throws {
    let v = try Verdicts()
    #expect(try v.verdict(v.insert(path: "/r", status: 301)) == Indexability.redirected)
}

@Test func aServerErrorIsNonIndexable() throws {
    let v = try Verdicts()
    #expect(try v.verdict(v.insert(path: "/e", status: 500)) == Indexability.serverError)
}

/// status 0 is this schema's transport-error marker. It must not fall through
/// to "Indexable" just because it fails every numeric range check above.
@Test func aTransportErrorIsNonIndexable() throws {
    let v = try Verdicts()
    #expect(try v.verdict(v.insert(path: "/t", status: 0)) == Indexability.serverError)
}

/// Precedence, and the reason it matters: the 404 is the thing to fix, so a
/// page that is both missing and noindexed is reported as missing.
@Test func aClientErrorBeatsNoindex() throws {
    let v = try Verdicts()
    let id = try v.insert(path: "/gone", status: 404, metaRobots: "noindex")
    #expect(try v.verdict(id) == Indexability.clientError)
}

@Test func noindexInMetaRobotsIsFound() throws {
    let v = try Verdicts()
    #expect(try v.verdict(v.insert(path: "/n", metaRobots: "noindex, follow")) == Indexability.noindex)
}

/// The header form counts too, and the match is case-insensitive because real
/// sites send `NOINDEX` and `NoIndex`.
@Test func noindexInTheXRobotsHeaderIsFound() throws {
    let v = try Verdicts()
    #expect(try v.verdict(v.insert(path: "/x", xRobots: "NOINDEX")) == Indexability.noindex)
}

@Test func aSelfReferencingCanonicalIsStillIndexable() throws {
    let v = try Verdicts()
    #expect(try v.verdict(v.insert(path: "/self", canonicalToSelf: true)) == Indexability.indexable)
}

@Test func aCanonicalPointingElsewhereIsCanonicalised() throws {
    let v = try Verdicts()
    let target = try v.insert(path: "/target")
    let id = try v.insert(path: "/dupe", canonicalTo: target)
    #expect(try v.verdict(id) == Indexability.canonicalised)
}

/// A queued URL with no response row yet is not a finding — it is a row the
/// live crawl has not reached. Reporting it as non-indexable would fill the
/// sidebar with phantom issues for the duration of every crawl.
@Test func anUncrawledURLIsNeitherIndexableNorAnIssue() throws {
    let v = try Verdicts()
    #expect(try v.verdict(v.insert(path: "/queued", status: nil)) == Indexability.notCrawled)
}
