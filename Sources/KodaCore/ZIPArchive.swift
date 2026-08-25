import Foundation

/// The smallest ZIP writer that produces a file Excel, Numbers and `unzip` all
/// accept: deflated entries, a central directory, no zip64, no data descriptors.
///
/// This exists because an `.xlsx` is a zip of XML parts, and pulling in a zip
/// library to write six small files would be the larger cost. Reading zips is
/// not needed anywhere, so it is not here.
enum ZIPArchive {
    struct Entry {
        let path: String
        let data: Data
    }

    /// Timestamps are fixed at the DOS epoch so exporting the same crawl twice
    /// produces byte-identical files, which is what makes a golden-file test
    /// possible. No spreadsheet application shows the per-entry date anyway.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = 0x0021  // 1980-01-01

    static func archive(_ entries: [Entry]) -> Data {
        var output = Data()
        var directory = Data()

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            // Apple calls raw DEFLATE "zlib"; it is exactly what ZIP method 8 wants.
            // A part that does not shrink is stored, which also covers the empty case:
            // deflate of nothing is two bytes, and storing zero is honest.
            let deflated = (try? (entry.data as NSData).compressed(using: .zlib) as Data)
            let useDeflate = (deflated?.count ?? .max) < entry.data.count
            let payload = useDeflate ? deflated! : entry.data
            let method: UInt16 = useDeflate ? 8 : 0
            let offset = UInt32(output.count)

            var header = Data()
            header.append(uint32: 0x0403_4B50)
            header.append(uint16: 20)          // version needed
            header.append(uint16: 0x0800)      // UTF-8 names
            header.append(uint16: method)
            header.append(uint16: dosTime)
            header.append(uint16: dosDate)
            header.append(uint32: crc)
            header.append(uint32: UInt32(payload.count))
            header.append(uint32: UInt32(entry.data.count))
            header.append(uint16: UInt16(name.count))
            header.append(uint16: 0)           // no extra field
            output += header
            output += name
            output += payload

            var central = Data()
            central.append(uint32: 0x0201_4B50)
            central.append(uint16: 20)         // version made by
            central.append(uint16: 20)         // version needed
            central.append(uint16: 0x0800)
            central.append(uint16: method)
            central.append(uint16: dosTime)
            central.append(uint16: dosDate)
            central.append(uint32: crc)
            central.append(uint32: UInt32(payload.count))
            central.append(uint32: UInt32(entry.data.count))
            central.append(uint16: UInt16(name.count))
            central.append(uint16: 0)          // extra
            central.append(uint16: 0)          // comment
            central.append(uint16: 0)          // disk
            central.append(uint16: 0)          // internal attributes
            central.append(uint32: 0)          // external attributes
            central.append(uint32: offset)
            directory += central
            directory += name
        }

        let directoryOffset = UInt32(output.count)
        output += directory

        var end = Data()
        end.append(uint32: 0x0605_4B50)
        end.append(uint16: 0)                  // this disk
        end.append(uint16: 0)                  // disk with the directory
        end.append(uint16: UInt16(entries.count))
        end.append(uint16: UInt16(entries.count))
        end.append(uint32: UInt32(directory.count))
        end.append(uint32: directoryOffset)
        end.append(uint16: 0)                  // no comment
        return output + end
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
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
