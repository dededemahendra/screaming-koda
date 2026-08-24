import Foundation
import GRDB
import Testing
@testable import KodaCore

/// Page-shaped prose: mostly boilerplate with a little page-specific detail,
/// which is the shape near-duplicate detection actually has to cope with.
private func productPage(colour: String, price: String) -> String {
    """
    Harrier running shoe in \(colour). Free delivery on all orders over fifty pounds \
    and free returns within thirty days. Price \(price). The upper is engineered mesh \
    with a padded collar and a reinforced heel counter for stability. The midsole uses \
    a compression moulded foam that balances cushioning with responsiveness on both \
    road and light trail. A rubber outsole with a directional tread pattern provides \
    grip in wet and dry conditions. Weight approximately two hundred and sixty grams \
    in a men's size nine. Sizing runs true to size; if you are between sizes we \
    recommend taking the larger. Care instructions: remove the insole and laces, wash \
    by hand in cool water with a mild detergent, and air dry away from direct heat. \
    All footwear carries a twelve month guarantee against manufacturing defects.
    """
}

private let base = productPage(colour: "black", price: "£89")
private let sibling = productPage(colour: "blue", price: "£95")
private let unrelatedPage = """
    Our returns policy explains how to send an item back, what condition it must be \
    in, and how long a refund takes to reach your account. Refunds are issued to the \
    original payment method. Exchanges are handled as a return followed by a new \
    order. Items marked final sale cannot be returned. If an item arrives damaged \
    please photograph it before contacting us so we can raise a claim with the \
    carrier on your behalf and send a replacement without waiting for the return.
    """

/// Similar text lands close; unrelated text does not. This is the entire
/// property the feature rests on.
@Test func twoPagesOnOneTemplateAreClose() throws {
    let a = try #require(SimHash.compute(base))
    let b = try #require(SimHash.compute(sibling))
    let distance = SimHash.distance(a, b)
    #expect(distance <= SimHash.nearThreshold, "measured \(distance)")
}

@Test func anUnrelatedPageIsFarAway() throws {
    let a = try #require(SimHash.compute(base))
    let b = try #require(SimHash.compute(unrelatedPage))
    let distance = SimHash.distance(a, b)
    #expect(distance > SimHash.nearThreshold * 2,
            "measured \(distance); the threshold needs clear air on both sides")
}

@Test func identicalTextProducesTheSameFingerprint() throws {
    #expect(SimHash.compute(base) == SimHash.compute(base))
    #expect(SimHash.distance(try #require(SimHash.compute(base)),
                             try #require(SimHash.compute(base))) == 0)
}

/// Every short page would otherwise be a near-duplicate of every other short
/// page, which is worse than saying nothing.
@Test func textTooShortToFingerprintHasNoFingerprint() {
    #expect(SimHash.compute("") == nil)
    #expect(SimHash.compute("two words") == nil)
    #expect(SimHash.compute("now there are three") != nil)
}

/// The property the whole prefilter rests on, stated as an invariant rather
/// than hoped for.
///
/// `k` differing bits can fall in at most `k` bands, so while the threshold
/// stays below the band count at least one band must survive intact and an
/// exact band match cannot miss a genuine pair. Raise the threshold to the band
/// count and the prefilter starts silently dropping near-duplicates — the worst
/// kind of wrong, because the report would look clean.
@Test func theThresholdStaysBelowTheBandCount() {
    #expect(SimHash.nearThreshold < SimHash.bandCount)
    #expect(SimHash.bandCount * SimHash.bandBits == 64)
}

/// And the invariant holds for actual fingerprints, not just on paper: no pair
/// within the threshold ever has all of its bands differ.
@Test func noPairWithinTheThresholdEverLosesEveryBand() throws {
    let origin = try #require(SimHash.compute(base))
    var checked = 0
    // Flip every combination of up to `nearThreshold` bits and confirm a band
    // always survives.
    for first in 0..<64 {
        for second in first..<64 {
            for third in second..<64 {
                let flipped = Int64(bitPattern: UInt64(bitPattern: origin)
                    ^ (1 << UInt64(first)) ^ (1 << UInt64(second)) ^ (1 << UInt64(third)))
                guard SimHash.distance(origin, flipped) <= SimHash.nearThreshold else { continue }
                let shared = zip(SimHash.bands(origin), SimHash.bands(flipped)).filter { $0 == $1 }
                #expect(!shared.isEmpty, "bits \(first),\(second),\(third) lost every band")
                checked += 1
            }
        }
    }
    #expect(checked > 40_000, "the sweep should have covered a great many pairs")
}

