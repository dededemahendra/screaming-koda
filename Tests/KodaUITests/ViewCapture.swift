import AppKit
import SwiftUI
import Testing

/// Renders a SwiftUI view to a bitmap so a test can assert it drew something.
///
/// **The opaque ground is not optional.** A view that paints no background
/// composites as transparent, and `cacheDisplay` leaves those regions
/// uninitialised rather than clearing them — so a perfectly good view captures
/// as noise or as nothing, and reads as a rendering failure. Two views were
/// wrongly diagnosed as broken during design before this was understood.
/// Hosting over `windowBackgroundColor` is what makes the capture mean
/// something.
///
/// The run-loop turns matter too: SwiftUI lays out and draws asynchronously,
/// and a capture taken immediately after `layoutIfNeeded` catches an empty
/// frame.
@MainActor
enum ViewCapture {
    static func bitmap<V: View>(of view: V, size: CGSize) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // A window, not a bare view: SwiftUI needs one to resolve environment
        // values and to run its layout pass at all.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        for _ in 0..<8 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// Samples every other pixel in both directions. A full scan of a
    /// 1100x660 window is 726,000 `colorAt` calls per assertion, which is slow
    /// enough to notice across a dozen view tests; every second pixel cannot
    /// miss a glyph.
    static func distinctColours(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let r = UInt32(colour.redComponent * 255)
                let g = UInt32(colour.greenComponent * 255)
                let b = UInt32(colour.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
            }
        }
        return seen.count
    }

    /// The assertion every view test uses, so the failure message names the
    /// view rather than reading "expected 1 > 10".
    static func expectNotBlank<V: View>(_ view: V, size: CGSize,
                                        atLeast: Int = 10, _ label: String,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        guard let rep = bitmap(of: view, size: size) else {
            Issue.record("\(label): could not build a bitmap", sourceLocation: sourceLocation)
            return
        }
        let colours = distinctColours(rep)
        #expect(colours >= atLeast,
                "\(label) drew \(colours) distinct colours, which reads as blank",
                sourceLocation: sourceLocation)
    }
}
