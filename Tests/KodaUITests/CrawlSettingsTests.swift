import Foundation
import KodaCore
import Testing
@testable import KodaUI

// MARK: - Form to config

@Test func defaultSettingsMatchTheCrawlDefaults() throws {
    let config = try CrawlSettings().config(seedURL: "https://fx.test/")
    let reference = CrawlConfig(seedURL: "https://fx.test/")
    #expect(config.workers == reference.workers)
    #expect(config.maxPerHost == reference.maxPerHost)
    #expect(config.respectRobots == reference.respectRobots)
    #expect(config.checkExternalLinks == reference.checkExternalLinks)
    #expect(config.maxDepth == nil, "blank means unlimited, not zero")
    #expect(config.include.isEmpty)
}

@Test func settingsRoundTripThroughACrawlConfig() throws {
    var original = CrawlConfig(seedURL: "https://fx.test/")
    original.workers = 12
    original.maxPerHost = 2
    original.timeout = 45
    original.userAgent = "Koda/test"
    original.urlCap = 900
    original.maxDepth = 3
    original.respectRobots = false
    original.followInternalNofollow = true
    original.crawlSubdomains = true
    original.checkExternalLinks = false
    original.checkImages = false
    original.retainBodies = false
    original.include = ["^/blog/", "^/docs/"]
    original.exclude = ["\\?print="]

    let rebuilt = try CrawlSettings(from: original).config(seedURL: original.seedURL)

    #expect(rebuilt.workers == 12)
    #expect(rebuilt.maxPerHost == 2)
    #expect(rebuilt.timeout == 45)
    #expect(rebuilt.userAgent == "Koda/test")
    #expect(rebuilt.urlCap == 900)
    #expect(rebuilt.maxDepth == 3)
    #expect(rebuilt.respectRobots == false)
    #expect(rebuilt.followInternalNofollow == true)
    #expect(rebuilt.crawlSubdomains == true)
    #expect(rebuilt.checkExternalLinks == false)
    #expect(rebuilt.checkImages == false)
    #expect(rebuilt.retainBodies == false)
    #expect(rebuilt.include == ["^/blog/", "^/docs/"])
    #expect(rebuilt.exclude == ["\\?print="])
}

@Test func blankAndWhitespaceLinesAreNotPatterns() throws {
    var settings = CrawlSettings()
    settings.includeText = "^/a/\n\n   \n^/b/\n"
    #expect(settings.include == ["^/a/", "^/b/"])
}

// MARK: - Validation

@Test func aBadRegexIsRefusedBeforeTheCrawlStarts() {
    var settings = CrawlSettings()
    settings.excludeText = "^/ok/\n[unclosed"
    let problems = settings.problems(seedURL: "https://fx.test/")
    #expect(problems.count == 1)
    #expect(problems[0].contains("[unclosed"))
    #expect(throws: CrawlSettingsError.self) { try settings.config(seedURL: "https://fx.test/") }
}

@Test func aNonNumericDepthIsRefusedRatherThanSilentlyIgnored() {
    var settings = CrawlSettings()
    settings.maxDepthText = "three"
    #expect(settings.problems(seedURL: "https://fx.test/").count == 1)

    settings.maxDepthText = "  "
    #expect(settings.problems(seedURL: "https://fx.test/").isEmpty, "blank is unlimited, not an error")
}

@Test func aSeedThatIsNotCrawlableIsAProblem() {
    let settings = CrawlSettings()
    #expect(settings.problems(seedURL: "").count == 1)
    #expect(settings.problems(seedURL: "ftp://fx.test/").count == 1)
    #expect(settings.problems(seedURL: "https://fx.test/").isEmpty)
}

@Test func anEmptyUserAgentIsRefused() {
    var settings = CrawlSettings()
    settings.userAgent = "  "
    #expect(settings.problems(seedURL: "https://fx.test/").count == 1)
}

@Test func numericFieldsAreClampedRatherThanRejected() throws {
    // A stepper can reach zero. Refusing to start is a worse answer than one worker.
    var settings = CrawlSettings()
    settings.workers = 0
    settings.maxPerHost = -3
    let config = try settings.config(seedURL: "https://fx.test/")
    #expect(config.workers == 1)
    #expect(config.maxPerHost == 1)
}

// MARK: - Persistence

@Test func settingsSurviveARelaunch() throws {
    let name = "koda.settings.\(UUID().uuidString)"
    let suite = try #require(UserDefaults(suiteName: name))
    defer { suite.removePersistentDomain(forName: name) }

    #expect(CrawlSettings.load(from: suite) == CrawlSettings(), "an unseen suite yields defaults")

    var settings = CrawlSettings()
    settings.respectRobots = false
    settings.workers = 9
    settings.excludeText = "\\.pdf$"
    settings.save(to: suite)

    #expect(CrawlSettings.load(from: suite) == settings)
}
