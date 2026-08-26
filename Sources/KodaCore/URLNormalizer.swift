import CryptoKit
import Foundation

public struct NormalizedURL: Hashable, Sendable {
    public let absoluteString: String
    public let host: String
    public let path: String
    /// Path plus query. robots.txt rules are matched against both, not the path
    /// alone: `Disallow: /*?sort=` and `Disallow: /search?` are ordinary rules,
    /// and a matcher given only `path` would silently ignore every one of them.
    public let pathWithQuery: String
    public let sha256: Data

    init(absoluteString: String, host: String, path: String, query: String? = nil) {
        self.absoluteString = absoluteString
        self.host = host
        self.path = path
        self.pathWithQuery = query.map { "\(path)?\($0)" } ?? path
        self.sha256 = Data(SHA256.hash(data: Data(absoluteString.utf8)))
    }
}

public enum URLNormalizer {
    /// Returns nil for anything that is not a crawlable http(s) URL.
    public static func normalize(_ raw: String, relativeTo base: NormalizedURL?) -> NormalizedURL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolved: URL?
        if let base, let baseURL = URL(string: base.absoluteString) {
            resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        } else {
            resolved = URL(string: trimmed)
        }
        guard let url = resolved,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return nil }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let rawHost = components.host?.lowercased(), !rawHost.isEmpty else { return nil }

        components.scheme = scheme
        components.host = rawHost
        components.fragment = nil
        components.user = nil
        components.password = nil

        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }

        // RFC 3986 §5.2.4: collapse dot segments on every path, not just relative
        // resolution — an already-absolute URL like "http://x/a/../b" bypasses
        // Foundation's relative-resolution normalization entirely.
        var encodedPath = components.percentEncodedPath
        if encodedPath.isEmpty {
            encodedPath = "/"
        }
        encodedPath = removeDotSegments(encodedPath)
        // RFC 3986 §6.2.2.1: percent-encoded octets are case-insensitive; canonicalize
        // to uppercase hex digits so "%2f" and "%2F" hash identically. This only
        // touches the two hex digits after each "%" — never decodes or re-encodes.
        components.percentEncodedPath = uppercasedPercentEscapes(in: encodedPath)

        // Preserve an empty-but-present query ("?") as absent; keep parameter order otherwise.
        if let encodedQuery = components.percentEncodedQuery {
            components.percentEncodedQuery = encodedQuery.isEmpty ? nil : uppercasedPercentEscapes(in: encodedQuery)
        }

        guard let finalURL = components.url else { return nil }
        return NormalizedURL(
            absoluteString: finalURL.absoluteString,
            host: rawHost,
            path: components.path,
            query: components.query
        )
    }
}

/// RFC 3986 §5.2.4 remove_dot_segments, applied to a percent-encoded path.
/// Operates purely on literal "." / ".." segments delimited by "/" — percent-escaped
/// dots (e.g. "%2E") are left alone, matching the RFC's scope.
private func removeDotSegments(_ path: String) -> String {
    var input = Substring(path)
    var output = ""

    func dropLastOutputSegment() {
        if let slash = output.range(of: "/", options: .backwards) {
            output.removeSubrange(slash.lowerBound...)
        } else {
            output = ""
        }
    }

    while !input.isEmpty {
        if input.hasPrefix("../") {
            input = input.dropFirst(3)
        } else if input.hasPrefix("./") {
            input = input.dropFirst(2)
        } else if input.hasPrefix("/./") {
            input = "/" + input.dropFirst(3)
        } else if input == "/." {
            input = "/"
        } else if input.hasPrefix("/../") {
            input = "/" + input.dropFirst(4)
            dropLastOutputSegment()
        } else if input == "/.." {
            input = "/"
            dropLastOutputSegment()
        } else if input == "." || input == ".." {
            input = ""
        } else {
            let searchStart = input.hasPrefix("/") ? input.index(after: input.startIndex) : input.startIndex
            if let nextSlash = input[searchStart...].firstIndex(of: "/") {
                output += input[input.startIndex..<nextSlash]
                input = input[nextSlash...]
            } else {
                output += input
                input = ""
            }
        }
    }
    return output
}

/// Uppercases the two hex digits of every percent-escape triplet in `string`.
/// Leaves everything else — including malformed "%" sequences — untouched, and
/// never decodes or re-encodes any character.
private func uppercasedPercentEscapes(in string: String) -> String {
    let chars = Array(string)
    var result = ""
    result.reserveCapacity(chars.count)
    var i = 0
    while i < chars.count {
        if chars[i] == "%", i + 2 < chars.count, chars[i + 1].isHexDigit, chars[i + 2].isHexDigit {
            result.append("%")
            result.append(Character(chars[i + 1].uppercased()))
            result.append(Character(chars[i + 2].uppercased()))
            i += 3
        } else {
            result.append(chars[i])
            i += 1
        }
    }
    return result
}
