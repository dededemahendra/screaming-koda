import Foundation

/// Caps how many requests may be in flight against any one host.
///
/// While a crawl only fetches the seed host, the global worker count is already
/// the per-host count and this is redundant. Status-checking external links
/// changes that: one batch can span dozens of hosts, and without a per-host cap
/// a site that links to the same small host fifty times would hit it with the
/// full worker pool at once.
actor HostLimiter {
    private let limit: Int
    private var active: [String: Int] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire(host: String) async {
        let current = active[host] ?? 0
        if current < limit {
            active[host] = current + 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting[host, default: []].append(continuation)
        }
    }

    func release(host: String) {
        // Hand the slot straight to the next waiter rather than decrementing and
        // letting it re-acquire: the count stays correct and no wake-up is lost.
        if var queue = waiting[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[host] = queue.isEmpty ? nil : queue
            next.resume()
            return
        }
        let remaining = (active[host] ?? 1) - 1
        if remaining <= 0 {
            active[host] = nil
        } else {
            active[host] = remaining
        }
    }

    /// Test hook: how many slots are currently held for a host.
    func activeCount(host: String) -> Int { active[host] ?? 0 }
}
