import CoreText
import Foundation

/// Measures title and description text the way a search result page would.
///
/// Character counts are a poor proxy for what actually gets truncated: at 20px
/// Arial, twenty W's is 378 pixels and twenty i's is 89, yet both are "20
/// characters". Measured rather than estimated, using CoreText — which is a
/// text-layout framework, not a UI one, so `KodaCore` stays headless.
public enum SERPMetrics {
    /// Google renders desktop result titles at roughly 20px Arial and snippets
    /// at roughly 14px. These are observed conventions rather than a published
    /// contract, and Google changes them; they are a guide, not a guarantee.
    public static let titleFont = "Arial"
    public static let titleSize: Double = 20
    public static let descriptionSize: Double = 14

    /// Widely-used truncation thresholds for desktop results. Same caveat: a
    /// guide, not a contract.
    public static let titleLimit: Double = 561
    public static let descriptionLimit: Double = 985

    /// Width in points, or nil for text that is empty or unmeasurable.
    public static func width(_ text: String?, size: Double) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        let font = CTFontCreateWithName(titleFont as CFString, size, nil)
        let attributed = NSAttributedString(
            string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return width.isFinite && width >= 0 ? width : nil
    }

    public static func titleWidth(_ text: String?) -> Double? { width(text, size: titleSize) }
    public static func descriptionWidth(_ text: String?) -> Double? {
        width(text, size: descriptionSize)
    }
}
