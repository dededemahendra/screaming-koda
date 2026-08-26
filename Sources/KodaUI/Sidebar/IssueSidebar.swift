import KodaCore
import SwiftUI

/// What is wrong with this site, ranked, over the reports it came from.
///
/// The old sidebar listed 163 filters under 26 headings whether or not any of
/// them found anything, on the argument that a stable list is easier to scan
/// than one that reorders. At eleven reports that held. At twenty-six it means
/// the four findings that matter are somewhere in a list of a hundred and
/// sixty, so the bands show only what was actually found and the full list
/// stays available below the divider.
public struct IssueSidebar: View {
    private let reports: [Report]
    private let counts: [String: Int]
    private let crawlName: String?
    private let selectedReportID: String
    private let selectedFilterID: String
    private let onSelect: (String, String) -> Void

    @State private var search = ""
    @State private var expanded: Set<String> = []

    public init(reports: [Report] = Reports.all, counts: [String: Int],
                crawlName: String?, selectedReportID: String, selectedFilterID: String,
                onSelect: @escaping (String, String) -> Void) {
        self.reports = reports
        self.counts = counts
        self.crawlName = crawlName
        self.selectedReportID = selectedReportID
        self.selectedFilterID = selectedFilterID
        self.onSelect = onSelect
    }

    private var bands: [SidebarBand] {
        SidebarModel.bands(reports: reports, counts: counts, search: search)
    }

    private var sections: [SidebarSection] {
        SidebarModel.sections(reports: reports, counts: counts, search: search)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                ForEach(bands) { band in
                    Section {
                        ForEach(band.items) { row($0) }
                    } header: {
                        HStack(spacing: Theme.Space.small) {
                            Text(band.severity.title).font(Theme.Face.title)
                            Spacer()
                            Text(band.total.formatted())
                                .font(Theme.Numeral.caption)
                                .foregroundStyle(Theme.ink(for: band.severity).color)
                        }
                    }
                }
                ForEach(sections) { section in
                    DisclosureGroup(isExpanded: expansion(of: section.reportID)) {
                        ForEach(section.items) { row($0) }
                    } label: {
                        Text(section.reportName).font(Theme.Face.label)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .onAppear { expanded.insert(selectedReportID) }
        .onChange(of: selectedReportID) { _, new in expanded.insert(new) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.hair) {
            Text(crawlName ?? "No crawl").font(Theme.Face.title).lineLimit(1)
            Text(SidebarModel.findingSummary(
                    SidebarModel.findingTotal(reports: reports, counts: counts)))
                .font(Theme.Numeral.caption)
                .foregroundStyle(Theme.Ink.quiet.color)
            // A plain field rather than `.searchable`. That modifier places its
            // field in a navigation container's own chrome, and this sidebar
            // does not live in one — so it had nowhere to go and simply never
            // appeared, leaving a tested narrowing rule with no way to reach it.
            TextField("Filter findings and reports", text: $search)
                .textFieldStyle(.roundedBorder)
                .font(Theme.Face.label)
                .padding(.top, Theme.Space.tight)
        }
        .padding(.horizontal, Theme.Space.medium)
        .padding(.vertical, Theme.Space.small)
    }

    /// The report being viewed is open and the rest are closed. Opening one by
    /// hand keeps it open — the set is only ever added to here, so navigating
    /// away does not collapse what the user deliberately opened.
    private func expansion(of reportID: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(reportID) },
                set: { isOn in
                    if isOn { expanded.insert(reportID) } else { expanded.remove(reportID) }
                })
    }

    private func row(_ item: SidebarItem) -> some View {
        let isSelected = item.reportID == selectedReportID
            && item.filterID == selectedFilterID
        return Button {
            onSelect(item.reportID, item.filterID)
        } label: {
            HStack(spacing: Theme.Space.small) {
                Text(item.filterName)
                    .font(Theme.Face.label)
                    .foregroundStyle(isSelected ? Color.primary : Theme.Ink.quiet.color)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.tight)
                // An en dash, not 0: before the crawl has counted a filter we
                // do not know the answer, and 0 is an answer.
                Text(item.count.map { $0.formatted() } ?? "–")
                    .font(Theme.Numeral.caption)
                    .foregroundStyle(countInk(item))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected
                           ? Theme.Ink.accent.color.opacity(0.18) : Color.clear)
    }

    /// Colour marks exceptions. A count of zero, and every navigation row, is
    /// unremarkable and stays quiet; a finding that found something takes its
    /// band's ink.
    private func countInk(_ item: SidebarItem) -> Color {
        guard let count = item.count, count > 0, let severity = item.severity
        else { return Theme.Ink.quiet.color.opacity(0.6) }
        return Theme.ink(for: severity).color
    }
}
