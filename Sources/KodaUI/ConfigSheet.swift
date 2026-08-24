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
    @State private var headerText: String
    @State private var jsExtractionText: String
    @State private var extractionText: String
    private let onApply: (CrawlConfig) -> Void
    private let onCancel: () -> Void

    public init(config: CrawlConfig,
                onApply: @escaping (CrawlConfig) -> Void,
                onCancel: @escaping () -> Void) {
        _draft = State(initialValue: config)
        _includeText = State(initialValue: config.include.joined(separator: "\n"))
        _excludeText = State(initialValue: config.exclude.joined(separator: "\n"))
        _sitemapText = State(initialValue: config.sitemapURLs.joined(separator: "\n"))
        _extractionText = State(initialValue: config.extractions
            .map { "\($0.name) = \($0.engine == .xpath ? "xpath:" : "")\($0.selector)" }
            .joined(separator: "\n"))
        _jsExtractionText = State(initialValue: config.javaScriptExtractions
            .map { "\($0.name) = \($0.selector)" }
            .joined(separator: "\n"))
        _headerText = State(initialValue: config.extraHeaders
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n"))
        self.onApply = onApply
        self.onCancel = onCancel
    }

    private var edited: CrawlConfig {
        var out = draft
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
                    Toggle("Crawl as a phone", isOn: $draft.mobile)
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
                Section("Authentication") {
                    Text("Stored in the crawl's config, in plain text, next to an "
                         + "unencrypted database. For sites you control.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Username", text: $draft.basicAuthUser)
                    SecureField("Password", text: $draft.basicAuthPassword)
                    LabeledContent("Extra headers") {
                        TextEditor(text: $headerText).font(.body.monospaced()).frame(height: 44)
                    }
                    Text("One per line, as Name: Value.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("JavaScript rendering") {
                    Toggle("Render pages in a browser engine", isOn: $draft.renderJavaScript)
                    Text("Far slower: a browser process and hundreds of milliseconds per page "
                         + "instead of one request. Worth it for a site that builds its content "
                         + "client-side, where a static crawl finds empty titles and no links.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if draft.renderJavaScript {
                        Stepper("Pages at once: \(draft.renderConcurrency)",
                                value: $draft.renderConcurrency, in: 1...8)
                        LabeledContent("Settle time (ms)") {
                            TextField("", value: $draft.renderSettleMs, format: .number)
                                .frame(width: 70)
                        }
                        LabeledContent("JavaScript extractions") {
                            TextEditor(text: $jsExtractionText)
                                .font(.body.monospaced()).frame(height: 56)
                        }
                        Text("One per line, as Name = expression. Reaches values that never "
                             + "appear in the DOM, such as window variables.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("Extraction") {
                    Text("One per line, as Name = selector. Prefix an expression with "
                         + "xpath: to use XPath instead of a CSS selector.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LabeledContent("Rules") {
                        TextEditor(text: $extractionText)
                            .font(.body.monospaced()).frame(height: 56)
                    }
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
