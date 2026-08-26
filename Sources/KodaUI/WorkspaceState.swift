import KodaCore
import SwiftUI

/// What the workspace should be showing.
///
/// Separate from `CrawlState` because two of these are not crawl states at all:
/// whether a finished crawl is clean depends on what it found, and whether
/// there is anything to show depends on whether a store was ever opened.
public enum WorkspaceState: Equatable, Sendable {
    case noCrawl
    case crawling
    case results
    case clean
    case failed(String)

    public static func resolve(crawl: CrawlState, hasStore: Bool,
                               urlsFound: Int, findingTotal: Int) -> WorkspaceState {
        if case .failed(let reason) = crawl { return .failed(reason) }
        if crawl.isActive { return .crawling }
        guard hasStore else { return .noCrawl }
        // Only a crawl that finished can claim to be clean. A stopped one has
        // not checked everything, and one that reached nothing has no opinion
        // to offer — "no issues found" would be a lie in both cases.
        if crawl == .finished, urlsFound > 0, findingTotal == 0 { return .clean }
        return .results
    }
}

/// The centred panel the workspace shows instead of an empty table.
struct EmptyStatePanel: View {
    let symbol: String
    let title: String
    let message: String
    var ink: Theme.Ink = .quiet

    var body: some View {
        VStack(spacing: Theme.Space.medium) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(ink.color)
            Text(title).font(Theme.Face.title)
            Text(message)
                .font(Theme.Numeral.label)
                .foregroundStyle(Theme.Ink.quiet.color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .padding(Theme.Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
