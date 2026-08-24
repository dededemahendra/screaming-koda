import Foundation
import Testing
@testable import KodaCore
@testable import KodaRender

/// A login page shaped like a real one: the value is tracked by a listener
/// rather than read off the element at submit time, which is how React and
/// friends behave and why setting `.value` alone is not enough.
private let loginPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Sign in</title></head>
    <body>
      <form id="f">
        <input type="email" name="email" id="email">
        <input type="password" name="password" id="password">
        <button type="submit">Sign in</button>
      </form>
      <script>
        var tracked = { email: '', password: '' };
        document.getElementById('email').addEventListener('input', function (e) {
          tracked.email = e.target.value;
        });
        document.getElementById('password').addEventListener('input', function (e) {
          tracked.password = e.target.value;
        });
        document.getElementById('f').addEventListener('submit', function (e) {
          e.preventDefault();
          if (tracked.email === 'me@x.test' && tracked.password === 'hunter2') {
            document.cookie = 'session=granted; path=/';
            document.cookie = 'role=admin; path=/';
            location.href = '/dashboard.html';
          } else {
            document.title = 'Sign in failed';
          }
        });
      </script>
    </body></html>
    """

private let dashboard = """
    <!doctype html><html><head><meta charset="utf-8"><title>Dashboard</title></head>
    <body><h1>Signed in</h1></body></html>
    """

@Test func aFormLoginFillsSubmitsAndReturnsTheSession() async throws {
    let server = try TinyServer(pages: ["login.html": loginPage, "dashboard.html": dashboard])
    defer { server.stop() }
    try await server.waitUntilReady()

    let login = FormLogin(url: server.url("/login.html").absoluteString,
                          username: "me@x.test", password: "hunter2")
    let result = try await WebKitRenderer(poolSize: 1).logIn(login, timeout: 20)

    #expect(result.cookieNames.contains("session"))
    #expect(result.cookieHeader.contains("session=granted"))
    #expect(result.finalURL.hasSuffix("/dashboard.html"),
            "landing back on the login page is how a failed login looks")
}

/// The reason the fill dispatches real input events: a framework that tracks
/// its inputs through change events never sees a value assigned directly, and
/// the form submits empty — which is indistinguishable from wrong credentials.
@Test func theFillDispatchesEventsSoFrameworksSeeTheValue() async throws {
    let server = try TinyServer(pages: ["login.html": loginPage, "dashboard.html": dashboard])
    defer { server.stop() }
    try await server.waitUntilReady()

    // This page only accepts the credentials it saw through input events.
    let login = FormLogin(url: server.url("/login.html").absoluteString,
                          username: "me@x.test", password: "hunter2")
    let result = try await WebKitRenderer(poolSize: 1).logIn(login, timeout: 20)
    #expect(!result.cookieHeader.isEmpty, "the tracked values matched, so a session was issued")
}

@Test func wrongCredentialsDoNotProduceASession() async throws {
    let server = try TinyServer(pages: ["login.html": loginPage, "dashboard.html": dashboard])
    defer { server.stop() }
    try await server.waitUntilReady()

    let login = FormLogin(url: server.url("/login.html").absoluteString,
                          username: "me@x.test", password: "wrong")
    let result = try await WebKitRenderer(poolSize: 1).logIn(login, timeout: 20)
    #expect(!result.finalURL.hasSuffix("/dashboard.html"))
    #expect(!result.cookieNames.contains("session"))
}

/// A selector that finds nothing is reported rather than silently submitting an
/// empty form, which would look like a rejected password.
@Test func aFormWhoseFieldsCannotBeFoundIsReported() async throws {
    let server = try TinyServer(pages: ["login.html": loginPage])
    defer { server.stop() }
    try await server.waitUntilReady()

    let login = FormLogin(url: server.url("/login.html").absoluteString,
                          username: "u", password: "p",
                          usernameSelector: "#nothing-like-this")
    await #expect(throws: RenderFailure.self) {
        _ = try await WebKitRenderer(poolSize: 1).logIn(login, timeout: 20)
    }
}

/// A renderer that cannot drive a form says so rather than pretending the login
/// worked and letting the crawl fail one page at a time.
@Test func aRendererWithoutFormSupportRefusesClearly() async {
    struct Basic: PageRenderer {
        func render(url: String, timeout: TimeInterval, settleMs: Int) async throws -> RenderedPage {
            RenderedPage(html: "", errors: [], elapsedMs: 0)
        }
    }
    await #expect(throws: RenderFailure.self) {
        _ = try await Basic().logIn(
            FormLogin(url: "https://x.test/login", username: "u", password: "p"), timeout: 5)
    }
}

/// Cookies belong to one crawl, not to the machine.
///
/// WKWebView defaults to a shared persistent store, so before this was fixed a
/// login during one crawl was still present when crawling a different site
/// later — and this very test suite proved it, by finding a session cookie in
/// the wrong-password case that an earlier test had established.
@Test func twoRenderersDoNotShareASession() async throws {
    let server = try TinyServer(pages: ["login.html": loginPage, "dashboard.html": dashboard])
    defer { server.stop() }
    try await server.waitUntilReady()

    let login = FormLogin(url: server.url("/login.html").absoluteString,
                          username: "me@x.test", password: "hunter2")
    let first = try await WebKitRenderer(poolSize: 1).logIn(login, timeout: 20)
    #expect(first.cookieNames.contains("session"))

    // A different renderer starts with nothing, however recently the other one
    // signed in.
    var wrong = login
    wrong.password = "wrong"
    let second = try await WebKitRenderer(poolSize: 1).logIn(wrong, timeout: 20)
    #expect(!second.cookieNames.contains("session"))
}

/// And within one renderer the session does carry, which is the point.
@Test func oneRendererKeepsItsSessionAcrossPages() async throws {
    let server = try TinyServer(pages: ["login.html": loginPage, "dashboard.html": dashboard])
    defer { server.stop() }
    try await server.waitUntilReady()

    let renderer = WebKitRenderer(poolSize: 1)
    let login = FormLogin(url: server.url("/login.html").absoluteString,
                          username: "me@x.test", password: "hunter2")
    _ = try await renderer.logIn(login, timeout: 20)

    let page = try await renderer.render(url: server.url("/dashboard.html").absoluteString,
                                         timeout: 20, settleMs: 200,
                                         scripts: [ExtractionRule(name: "cookie",
                                                                  selector: "document.cookie")])
    #expect(page.scriptResults["cookie"]?.contains("session=granted") == true)
}
