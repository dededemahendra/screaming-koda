import Foundation
import Testing
@testable import KodaCore
@testable import KodaUI

/// A scratch suite per test, so nothing here can read or write the real
/// preference domain.
private func scratch() -> (CrawlSettings, UserDefaults, String) {
    let name = "koda.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (CrawlSettings(defaults: defaults), defaults, name)
}

@Test func defaultsAreReturnedWhenNothingIsStored() {
    let (settings, _, name) = scratch()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    #expect(settings.config.workers == 5)
    #expect(settings.config.respectRobots)
}

@Test func settingsRoundTripThroughUserDefaults() {
    let (settings, defaults, name) = scratch()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }

    var config = CrawlConfig(seedURL: "https://ignored.test/")
    config.workers = 9
    config.maxPerHost = 3
    config.checkImages = false
    config.maxDepth = 4
    config.exclude = ["/tag/"]
    settings.config = config

    let reloaded = CrawlSettings(defaults: defaults).config
    #expect(reloaded.workers == 9)
    #expect(reloaded.maxPerHost == 3)
    #expect(reloaded.checkImages == false)
    #expect(reloaded.maxDepth == 4)
    #expect(reloaded.exclude == ["/tag/"])
}

/// The seed changes every crawl; persisting it would reopen the app pointed at
/// whatever site was crawled last.
@Test func theSeedURLIsNotPersisted() {
    let (settings, defaults, name) = scratch()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    var config = CrawlConfig(seedURL: "https://example.test/")
    config.workers = 7
    settings.config = config
    #expect(CrawlSettings(defaults: defaults).config.seedURL.isEmpty)
}

/// A truncated write or a config from an older schema must not leave the app
/// unable to start a crawl.
@Test func corruptStoredJSONFallsBackToDefaults() {
    let (settings, defaults, name) = scratch()
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }
    defaults.set(Data("{ not json".utf8), forKey: CrawlSettings.key)
    #expect(settings.config.workers == 5)
}

@Test func outOfRangeValuesAreClampedNotAccepted() {
    var config = CrawlConfig(seedURL: "")
    config.workers = 9_000
    config.timeout = 0
    config.maxRedirects = -3
    config.urlCap = 0
    let clamped = CrawlSettings.clamped(config)
    #expect(clamped.workers == 50)
    #expect(clamped.timeout == 1)
    #expect(clamped.maxRedirects == 0)
    #expect(clamped.urlCap == 1)
}

/// maxPerHost above workers is the same as no cap at all, because a batch is
/// only `workers` long — allowing it would make the politeness setting a lie.
@Test func maxPerHostIsClampedToWorkers() {
    var config = CrawlConfig(seedURL: "")
    config.workers = 3
    config.maxPerHost = 10
    #expect(CrawlSettings.clamped(config).maxPerHost == 3)
}

@Test func anEmptyUserAgentIsReplacedRatherThanSentBlank() {
    var config = CrawlConfig(seedURL: "")
    config.userAgent = "   "
    #expect(!CrawlSettings.clamped(config).userAgent.trimmingCharacters(in: .whitespaces).isEmpty)
}

/// The important validation. `Store.passesFilters` cannot tell an invalid
/// pattern from one that did not match, so an invalid include pattern would
/// silently crawl one page and stop, looking like a broken tool.
@Test func anInvalidRegexIsRejectedWithTheOffendingPattern() {
    var config = CrawlConfig(seedURL: "")
    config.include = ["[unclosed"]
    let problems = CrawlSettings.problems(in: config)
    #expect(problems.count == 1)
    #expect(problems[0].contains("[unclosed"))
    #expect(problems[0].contains("Include"))
}

@Test func anEmptyPatternIsReportedRatherThanIgnored() {
    var config = CrawlConfig(seedURL: "")
    config.exclude = ["  "]
    #expect(CrawlSettings.problems(in: config).count == 1)
}

@Test func validPatternsProduceNoProblems() {
    var config = CrawlConfig(seedURL: "")
    config.include = ["^https://x\\.test/blog/"]
    config.exclude = ["\\?replytocom=", "/tag/"]
    #expect(CrawlSettings.problems(in: config).isEmpty)
}

// MARK: - The controller honours the configuration

private struct CountingClient: HTTPClient {
    func fetch(url: String, method: String, userAgent: String, timeout: TimeInterval) async -> FetchOutcome {
        if url.hasSuffix("/robots.txt") {
            return .response(HTTPResponse(status: 404, headers: [:], body: Data(), elapsedMs: 1))
        }
        let body = "<html><head><title>T</title></head><body><a href=\"/deep\">d</a></body></html>"
        return .response(HTTPResponse(status: 200, headers: ["Content-Type": "text/html"],
                                      body: Data(body.utf8), elapsedMs: 1))
    }
}

@MainActor
@Test func aBadRegexRefusesTheCrawlBeforeItStarts() async {
    let c = CrawlController(client: CountingClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.config.include = ["[unclosed"]
    c.seedURL = "https://cfg.test/"
    await c.start()

    #expect(c.state == .idle, "the crawl must not have started")
    #expect(c.rows == nil)
    #expect(c.notice?.contains("[unclosed") == true, "the notice names the offending pattern")
}

/// The configuration must actually reach the crawl, not merely be stored.
@MainActor
@Test func theConfiguredMaxDepthLimitsTheCrawl() async throws {
    let c = CrawlController(client: CountingClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.config.maxDepth = 0
    c.seedURL = "https://cfg.test/"
    await c.start()

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, c.state != .finished { try? await Task.sleep(nanoseconds: 20_000_000) }
    #expect(c.state == .finished)
    // The seed is crawled; /deep is discovered but never queued.
    let store = try #require(c.store)
    #expect(try store.summary().byStatusClass["2xx"] == 1, "maxDepth 0 means the seed only")
}

@MainActor
@Test func aBareControllerDoesNotTouchStoredPreferences() {
    let c = CrawlController(client: CountingClient(), parser: SwiftSoupParser(), dbPath: nil)
    c.config.workers = 42
    // Nothing was injected, so nothing is persisted and a fresh controller is clean.
    let fresh = CrawlController(client: CountingClient(), parser: SwiftSoupParser(), dbPath: nil)
    #expect(fresh.config.workers == 5)
}

@MainActor
@Test func aControllerGivenSettingsPersistsChanges() {
    let name = "koda.test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { UserDefaults.standard.removePersistentDomain(forName: name) }

    let settings = CrawlSettings(defaults: defaults)
    let c = CrawlController(client: CountingClient(), parser: SwiftSoupParser(),
                            dbPath: nil, settings: settings)
    c.config.checkImages = false
    #expect(CrawlSettings(defaults: defaults).config.checkImages == false)
}
