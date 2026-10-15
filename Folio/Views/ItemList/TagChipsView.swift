import AppKit
import FolioCore

/// Draws tag capsules in a list cell. Each chip is capped at ~6 CJK characters and truncated with
/// "…"; chips that do not fit collapse into "+N" (TAG-05).
final class TagChipsView: NSView {
    static let maxChipWidth: CGFloat = 90
    private static let font = CapsuleLabel.tagFont
    private static let spacing: CGFloat = 4
    private static let padding = CapsuleLabel.tagPadding

    var tags: [Tag] = [] {
        didSet {
            needsDisplay = true
            toolTip = tags.isEmpty ? nil : tags.map(\.name).joined(separator: "、")
            setAccessibilityValue(tags.map(\.name).joined(separator: ","))
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let height = CapsuleLabel.tagHeight
        let scale = window?.backingScaleFactor ?? 2
        let y = ((bounds.height - height) / 2 * scale).rounded() / scale
        var x: CGFloat = 2
        let limit = bounds.width - 2
        for (index, tag) in tags.enumerated() {
            var width = Self.chipWidth(tag.name)
            let remaining = tags.count - index - 1
            let reserve: CGFloat = remaining > 0 ? Self.badgeWidth(remaining) + Self.spacing : 0
            if x + width + reserve > limit {
                guard index == 0 else {
                    drawCount("+\(tags.count - index)", x: x, y: y, height: height, scale: scale)
                    return
                }
                // Always show the first tag, truncated to the space left.
                width = max(limit - x - reserve, 28)
            }
            CapsuleLabel.draw(tag.name, in: NSRect(x: x, y: y, width: width, height: height), tint: NSColor(hex: tag.colorHex),
                              font: Self.font, padding: Self.padding, appearance: effectiveAppearance, flipped: true, scale: scale)
            x += width + Self.spacing
        }
    }

    static func chipWidth(_ name: String) -> CGFloat {
        min(CapsuleLabel.textWidth(name, font: font) + padding * 2, maxChipWidth)
    }

    private static func badgeWidth(_ count: Int) -> CGFloat {
        CapsuleLabel.textWidth("+\(count)", font: font) + padding * 2
    }

    /// "+N": the tags that did not fit, in a neutral capsule.
    private func drawCount(_ text: String, x: CGFloat, y: CGFloat, height: CGFloat, scale: CGFloat) {
        let rect = NSRect(x: x, y: y, width: Self.badgeWidth(Int(text.dropFirst()) ?? 0), height: height)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        CapsuleLabel.drawText(text, in: rect.insetBy(dx: Self.padding, dy: 0), color: .secondaryLabelColor, font: Self.font,
                              flipped: true, scale: scale)
    }
}
