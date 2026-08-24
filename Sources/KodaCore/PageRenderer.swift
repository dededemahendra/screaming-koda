import Foundation

/// Timings a renderer could actually observe.
///
/// Every field is optional because a page may not produce it, and every field
/// that WebKit cannot report is simply absent rather than defaulted. In
/// particular there is no CLS and no INP: WebKit's `supportedEntryTypes` has no
/// `layout-shift`, and INP needs a real interaction that a crawler never makes.
/// Reporting either as zero would be inventing a passing grade.
public struct PageMetrics: Codable, Sendable, Equatable {
    /// Time to first byte.
    public let ttfb: Double?
    /// First contentful paint.
    public let fcp: Double?
    /// Largest contentful paint, when the engine produced an entry.
    public let lcp: Double?
    /// DOMContentLoaded, then the load event.
    public let dcl: Double?
    public let load: Double?
    /// How many subresources the page pulled in.
    public let resources: Int?

    public init(ttfb: Double?, fcp: Double?, lcp: Double?, dcl: Double?,
                load: Double?, resources: Int?) {
        self.ttfb = ttfb
        self.fcp = fcp
        self.lcp = lcp
        self.dcl = dcl
        self.load = load
        self.resources = resources
    }
}

/// What a renderer gives back for one page.
public struct RenderedPage: Sendable, Equatable {
    /// The DOM after scripts have run, serialised back to HTML.
    public let html: String
    /// Console errors and uncaught exceptions the page produced.
    public let errors: [String]
    /// Results of the caller's JavaScript snippets, by name.
    public let scriptResults: [String: String]
    /// Timings, when the page produced any.
    public let metrics: PageMetrics?
    /// How long rendering took, which is the number that decides whether
    /// rendering a whole site is affordable.
    public let elapsedMs: Int
    /// The status of the rendered navigation, when one was reported. Kept so a
    /// caller can notice the renderer and the fetcher disagreeing — which
    /// happens on sites that serve different content to a real browser.
    public let status: Int?

    public init(html: String, errors: [String], elapsedMs: Int, status: Int? = nil,
                scriptResults: [String: String] = [:],
                metrics: PageMetrics? = nil) {
        self.html = html
        self.errors = errors
        self.scriptResults = scriptResults
        self.metrics = metrics
        self.elapsedMs = elapsedMs
        self.status = status
    }
}

public enum RenderFailure: Error, Sendable, Equatable {
    case timedOut(afterMs: Int)
    case navigationFailed(String)
    case scriptFailed(String)
}

/// Turns a URL into a rendered DOM.
///
/// A protocol in `KodaCore` with no implementation here on purpose: rendering
/// needs WebKit, which needs a UI framework and a main-thread run loop, and
/// `KodaCore`'s defining property is that it builds and tests headless. The
/// implementation lives in `KodaRender` and is injected.
/// What a login attempt produced.
public struct LoginResult: Sendable, Equatable {
    /// A `Cookie` header value carrying the session, for the crawler's own
    /// requests. The renderer keeps its cookies itself; the fetcher cannot.
    public let cookieHeader: String
    /// Where the browser ended up. A login that stayed on the login page is the
    /// usual sign it failed, and the caller can say so.
    public let finalURL: String
    public let cookieNames: [String]

    public init(cookieHeader: String, finalURL: String, cookieNames: [String]) {
        self.cookieHeader = cookieHeader
        self.finalURL = finalURL
        self.cookieNames = cookieNames
    }
}

public protocol PageRenderer: Sendable {
    func render(url: String, timeout: TimeInterval, settleMs: Int) async throws -> RenderedPage

    /// Render, then evaluate named snippets against the finished DOM.
    /// Default-implemented by ignoring them, so a renderer that cannot run
    /// scripts still satisfies the protocol.
    func render(url: String, timeout: TimeInterval, settleMs: Int,
                scripts: [ExtractionRule]) async throws -> RenderedPage

    /// Drives a login form and hands back the resulting session.
    func logIn(_ login: FormLogin, timeout: TimeInterval) async throws -> LoginResult
}

extension PageRenderer {
    public func render(url: String, timeout: TimeInterval, settleMs: Int,
                       scripts: [ExtractionRule]) async throws -> RenderedPage {
        try await render(url: url, timeout: timeout, settleMs: settleMs)
    }

    /// A renderer that cannot drive a form says so rather than pretending the
    /// login worked and letting the crawl fail one page at a time.
    public func logIn(_ login: FormLogin, timeout: TimeInterval) async throws -> LoginResult {
        throw RenderFailure.scriptFailed("this renderer cannot perform a form login")
    }
}
