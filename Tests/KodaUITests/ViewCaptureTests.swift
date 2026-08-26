import SwiftUI
import Testing

/// The utility has to fail on a genuinely blank view, or every assertion built
/// on it is worthless. This is the control case.
@MainActor
@Test func anEmptyViewCapturesAsOneColour() throws {
    let rep = try #require(ViewCapture.bitmap(of: Color.clear.frame(width: 200, height: 80),
                                              size: CGSize(width: 200, height: 80)))
    #expect(ViewCapture.distinctColours(rep) == 1)
}

@MainActor
@Test func aViewWithTextCapturesManyColours() throws {
    let view = VStack {
        Text("Breaks indexing").font(.headline)
        Text("404")
    }
    .frame(width: 300, height: 120)
    let rep = try #require(ViewCapture.bitmap(of: view, size: CGSize(width: 300, height: 120)))
    // Antialiased glyph edges alone put this in the dozens; the design probe
    // measured 107. Ten is a floor that only a blank capture falls below.
    #expect(ViewCapture.distinctColours(rep) > 10)
}
