import KodaCore
import SwiftUI

public enum InspectorPane: String, CaseIterable, Identifiable, Sendable {
    case details, inlinks, outlinks, images, chain
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .details: return "Details"
        case .inlinks: return "Inlinks"
        case .outlinks: return "Outlinks"
        case .images: return "Images"
        case .chain: return "Redirect Chain"
        }
    }
}

/// The bottom pane: everything about the selected URL that no column has room
/// for. Each pane is one small indexed query, run when the selection changes.
public struct InspectorView: View {
    private let detail: URLDetail?
    private let inlinks: InspectorRows<LinkRow>?
    private let outlinks: InspectorRows<LinkRow>?
    private let images: InspectorRows<ImageRow>?
    private let chain: [RedirectHop]
    @State private var pane: InspectorPane = .details

    public init(detail: URLDetail?, inlinks: InspectorRows<LinkRow>?,
                outlinks: InspectorRows<LinkRow>?, images: InspectorRows<ImageRow>?,
                chain: [RedirectHop] = []) {
        self.detail = detail
        self.inlinks = inlinks
        self.outlinks = outlinks
        self.images = images
        self.chain = chain
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(panes) { Text(label(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            if detail == nil {
                placeholder("Select a row to inspect it")
            } else {
                content
            }
        }
        .frame(minHeight: 140)
    }

    /// The chain pane appears only for a URL that actually redirects — an
    /// always-present pane reading "not a redirect" on every ordinary page is
    /// noise in a bar that is only five items wide.
    private var panes: [InspectorPane] {
        InspectorPane.allCases.filter { $0 != .chain || chain.count > 1 }
    }

    /// Counts live in the tab labels so the cost of a page is visible before
    /// clicking into it.
    private func label(for pane: InspectorPane) -> String {
        switch pane {
        case .details: return pane.title
        case .inlinks: return count(inlinks?.total, pane.title)
        case .outlinks: return count(outlinks?.total, pane.title)
        case .images: return count(images?.total, pane.title)
        case .chain: return "\(pane.title) (\(max(chain.count - 1, 0)))"
        }
    }

    private func count(_ total: Int?, _ title: String) -> String {
        guard let total else { return title }
        return "\(title) (\(total))"
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .details:
            detailsList
        case .inlinks:
            linkList(inlinks, empty: "Nothing links here")
        case .outlinks:
            linkList(outlinks, empty: "This page links nowhere")
        case .images:
            imageList
        case .chain:
            chainList
        }
    }

    private var detailsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(detail?.fields ?? []) { field in
                    HStack(alignment: .top, spacing: 10) {
                        Text(field.label)
                            .frame(width: 190, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        // An absent value reads as a dash rather than a blank, so
                        // "no title" is visibly different from a rendering gap.
                        Text(field.value ?? "–")
                            .textSelection(.enabled)
                            .foregroundStyle(field.value == nil ? .secondary : .primary)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
        }
    }

    private func linkList(_ rows: InspectorRows<LinkRow>?, empty: String) -> some View {
        Group {
            if let rows, !rows.items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        truncationNotice(rows.items.count, rows.total)
                        ForEach(rows.items) { link in
                            HStack(spacing: 10) {
                                Text(link.status.map(String.init) ?? "–")
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                                    .foregroundStyle(statusColour(link.status))
                                Text(link.url).lineLimit(1).truncationMode(.middle)
                                Text(link.anchor ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                                if let rel = link.rel {
                                    Text(rel).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            } else {
                placeholder(empty)
            }
        }
    }

    private var imageList: some View {
        Group {
            if let images, !images.items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        truncationNotice(images.items.count, images.total)
                        ForEach(images.items) { image in
                            HStack(spacing: 10) {
                                Text(image.status.map(String.init) ?? "–")
                                    .monospacedDigit()
                                    .frame(width: 40, alignment: .trailing)
                                    .foregroundStyle(statusColour(image.status))
                                Text(image.url).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(image.alt ?? "no alt text")
                                    .foregroundStyle(image.alt == nil ? .orange : .secondary)
                                    .lineLimit(1)
                                Text(image.bytes.map { "\($0 / 1024) KB" } ?? "–")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(10)
                }
            } else {
                placeholder("This page uses no images")
            }
        }
    }

    private var chainList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(chain) { hop in
                    HStack(spacing: 10) {
                        Text("\(hop.id + 1)")
                            .monospacedDigit().frame(width: 22, alignment: .trailing)
                            .foregroundStyle(.secondary)
                        Text(hop.status.map(String.init) ?? "–")
                            .monospacedDigit().frame(width: 40, alignment: .trailing)
                            .foregroundStyle(statusColour(hop.status))
                        Text(hop.url).lineLimit(1).truncationMode(.middle)
                        if hop.isLoop {
                            Text("loop closes here")
                                .font(.caption).foregroundStyle(.red)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(10)
        }
    }

    /// The cap is stated rather than applied silently: a page with 4,000 inlinks
    /// showing 1,000 of them must not look like a page with 1,000 inlinks.
    @ViewBuilder
    private func truncationNotice(_ shown: Int, _ total: Int) -> some View {
        if shown < total {
            Text("Showing the first \(shown) of \(total).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        }
    }

    private func statusColour(_ status: Int?) -> Color {
        guard let status else { return .secondary }
        if status == 0 || status >= 500 { return .red }
        if status >= 400 { return .orange }
        if status >= 300 { return .yellow }
        return .secondary
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(text).foregroundStyle(.secondary)
                Spacer()
            }
            Spacer()
        }
    }
}
