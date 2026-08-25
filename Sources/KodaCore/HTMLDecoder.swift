import Foundation

/// Turns a response body into HTML text using the encoding the page declares.
///
/// Assuming UTF-8 is wrong often enough to matter. A page served as
/// windows-1252 or Latin-1 — still ordinary on older CMSes, and on most of the
/// European web that predates them — decodes into a row of U+FFFD, which then
/// becomes the stored title, the meta description, the anchor text and the
/// content hash. Every report downstream inherits the damage, and it looks like
/// the site's fault rather than the crawler's.
///
/// The order follows the HTML standard: a byte order mark, then the transport
/// layer's `Content-Type`, then a bounded prescan of the document, then a guess.
public enum HTMLDecoder {
    /// How far into the document the meta prescan looks. The standard says 1024
    /// bytes; this is more generous, because a real `<head>` full of preloads and
    /// inline JSON-LD can push the declaration past that. It stays bounded so a
    /// `charset=` in the body can never redecode the page.
    public static let prescanLimit = 4096

    public static func decode(_ body: Data, contentTypeHeader: String?) -> String {
        guard !body.isEmpty else { return "" }

        if let mark = byteOrderMark(body) {
            let rest = Data(body.dropFirst(mark.length))
            if let text = String(data: rest, encoding: mark.encoding) { return text }
            return guess(rest)
        }

        for label in [charset(inContentType: contentTypeHeader), prescanCharset(body)] {
            guard let label, let encoding = encoding(for: label),
                  let text = String(data: body, encoding: encoding)
            else { continue }
            return text
        }

        return guess(body)
    }

    /// What to do when nothing said, or what was said did not decode.
    ///
    /// UTF-8 first and strictly: reading valid UTF-8 as a single-byte encoding
    /// never fails, it just silently turns "é" into "Ã©", and silent corruption is
    /// worse than none. Bytes that cannot be UTF-8 are legacy bytes, and
    /// windows-1252 recovers them where lossy UTF-8 would not.
    private static func guess(_ body: Data) -> String {
        if let text = String(data: body, encoding: .utf8) { return text }
        if let text = String(data: body, encoding: .windowsCP1252) { return text }
        return String(decoding: body, as: UTF8.self)
    }

    private static func byteOrderMark(_ body: Data) -> (encoding: String.Encoding, length: Int)? {
        let prefix = [UInt8](body.prefix(3))
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if prefix.starts(with: [0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if prefix.starts(with: [0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    /// The `charset` parameter of a `Content-Type`, unquoted.
    static func charset(inContentType header: String?) -> String? {
        guard let header else { return nil }
        for parameter in header.split(separator: ";").dropFirst() {
            let trimmed = parameter.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("charset=") else { continue }
            let value = trimmed.dropFirst("charset=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// A `<meta charset>` or a `<meta http-equiv="Content-Type">` in the opening
    /// bytes. One pattern covers both, because both end in `charset=<label>`.
    ///
    /// The prefix is read as Latin-1 rather than UTF-8: it never fails, and every
    /// byte survives as itself, so a truncated multi-byte sequence at the cut
    /// cannot swallow the match that follows it.
    static func prescanCharset(_ body: Data) -> String? {
        let prefix = String(String.UnicodeScalarView(body.prefix(prescanLimit).map(Unicode.Scalar.init)))
        guard let match = metaCharset.firstMatch(
            in: prefix, range: NSRange(prefix.startIndex..., in: prefix)
        ), let range = Range(match.range(at: 1), in: prefix) else { return nil }
        return String(prefix[range])
    }

    private static let metaCharset = try! NSRegularExpression(
        pattern: #"<meta[^>]+?charset\s*=\s*["']?\s*([A-Za-z0-9_:.\-]+)"#,
        options: .caseInsensitive
    )

    /// Maps an IANA charset label to an encoding Foundation can decode with.
    ///
    /// `CFStringConvertIANACharSetNameToEncoding` knows the whole registry, which
    /// beats a hand-kept table: Shift JIS, EUC-KR, Big5 and KOI8-R all arrive for
    /// free.
    static func encoding(for label: String) -> String.Encoding? {
        let name = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return nil }

        // The standard maps these onto windows-1252, and so does every browser.
        // Pages labelled Latin-1 are full of smart quotes and dashes, which live
        // in the 0x80–0x9F range that Latin-1 reserves for control characters and
        // windows-1252 fills in. Honouring the label literally loses them.
        if latin1Labels.contains(name) { return .windowsCP1252 }

        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    private static let latin1Labels: Set<String> = [
        "iso-8859-1", "iso8859-1", "iso_8859-1", "iso88591", "latin1", "l1",
        "ascii", "us-ascii", "iso-ir-100", "cp819", "ibm819", "csisolatin1",
    ]
}
