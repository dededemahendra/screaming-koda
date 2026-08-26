import CryptoKit
import Foundation

/// Charikar simhash over word shingles, for finding pages that are *similar*
/// rather than identical.
///
/// Exact matching on `content_hash` already finds byte-identical pages, and
/// misses the far more common case: two product pages differing by a price, or
/// a paginated series where only a heading changes. Simhash gives those a
/// distance rather than a yes or no.
///
/// The construction is the standard one — hash each shingle, add or subtract per
/// bit position weighted by the shingle count, then take the sign of each
/// column. Two documents that share most of their shingles land within a few
/// bits of each other whatever their length.
public enum SimHash {
    /// Words per shingle. Three is the usual choice: single words collide across
    /// unrelated pages, and longer runs stop matching text that was lightly
    /// edited — which is exactly the text this is meant to catch.
    public static let shingleSize = 3

    /// A page shorter than one shingle has no meaningful fingerprint, and
    /// returning one anyway would make every short page a near-duplicate of
    /// every other.
    public static func compute(_ text: String) -> Int64? {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard words.count >= shingleSize else { return nil }

        var counts: [UInt64: Int] = [:]
        for start in 0...(words.count - shingleSize) {
            let shingle = words[start..<(start + shingleSize)].joined(separator: " ")
            counts[hash64(shingle), default: 0] += 1
        }

        var columns = [Int](repeating: 0, count: 64)
        for (hash, count) in counts {
            for bit in 0..<64 {
                columns[bit] += (hash >> UInt64(bit)) & 1 == 1 ? count : -count
            }
        }
        var out: UInt64 = 0
        for bit in 0..<64 where columns[bit] > 0 { out |= (1 << UInt64(bit)) }
        return Int64(bitPattern: out)
    }

    /// How many bits differ. Zero means the fingerprints match; small numbers
    /// mean the documents are close.
    public static func distance(_ a: Int64, _ b: Int64) -> Int {
        (UInt64(bitPattern: a) ^ UInt64(bitPattern: b)).nonzeroBitCount
    }

    /// The fingerprint is split into this many equal bands, used as an
    /// index-backed prefilter so that finding near-duplicates does not require
    /// comparing every page against every other — which a large crawl cannot
    /// afford.
    public static let bandCount = 8
    public static let bandBits = 64 / bandCount

    /// Bits allowed to differ before two pages stop counting as near-duplicates.
    ///
    /// **This number is not free to choose.** The prefilter only works because of
    /// the pigeonhole principle: `k` differing bits can fall in at most `k`
    /// bands, so if `k < bandCount` at least one band must survive intact and an
    /// exact band match cannot miss a real pair. Raise the threshold to
    /// `bandCount` or beyond and the prefilter starts silently dropping genuine
    /// near-duplicates — the worst kind of wrong, because the report would look
    /// clean.
    ///
    /// So the threshold is `bandCount - 1`, and the two move together. Measured
    /// against realistic page prose: two product pages on one template sit
    /// around 4 bits apart, and an unrelated page around 26, so 7 separates them
    /// with room on both sides. It errs towards missing a distant pair rather
    /// than inventing a close one.
    public static let nearThreshold = bandCount - 1

    /// The fingerprint split into equal bands, low bits first.
    public static func bands(_ hash: Int64) -> [Int] {
        let bits = UInt64(bitPattern: hash)
        let mask = (UInt64(1) << UInt64(bandBits)) - 1
        return (0..<bandCount).map { Int((bits >> UInt64($0 * bandBits)) & mask) }
    }

    static func hash64(_ text: String) -> UInt64 {
        var digest = SHA256.hash(data: Data(text.utf8)).makeIterator()
        var out: UInt64 = 0
        for _ in 0..<8 { out = (out << 8) | UInt64(digest.next() ?? 0) }
        return out
    }
}
