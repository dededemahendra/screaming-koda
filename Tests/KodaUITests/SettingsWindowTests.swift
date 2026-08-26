import SwiftUI
import Testing
@testable import KodaCore
@testable import KodaUI

@Test func everyPaneHasATitleAndASymbol() {
    #expect(SettingsPane.allCases.map(\.rawValue)
            == ["crawl", "limits", "rendering", "authentication", "extraction", "dataSources"])
    for pane in SettingsPane.allCases {
        #expect(!pane.title.isEmpty)
        #expect(!pane.symbol.isEmpty)
    }
}

/// Sentence case, no exclamation marks, and units on anything numeric — the
/// timeout read "20" with nothing saying seconds.
@Test func numericFieldsCarryTheirUnits() {
    #expect(SettingsPane.unit(for: "timeout") == "seconds")
    #expect(SettingsPane.unit(for: "renderSettleMs") == "milliseconds")
    #expect(SettingsPane.unit(for: "urlCap") == "URLs")
}

@MainActor
@Test func everyPaneDraws() {
    let controller = CrawlController(dbPath: nil)
    for pane in SettingsPane.allCases {
        ViewCapture.expectNotBlank(
            SettingsWindow(controller: controller, pane: pane)
                .frame(width: 560, height: 460),
            size: CGSize(width: 560, height: 460), "the \(pane.title) pane")
    }
}

/// Where hand-rolled number formatting breaks. `.number` is the same style the
/// text fields use, and it has to survive a locale whose separators are not the
/// author's: 500000 renders "500,000" in en_AU and "500.000" in en_ID and
/// de_DE, and all three must parse back to the same integer.
@Test func numericFieldsRoundTripUnderALocaleWithOtherSeparators() throws {
    for identifier in ["en_AU", "en_ID", "de_DE", "fr_FR"] {
        let style = IntegerFormatStyle<Int>(locale: Locale(identifier: identifier))
        let text = 500_000.formatted(style)
        #expect(try style.parseStrategy.parse(text) == 500_000,
                "500000 did not round-trip in \(identifier), via \"\(text)\"")
    }
}

/// The one property this whole task turns on: `configToApply` is the exact
/// gate `SettingsWindow`'s `.onChange` calls before every write to
/// `controller.config`. A pattern that will not compile is indistinguishable
/// from one that matched nothing, so an invalid include pattern reaching the
/// controller would silently crawl the seed and stop, looking like a broken
/// tool. Testing `problems(in:)` alone (as this test used to) would miss a
/// regression where some future binding wrote to `controller.config` without
/// going through this gate at all.
@Test func aCandidateWithAPatternThatWillNotCompileIsNeverAppliedThroughTheGate() {
    var invalidInclude = CrawlConfig(seedURL: "https://example.com/")
    invalidInclude.include = ["([unclosed"]
    #expect(CrawlSettings.configToApply(invalidInclude) == nil)

    var invalidExclude = CrawlConfig(seedURL: "https://example.com/")
    invalidExclude.exclude = ["([unclosed"]
    #expect(CrawlSettings.configToApply(invalidExclude) == nil)

    var valid = CrawlConfig(seedURL: "https://example.com/")
    valid.include = ["^/blog/"]
    let applied = CrawlSettings.configToApply(valid)
    #expect(applied?.include == ["^/blog/"])
}
