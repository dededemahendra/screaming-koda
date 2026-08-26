import AppKit
import Foundation
import SwiftUI
import Testing
@testable import KodaCore
@testable import KodaUI

private func node(_ id: Int64, depth: Int, inlinks: Int = 1,
                  indexable: Bool = true) -> GraphNode {
    GraphNode(id: id, url: "https://s.test/\(id)", label: "\(id)",
              depth: depth, indexable: indexable, inlinks: inlinks)
}

/// Edges and nodes must be positioned by the same pass, or the lines land
/// somewhere other than the circles they claim to join.
@MainActor
@Test func everyNodeGetsAPositionInsideTheCanvas() {
    let graph = CrawlGraph(
        nodes: [node(1, depth: 0), node(2, depth: 1), node(3, depth: 1), node(4, depth: 3)],
        edges: [GraphEdge(from: 1, to: 2), GraphEdge(from: 1, to: 3)],
        totalNodes: 4)
    let size = CGSize(width: 800, height: 600)
    let points = LinkGraphView.layout(graph, size: size)

    #expect(points.count == graph.nodes.count)
    for (_, point) in points {
        #expect(point.x > 0 && point.x < size.width)
        #expect(point.y > 0 && point.y < size.height)
    }
}

/// Depth is the axis, because depth is what an SEO crawl is about: a page four
/// clicks from the entry point should look four clicks away.
@MainActor
@Test func deeperPagesSitFurtherAcross() {
    let graph = CrawlGraph(nodes: [node(1, depth: 0), node(2, depth: 1), node(3, depth: 4)],
                           edges: [], totalNodes: 3)
    let points = LinkGraphView.layout(graph, size: CGSize(width: 900, height: 400))
    let x = { (id: Int64) in points[id]!.x }
    #expect(x(1) < x(2))
    #expect(x(2) < x(3))
}

/// Two pages at the same depth must not land on top of each other.
@MainActor
@Test func pagesAtTheSameDepthAreSpreadOut() {
    let nodes = (1...5).map { node(Int64($0), depth: 2) }
    let points = LinkGraphView.layout(
        CrawlGraph(nodes: nodes, edges: [], totalNodes: 5), size: CGSize(width: 600, height: 500))
    let ys = Set(points.values.map(\.y))
    #expect(ys.count == 5)
    #expect(Set(points.values.map(\.x)).count == 1, "same depth, same column")
}

@MainActor
@Test func anEmptyGraphLaysOutWithoutDividingByZero() {
    let points = LinkGraphView.layout(CrawlGraph(nodes: [], edges: [], totalNodes: 0),
                                      size: CGSize(width: 500, height: 500))
    #expect(points.isEmpty)
}

// MARK: - They actually draw

/// Rendered rather than merely constructed. A SwiftUI view that compiles can
/// still fail to produce anything, and these two are the only views in the app
/// that draw rather than lay out text.
@MainActor
private func renders(_ view: some View, size: CGSize) -> Bool {
    let renderer = ImageRenderer(content: AnyView(view.frame(width: size.width,
                                                            height: size.height)))
    renderer.scale = 1
    guard let image = renderer.nsImage, image.size.width > 0 else { return false }
    return true
}

@MainActor
@Test func theTreeViewRendersRealContent() throws {
    let child = SiteTreeNode(id: "/blog/one", name: "one", urlID: 2, status: 200,
                             pageCount: 1, issueCount: 0, children: [])
    let blog = SiteTreeNode(id: "/blog", name: "blog", urlID: 1, status: 200,
                            pageCount: 2, issueCount: 1, children: [child])
    let root = SiteTreeNode(id: "/", name: "/", urlID: nil, status: nil,
                            pageCount: 2, issueCount: 1, children: [blog])
    #expect(renders(SiteTreeView(root: root), size: CGSize(width: 320, height: 400)))
    #expect(renders(SiteTreeView(root: nil), size: CGSize(width: 320, height: 400)),
            "and the empty state draws too")
}

@MainActor
@Test func theGraphViewRendersRealContent() {
    let graph = CrawlGraph(
        nodes: (1...20).map { node(Int64($0), depth: $0 % 4, inlinks: $0,
                                   indexable: $0 % 5 != 0) },
        edges: (2...20).map { GraphEdge(from: 1, to: Int64($0)) },
        totalNodes: 60)
    #expect(renders(LinkGraphView(graph: graph), size: CGSize(width: 800, height: 500)))
    #expect(renders(LinkGraphView(graph: nil), size: CGSize(width: 800, height: 500)))
}

@MainActor
@Test func theTreeAndGraphDrawWithNothingToShow() {
    ViewCapture.expectNotBlank(SiteTreeView(root: nil, onSelect: { _ in })
                                 .frame(width: 700, height: 400),
                               size: CGSize(width: 700, height: 400), "the empty site tree")
    ViewCapture.expectNotBlank(LinkGraphView(graph: nil)
                                 .frame(width: 700, height: 400),
                               size: CGSize(width: 700, height: 400), "the empty link graph")
}
