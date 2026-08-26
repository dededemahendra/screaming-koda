import KodaCore
import SwiftUI

/// The crawl settings preferences window.
///
/// Applies as it goes, which is the platform convention for a `Settings`
/// scene and what makes the six panes independent of one another — except for
/// a regular expression that will not compile. `Store.passesFilters` cannot
/// tell an invalid pattern from one that matched nothing, so an invalid
/// include pattern reaching the controller would silently crawl the seed and
/// stop, looking like a broken tool. Text fields stay as local text while
/// being edited, so a half-typed pattern is never repeatedly parsed and
/// rejected mid-keystroke.
///
/// The safety property is narrower than "every write to `controller.config`":
/// only the six text-buffer fields — include, exclude, sitemap URLs, extra
/// headers and the two extraction-rule lists — are reachable exclusively
/// through `edited` and `CrawlSettings.configToApply(_:)`, which is what
/// keeps an invalid regular expression from ever reaching the controller.
/// `workers`, `timeout`, `urlCap`, `maxDepth`, every `Toggle` and both
/// credential fields bind directly to `$controller.config.*` and write
/// through immediately; those cannot fail to compile, so the gate only needs
/// to clamp them back into range after the write, not refuse them before it.
public struct SettingsWindow: View {
    @Bindable var controller: CrawlController
    @State private var pane: SettingsPane
    // Text-area fields stay as text while being edited so a half-typed regular
    // expression is not repeatedly parsed and rejected mid-keystroke.
    @State var includeText: String
    @State var excludeText: String
    @State var sitemapText: String
    @State var headerText: String
    @State var jsExtractionText: String
    @State var extractionText: String

    public init(controller: CrawlController, pane: SettingsPane = .crawl) {
        self.controller = controller
        _pane = State(initialValue: pane)
        _includeText = State(initialValue: controller.config.include.joined(separator: "\n"))
        _excludeText = State(initialValue: controller.config.exclude.joined(separator: "\n"))
        _sitemapText = State(initialValue: controller.config.sitemapURLs.joined(separator: "\n"))
        _extractionText = State(initialValue: controller.config.extractions
            .map { "\($0.name) = \($0.engine == .xpath ? "xpath:" : "")\($0.selector)" }
            .joined(separator: "\n"))
        _jsExtractionText = State(initialValue: controller.config.javaScriptExtractions
            .map { "\($0.name) = \($0.selector)" }
            .joined(separator: "\n"))
        _headerText = State(initialValue: controller.config.extraHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n"))
    }

    private var edited: CrawlConfig {
        var out = controller.config
        out.include = patterns(includeText)
        out.exclude = patterns(excludeText)
        out.sitemapURLs = patterns(sitemapText)
        out.extractions = patterns(extractionText).compactMap { line in
            guard let split = line.firstIndex(of: "=") else { return nil }
            let name = String(line[..<split]).trimmingCharacters(in: .whitespaces)
            var selector = String(line[line.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
            let isXPath = selector.lowercased().hasPrefix("xpath:")
            if isXPath { selector = String(selector.dropFirst("xpath:".count))
                .trimmingCharacters(in: .whitespaces) }
            guard !name.isEmpty, !selector.isEmpty else { return nil }
            return ExtractionRule(name: name, selector: selector,
                                  engine: isXPath ? .xpath : .css)
        }
        out.javaScriptExtractions = patterns(jsExtractionText).compactMap { line in
            guard let split = line.firstIndex(of: "=") else { return nil }
            let name = String(line[..<split]).trimmingCharacters(in: .whitespaces)
            let expression = String(line[line.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !expression.isEmpty else { return nil }
            return ExtractionRule(name: name, selector: expression)
        }
        out.extraHeaders = Dictionary(uniqueKeysWithValues: patterns(headerText).compactMap { line in
            guard let split = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<split]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name, value)
        })
        // Not redundant with `configToApply`'s own clamp: this is the
        // termination guard for the `.onChange(of: edited)` →
        // `controller.config = applied` → `edited` recompute cycle. Without
        // it, a directly-bound field (e.g. `workers`) written out of range
        // would make `edited` keep producing a different clamped value each
        // time `controller.config` is corrected, and the cycle would never
        // settle.
        return CrawlSettings.clamped(out)
    }

    private func patterns(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var problems: [String] { CrawlSettings.problems(in: edited) }

    public var body: some View {
        TabView(selection: $pane) {
            ForEach(SettingsPane.allCases) { item in
                form(for: item)
                    .tabItem { Label(item.title, systemImage: item.symbol) }
                    .tag(item)
            }
        }
        // Changing the configuration mid-crawl would apply to nothing already
        // running and silently to whatever is not, so it waits.
        .disabled(controller.state.isActive)
        .overlay(alignment: .bottom) { problemList }
        .frame(width: 560, height: 460)
        .onChange(of: edited) { _, candidate in
            if let applied = CrawlSettings.configToApply(candidate) { controller.config = applied }
        }
    }

    @ViewBuilder
    private var problemList: some View {
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.hair) {
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Ink.warning.color)
                        .font(Theme.Face.label)
                }
            }
            .padding(Theme.Space.medium)
            .background(.regularMaterial)
        }
    }
}
