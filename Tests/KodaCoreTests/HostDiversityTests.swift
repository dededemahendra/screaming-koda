import Foundation
import GRDB
import Testing
@testable import KodaCore

@MainActor
private func storeWith(hosts: [(host: String, count: Int)]) throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        var n = 0
        for entry in hosts {
            for i in 0..<entry.count {
                n += 1
                try db.execute(
                    sql: """
                        INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                        VALUES (?,?,?,?,1,1,0,0)
                        """,
                    arguments: ["https://\(entry.host)/p/\(i)", Data("h\(n)".utf8), entry.host, "/p/\(i)"]
                )
            }
        }
    }
    return store
}

@MainActor
@Test func aBatchNeverExceedsMaxPerHost() throws {
    // 50 URLs on one host: without the cap a batch of 10 would be 10 requests to it.
    let store = try storeWith(hosts: [("crowded.test", 50)])
    let batch = try store.claimNext(limit: 10, maxPerHost: 3)
    #expect(batch.count == 3, "only maxPerHost URLs from a single host may be claimed at once")
}

@MainActor
@Test func batchesSpreadAcrossHosts() throws {
    let store = try storeWith(hosts: [("a.test", 20), ("b.test", 20), ("c.test", 20)])
    let batch = try store.claimNext(limit: 9, maxPerHost: 3)
    #expect(batch.count == 9)
    var perHost: [String: Int] = [:]
    for item in batch { perHost[item.url.host, default: 0] += 1 }
    #expect(perHost.count == 3, "all three hosts should appear, got \(perHost)")
    #expect(perHost.values.allSatisfy { $0 <= 3 }, "no host over the cap: \(perHost)")
}

@MainActor
@Test func repeatedClaimsEventuallyDrainACrowdedHost() throws {
    let store = try storeWith(hosts: [("crowded.test", 7)])
    var claimed = 0
    for _ in 0..<10 {
        let batch = try store.claimNext(limit: 10, maxPerHost: 3)
        if batch.isEmpty { break }
        claimed += batch.count
        for item in batch { try store.markDone(item.id) }
    }
    #expect(claimed == 7, "the cap throttles a host per batch, it does not strand its URLs")
}

@MainActor
@Test func frontierItemCarriesCheckOnly() throws {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        try db.execute(
            sql: """
                INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state, check_only)
                VALUES (?,?,?,?,1,0,0,0,1)
                """,
            arguments: ["https://ext.test/img.png", Data("hi".utf8), "ext.test", "/img.png"]
        )
    }
    let batch = try store.claimNext(limit: 10, maxPerHost: 5)
    #expect(batch.first?.checkOnly == true)
}

@MainActor
@Test func ordinaryURLsAreNotCheckOnly() throws {
    let store = try storeWith(hosts: [("a.test", 1)])
    let batch = try store.claimNext(limit: 10, maxPerHost: 5)
    #expect(batch.first?.checkOnly == false)
}
