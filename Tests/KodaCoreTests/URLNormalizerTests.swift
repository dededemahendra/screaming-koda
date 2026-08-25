import Foundation
import Testing
@testable import KodaCore

private func norm(_ s: String, base: String? = nil) -> NormalizedURL? {
    let b = base.flatMap { URLNormalizer.normalize($0, relativeTo: nil) }
    return URLNormalizer.normalize(s, relativeTo: b)
}

@Test func lowercasesSchemeAndHost() {
    #expect(norm("HTTP://Example.COM/Path")?.absoluteString == "http://example.com/Path")
}

@Test func preservesPathCase() {
    #expect(norm("http://example.com/CaseSensitive")?.path == "/CaseSensitive")
}

@Test func stripsFragment() {
    #expect(norm("http://example.com/a#section")?.absoluteString == "http://example.com/a")
}

@Test func removesDefaultPorts() {
    #expect(norm("http://example.com:80/a")?.absoluteString == "http://example.com/a")
    #expect(norm("https://example.com:443/a")?.absoluteString == "https://example.com/a")
}

@Test func keepsNonDefaultPort() {
    #expect(norm("http://example.com:8080/a")?.absoluteString == "http://example.com:8080/a")
}

@Test func preservesTrailingSlashDistinction() {
    #expect(norm("http://example.com/a")?.absoluteString != norm("http://example.com/a/")?.absoluteString)
}

@Test func preservesQueryParameterOrder() {
    #expect(norm("http://example.com/a?b=2&a=1")?.absoluteString == "http://example.com/a?b=2&a=1")
}

@Test func emptyPathBecomesRoot() {
    #expect(norm("http://example.com")?.path == "/")
}

@Test func resolvesRelativeReference() {
    #expect(norm("../c", base: "http://example.com/a/b/page")?.absoluteString == "http://example.com/a/c")
}

@Test func resolvesRootRelativeReference() {
    #expect(norm("/x", base: "http://example.com/a/b")?.absoluteString == "http://example.com/x")
}

@Test func rejectsNonHTTPSchemes() {
    #expect(norm("mailto:a@b.com") == nil)
    #expect(norm("tel:+123") == nil)
    #expect(norm("javascript:void(0)") == nil)
    #expect(norm("ftp://example.com/f") == nil)
}

@Test func rejectsGarbage() {
    #expect(norm("") == nil)
    #expect(norm("   ") == nil)
    #expect(norm("http://") == nil)
}

@Test func hashIsStableAndDistinct() {
    let a = norm("http://example.com/a")!
    let b = norm("HTTP://EXAMPLE.com/a")!
    let c = norm("http://example.com/b")!
    #expect(a.sha256 == b.sha256)
    #expect(a.sha256 != c.sha256)
    #expect(a.sha256.count == 32)
}

// MARK: - Fix round: percent-encoding case, dot-segment collapse, empty query

@Test func canonicalizesPercentEncodingCaseInPath() {
    #expect(norm("http://example.com/%2f")?.sha256 == norm("http://example.com/%2F")?.sha256)
    #expect(norm("http://example.com/%2f")?.absoluteString == "http://example.com/%2F")
}

@Test func canonicalizesPercentEncodingCaseInQuery() {
    #expect(norm("http://example.com/a?x=%2f")?.absoluteString == "http://example.com/a?x=%2F")
}

@Test func collapsesDotSegmentsInAbsoluteURL() {
    #expect(norm("http://example.com/a/../b")?.absoluteString == "http://example.com/b")
}

@Test func collapsesTrailingDotDotToDirectory() {
    #expect(norm("http://example.com/a/b/..")?.absoluteString == "http://example.com/a/")
}

@Test func dotDotCannotEscapeAboveRoot() {
    #expect(norm("http://example.com/../a")?.absoluteString == "http://example.com/a")
}

@Test func emptyQueryIsTreatedAsAbsent() {
    #expect(norm("http://example.com/a?")?.absoluteString == norm("http://example.com/a")?.absoluteString)
}

// MARK: - Seeds

/// A seed is typed by a person, not found in an href, so it gets a scheme it did
/// not ask for. Link resolution deliberately does not: `example.com` inside a
/// page is a relative path, and treating it as a host would invent URLs.

@Test func aBareHostIsAssumedToBeHTTPS() {
    #expect(URLNormalizer.seed("example.com")?.absoluteString == "https://example.com/")
    #expect(URLNormalizer.seed("example.com/blog")?.absoluteString == "https://example.com/blog")
    #expect(URLNormalizer.seed("example.com?q=1")?.absoluteString == "https://example.com/?q=1")
}

@Test func aSeedThatAlreadyHasASchemeKeepsIt() {
    #expect(URLNormalizer.seed("http://example.com")?.absoluteString == "http://example.com/")
    #expect(URLNormalizer.seed("HTTPS://Example.com/A")?.absoluteString == "https://example.com/A")
}

@Test func aProtocolRelativeSeedGetsHTTPS() {
    #expect(URLNormalizer.seed("//example.com/x")?.absoluteString == "https://example.com/x")
}

@Test func aSeedIsTrimmedBeforeAnythingElse() {
    #expect(URLNormalizer.seed("  example.com  ")?.absoluteString == "https://example.com/")
    #expect(URLNormalizer.seed("   ") == nil)
    #expect(URLNormalizer.seed("") == nil)
}

/// A port after the colon is a port. A word after it is a scheme, and every
/// scheme that is not http(s) is refused rather than quietly rewritten — a
/// `mailto:` seed prefixed with https:// parses as userinfo and would crawl a
/// host nobody named.
@Test func aHostWithAPortIsNotMistakenForAScheme() {
    #expect(URLNormalizer.seed("localhost:8080/x")?.absoluteString == "http://localhost:8080/x")
    #expect(URLNormalizer.seed("127.0.0.1:8931")?.absoluteString == "http://127.0.0.1:8931/")
    #expect(URLNormalizer.seed("example.com:8443")?.absoluteString == "https://example.com:8443/")
}

@Test func aSeedInAnotherSchemeIsRefusedRatherThanRewritten() {
    #expect(URLNormalizer.seed("mailto:someone@example.com") == nil)
    #expect(URLNormalizer.seed("ftp://example.com") == nil)
    #expect(URLNormalizer.seed("javascript:void(0)") == nil)
    #expect(URLNormalizer.seed("file:///Users/x/site") == nil)
}

/// Nothing serves https on a bare loopback address, and this is a tool people
/// point at their own dev server.
@Test func loopbackWithoutASchemeIsHTTP() {
    #expect(URLNormalizer.seed("localhost")?.absoluteString == "http://localhost/")
    #expect(URLNormalizer.seed("127.0.0.1/a")?.absoluteString == "http://127.0.0.1/a")
    #expect(URLNormalizer.seed("[::1]:8080")?.absoluteString == "http://[::1]:8080/")
    #expect(URLNormalizer.seed("https://localhost")?.absoluteString == "https://localhost/",
            "an explicit scheme is still obeyed")
}
