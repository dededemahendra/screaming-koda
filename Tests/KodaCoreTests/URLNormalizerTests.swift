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
