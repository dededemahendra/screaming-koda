import KodaCore
import KodaUI
import SwiftUI

/// Overview counts and the report list. Each row's number is a `COUNT(*)` over
/// the same query its table uses, so the sidebar can never disagree with the
/// table it leads to.
struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedReportID },
            set: { model.select(reportID: $0 ?? model.selectedReportID) }
        )) {
            if let summary = model.summary {
                Section("Overview") {
                    overview("URLs discovered", summary.totalURLs)
                    overview("Crawled", summary.crawledURLs)
                    overview("Internal", summary.internalURLs)
                    overview("External", summary.externalURLs)
                    overview("Max depth", summary.maxDepth)
                    if let meta = model.meta {
                        HStack {
                            Text(meta.isFinished ? "Crawled" : "Stopped")
                            Spacer()
                            Text(meta.startedAt, format: .dateTime.day().month().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .selectionDisabled()
                        // Only a finished crawl knows how long it took. A stopped
                        // one has no end time, and timing it against the clock
                        // would say a crawl abandoned last week took a week.
                        .help(meta.duration.map {
                            "Took \(Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds])))"
                        } ?? "Stopped before it finished")
                    }
                }
            }

            ForEach(model.visibleGroups, id: \.group) { group in
                Section(group.group) {
                    ForEach(group.reports) { report in
                        HStack {
                            Text(report.name)
                            Spacer()
                            Text("\(model.reportCounts[report.id] ?? 0)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .tag(report.id)
                        .help(report.summary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Toggle("Show empty reports", isOn: $model.showsEmptyReports)
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(8)
        }
    }

    private func overview(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.caption)
        .selectionDisabled()
    }
}
