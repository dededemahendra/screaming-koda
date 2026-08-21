import AppKit
import Testing
@testable import KodaUI

@MainActor
@Test func everyVisibleColumnMapsToASortColumn() {
    #expect(URLTableColumn.address.sortColumn == .address)
    #expect(URLTableColumn.status.sortColumn == .status)
    #expect(URLTableColumn.title.sortColumn == .title)
    #expect(URLTableColumn.depth.sortColumn == .depth)
}

@MainActor
@Test func everySelectableSortHasAColumn() {
    let mapped = Set(URLTableColumn.allCases.map(\.sortColumn))
    for sort in SortColumn.selectable {
        #expect(mapped.contains(sort), "\(sort) has no column header to click")
    }
}

@MainActor
@Test func discoveryOrderIsNotClickable() {
    #expect(!SortColumn.selectable.contains(.discoveryOrder),
            "discovery order is the default state, not a column")
}

@MainActor
@Test func aSortDescriptorMapsToColumnAndDirection() {
    let descriptor = NSSortDescriptor(key: URLTableColumn.status.rawValue, ascending: false)
    let resolved = URLTableCoordinator.sort(from: descriptor)
    #expect(resolved?.column == .status)
    #expect(resolved?.ascending == false)
}

@MainActor
@Test func anUnknownSortDescriptorResolvesToNil() {
    let descriptor = NSSortDescriptor(key: "nonsense", ascending: true)
    #expect(URLTableCoordinator.sort(from: descriptor) == nil)
}
