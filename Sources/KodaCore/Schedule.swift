import Foundation

/// A recurring crawl, expressed as a launchd agent.
///
/// launchd rather than a timer inside the app, because a scheduled crawl whose
/// schedule only runs while the app happens to be open is not scheduled. launchd
/// starts the job whether or not anyone is logged into the app, survives a
/// reboot, and is the mechanism macOS actually provides for this.
public struct CrawlSchedule: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var seedURL: String
    /// 0 to 23, in local time.
    public var hour: Int
    public var minute: Int
    /// nil for every day; 0 is Sunday, matching launchd's own numbering.
    public var weekday: Int?
    /// Where the crawl is written. Each run overwrites it, so the schedule
    /// keeps a current picture rather than an ever-growing pile.
    public var databasePath: String
    /// Write a workbook beside the database after each run.
    public var exportAfterwards: Bool

    public init(id: String = UUID().uuidString, seedURL: String, hour: Int, minute: Int = 0,
                weekday: Int? = nil, databasePath: String, exportAfterwards: Bool = true) {
        self.id = id
        self.seedURL = seedURL
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.databasePath = databasePath
        self.exportAfterwards = exportAfterwards
    }

    public var label: String { "co.sistercreatives.koda.\(id)" }

    public var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        guard let weekday else { return "Every day at \(time)" }
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let name = weekday >= 0 && weekday < names.count ? names[weekday] : "day \(weekday)"
        return "Every \(name) at \(time)"
    }

    public var problems: [String] {
        var out: [String] = []
        if CrawlConfig(seedURL: seedURL).seedHost == nil {
            out.append("\(seedURL) is not a crawlable http(s) URL.")
        }
        if !(0...23).contains(hour) { out.append("Hour must be between 0 and 23.") }
        if !(0...59).contains(minute) { out.append("Minute must be between 0 and 59.") }
        if let weekday, !(0...6).contains(weekday) {
            out.append("Weekday must be between 0 (Sunday) and 6.")
        }
        if databasePath.isEmpty { out.append("A database path is needed.") }
        return out
    }
}

public enum ScheduleWriter {
    /// The launchd agent for one schedule.
    ///
    /// The binary path is written in full rather than relying on a PATH:
    /// launchd jobs run with a minimal environment, and `koda` on the user's
    /// shell PATH is not on launchd's.
    public static func plist(_ schedule: CrawlSchedule, binary: String,
                             logDirectory: String) -> String {
        var program = [binary, "crawl", schedule.seedURL, "--db", schedule.databasePath]
        // Two commands in one job would need a shell; instead the crawl runs
        // here and the export is a second job argument list joined by a shell
        // only when it is actually wanted.
        if schedule.exportAfterwards {
            let workbook = (schedule.databasePath as NSString)
                .deletingPathExtension + ".xlsx"
            program = ["/bin/sh", "-c",
                       "\(shellQuoted(binary)) crawl \(shellQuoted(schedule.seedURL)) "
                       + "--db \(shellQuoted(schedule.databasePath)) && "
                       + "\(shellQuoted(binary)) export \(shellQuoted(schedule.databasePath)) "
                       + "--out \(shellQuoted(workbook))"]
        }

        var calendar = "      <key>Hour</key><integer>\(schedule.hour)</integer>\n"
            + "      <key>Minute</key><integer>\(schedule.minute)</integer>"
        if let weekday = schedule.weekday {
            calendar += "\n      <key>Weekday</key><integer>\(weekday)</integer>"
        }

        let arguments = program
            .map { "      <string>\(xmlEscaped($0))</string>" }
            .joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key>
              <string>\(xmlEscaped(schedule.label))</string>
              <key>ProgramArguments</key>
              <array>
            \(arguments)
              </array>
              <key>StartCalendarInterval</key>
              <dict>
            \(calendar)
              </dict>
              <key>StandardOutPath</key>
              <string>\(xmlEscaped(logDirectory))/\(xmlEscaped(schedule.id)).log</string>
              <key>StandardErrorPath</key>
              <string>\(xmlEscaped(logDirectory))/\(xmlEscaped(schedule.id)).log</string>
              <key>RunAtLoad</key>
              <false/>
              <!-- A crawl is polite but not free, and a machine that was asleep
                   at the scheduled time should crawl when it wakes rather than
                   skip the run entirely. -->
              <key>ProcessType</key>
              <string>Background</string>
            </dict>
            </plist>
            """
    }

    /// Escaped for XML. A URL with an ampersand in its query is ordinary, and
    /// unescaped it would make the plist unparseable — which launchd reports as
    /// a job that simply never runs.
    static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Single-quoted for `/bin/sh`, since the export form goes through a shell.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func agentPath(_ schedule: CrawlSchedule, home: URL) -> URL {
        home.appendingPathComponent("Library/LaunchAgents/\(schedule.label).plist")
    }
}
