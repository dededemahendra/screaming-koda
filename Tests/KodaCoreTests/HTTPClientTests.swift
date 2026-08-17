import Foundation
import Testing
@testable import KodaCore

/// Serves canned responses so fetcher tests never touch the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, [String: String], Data)] = [:]
    nonisolated(unsafe) static var failWith: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.failWith {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let key = request.url?.absoluteString ?? ""
        let (status, headers, body) = Self.routes[key] ?? (404, [:], Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeClient() -> URLSessionHTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSessionHTTPClient(session: URLSession(configuration: config))
}

// StubURLProtocol above is shared, mutable, process-global state (by design, per
// URLProtocol's own registration model). swift-testing runs `@Test` functions
// concurrently by default, so without forcing this suite to run serially, one
// test's `StubURLProtocol.routes`/`failWith` assignment races with another's
// in-flight request and the outcome becomes nondeterministic. `.serialized`
// makes execution order match declaration order within this suite so the shared
// stub state is never read while a sibling test is mutating it.
@Suite(.serialized)
struct HTTPClientTests {
    @Test func fetchesBodyAndStatus() async {
        StubURLProtocol.failWith = nil
        StubURLProtocol.routes = ["https://example.com/": (200, ["Content-Type": "text/html"], Data("<html></html>".utf8))]
        let outcome = await makeClient().fetch(url: "https://example.com/", method: "GET",
                                               userAgent: "ScreamingKoda/0.1", timeout: 5)
        guard case .response(let r) = outcome else { Issue.record("expected response"); return }
        #expect(r.status == 200)
        #expect(r.contentType == "text/html")
        #expect(r.body.map { String(decoding: $0, as: UTF8.self) } == "<html></html>")
    }

    @Test func doesNotFollowRedirects() async {
        StubURLProtocol.failWith = nil
        StubURLProtocol.routes = [
            "https://example.com/old": (301, ["Location": "https://example.com/new"], Data()),
            "https://example.com/new": (200, ["Content-Type": "text/html"], Data("ok".utf8)),
        ]
        let outcome = await makeClient().fetch(url: "https://example.com/old", method: "GET",
                                               userAgent: "ScreamingKoda/0.1", timeout: 5)
        guard case .response(let r) = outcome else { Issue.record("expected response"); return }
        #expect(r.status == 301)
        #expect(r.isRedirect)
        #expect(r.location == "https://example.com/new")
    }

    @Test func transportFailureBecomesFailureOutcome() async {
        StubURLProtocol.routes = [:]
        StubURLProtocol.failWith = URLError(.cannotFindHost)
        let outcome = await makeClient().fetch(url: "https://nope.invalid/", method: "GET",
                                               userAgent: "ScreamingKoda/0.1", timeout: 5)
        guard case .failure(let kind) = outcome else { Issue.record("expected failure"); return }
        #expect(kind.contains("cannotFindHost"))
        StubURLProtocol.failWith = nil
    }

    @Test func invalidURLFails() async {
        let outcome = await makeClient().fetch(url: "not a url", method: "GET",
                                               userAgent: "ScreamingKoda/0.1", timeout: 5)
        guard case .failure(let kind) = outcome else { Issue.record("expected failure"); return }
        #expect(kind == "invalidURL")
    }

    @Test func headersAreCaseInsensitive() async {
        StubURLProtocol.failWith = nil
        StubURLProtocol.routes = ["https://example.com/h": (200, ["X-Robots-Tag": "noindex"], Data())]
        let outcome = await makeClient().fetch(url: "https://example.com/h", method: "GET",
                                               userAgent: "ScreamingKoda/0.1", timeout: 5)
        guard case .response(let r) = outcome else { Issue.record("expected response"); return }
        #expect(r.header("x-robots-tag") == "noindex")
    }
}
