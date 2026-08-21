import KodaCore
import SwiftUI

/// Reports and their issue counts.
///
/// Every filter is listed whether or not it found anything, and a zero count is
/// greyed rather than hidden: a list that reorders or shrinks itself mid-crawl
/// is far harder to scan than a stable one, and "we checked, it's clean" is
/// itself worth showing.
public struct SidebarView: View {
    private let counts: [String: Int]
    private let selectedReportID: String
    private let selectedFilterID: String
    private let onSelect: (String, String) -> Void

    public init(counts: [String: Int], selectedReportID: String, selectedFilterID: String,
                onSelect: @escaping (String, String) -> Void) {
        self.counts = counts
        self.selectedReportID = selectedReportID
        self.selectedFilterID = selectedFilterID
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            ForEach(Reports.all) { report in
                Section {
                    ForEach(report.filters) { filter in
                        row(report, filter)
                    }
                } header: {
                    Text(report.name).font(.headline)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 210, idealWidth: 240)
    }

    private func row(_ report: Report, _ filter: ReportFilter) -> some View {
        let count = counts["\(report.id).\(filter.id)"]
        let isSelected = report.id == selectedReportID && filter.id == selectedFilterID
        return Button {
            onSelect(report.id, filter.id)
        } label: {
            HStack {
                Text(filter.name)
                    .foregroundStyle(isSelected ? Color.primary : .secondary)
                Spacer()
                Text(count.map(String.init) ?? "–")
                    .monospacedDigit()
                    .foregroundStyle(countColour(filter: filter, count: count))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// An issue filter that found something is the one thing in this pane worth
    /// drawing the eye to.
    private func countColour(filter: ReportFilter, count: Int?) -> Color {
        guard let count, count > 0 else { return .secondary.opacity(0.5) }
        return filter.isIssue ? .orange : .secondary
    }
}
