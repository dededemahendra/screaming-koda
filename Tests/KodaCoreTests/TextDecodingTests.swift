import Foundation
import Testing
@testable import KodaCore

/// "Café — naïve façade" in Windows-1252. Every one of these bytes is invalid
/// as standalone UTF-8, so a UTF-8 decode mangles them visibly.
private let latin1Body = Data([
    0x3C, 0x68, 0x74, 0x6D, 0x6C, 0x3E, 0x3C, 0x68, 0x65, 0x61, 0x64, 0x3E,   // <html><head>
    0x3C, 0x74, 0x69, 0x74, 0x6C, 0x65, 0x3E,                                  // <title>
    0x43, 0x61, 0x66, 0xE9, 0x20, 0x6E, 0x61, 0xEF, 0x76, 0x65,                // Café naïve
    0x3C, 0x2F, 0x74, 0x69, 0x74, 0x6C, 0x65, 0x3E,                            // </title>
    0x3C, 0x2F, 0x68, 0x65, 0x61, 0x64, 0x3E, 0x3C, 0x2F, 0x68, 0x74, 0x6D, 0x6C, 0x3E,
])

@Test func aCharsetHeaderIsBelieved() {
    let text = TextDecoding.decode(latin1Body, contentType: "text/html; charset=windows-1252")
    #expect(text.contains("Café naïve"))
}

@Test func charsetParsingToleratesQuotesAndSpacing() {
    for header in ["text/html;charset=windows-1252", "text/html; charset=\"windows-1252\"",
                   "text/html; Charset = WINDOWS-1252", "text/html; charset=iso-8859-1"] {
        let text = TextDecoding.decode(latin1Body, contentType: header)
        #expect(text.contains("Café naïve"), "failed for header: \(header)")
    }
}

@Test func aMetaCharsetIsUsedWhenTheHeaderIsSilent() {
    var body = Data("<html><head><meta charset=\"windows-1252\">".utf8)
    body.append(latin1Body)
    #expect(TextDecoding.decode(body, contentType: "text/html").contains("Café naïve"))
}

@Test func aMetaHttpEquivIsAlsoRead() {
    var body = Data("""
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=windows-1252">
        """.utf8)
    body.append(latin1Body)
    #expect(TextDecoding.decode(body, contentType: nil).contains("Café naïve"))
}

/// The server is authoritative. When the header and the markup disagree, a
/// stale meta tag left in a template must not override what was actually sent.
@Test func theHeaderBeatsTheMetaTag() {
    var body = Data("<html><head><meta charset=\"utf-8\">".utf8)
    body.append(latin1Body)
    #expect(TextDecoding.decode(body, contentType: "text/html; charset=windows-1252")
        .contains("Café naïve"))
}

@Test func validUTF8DecodesAsUTF8WithNoDeclaration() {
    let body = Data("<html><head><title>Café naïve 日本語</title></head></html>".utf8)
    #expect(TextDecoding.decode(body, contentType: "text/html").contains("Café naïve 日本語"))
}

/// The floor: a page that lies about its encoding must still produce readable
/// text. Returning empty, or dropping the page, would make it vanish from every
/// report — a crawl never dies from a bad page.
@Test func aMislabelledPageStillDecodesToSomething() {
    let text = TextDecoding.decode(latin1Body, contentType: "text/html; charset=utf-8")
    #expect(!text.isEmpty)
    #expect(text.contains("<title>"), "the markup must survive even if the accents do not")
}

@Test func anUnknownCharsetNameFallsThroughRatherThanFailing() {
    let body = Data("<html><title>Plain ASCII</title></html>".utf8)
    #expect(TextDecoding.decode(body, contentType: "text/html; charset=x-nonsense-9000")
        .contains("Plain ASCII"))
}

@Test func decodingIsLosslessForASCII() {
    let source = "<html><title>Ordinary ASCII title</title></html>"
    #expect(TextDecoding.decode(Data(source.utf8), contentType: nil) == source)
}

@Test func anEmptyBodyDecodesToAnEmptyString() {
    #expect(TextDecoding.decode(Data(), contentType: "text/html").isEmpty)
}

/// A declaration past the sniff window is ignored rather than scanning a
/// multi-megabyte body looking for one.
///
/// Asserted against `charset(sniffedFrom:)` rather than through `decode`: for a
/// Windows-1252 body the fallback produces exactly the same text as a successful
/// sniff, so a `decode`-level assertion could not tell the two apart and would
/// pass whether or not the window was honoured.
@Test func aMetaTagBeyondTheSniffWindowIsIgnored() {
    var far = Data(String(repeating: " ", count: TextDecoding.sniffWindow).utf8)
    far.append(Data("<meta charset=\"windows-1252\">".utf8))
    #expect(TextDecoding.charset(sniffedFrom: far) == nil)

    var near = Data(String(repeating: " ", count: 100).utf8)
    near.append(Data("<meta charset=\"windows-1252\">".utf8))
    #expect(TextDecoding.charset(sniffedFrom: near) == .windowsCP1252)
}

/// A body past the window still decodes; ignoring the declaration must not mean
/// dropping the page.
@Test func aBodyWithADeclarationTooLateStillDecodes() {
    var body = Data(String(repeating: " ", count: TextDecoding.sniffWindow).utf8)
    body.append(Data("<meta charset=\"windows-1252\">".utf8))
    body.append(latin1Body)
    #expect(!TextDecoding.decode(body, contentType: "text/html").isEmpty)
}

/// Shift_JIS is where the fallback and a correct sniff genuinely differ, so this
/// proves the sniffed encoding is actually applied rather than coincidentally
/// matching Windows-1252.
@Test func aSniffedEncodingIsActuallyApplied() throws {
    let japanese = "<title>\u{65E5}\u{672C}\u{8A9E}</title>"
    let sjisBytes = try #require(japanese.data(using: .shiftJIS))
    var body = Data("<html><head><meta charset=\"shift_jis\">".utf8)
    body.append(sjisBytes)

    #expect(TextDecoding.decode(body, contentType: "text/html").contains("\u{65E5}\u{672C}\u{8A9E}"))
    // And without the declaration it does not, which is what makes the above meaningful.
    var undeclared = Data("<html><head>".utf8)
    undeclared.append(sjisBytes)
    #expect(!TextDecoding.decode(undeclared, contentType: "text/html").contains("\u{65E5}\u{672C}\u{8A9E}"))
}
