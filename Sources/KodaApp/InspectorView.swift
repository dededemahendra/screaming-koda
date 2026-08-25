import KodaCore
import KodaUI
import SwiftUI

/// Everything known about the selected URL. Each pane is one small query keyed
/// on the URL's id, so opening the inspector on a large crawl costs nothing.
struct InspectorView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let detail = model.selectedDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(detail)
                        facts(detail)
                        links("Outlinks", model.outlinks)
                        links("Inlinks", model.inlinks)
                        images
                        // Only when there are any: most sites have none, and an
                        // empty pane on every selection is noise.
                        if !model.selectedHreflang.isEmpty { hreflang }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("No selection", systemImage: "sidebar.right",
                                       description: Text("Select a row to inspect it."))
            }
        }
        .frame(minWidth: 260)
    }

    private func header(_ detail: URLDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.url)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let url = URL(string: detail.url), url.scheme?.hasPrefix("http") == true {
                    Link(destination: url) {
                        Label("Open", systemImage: "arrow.up.forward.square")
                    }
                    .font(.caption)
                }
                StatusBadge(status: detail.status, errorKind: detail.errorKind)
                Text("Depth \(detail.depth)").foregroundStyle(.secondary)
                if !detail.isInternal {
                    Text("External").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private func facts(_ detail: URLDetail) -> some View {
        Section("Details") {
            LabeledContent("Title", value: detail.title ?? "—")
            LabeledContent("Meta description", value: detail.metaDescription ?? "—")
            LabeledContent("H1", value: detail.h1 ?? "—")
            LabeledContent("H2s", value: detail.h2Count.map(String.init) ?? "—")
            LabeledContent("Canonical", value: detail.canonical ?? "—")
            LabeledContent("Meta robots", value: detail.metaRobots ?? "—")
            LabeledContent("X-Robots-Tag", value: detail.xRobotsTag ?? "—")
            LabeledContent("Language", value: detail.lang ?? "—")
            LabeledContent("Words", value: detail.wordCount.map(String.init) ?? "—")
            LabeledContent("Content type", value: detail.contentType ?? "—")
            LabeledContent("Size", value: detail.contentLength.map { "\($0) bytes" } ?? "—")
            LabeledContent("Response time", value: detail.responseTimeMs.map { "\($0) ms" } ?? "—")
            if let target = detail.redirectTarget {
                LabeledContent("Redirects to", value: target)
            }
        }
        .labeledContentStyle(.automatic)
        .font(.caption)
    }

    private func links(_ title: String, _ rows: [LinkRow]) -> some View {
        Section("\(title) (\(rows.count))") {
            if rows.isEmpty {
                Text("None").foregroundStyle(.secondary).font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(indexed(rows, limit: 50)) { item in
                        let link = item.value
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            StatusBadge(status: link.status, errorKind: nil)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(link.url).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                                if let anchor = link.anchor, !anchor.isEmpty {
                                    Text(anchor).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    if rows.count > 50 {
                        Text("… and \(rows.count - 50) more").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var hreflang: some View {
        Section("Hreflang (\(model.selectedHreflang.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(indexed(model.selectedHreflang)) { item in
                    let alternate = item.value
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        StatusBadge(status: alternate.status, errorKind: nil)
                        Text(alternate.lang)
                            .font(.caption2.bold())
                            .frame(minWidth: 46, alignment: .leading)
                        Text(alternate.url)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var images: some View {
        Section("Images (\(model.selectedImages.count))") {
            if model.selectedImages.isEmpty {
                Text("None").foregroundStyle(.secondary).font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(indexed(model.selectedImages)) { item in
                        let image = item.value
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            StatusBadge(status: image.status, errorKind: nil)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(image.url).font(.system(.caption2, design: .monospaced)).lineLimit(1)
                                Text(image.alt.map { $0.isEmpty ? "no alt" : $0 } ?? "no alt")
                                    .font(.caption2)
                                    .foregroundStyle(image.alt?.isEmpty == false ? Color.secondary : Color.red)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Positional identity for rows that have no natural id.
///
/// Built with `map` rather than `Array(...)`: GRDB adds an `Array(cursor:)`
/// initialiser that wins overload resolution against `Array(someSequence)` here,
/// even when qualified.
struct Indexed<Value>: Identifiable {
    let id: Int
    let value: Value
}

func indexed<Value>(_ values: [Value], limit: Int = .max) -> [Indexed<Value>] {
    values.prefix(limit).enumerated().map { Indexed(id: $0.offset, value: $0.element) }
}

/// Status codes are the thing the eye looks for first, so they get colour.
struct StatusBadge: View {
    let status: Int?
    let errorKind: String?

    var body: some View {
        Text(label)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(colour.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(colour)
            .help(errorKind ?? label)
    }

    private var label: String {
        guard let status else { return "—" }
        return status == 0 ? "ERR" : "\(status)"
    }

    private var colour: Color {
        guard let status else { return .secondary }
        switch status {
        case 0: return .purple
        case 200..<300: return .green
        case 300..<400: return .orange
        default: return .red
        }
    }
}
