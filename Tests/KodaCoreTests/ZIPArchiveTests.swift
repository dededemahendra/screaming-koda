import Foundation
import Testing
@testable import KodaCore

/// Every assertion here goes through the *system* `unzip`, not a reader written
/// alongside the writer. A self-checking pair only proves it is self-consistent;
/// what matters is whether Excel and Finder will open the file.
@MainActor
private func withArchive<T>(_ data: Data, _ body: (URL) throws -> T) throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("zip-\(UUID().uuidString).zip")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

@discardableResult
private func run(_ launchPath: String, _ arguments: [String]) throws -> (status: Int32, out: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, out)
}

@MainActor
@Test func producesAnArchiveTheSystemUnzipAccepts() throws {
    var zip = ZIPArchive()
    zip.add(path: "hello.txt", data: Data("hello".utf8))
    let result = try withArchive(zip.finish()) { try run("/usr/bin/unzip", ["-t", $0.path]) }
    #expect(result.status == 0)
    #expect(String(decoding: result.out, as: UTF8.self).contains("No errors detected"))
}

@MainActor
@Test func roundTripsFileContentsExactly() throws {
    // Includes bytes that are not valid UTF-8, so this covers arbitrary data
    // rather than only text.
    let payload = Data((0...255).map { UInt8($0) })
    var zip = ZIPArchive()
    zip.add(path: "bytes.bin", data: payload)
    let out = try withArchive(zip.finish()) { try run("/usr/bin/unzip", ["-p", $0.path, "bytes.bin"]) }
    #expect(out.out == payload)
}

@MainActor
@Test func handlesMultipleEntriesAndNestedPaths() throws {
    var zip = ZIPArchive()
    zip.add(path: "[Content_Types].xml", data: Data("<types/>".utf8))
    zip.add(path: "xl/workbook.xml", data: Data("<workbook/>".utf8))
    zip.add(path: "xl/worksheets/sheet1.xml", data: Data("<sheet/>".utf8))
    let data = zip.finish()

    try withArchive(data) { url in
        #expect(try run("/usr/bin/unzip", ["-t", url.path]).status == 0)
        let listing = try run("/usr/bin/unzip", ["-Z1", url.path]).out
        let names = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(names.sorted() == ["[Content_Types].xml", "xl/workbook.xml", "xl/worksheets/sheet1.xml"])
        let sheet = try run("/usr/bin/unzip", ["-p", url.path, "xl/worksheets/sheet1.xml"]).out
        #expect(String(decoding: sheet, as: UTF8.self) == "<sheet/>")
    }
}

/// An empty part is legal and `.xlsx` writers do produce them; a zero-length
/// entry must not corrupt the offsets of everything after it.
@MainActor
@Test func handlesAnEmptyFileWithoutCorruptingLaterEntries() throws {
    var zip = ZIPArchive()
    zip.add(path: "empty.txt", data: Data())
    zip.add(path: "after.txt", data: Data("still here".utf8))
    try withArchive(zip.finish()) { url in
        #expect(try run("/usr/bin/unzip", ["-t", url.path]).status == 0)
        let after = try run("/usr/bin/unzip", ["-p", url.path, "after.txt"]).out
        #expect(String(decoding: after, as: UTF8.self) == "still here")
    }
}

@MainActor
@Test func isByteDeterministic() {
    func build() -> Data {
        var zip = ZIPArchive()
        zip.add(path: "a.txt", data: Data("one".utf8))
        zip.add(path: "b.txt", data: Data("two".utf8))
        return zip.finish()
    }
    #expect(build() == build(), "a timestamp from the clock would break this")
}

/// The known CRC-32 of "123456789", the standard check value for this
/// polynomial. A wrong CRC makes an archive that unzip rejects.
@Test func crc32MatchesTheStandardCheckValue() {
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    #expect(CRC32.checksum(Data()) == 0)
}
