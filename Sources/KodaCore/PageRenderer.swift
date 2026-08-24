import Foundation

/// What a renderer gives back for one page.
public struct RenderedPage: Sendable, Equatable {
    /// The DOM after scripts have run, serialised back to HTML.
    public let html: String
    /// Console errors and uncaught exceptions the page produced.
    public let errors: [String]
    /// How long rendering took, which is the number that decides whether
    /// rendering a whole site is affordable.
    public let elapsedMs: Int
    /// The status of the rendered navigation, when one was reported. Kept so a
    /// caller can notice the renderer and the fetcher disagreeing — which
    /// happens on sites that serve different content to a real browser.
    public let status: Int?

    public init(html: String, errors: [String], elapsedMs: Int, status: Int? = nil) {
        self.html = html
        self.errors = errors
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
public protocol PageRenderer: Sendable {
    func render(url: String, timeout: TimeInterval, settleMs: Int) async throws -> RenderedPage
}
