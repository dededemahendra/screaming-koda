import AppKit
import Testing
@testable import KodaCore
@testable import KodaUI

/// Both appearances, because a palette defined once and checked once is a
/// palette that works in whichever appearance the author happened to be using.
@MainActor
@Test func everyInkResolvesInBothAppearances() {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: name)!
        appearance.performAsCurrentDrawingAppearance {
            for ink in Theme.Ink.allCases {
                #expect(ink.nsColor.usingColorSpace(.sRGB) != nil,
                        "\(ink.rawValue) did not resolve in \(name.rawValue)")
            }
        }
    }
}

/// The three data inks have to be told apart at a glance, which is the whole
/// reason they exist. Equal RGB in either appearance defeats the design.
@MainActor
@Test func theDataInksAreDistinguishableInBothAppearances() {
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: name)!
        appearance.performAsCurrentDrawingAppearance {
            let resolved = [Theme.Ink.critical, .warning, .quiet].map {
                $0.nsColor.usingColorSpace(.sRGB)!
            }
            for (a, b) in [(0, 1), (0, 2), (1, 2)] {
                #expect(resolved[a] != resolved[b],
                        "two data inks matched in \(name.rawValue)")
            }
        }
    }
}

/// Neither test above would notice an ink that stopped adapting: resolving
/// to *something*, and differing from its siblings, both hold even for a
/// colour frozen at its light-mode value. This compares each data ink to
/// itself across the two appearances, which is the comparison that would
/// actually catch that regression. `.accent` is excluded: it is the user's
/// chosen system accent colour, which can legitimately resolve identically
/// in both appearances depending on which colour they picked.
@MainActor
@Test func eachDataInkAdaptsBetweenAppearances() {
    let inks: [Theme.Ink] = [.critical, .warning, .quiet]
    var resolvedByAppearance: [NSAppearance.Name: [NSColor]] = [:]

    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = NSAppearance(named: name)!
        appearance.performAsCurrentDrawingAppearance {
            resolvedByAppearance[name] = inks.map { $0.nsColor.usingColorSpace(.sRGB)! }
        }
    }

    let light = resolvedByAppearance[.aqua]!
    let dark = resolvedByAppearance[.darkAqua]!
    for index in inks.indices {
        #expect(light[index] != dark[index],
                "\(inks[index].rawValue) did not adapt between appearances")
    }
}

@Test func theSpacingGridIsWhatTheDesignSays() {
    let grid: [CGFloat] = [Theme.Space.hair, Theme.Space.tight, Theme.Space.small,
                           Theme.Space.medium, Theme.Space.large, Theme.Space.section]
    #expect(grid == [2, 4, 8, 12, 16, 24])
    #expect(grid == grid.sorted())
}

/// A 200 is not an event. If every row is coloured, none of them is.
@Test func onlyExceptionalStatusCodesTakeAnInk() {
    #expect(Theme.ink(forStatus: 200) == nil)
    #expect(Theme.ink(forStatus: 204) == nil)
    #expect(Theme.ink(forStatus: nil) == nil)
    #expect(Theme.ink(forStatus: 301) == .warning)
    #expect(Theme.ink(forStatus: 404) == .critical)
    #expect(Theme.ink(forStatus: 503) == .critical)
    #expect(Theme.ink(forStatus: 0) == .critical)
}

@Test func eachBandTakesItsOwnInk() {
    #expect(Theme.ink(for: .breaksIndexing) == .critical)
    #expect(Theme.ink(for: .costsClicks) == .warning)
    #expect(Theme.ink(for: .hygiene) == .quiet)
}
