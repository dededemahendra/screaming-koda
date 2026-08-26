import Foundation

enum ZIPArchiveError: Error, CustomStringConvertible {
    case tooLarge(limitBytes: Int)

    var description: String {
        switch self {
        case .tooLarge(let limit):
            return "This crawl is too large for a single .xlsx (the format's 32-bit "
                + "size limit is \(limit / 1_000_000_000)GB). Export to CSV, or export "
                + "one report at a time."
        }
    }
}

/// A minimal store-only ZIP writer, existing solely so `.xlsx` export needs no
/// third-party dependency.
///
/// An `.xlsx` is a ZIP of XML parts. Pulling in a spreadsheet library for that
/// would be a large dependency for a small, fully specified job — the format is
/// PKWARE APPNOTE section 4.3, and the subset a workbook needs is a local file
/// header, a central directory, and an end-of-central-directory record.
///
/// Store method (0), no compression: XML compresses well, but a crawl export is
/// written once and opened once, and correctness here matters more than size.
/// Deflate would add a second thing that can be subtly wrong.
struct ZIPArchive {
    /// ZIP32 stores every size and offset as a `UInt32`, so an archive cannot
    /// exceed 4GB. A whole-crawl workbook at the 500,000-URL cap across eleven
    /// reports can plausibly get within reach of that, and `UInt32(someInt)`
    /// *traps* on overflow — so without this guard the failure mode is a crash
    /// with no explanation rather than a message telling the user to export CSV.
    ///
    /// Injectable so a test can drive the limit without building 4GB of data.
    let sizeLimit: Int

    init(sizeLimit: Int = Int(UInt32.max)) {
        self.sizeLimit = sizeLimit
    }

    private struct Entry {
        let path: String
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var entries: [Entry] = []
    private var payload = Data()

    /// A fixed DOS timestamp (1 January 1980, the format's own epoch) rather
    /// than the current time, so the same input always produces the same bytes.
    /// That makes the output diffable and lets a test assert determinism.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021

    mutating func add(path: String, data: Data) throws {
        // Checked before writing, and against the running total rather than just
        // this entry, because the central directory offset must fit too.
        guard payload.count + data.count + path.utf8.count + 30 <= sizeLimit else {
            throw ZIPArchiveError.tooLarge(limitBytes: sizeLimit)
        }
        let crc = CRC32.checksum(data)
        let offset = UInt32(payload.count)
        var header = Data()
        header.append(uint32: 0x0403_4B50)          // local file header signature
        header.append(uint16: 20)                    // version needed
        header.append(uint16: 0)                     // flags
        header.append(uint16: 0)                     // method: stored
        header.append(uint16: Self.dosTime)
        header.append(uint16: Self.dosDate)
        header.append(uint32: crc)
        header.append(uint32: UInt32(data.count))    // compressed size
        header.append(uint32: UInt32(data.count))    // uncompressed size
        let name = Data(path.utf8)
        header.append(uint16: UInt16(name.count))
        header.append(uint16: 0)                     // extra field length
        header.append(name)

        payload.append(header)
        payload.append(data)
        entries.append(Entry(path: path, data: data, crc: crc, offset: offset))
    }

    func finish() throws -> Data {
        var out = payload
        guard out.count <= sizeLimit else {
            throw ZIPArchiveError.tooLarge(limitBytes: sizeLimit)
        }
        let directoryOffset = UInt32(out.count)

        for entry in entries {
            var record = Data()
            record.append(uint32: 0x0201_4B50)       // central directory signature
            record.append(uint16: 20)                 // version made by
            record.append(uint16: 20)                 // version needed
            record.append(uint16: 0)                  // flags
            record.append(uint16: 0)                  // method: stored
            record.append(uint16: Self.dosTime)
            record.append(uint16: Self.dosDate)
            record.append(uint32: entry.crc)
            record.append(uint32: UInt32(entry.data.count))
            record.append(uint32: UInt32(entry.data.count))
            let name = Data(entry.path.utf8)
            record.append(uint16: UInt16(name.count))
            record.append(uint16: 0)                  // extra field length
            record.append(uint16: 0)                  // comment length
            record.append(uint16: 0)                  // disk number
            record.append(uint16: 0)                  // internal attributes
            record.append(uint32: 0)                  // external attributes
            record.append(uint32: entry.offset)
            record.append(name)
            out.append(record)
        }

        let directorySize = UInt32(out.count) - directoryOffset
        var end = Data()
        end.append(uint32: 0x0605_4B50)              // end of central directory
        end.append(uint16: 0)                         // this disk
        end.append(uint16: 0)                         // disk with directory start
        end.append(uint16: UInt16(entries.count))     // entries on this disk
        end.append(uint16: UInt16(entries.count))     // entries total
        end.append(uint32: directorySize)
        end.append(uint32: directoryOffset)
        end.append(uint16: 0)                         // comment length
        out.append(end)
        return out
    }
}

/// CRC-32 as ZIP requires it: the reflected IEEE 802.3 polynomial. Built once,
/// lazily, rather than hard-coded as 256 literals nobody could review.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    /// ZIP is little-endian throughout.
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
