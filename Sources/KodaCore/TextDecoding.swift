import Foundation

/// Turns response bytes into text.
///
/// Before this existed every body was decoded as UTF-8 unconditionally, so a
/// page served in Windows-1252 — still common on older sites — produced a
/// mangled title, and that mangled title then appeared in the Titles report as
/// a genuine finding. A report inventing problems is worse than one missing
/// them, which is why this is not merely cosmetic.
public enum TextDecoding {

    /// How far into the body to look for a `<meta>` declaration. The HTML spec's
    /// own sniffing algorithm uses 1024 bytes; 2048 is a little slack for pages
    /// that put a long comment or a pile of `<link>` tags first. Scanning the
    /// whole body would mean re-reading megabytes to find something that is,
    /// by definition, meant to be near the top.
    static let sniffWindow = 2048

    /// Decoding always succeeds. The last step is Windows-1252, which has no
    /// invalid byte sequences, so a page that lies about its encoding crawls
    /// with slightly wrong accents rather than vanishing from every report —
    /// the same rule as the rest of the crawler: never die from a bad page.
    public static func decode(_ body: Data, contentType: String?) -> String {
        guard !body.isEmpty else { return "" }

        // The server is authoritative: a stale `<meta charset>` left in a
        // template must not override what was actually sent.
        if let declared = charset(fromContentType: contentType),
           let text = String(data: body, encoding: declared) {
            return text
        }
        if let sniffed = charset(sniffedFrom: body),
           let text = String(data: body, encoding: sniffed) {
            return text
        }
        if let utf8 = String(data: body, encoding: .utf8) {
            return utf8
        }
        // Windows-1252 maps every one of the 256 byte values, so this cannot
        // return nil. The lossy UTF-8 decode after it is unreachable belt and
        // braces rather than a real path.
        return String(data: body, encoding: .windowsCP1252)
            ?? String(decoding: body, as: UTF8.self)
    }

    /// `text/html; charset=windows-1252` → `.windowsCP1252`. Tolerates quoting,
    /// spacing, and case, all of which appear in the wild.
    static func charset(fromContentType contentType: String?) -> String.Encoding? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset"
            else { continue }
            let name = pair[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return encoding(named: name)
        }
        return nil
    }

    /// Reads a `<meta charset>` or `<meta http-equiv="Content-Type">` out of the
    /// head. Deliberately a byte-level scan rather than an HTML parse: the whole
    /// point is to find the encoding *before* there is a string to parse.
    static func charset(sniffedFrom body: Data) -> String.Encoding? {
        // ASCII-decoding the window is safe for this purpose — every encoding
        // this can detect is ASCII-compatible in its declaration, and a byte
        // that is not ASCII simply will not match the patterns below.
        let window = body.prefix(sniffWindow)
        let head = String(decoding: window, as: UTF8.self).lowercased()

        if let range = head.range(of: #"<meta[^>]+charset\s*=\s*["']?([a-z0-9_.:-]+)"#,
                                  options: .regularExpression) {
            let match = String(head[range])
            if let equals = match.range(of: "charset", options: .backwards) {
                let tail = match[equals.upperBound...]
                    .drop { $0 == "=" || $0 == " " || $0 == "\"" || $0 == "'" }
                return encoding(named: String(tail))
            }
        }
        return nil
    }

    /// IANA charset name to `String.Encoding`. Only the encodings a crawler
    /// actually meets — an unknown name returns nil and decoding falls through
    /// rather than failing.
    static func encoding(named name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8", "ascii", "us-ascii":
            return .utf8
        case "utf-16", "utf16":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        // ISO-8859-1 is folded into Windows-1252 on purpose: the HTML standard
        // requires it, because a page labelled latin-1 that uses smart quotes
        // (0x93/0x94, undefined in true ISO-8859-1) is overwhelmingly 1252.
        case "windows-1252", "cp1252", "iso-8859-1", "iso8859-1", "latin1", "latin-1":
            return .windowsCP1252
        case "windows-1251", "cp1251":
            return .windowsCP1251
        case "iso-8859-2", "iso8859-2", "latin2":
            return .isoLatin2
        case "shift_jis", "shift-jis", "sjis":
            return .shiftJIS
        case "euc-jp", "eucjp":
            return .japaneseEUC
        case "iso-2022-jp":
            return .iso2022JP
        default:
            return nil
        }
    }
}