@Test func bandsCoverTheWholeFingerprint() throws {
    let hash = try #require(SimHash.compute(base))
    let bands = SimHash.bands(hash)
    #expect(bands.count == SimHash.bandCount)
    let ceiling = 1 << SimHash.bandBits
    #expect(bands.allSatisfy { $0 >= 0 && $0 < ceiling })
    var rebuilt: UInt64 = 0
    for (index, band) in bands.enumerated() {
        rebuilt |= UInt64(band) << UInt64(index * SimHash.bandBits)
    }
    #expect(Int64(bitPattern: rebuilt) == hash, "the bands are the fingerprint, split up")
}

// MARK: - Through the database

@MainActor
private func storeWith(_ pages: [(String, String)]) throws -> Store {
    let store = try Store(path: nil)
    try store.migrate()
    try store.dbQueue.write { db in
        for (path, text) in pages {
            try db.execute(
                sql: """
                    INSERT INTO urls (url, url_hash, host, path, depth, is_internal, discovered_at, state)
                    VALUES (?,?,?,?,1,1,0,2)
                    """,
                arguments: ["https://s.test\(path)", Data(path.utf8), "s.test", path])
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO responses (url_id, status, content_type, fetched_at)
                    VALUES (?,200,'text/html; charset=utf-8',0)
                    """,
                arguments: [id])
            let hash = SimHash.compute(text)
            try db.execute(
                sql: """
                    INSERT INTO page_facts (url_id, title, word_count, content_hash, simhash)
                    VALUES (?,?,?,?,?)
                    """,
                arguments: [id, "Title \(path)", 60, Data(text.utf8), hash])
            if let hash {
                for (band, value) in SimHash.bands(hash).enumerated() {
                    try db.execute(
                        sql: "INSERT INTO simhash_bands (url_id, band, value) VALUES (?,?,?)",
                        arguments: [id, band, value])
                }
            }
        }
    }
    return store
}

@MainActor
@Test func theHammingFunctionIsAvailableInSQL() throws {
    let store = try storeWith([("/a", base)])
    let distance = try store.dbQueue.read { db in
        try Int.fetchOne(db, sql: "SELECT koda_hamming(?, ?)", arguments: [Int64(0), Int64(7)])
    }
    #expect(distance == 3, "0b111 differs from 0 in three bits")
}

@MainActor
@Test func theContentReportFindsNearDuplicatesExactMatchingCannotSee() throws {
    let store = try storeWith([
        ("/product-red", base),
        ("/product-blue", sibling),
        ("/unrelated", unrelatedPage),
    ])

    func paths(_ filter: String) throws -> Set<String> {
        let f = Reports.content.filters.first { $0.id == filter }!
        let ids = try store.ids(for: Reports.content, filter: f, sortBy: nil, ascending: true)
        return try store.dbQueue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT path FROM urls WHERE id IN (\(ids.map(String.init).joined(separator: ",")))
                """))
        }
    }

    #expect(try paths("nearDuplicate") == ["/product-red", "/product-blue"])
    #expect(try paths("duplicate").isEmpty,
            "they are not byte-identical, which is exactly why exact matching misses them")
}

/// A page identical to another is an exact duplicate, and reporting it as a
/// near-duplicate as well would double-count the same finding.
@MainActor
@Test func anExactDuplicateIsNotAlsoReportedAsNear() throws {
    let store = try storeWith([("/one", base), ("/two", base)])
    let f = Reports.content.filters.first { $0.id == "nearDuplicate" }!
    #expect(try store.ids(for: Reports.content, filter: f, sortBy: nil, ascending: true).isEmpty)
}
