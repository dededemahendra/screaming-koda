import Foundation
import Testing
@testable import KodaCore

/// Builds a body in a legacy encoding, so the tests exercise real bytes rather
/// than a string that was UTF-8 all along.
private func bytes(_ text: String, _ encoding: String.Encoding) -> Data {
    guard let data = text.data(using: encoding) else {
        Issue.record("Fixture is not representable in \(encoding)")
        return Data()
    }
    return data
}

@Test func plainUTF8NeedsNoDeclaration() {
    let html = "<html><head><title>Café Crème</title></head><body>Thé</body></html>"
    #expect(HTMLDecoder.decode(Data(html.utf8), contentTypeHeader: nil) == html)
}

@Test func honoursTheCharsetOnTheContentTypeHeader() {
    let html = "<html><head><title>Café</title></head></html>"
    let body = bytes(html, .windowsCP1252)
    #expect(HTMLDecoder.decode(body, contentTypeHeader: "text/html; charset=windows-1252") == html)
}

@Test func honoursAMetaCharsetWhenTheHeaderIsSilent() {
    let html = "<html><head><meta charset=\"ISO-8859-1\"><title>Café</title></head></html>"
    let body = bytes(html, .isoLatin1)
    #expect(HTMLDecoder.decode(body, contentTypeHeader: "text/html") == html)
}

@Test func honoursTheOlderHttpEquivDeclaration() {
    let html = """
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252">\
        <title>Café</title></head></html>
        """
    let body = bytes(html, .windowsCP1252)
    #expect(HTMLDecoder.decode(body, contentTypeHeader: nil) == html)
}

/// WHATWG treats the label `iso-8859-1` as windows-1252, and so does every
/// browser. Real pages labelled Latin-1 are full of smart quotes, which are
/// windows-1252 bytes in the 0x80–0x9F range that Latin-1 defines as controls.
@Test func latin1IsDecodedAsWindows1252LikeBrowsersDo() {
    // 0x92 is a right single quote in windows-1252 and a C1 control in Latin-1.
    let body = Data("<html><head><title>It".utf8) + Data([0x92]) + Data("s</title></head></html>".utf8)
    let text = HTMLDecoder.decode(body, contentTypeHeader: "text/html; charset=iso-8859-1")
    #expect(text.contains("It\u{2019}s"))
}

@Test func theHeaderBeatsTheDocumentWhenTheyDisagree() {
    let html = "<html><head><meta charset=\"utf-8\"><title>Café</title></head></html>"
    let body = bytes(html, .windowsCP1252)
    #expect(HTMLDecoder.decode(body, contentTypeHeader: "text/html;charset=windows-1252") == html)
}

@Test func aByteOrderMarkBeatsEveryDeclaration() {
    let html = "<html><head><meta charset=\"windows-1252\"><title>Café</title></head></html>"
    let body = Data([0xEF, 0xBB, 0xBF]) + Data(html.utf8)
    let text = HTMLDecoder.decode(body, contentTypeHeader: "text/html; charset=windows-1252")
    #expect(text == html)
}

@Test func utf16IsRecognisedFromItsByteOrderMark() {
    let html = "<html><head><title>Café</title></head></html>"
    let body = Data([0xFF, 0xFE]) + bytes(html, .utf16LittleEndian)
    #expect(HTMLDecoder.decode(body, contentTypeHeader: nil) == html)
}

/// An unlabelled page is the common case, and guessing wrong is worse than not
/// guessing: valid UTF-8 read as windows-1252 turns "é" into "Ã©" silently.
@Test func unlabelledValidUTF8StaysUTF8() {
    let html = "<html><head><title>Café</title></head></html>"
    #expect(HTMLDecoder.decode(Data(html.utf8), contentTypeHeader: "text/html") == html)
}

/// The other half of that trade: bytes that cannot be UTF-8 are legacy bytes, and
/// windows-1252 recovers them where UTF-8 would leave a row of U+FFFD.
@Test func unlabelledNonUTF8BytesFallBackRatherThanBecomeReplacements() {
    let body = bytes("<html><head><title>Café</title></head></html>", .windowsCP1252)
    let text = HTMLDecoder.decode(body, contentTypeHeader: nil)
    #expect(text.contains("Café"))
    #expect(!text.contains("\u{FFFD}"))
}

@Test func anUnknownCharsetLabelFallsBackInsteadOfFailing() {
    let html = "<html><head><title>Café</title></head></html>"
    let text = HTMLDecoder.decode(Data(html.utf8), contentTypeHeader: "text/html; charset=x-nonesuch")
    #expect(text == html)
}

/// The prescan is bounded, as the HTML spec's is. Without a bound, a page that
/// mentions `charset=` in its body could redecode the whole document.
@Test func aCharsetMentionedFarIntoTheBodyIsIgnored() {
    let filler = String(repeating: "<p>padding</p>", count: 400)
    let html = "<html><head><title>Café</title></head><body>\(filler)"
        + "<meta charset=\"shift_jis\"></body></html>"
    #expect(Data(html.utf8).count > HTMLDecoder.prescanLimit)
    #expect(HTMLDecoder.decode(Data(html.utf8), contentTypeHeader: nil).contains("Café"))
}

@Test func anEmptyBodyIsAnEmptyString() {
    #expect(HTMLDecoder.decode(Data(), contentTypeHeader: "text/html; charset=utf-8").isEmpty)
}

@Test func aQuotedCharsetParameterIsUnwrapped() {
    let html = "<html><head><title>Café</title></head></html>"
    let body = bytes(html, .windowsCP1252)
    #expect(HTMLDecoder.decode(body, contentTypeHeader: "text/html; charset=\"windows-1252\"") == html)
}
