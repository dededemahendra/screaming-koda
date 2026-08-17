import Foundation
import GRDB

public struct FrontierItem: Sendable {
    public let id: Int64
    public let url: NormalizedURL
    public let depth: Int
}

extension Store {
    /// Inserts the URL if unseen; returns the row id either way.
    public func insertURLIfNew(
        _ url: NormalizedURL,
        depth: Int,
        isInternal: Bool,
        discoveredAt: Date
    ) throws -> Int64 {
        try dbQueue.write { db in
            try Self.insertURL(db, url, depth: depth, isInternal: isInternal, discoveredAt: discoveredAt)
        }
    }

    /// Same as `insertURLIfNew` but inside a caller-managed transaction.
    static func insertURL(
        _ db: Database,
        _ url: NormalizedURL,
        depth: Int,
        isInternal: Bool,
        discoveredAt: Date
    ) throws -> Int64 {
        if let existing = try Int64.fetchOne(db, sql: "SELECT id FROM urls WHERE url_hash = ?", arguments: [url.sha256]) {
            return existing
        }
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                VALUES (?,?,?,?,?,?,?,0)
                """,
            arguments: [url.absoluteString, url.sha256, url.host, url.path, depth, isInternal ? 1 : 0,
                        discoveredAt.timeIntervalSince1970]
        )
        return db.lastInsertedRowID
    }

    /// Claims up to `limit` queued URLs, shallowest first, marking them in-flight.
    ///
    /// A claimed row whose stored `url` string can no longer be re-normalized (e.g. a
    /// future normalizer change, or corrupt data) is marked skipped rather than left
    /// in-flight forever — otherwise it would silently strand the frontier: nothing
    /// else moves a row out of the in-flight state, and `claimNext` only ever selects
    /// queued rows, so the row would never be crawled and never complete.
    public func claimNext(limit: Int) throws -> [FrontierItem] {
        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, url, depth FROM urls WHERE state = 0 ORDER BY depth ASC, id ASC LIMIT ?",
                arguments: [limit]
            )
            guard !rows.isEmpty else { return [] }
            let ids = rows.map { $0["id"] as Int64 }
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.execute(
                sql: "UPDATE urls SET state = 1 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            var items: [FrontierItem] = []
            items.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["id"]
                if let normalized = URLNormalizer.normalize(row["url"], relativeTo: nil) {
                    items.append(FrontierItem(id: id, url: normalized, depth: row["depth"]))
                } else {
                    try Self.setState(db, id: id, state: 3)
                }
            }
            return items
        }
    }

    public func markDone(_ id: Int64) throws {
        try dbQueue.write { db in try Self.setState(db, id: id, state: 2) }
    }

    public func markSkipped(_ id: Int64) throws {
        try dbQueue.write { db in try Self.setState(db, id: id, state: 3) }
    }

    static func setState(_ db: Database, id: Int64, state: Int) throws {
        try db.execute(sql: "UPDATE urls SET state = ? WHERE id = ?", arguments: [state, id])
    }

    /// Requeues URLs left in-flight by a crash or quit. Returns how many were reset.
    @discardableResult
    public func resetInFlight() throws -> Int {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE urls SET state = 0 WHERE state = 1")
            return db.changesCount
        }
    }

    public func urlCounts() throws -> (queued: Int, inFlight: Int, done: Int, total: Int) {
        try dbQueue.read { db in
            func count(_ state: Int) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM urls WHERE state = ?", arguments: [state]) ?? 0
            }
            let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM urls") ?? 0
            return (try count(0), try count(1), try count(2), total)
        }
    }
}
