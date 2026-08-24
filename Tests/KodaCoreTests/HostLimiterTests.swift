import Foundation
import Testing
@testable import KodaCore

private actor Peak {
    private var current: [String: Int] = [:]
    private(set) var highest: [String: Int] = [:]

    func enter(_ host: String) {
        let now = (current[host] ?? 0) + 1
        current[host] = now
        highest[host] = max(highest[host] ?? 0, now)
    }

    func leave(_ host: String) { current[host] = (current[host] ?? 1) - 1 }
}

private func runConcurrently(hosts: [String], limit: Int) async -> [String: Int] {
    let limiter = HostLimiter(limit: limit)
    let peak = Peak()
    await withTaskGroup(of: Void.self) { group in
        for host in hosts {
            group.addTask {
                await limiter.acquire(host: host)
                await peak.enter(host)
                try? await Task.sleep(nanoseconds: 2_000_000)
                await peak.leave(host)
                await limiter.release(host: host)
            }
        }
    }
    return await peak.highest
}

@Test func neverExceedsTheLimitForOneHost() async {
    let peaks = await runConcurrently(hosts: Array(repeating: "a.test", count: 20), limit: 3)
    #expect(peaks["a.test"]! <= 3)
    #expect(peaks["a.test"]! > 1, "the limit is a cap, not a serialiser")
}

@Test func hostsDoNotBlockEachOther() async {
    // Ten hosts at a limit of one each should still all run at once.
    let hosts = (0..<10).map { "h\($0).test" }
    let peaks = await runConcurrently(hosts: hosts, limit: 1)
    #expect(peaks.count == 10)
    #expect(peaks.values.allSatisfy { $0 == 1 })
}

@Test func everyWaiterIsEventuallyResumed() async {
    // If release dropped a waiter this would hang rather than fail, so the test
    // asserting completion at all is the point.
    let peaks = await runConcurrently(hosts: Array(repeating: "b.test", count: 50), limit: 2)
    #expect(peaks["b.test"]! <= 2)
}

@Test func slotsAreReleasedBackToZero() async {
    let limiter = HostLimiter(limit: 2)
    await limiter.acquire(host: "c.test")
    await limiter.acquire(host: "c.test")
    #expect(await limiter.activeCount(host: "c.test") == 2)
    await limiter.release(host: "c.test")
    await limiter.release(host: "c.test")
    #expect(await limiter.activeCount(host: "c.test") == 0)
}

@Test func aZeroLimitIsTreatedAsOne() async {
    let peaks = await runConcurrently(hosts: Array(repeating: "d.test", count: 5), limit: 0)
    #expect(peaks["d.test"] == 1)
}
