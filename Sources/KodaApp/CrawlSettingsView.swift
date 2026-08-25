import KodaCore
import KodaUI
import SwiftUI

/// The crawl form.
///
/// Edits a draft rather than the live settings so Cancel means cancel. The
/// settings only reach `AppModel` when Done is pressed, and only get persisted
/// when a crawl actually starts — a form someone opened, fiddled with and
/// abandoned should not change what the next crawl does.
struct CrawlSettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = CrawlSettings()
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Scope") {
                    LabeledContent("Maximum depth") {
                        TextField("Unlimited", text: $draft.maxDepthText)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }
                    .help("How many links from the seed to follow. Blank crawls the whole site.")

                    LabeledContent("Stop after") {
                        // An explicit HStack: LabeledContent stacks a multi-view
                        // value vertically, which puts the unit under the field.
                        HStack(spacing: 6) {
                            TextField("", value: $draft.urlCap, format: .number)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                            Text("URLs")
                        }
                    }

                    Toggle("Crawl subdomains of the seed host", isOn: $draft.crawlSubdomains)
                    Toggle("Follow internal rel=nofollow links", isOn: $draft.followInternalNofollow)

                    patternField(
                        "Include", text: $draft.includeText,
                        help: "One regular expression per line. Only URLs matching one of these are crawled."
                    )
                    patternField(
                        "Exclude", text: $draft.excludeText,
                        help: "One regular expression per line. Beats Include."
                    )
                }

                Section("Politeness") {
                    Toggle("Respect robots.txt", isOn: $draft.respectRobots)
                    if !draft.respectRobots {
                        Label("Only do this on sites you control.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                    stepper("Concurrent workers", value: $draft.workers, range: 1...50)
                    stepper("Maximum per host", value: $draft.maxPerHost, range: 1...50)
                    LabeledContent("Request timeout") {
                        HStack(spacing: 6) {
                            TextField("", value: $draft.timeout, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                            Text("seconds")
                        }
                    }
                    LabeledContent("User agent") {
                        TextField("", text: $draft.userAgent).frame(width: 240)
                    }
                }

                Section("Collect") {
                    Toggle("Status-check external links", isOn: $draft.checkExternalLinks)
                    Toggle("Status-check images", isOn: $draft.checkImages)
                    Toggle("Store page bodies", isOn: $draft.retainBodies)
                    Text("Bodies let a new report rule be tried against this crawl without "
                         + "re-fetching it. Retention stops on its own past 50,000 URLs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .task {
            // Once. Re-copying on every body pass would fight the user's typing.
            guard !loaded else { return }
            draft = model.settings
            loaded = true
        }
    }

    private var footer: some View {
        HStack {
            Button("Restore Defaults") { draft = CrawlSettings() }
            Spacer()
            if let problem = problems.first {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
            }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Done") {
                model.settings = draft
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!problems.isEmpty)
        }
        .padding(12)
    }

    /// Judged against the seed already in the toolbar, so an empty field is not
    /// reported as a settings problem while the settings themselves are fine.
    private var problems: [String] {
        draft.problems(seedURL: model.seedURL).filter { !$0.hasPrefix("Enter a URL") }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: value, in: range).labelsHidden()
            }
        }
    }

    private func patternField(_ title: String, text: Binding<String>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 52)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}
