import Foundation
import KodaCore
import WebKit

/// Renders pages with WKWebView.
///
/// Every WebKit interaction is `@MainActor`, so rendering is inherently
/// serialised against the crawler's concurrent worker pool. That is not a bug to
/// engineer around — it is what rendering costs. A rendered crawl is orders of
/// magnitude slower than a fetch-and-parse one, and pretending otherwise by
/// spinning up many web views would trade a clear bottleneck for memory
/// exhaustion on a large site.
public actor WebKitRenderer: PageRenderer {
    private let poolSize: Int

    /// - Parameter poolSize: how many pages may render at once. Each one is a
    ///   full web view with its own process, so this is memory, not just
    ///   parallelism. Two is a deliberate default.
    public init(poolSize: Int = 2) {
        self.poolSize = max(1, poolSize)
    }

    /// Bounds concurrency without a semaphore type: each render waits for a slot
    /// by suspending on a continuation held here in the actor.
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if active < poolSize { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
        active += 1
    }

    private func release() {
        active -= 1
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }

    public func render(url: String, timeout: TimeInterval = 20,
                       settleMs: Int = 400) async throws -> RenderedPage {
        try await render(url: url, timeout: timeout, settleMs: settleMs, scripts: [])
    }

    public func render(url: String, timeout: TimeInterval, settleMs: Int,
                       scripts: [ExtractionRule]) async throws -> RenderedPage {
        await acquire()
        defer { release() }
        return try await RenderSession.run(url: url, timeout: timeout, settleMs: settleMs,
                                           scripts: scripts)
    }
}
