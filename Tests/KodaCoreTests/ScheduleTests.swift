import Foundation
import Testing
@testable import KodaCore

private let daily = CrawlSchedule(id: "abc", seedURL: "https://x.test/",
                                  hour: 3, minute: 30, databasePath: "/tmp/x.koda",
                                  exportAfterwards: false)

@Test func aDailyScheduleProducesAValidPlist() throws {
    let text = ScheduleWriter.plist(daily, binary: "/usr/local/bin/koda", logDirectory: "/tmp/logs")
    let data = Data(text.utf8)
    // Parsed by the real property list reader, not by eye: a plist that does not
    // parse is a job launchd silently never runs.
    let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
    let dict = try #require(parsed as? [String: Any])

    #expect(dict["Label"] as? String == "co.sistercreatives.koda.abc")
    let interval = try #require(dict["StartCalendarInterval"] as? [String: Any])
    #expect(interval["Hour"] as? Int == 3)
    #expect(interval["Minute"] as? Int == 30)
    #expect(interval["Weekday"] == nil, "every day means no weekday key")

    let arguments = try #require(dict["ProgramArguments"] as? [String])
    #expect(arguments.first == "/usr/local/bin/koda",
            "the full path, because launchd's PATH is not the shell's")
    #expect(arguments.contains("https://x.test/"))
}

@Test func aWeeklyScheduleNamesItsDay() throws {
    var weekly = daily
    weekly.weekday = 1
    let parsed = try PropertyListSerialization.propertyList(
        from: Data(ScheduleWriter.plist(weekly, binary: "/bin/koda",
                                        logDirectory: "/tmp").utf8), format: nil)
    let interval = try #require((parsed as? [String: Any])?["StartCalendarInterval"] as? [String: Any])
    #expect(interval["Weekday"] as? Int == 1)
    #expect(weekly.summary == "Every Monday at 03:30")
}

/// A URL with an ampersand in its query is ordinary, and unescaped it makes the
/// plist unparseable — which launchd reports as a job that simply never runs.
@Test func aURLWithAnAmpersandStillProducesAParseablePlist() throws {
    var awkward = daily
    awkward.seedURL = "https://x.test/search?a=1&b=2&c=<3>"
    let text = ScheduleWriter.plist(awkward, binary: "/bin/koda", logDirectory: "/tmp")
    let parsed = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
    let arguments = try #require((parsed as? [String: Any])?["ProgramArguments"] as? [String])
    #expect(arguments.contains("https://x.test/search?a=1&b=2&c=<3>"),
            "and it survives the escaping intact")
}

@Test func exportingAfterwardsRunsBothCommands() throws {
    var withExport = daily
    withExport.exportAfterwards = true
    let text = ScheduleWriter.plist(withExport, binary: "/bin/koda", logDirectory: "/tmp")
    let parsed = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
    let arguments = try #require((parsed as? [String: Any])?["ProgramArguments"] as? [String])
    #expect(arguments.first == "/bin/sh")
    let script = try #require(arguments.last)
    #expect(script.contains("crawl"))
    #expect(script.contains("export"))
    #expect(script.contains("&&"), "the export only runs if the crawl succeeded")
    #expect(script.contains("x.xlsx"))
}

/// A path with a quote or a space in it must not break out of the shell command.
@Test func awkwardPathsAreQuotedForTheShell() throws {
    var awkward = daily
    awkward.exportAfterwards = true
    awkward.databasePath = "/tmp/Site's Crawl/data.koda"
    let text = ScheduleWriter.plist(awkward, binary: "/bin/koda", logDirectory: "/tmp")
    let parsed = try PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil)
    let arguments = try #require((parsed as? [String: Any])?["ProgramArguments"] as? [String])
    let script = try #require(arguments.last)
    #expect(script.contains(#"'/tmp/Site'\''s Crawl/data.koda'"#))
}

@Test func aScheduleValidatesItself() {
    #expect(daily.problems.isEmpty)

    var bad = daily
    bad.hour = 25
    bad.seedURL = "not a url"
    bad.weekday = 9
    bad.databasePath = ""
    #expect(bad.problems.count == 4)
}

@Test func theAgentGoesWhereLaunchdLooks() {
    let path = ScheduleWriter.agentPath(daily, home: URL(fileURLWithPath: "/Users/someone"))
    #expect(path.path == "/Users/someone/Library/LaunchAgents/co.sistercreatives.koda.abc.plist")
}

@Test func schedulesRoundTripAsJSON() throws {
    let data = try JSONEncoder().encode([daily])
    #expect(try JSONDecoder().decode([CrawlSchedule].self, from: data) == [daily])
}
