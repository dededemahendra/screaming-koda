import KodaCore
import SwiftUI

/// The crawl settings form.
///
/// Edits a working copy and applies it on Done, so Cancel genuinely cancels —
/// binding straight to the controller would let a half-typed number reach the
/// next crawl the moment the sheet was dismissed by any route.
public struct ConfigSheet: View {
    @State private var draft: CrawlConfig
    @State private var includeText: String
    @State private var excludeText: String
    @State private var sitemapText: String
    private let onApply: (CrawlConfig) -> Void
    private let onCancel: () -> Void

    public init(config: CrawlConfig,
                onApply: @escaping (CrawlConfig) -> Void,
                onCancel: @escaping () -> Void) {
        _draft = State(initialValue: config)
        _includeText = State(initialValue: config.include.joined(separator: "\n"))
        _excludeText = State(initialValue: config.exclude.joined(separator: "\n"))
        _sitemapText = State(initialValue: config.sitemapURLs.joined(separator: "\n"))
        self.onApply = onApply
        self.onCancel = onCancel
    }

    private var edited: CrawlConfig {
        var out = draft
        out.include = patterns(includeText)
        out.exclude = patterns(excludeText)
        out.sitemapURLs = patterns(sitemapText)
        return CrawlSettings.clamped(out)
    }

    private func patterns(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var problems: [String] { CrawlSettings.problems(in: edited) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Crawl settings").font(.title3).padding(.horizontal, 20).padding(.top, 20)
            Form {
                Section("Politeness") {
                    Stepper("Workers: \(draft.workers)", value: $draft.workers, in: 1...50)
                    Stepper("Max per host: \(draft.maxPerHost)",
                            value: $draft.maxPerHost, in: 1...max(draft.workers, 1))
                    Toggle("Respect robots.txt", isOn: $draft.respectRobots)
                    Toggle("Crawl subdomains", isOn: $draft.crawlSubdomains)
                    Toggle("Follow internal nofollow links", isOn: $draft.followInternalNofollow)
                    TextField("User agent", text: $draft.userAgent)
                }
                Section("Limits") {
                    LabeledContent("Request timeout") {
                        TextField("", value: $draft.timeout, format: .number)
                            .frame(width: 70)
                    }
                    Stepper("Max redirect hops: \(draft.maxRedirects)",
                            value: $draft.maxRedirects, in: 0...50)
                    LabeledContent("URL cap") {
                        TextField("", value: $draft.urlCap, format: .number)
                            .frame(width: 100)
                    }
                    Toggle("Limit crawl depth", isOn: Binding(
                        get: { draft.maxDepth != nil },
                        set: { draft.maxDepth = $0 ? (draft.maxDepth ?? 3) : nil }))
                    if draft.maxDepth != nil {
                        Stepper("Max depth: \(draft.maxDepth ?? 3)", value: Binding(
                            get: { draft.maxDepth ?? 3 },
                            set: { draft.maxDepth = $0 }), in: 0...50)
                    }
                }
                Section("Sitemaps") {
                    Toggle("Read Sitemap: directives from robots.txt", isOn: $draft.discoverSitemaps)
                    Toggle("List mode: crawl only the seed and sitemap URLs",
                           isOn: $draft.listModeOnly)
                    LabeledContent("Sitemap URLs") {
                        TextEditor(text: $sitemapText).font(.body.monospaced()).frame(height: 44)
                    }
                }
                Section("What to fetch") {
                    Toggle("Status-check external links", isOn: $draft.checkExternalLinks)
                    Toggle("Status-check images", isOn: $draft.checkImages)
                    Toggle("Status-check stylesheets and scripts", isOn: $draft.checkResources)
                    Toggle("Retain page bodies", isOn: $draft.retainBodies)
                }
                Section("URL filters") {
                    Text("One regular expression per line. Include, when non-empty, "
                         + "restricts the crawl to matching URLs; Exclude always wins.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Include") {
                        TextEditor(text: $includeText).font(.body.monospaced()).frame(height: 56)
                    }
                    LabeledContent("Exclude") {
                        TextEditor(text: $excludeText).font(.body.monospaced()).frame(height: 56)
                    }
                }
            }
            .formStyle(.grouped)

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Done") { onApply(edited) }
                    .keyboardShortcut(.defaultAction)
                    // A pattern that will not compile silently matches nothing,
                    // so it must not be possible to save one.
                    .disabled(!problems.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
    }
}
