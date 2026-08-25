import Foundation

/// How a live counter is written to stderr.
///
/// A terminal gets one line rewritten in place. A pipe or a file gets ordinary
/// lines: carriage returns and blank padding are how a redirected crawl log ends
/// up as a single unreadable line of escape noise, and `koda crawl … 2> crawl.log`
/// is the normal way to run a long crawl.
enum Progress {
    /// True when stderr is a terminal, so nothing else has to ask.
    static let isInteractive = isatty(STDERR_FILENO) == 1

    /// Padded so a shorter update fully overwrites a longer one; `\r` alone
    /// leaves the tail of the previous line on screen.
    static func line(_ text: String) -> String {
        guard isInteractive else { return text + "\n" }
        return "\r" + text.padding(toLength: max(text.count, width), withPad: " ", startingAt: 0)
    }

    /// Wipes the counter so the summary does not print over half of it.
    static func clear() {
        guard isInteractive else { return }
        FileHandle.standardError.write(Data("\r\(String(repeating: " ", count: width))\r".utf8))
    }

    private static let width = 60
}
