import AppKit
import KodaCore
import SwiftUI

/// Everything visual in the app reads from here.
///
/// Native chrome, deliberate data language: standard controls and materials do
/// the work of looking like a Mac app, and what is designed is the data
/// display. Dense tables are won on legibility, not decoration.
public enum Theme {

    /// Semantic colour. Four roles and no decorative fifth.
    ///
    /// Every value is a system colour, so both appearances and the
    /// increased-contrast setting come free instead of needing a second
    /// palette that would drift from this one.
    public enum Ink: String, CaseIterable, Sendable {
        case critical, warning, quiet, accent

        public var nsColor: NSColor {
            switch self {
            case .critical: return .systemRed
            case .warning: return .systemOrange
            case .quiet: return .secondaryLabelColor
            case .accent: return .controlAccentColor
            }
        }

        public var color: Color { Color(nsColor: nsColor) }
    }

    /// A 4pt grid. These six values are the only spacing in `Sources/KodaUI/`.
    public enum Space {
        public static let hair: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let section: CGFloat = 24
    }

    /// Four roles, all system font. Named after the job rather than the size so
    /// a change of scale is one edit here.
    public enum Face {
        /// Section headers and band headings.
        public static let title = Font.headline
        /// Table rows and detail values.
        public static let body = Font.body
        /// Sidebar rows and column headers.
        public static let label = Font.callout
        /// Counts, units, secondary text.
        public static let caption = Font.caption
    }

    /// The same roles for anything with digits in it. A column of
    /// right-aligned counts that jitter as they update during a crawl is the
    /// most obvious tell of an unconsidered data view.
    public enum Numeral {
        public static let body = Font.body.monospacedDigit()
        public static let label = Font.callout.monospacedDigit()
        public static let caption = Font.caption.monospacedDigit()
    }

    /// The one place a status code becomes a colour.
    ///
    /// Returns nil for 2xx deliberately: colour marks exceptions, and a table
    /// where every row is coloured has no exceptions left to mark. This also
    /// corrects two disagreements from before the tokens existed — the
    /// inspector drew 4xx orange and 5xx red as though a 404 were the milder
    /// problem, and drew 3xx yellow, which fails contrast on a light ground.
    public static func ink(forStatus status: Int?) -> Ink? {
        guard let status else { return nil }
        if status == 0 || status >= 400 { return .critical }
        if status >= 300 { return .warning }
        return nil
    }

    public static func ink(for severity: Severity) -> Ink {
        switch severity {
        case .breaksIndexing: return .critical
        case .costsClicks: return .warning
        case .hygiene: return .quiet
        }
    }
}
