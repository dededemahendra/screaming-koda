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
    let webView: WKWebView
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
    /// evaluation is still captured, and so the performance observers below are
    /// registered before the metrics they watch for occur. Console output is
    /// forwarded rather than replaced, so a page that reads its own console
    /// still behaves normally.
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

          // Performance metrics. Registered here, at document start, because an
          // observer added after load misses the events it is watching for even
          // with buffered:true in some engines.
          //
          // Only what WebKit can actually report: its supportedEntryTypes has no
          // "layout-shift", so CLS is not measurable here at all, and INP needs a
          // real interaction that a crawler never makes. Reporting either as zero
          // would be inventing a passing grade.
          window.__kodaPerf = { ttfb: null, fcp: null, lcp: null, dcl: null, load: null, resources: 0 };
          try {
            new PerformanceObserver(function (l) {
              var e = l.getEntries();
              if (e.length) { window.__kodaPerf.lcp = e[e.length - 1].startTime; }
            }).observe({ type: "largest-contentful-paint", buffered: true });
          } catch (e) {}
          try {
            new PerformanceObserver(function (l) {
              l.getEntries().forEach(function (x) {
                if (x.name === "first-contentful-paint") { window.__kodaPerf.fcp = x.startTime; }
              });
            }).observe({ type: "paint", buffered: true });
          } catch (e) {}
          // Deferred by a tick: inside the load handler `loadEventEnd` has not
          // been written yet, so reading it there always yields 0.
          window.addEventListener("load", function () {
            setTimeout(function () {
            try {
              var n = performance.getEntriesByType("navigation")[0];
              if (n) {
                window.__kodaPerf.ttfb = n.responseStart;
                window.__kodaPerf.dcl = n.domContentLoadedEventEnd;
                window.__kodaPerf.load = n.loadEventEnd;
              }
              window.__kodaPerf.resources = performance.getEntriesByType("resource").length;
            } catch (e) {}
            }, 0);
          });
        })();
        """

    /// A phone-sized viewport, matching what `CrawlConfig.mobile` asks for.
    /// Responsive sites choose their layout from the viewport, so crawling as a
    /// phone means resizing the view as well as changing the user agent.
    static let mobileViewport = CGSize(width: 390, height: 844)
    static let desktopViewport = CGSize(width: 1440, height: 900)

    private init(viewport: CGSize = RenderSession.desktopViewport, userAgent: String? = nil,
                 dataStore: WKWebsiteDataStore? = nil) {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.errorCapture,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.suppressesIncrementalRendering = true
        // Cookies belong to one crawl, not to the machine.
        //
        // WKWebView defaults to the shared persistent store, which means a login
        // during one crawl would still be present when crawling a different site
        // later, and across app launches. A renderer owns a non-persistent store
        // and hands it to every page it renders, so a session lasts exactly as
        // long as the crawl that established it.
        if let dataStore { configuration.websiteDataStore = dataStore }
        // A real viewport: a zero-sized view makes some frameworks skip
        // rendering entirely.
        webView = WKWebView(frame: CGRect(origin: .zero, size: viewport),
                            configuration: configuration)
        super.init()
        if let userAgent { webView.customUserAgent = userAgent }
        controller.add(self, name: "kodaErrors")
        webView.navigationDelegate = self
    }

    static func run(url: String, timeout: TimeInterval, settleMs: Int,
                    scripts: [ExtractionRule] = [], mobile: Bool = false,
                    userAgent: String? = nil,
                    dataStore: WKWebsiteDataStore? = nil) async throws -> RenderedPage {
        let session = RenderSession(viewport: mobile ? mobileViewport : desktopViewport,
                                    userAgent: userAgent, dataStore: dataStore)
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
        // Read before the caller's own snippets, so a snippet that navigates or
        // rewrites the page cannot destroy the measurements.
        var metrics: PageMetrics?
        if let raw = try? await webView.evaluateJavaScript("JSON.stringify(window.__kodaPerf || null)"),
           let json = raw as? String, let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PageMetrics.self, from: data) {
            metrics = decoded
        }

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
                            scriptResults: scriptResults,
                            metrics: metrics)
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

// MARK: - Form login

@MainActor
extension RenderSession {
    /// Loads the login page, fills the form, submits it, and reads back the
    /// session cookies.
    ///
    /// The fields are found and filled with real DOM events dispatched after
    /// each assignment. Setting `.value` alone is not enough on a modern login
    /// page: React and friends track input through change events, and a form
    /// whose framework never saw the value submits empty — which looks exactly
    /// like wrong credentials.
    static func logIn(_ login: FormLogin, timeout: TimeInterval,
                      dataStore: WKWebsiteDataStore? = nil) async throws -> LoginResult {
        let session = RenderSession(dataStore: dataStore)
        _ = try await session.load(url: login.url, timeout: timeout,
                                   settleMs: 300, scripts: [])

        let fill = """
            (function () {
              function set(selector, value) {
                var el = document.querySelector(selector);
                if (!el) { return false; }
                var setter = Object.getOwnPropertyDescriptor(
                  window.HTMLInputElement.prototype, 'value').set;
                setter.call(el, value);
                el.dispatchEvent(new Event('input', { bubbles: true }));
                el.dispatchEvent(new Event('change', { bubbles: true }));
                return true;
              }
              var okUser = set(\(jsLiteral(login.usernameSelector)), \(jsLiteral(login.username)));
              var okPass = set(\(jsLiteral(login.passwordSelector)), \(jsLiteral(login.password)));
              if (!okUser || !okPass) { return 'fields-not-found'; }
              var button = document.querySelector(\(jsLiteral(login.submitSelector)));
              if (button) { button.click(); return 'submitted'; }
              var form = document.querySelector('form');
              if (form) { form.submit(); return 'submitted-form'; }
              return 'no-submit';
            })();
            """
        let outcome = (try? await session.webView.evaluateJavaScript(fill)) as? String ?? "failed"
        guard outcome.hasPrefix("submitted") else {
            throw RenderFailure.scriptFailed("could not complete the login form: \(outcome)")
        }

        try? await Task.sleep(nanoseconds: UInt64(max(login.settleMs, 0)) * 1_000_000)

        let cookies = await session.webView.configuration.websiteDataStore
            .httpCookieStore.allCookies()
        let host = URL(string: login.url)?.host ?? ""
        // Only cookies for the site being crawled: sending a third-party
        // analytics cookie along with every request would be both useless and
        // a small privacy leak.
        let relevant = cookies.filter { host.hasSuffix($0.domain.hasPrefix(".")
            ? String($0.domain.dropFirst()) : $0.domain) }
        let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let final = (try? await session.webView.evaluateJavaScript("location.href")) as? String

        return LoginResult(cookieHeader: header,
                           finalURL: final ?? login.url,
                           cookieNames: relevant.map(\.name).sorted())
    }
}
