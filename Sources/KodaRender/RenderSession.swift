import Foundation
import KodaCore
import WebKit

/// One page load, from navigation to serialised DOM.
///
/// `@MainActor` throughout because every WebKit API is. The web view is created
/// per render and torn down after: WebKit keeps a content process per view, and
/// reusing one across pages leaks the previous page's globals, timers and
/// service workers into the next — which would make a crawl's results depend on
/// the order pages happened to be visited in.
@MainActor
final class RenderSession: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private var errors: [String] = []
    private var finished = false
    /// Whether an HTTP response actually arrived.
    ///
    /// Probed rather than assumed, because WebKit's failure reporting is
    /// narrower than it looks: a refused or blocked port produces
    /// `startProvisional → didCommit → didFinish` with an empty 39-byte
    /// document and no error at all, while only a DNS failure reports
    /// `didFailProvisional`. Neither `didFinish` nor `didCommit` distinguishes
    /// a real page from nothing; the arrival of a response does.
    private var response: HTTPURLResponse?
    private var sawResponse = false
    private var failure: RenderFailure?
    private var continuation: CheckedContinuation<Void, Never>?

    /// Installed before any page script runs, so an error thrown during initial
    /// evaluation is still captured. Console output is forwarded rather than
    /// replaced, so a page that reads its own console still behaves normally.
    private static let errorCapture = """
        (function () {
          const post = (kind, parts) => {
            try {
              window.webkit.messageHandlers.kodaErrors.postMessage(
                kind + ": " + parts.map(String).join(" "));
            } catch (e) {}
          };
          const realError = console.error;
          console.error = function (...args) { post("console.error", args); realError.apply(console, args); };
          window.addEventListener("error", function (e) {
            post("uncaught", [e.message + " (" + (e.filename || "") + ":" + (e.lineno || 0) + ")"]);
          });
          window.addEventListener("unhandledrejection", function (e) {
            post("unhandled promise rejection", [e.reason]);
          });
        })();
        """

    private override init() {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.errorCapture,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.suppressesIncrementalRendering = true
        // A viewport large enough that responsive sites render their desktop
        // layout; a zero-sized view makes some frameworks skip rendering.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                            configuration: configuration)
        super.init()
        controller.add(self, name: "kodaErrors")
        webView.navigationDelegate = self
    }

    static func run(url: String, timeout: TimeInterval, settleMs: Int,
                    scripts: [ExtractionRule] = []) async throws -> RenderedPage {
        let session = RenderSession()
        return try await session.load(url: url, timeout: timeout, settleMs: settleMs,
                                      scripts: scripts)
    }

    private func load(url: String, timeout: TimeInterval, settleMs: Int,
                      scripts: [ExtractionRule]) async throws -> RenderedPage {
        guard let target = URL(string: url) else {
            throw RenderFailure.navigationFailed("not a URL: \(url)")
        }
        let started = Date()

        // The timeout races the navigation rather than wrapping it, because a
        // page that never fires didFinish — a hanging XHR, an endless redirect —
        // is common enough that relying on WebKit's own timeout would leave the
        // crawl stalled.
        let timedOut = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.failure = .timedOut(afterMs: Int(timeout * 1000))
            self.finish()
        }
        defer { timedOut.cancel() }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            continuation = c
            webView.load(URLRequest(url: target, timeoutInterval: timeout))
        }
        if let failure { throw failure }
        guard sawResponse else {
            // WebKit reported no error, but nothing was ever served. Calling
            // this a successful render of an empty page would be worse than
            // failing: the caller would throw away a perfectly good static parse
            // and store nothing in its place.
            throw RenderFailure.navigationFailed("no response from \(url)")
        }

        // Let scripts that run after load — analytics, hydration, lazy content —
        // have their moment before the DOM is read.
        try? await Task.sleep(nanoseconds: UInt64(max(settleMs, 0)) * 1_000_000)

        let html: String
        do {
            let value = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
            html = (value as? String) ?? ""
        } catch {
            throw RenderFailure.scriptFailed(String(describing: error))
        }

        // The caller's snippets run against the finished DOM. Each is wrapped so
        // a snippet that throws yields no value for that rule rather than
        // failing the render — one bad snippet must not cost the page.
        var scriptResults: [String: String] = [:]
        for rule in scripts {
            let wrapped = "(function(){ try { return String(eval(\(Self.jsLiteral(rule.selector)))); }"
                + " catch (e) { return null; } })()"
            if let value = try? await webView.evaluateJavaScript(wrapped),
               let text = value as? String, !text.isEmpty, text != "null", text != "undefined" {
                scriptResults[rule.name] = text
            }
        }

        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "kodaErrors")

        return RenderedPage(html: html, errors: errors,
                            elapsedMs: Int(Date().timeIntervalSince(started) * 1000),
                            status: response?.statusCode,
                            scriptResults: scriptResults)
    }

    /// A snippet is user text going into a JavaScript program, so it is passed
    /// as a JSON string literal rather than spliced in — the same reasoning that
    /// keeps user input out of the SQL.
    nonisolated static func jsLiteral(_ source: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [source])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        continuation?.resume()
        continuation = nil
    }

    // MARK: - Delegates

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        let text = String(describing: message.body)
        Task { @MainActor in
            // Bounded: a page in an error loop can produce thousands, and the
            // point is to know it happened, not to store every repetition.
            if self.errors.count < 50 { self.errors.append(text) }
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy {
        sawResponse = true
        response = navigationResponse.response as? HTTPURLResponse
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failure = .navigationFailed(error.localizedDescription)
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        failure = .navigationFailed(error.localizedDescription)
        finish()
    }
}
