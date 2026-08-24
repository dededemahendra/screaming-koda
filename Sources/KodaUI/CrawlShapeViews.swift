import KodaCore
import SwiftUI

/// The site as a folder tree.
///
/// Built from URL paths rather than from links, because people think about a
/// site as folders — and a link-derived tree would put a page under whichever
/// page happened to link to it first, which is an accident of crawl order.
public struct SiteTreeView: View {
    private let root: SiteTreeNode?
    private let onSelect: (Int64) -> Void

    public init(root: SiteTreeNode?, onSelect: @escaping (Int64) -> Void = { _ in }) {
        self.root = root
        self.onSelect = onSelect
    }

    public var body: some View {
        Group {
            if let root, !root.children.isEmpty {
                List(root.children, children: \.optionalChildren) { node in
                    row(node)
                }
                .listStyle(.sidebar)
            } else {
                placeholder("Crawl a site to see its shape")
            }
        }
    }

    private func row(_ node: SiteTreeNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.isFolder ? "folder" : "doc.text")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(node.name).lineLimit(1)
            if node.urlID == nil, node.isFolder {
                Text("folder only").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if node.issueCount > 0 {
                Text("\(node.issueCount)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.orange)
                    .help("Non-indexable pages here or below")
            }
            Text("\(node.pageCount)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let id = node.urlID { onSelect(id) } }
    }

    private func placeholder(_ text: String) -> some View {
        VStack { Spacer(); Text(text).foregroundStyle(.secondary); Spacer() }
    }
}

private extension SiteTreeNode {
    /// `List(children:)` wants nil rather than an empty array for a leaf, or it
    /// draws a disclosure arrow on every page.
    var optionalChildren: [SiteTreeNode]? { children.isEmpty ? nil : children }
}

/// The internal link graph, laid out by crawl depth.
///
/// Depth columns rather than a force-directed layout: force simulation looks
/// impressive and tells you almost nothing, whereas depth is the thing an SEO
/// crawl is actually about — how far from the entry point a page sits, and
/// whether anything links across.
public struct LinkGraphView: View {
    private let graph: CrawlGraph?
    @State private var hovered: Int64?

    public init(graph: CrawlGraph?) { self.graph = graph }

    public var body: some View {
        Group {
            if let graph, !graph.nodes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    caption(graph)
                    Divider()
                    GeometryReader { geometry in
                        Canvas { context, size in
                            draw(graph, in: context, size: size)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            } else {
                VStack { Spacer()
                    Text("Crawl a site to see how it links together")
                        .foregroundStyle(.secondary)
                    Spacer() }
            }
        }
    }

    private func caption(_ graph: CrawlGraph) -> some View {
        HStack(spacing: 14) {
            Label("\(graph.nodes.count) pages", systemImage: "circle.grid.2x2")
            Label("\(graph.edges.count) links", systemImage: "arrow.triangle.branch")
            Label("depth 0–\(graph.maxDepth)", systemImage: "arrow.down.right")
            if graph.isTruncated {
                // Stated rather than hidden: a capped diagram that looks complete
                // is worse than no diagram.
                Text("showing the \(graph.nodes.count) most-linked of \(graph.totalNodes)")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.caption)
        .padding(8)
    }

    /// Positions every node once, so edges and nodes agree.
    static func layout(_ graph: CrawlGraph, size: CGSize) -> [Int64: CGPoint] {
        let columns = max(graph.maxDepth + 1, 1)
        let columnWidth = size.width / CGFloat(columns + 1)
        var byDepth: [Int: [GraphNode]] = [:]
        for node in graph.nodes { byDepth[node.depth, default: []].append(node) }

        var points: [Int64: CGPoint] = [:]
        for (depth, nodes) in byDepth {
            let spacing = size.height / CGFloat(nodes.count + 1)
            for (index, node) in nodes.enumerated() {
                points[node.id] = CGPoint(x: columnWidth * CGFloat(depth + 1),
                                          y: spacing * CGFloat(index + 1))
            }
        }
        return points
    }

    private func draw(_ graph: CrawlGraph, in context: GraphicsContext, size: CGSize) {
        let points = Self.layout(graph, size: size)

        // Edges first, so nodes sit on top of them.
        var path = Path()
        for edge in graph.edges {
            guard let from = points[edge.from], let to = points[edge.to] else { continue }
            path.move(to: from)
            // A gentle curve rather than a straight line: parallel straight
            // lines between two columns overlap into a single smear.
            let midX = (from.x + to.x) / 2
            path.addCurve(to: to,
                          control1: CGPoint(x: midX, y: from.y),
                          control2: CGPoint(x: midX, y: to.y))
        }
        context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 0.75)

        for node in graph.nodes {
            guard let point = points[node.id] else { continue }
            // Size carries inlink count: the pages everything points at should
            // be the ones you see first.
            let radius = 3 + min(CGFloat(node.inlinks), 12) * 0.7
            let rect = CGRect(x: point.x - radius, y: point.y - radius,
                              width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect),
                         with: .color(node.indexable ? .accentColor : .orange))
        }
    }
}
