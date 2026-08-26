import SwiftUI
import Testing
@testable import KodaCore
@testable import KodaUI

@MainActor
@Test func theInspectorDrawsItsPlaceholderWithNothingSelected() {
    ViewCapture.expectNotBlank(
        InspectorView(detail: nil, inlinks: nil, outlinks: nil, images: nil)
            .frame(width: 900, height: 240),
        size: CGSize(width: 900, height: 240), "the inspector with no selection")
}

/// The inspector was reported blank during design and was not — the capture
/// had a transparent ground. This is the assertion that settles it, over an
/// opaque one.
@MainActor
@Test func theInspectorDrawsADetailPane() {
    let detail = URLDetail(id: 1, url: "https://example.com/", fields: [
        DetailField(label: "Address", value: "https://example.com/"),
        DetailField(label: "Status", value: "200"),
        DetailField(label: "Title", value: nil),
    ])
    ViewCapture.expectNotBlank(
        InspectorView(detail: detail, inlinks: nil, outlinks: nil, images: nil)
            .frame(width: 900, height: 240),
        size: CGSize(width: 900, height: 240), "the inspector detail pane")
}
