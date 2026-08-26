import KodaCore
import SwiftUI

/// One tab of the preferences window.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case crawl, limits, rendering, authentication, extraction, dataSources
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .crawl: return "Crawl"
        case .limits: return "Limits"
        case .rendering: return "Rendering"
        case .authentication: return "Authentication"
        case .extraction: return "Extraction"
        case .dataSources: return "Data sources"
        }
    }

    public var symbol: String {
        switch self {
        case .crawl: return "arrow.triangle.branch"
        case .limits: return "gauge.with.dots.needle.33percent"
        case .rendering: return "globe"
        case .authentication: return "lock"
        case .extraction: return "scissors"
        case .dataSources: return "square.stack.3d.up"
        }
    }

    /// Units belong beside the number. The request timeout read "20" with
    /// nothing saying seconds, which is a guess a person should not have to
    /// make about how long a crawl will wait on a slow server.
    public static func unit(for field: String) -> String {
        switch field {
        case "timeout": return "seconds"
        case "renderSettleMs": return "milliseconds"
        case "urlCap": return "URLs"
        default: return ""
        }
    }
}

extension SettingsWindow {
    @ViewBuilder
    func form(for pane: SettingsPane) -> some View {
        Form {
            switch pane {
            case .crawl: crawlPane
            case .limits: limitsPane
            case .rendering: renderingPane
            case .authentication: authenticationPane
            case .extraction: extractionPane
            case .dataSources: dataSourcesPane
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    var crawlPane: some View {
        Section("Politeness") {
            Stepper("Workers: \(controller.config.workers)",
                    value: $controller.config.workers, in: 1...50)
            Stepper("Max per host: \(controller.config.maxPerHost)",
                    value: $controller.config.maxPerHost, in: 1...max(controller.config.workers, 1))
            Toggle("Respect robots.txt", isOn: $controller.config.respectRobots)
            Toggle("Crawl subdomains", isOn: $controller.config.crawlSubdomains)
            Toggle("Crawl as a phone", isOn: $controller.config.mobile)
            Toggle("Follow internal nofollow links", isOn: $controller.config.followInternalNofollow)
            TextField("User agent", text: $controller.config.userAgent)
        }
        Section("What to fetch") {
            Toggle("Status-check external links", isOn: $controller.config.checkExternalLinks)
            Toggle("Status-check images", isOn: $controller.config.checkImages)
            Toggle("Status-check stylesheets and scripts", isOn: $controller.config.checkResources)
            Toggle("Retain page bodies", isOn: $controller.config.retainBodies)
        }
    }

    @ViewBuilder
    var limitsPane: some View {
        Section("Limits") {
            LabeledContent("Request timeout (\(SettingsPane.unit(for: "timeout")))") {
                TextField("", value: $controller.config.timeout, format: .number)
                    .frame(width: 70)
            }
            Stepper("Max redirect hops: \(controller.config.maxRedirects)",
                    value: $controller.config.maxRedirects, in: 0...50)
            LabeledContent("URL cap (\(SettingsPane.unit(for: "urlCap")))") {
                TextField("", value: $controller.config.urlCap, format: .number)
                    .frame(width: 100)
            }
            Toggle("Limit crawl depth", isOn: Binding(
                get: { controller.config.maxDepth != nil },
                set: { controller.config.maxDepth = $0 ? (controller.config.maxDepth ?? 3) : nil }))
            if controller.config.maxDepth != nil {
                Stepper("Max depth: \(controller.config.maxDepth ?? 3)", value: Binding(
                    get: { controller.config.maxDepth ?? 3 },
                    set: { controller.config.maxDepth = $0 }), in: 0...50)
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

    @ViewBuilder
    var renderingPane: some View {
        Section("JavaScript rendering") {
            Toggle("Render pages in a browser engine", isOn: $controller.config.renderJavaScript)
            Text("Far slower: a browser process and hundreds of milliseconds per page "
                 + "instead of one request. Worth it for a site that builds its content "
                 + "client-side, where a static crawl finds empty titles and no links.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.config.renderJavaScript {
                Stepper("Pages at once: \(controller.config.renderConcurrency)",
                        value: $controller.config.renderConcurrency, in: 1...8)
                LabeledContent("Settle time (\(SettingsPane.unit(for: "renderSettleMs")))") {
                    TextField("", value: $controller.config.renderSettleMs, format: .number)
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
    }

    @ViewBuilder
    var authenticationPane: some View {
        Section("Authentication") {
            Text("Stored in the crawl's config, in plain text, next to an "
                 + "unencrypted database. For sites you control.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Username", text: $controller.config.basicAuthUser)
            SecureField("Password", text: $controller.config.basicAuthPassword)
            LabeledContent("Extra headers") {
                TextEditor(text: $headerText).font(.body.monospaced()).frame(height: 44)
            }
            Text("One per line, as Name: Value.")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("Log in through a form", isOn: Binding(
                get: { controller.config.login != nil },
                set: { on in
                    controller.config.login = on
                        ? (controller.config.login ?? FormLogin(url: "", username: "", password: ""))
                        : nil
                }))
            if controller.config.login != nil {
                TextField("Login page URL", text: Binding(
                    get: { controller.config.login?.url ?? "" },
                    set: { controller.config.login?.url = $0 }))
                TextField("Form username", text: Binding(
                    get: { controller.config.login?.username ?? "" },
                    set: { controller.config.login?.username = $0 }))
                SecureField("Form password", text: Binding(
                    get: { controller.config.login?.password ?? "" },
                    set: { controller.config.login?.password = $0 }))
                Text("Needs rendering switched on: a form login is a page, and driving "
                     + "it needs a browser.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    var extractionPane: some View {
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
    }

    @ViewBuilder
    var dataSourcesPane: some View {
        Section("Sitemaps") {
            Toggle("Read Sitemap: directives from robots.txt", isOn: $controller.config.discoverSitemaps)
            Toggle("List mode: crawl only the seed and sitemap URLs",
                   isOn: $controller.config.listModeOnly)
            LabeledContent("Sitemap URLs") {
                TextEditor(text: $sitemapText).font(.body.monospaced()).frame(height: 44)
            }
        }
        Text("Search Console, Analytics, backlink and PageSpeed data are "
             + "added after a crawl by koda enrich, which reads its "
             + "credentials from environment variables rather than from "
             + "here.")
            .font(Theme.Face.caption)
            .foregroundStyle(Theme.Ink.quiet.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
