import AppKit
import FolioCore

/// Draws tag capsules in a list cell. Each chip is capped at ~6 CJK characters and truncated with
/// "…"; chips that do not fit collapse into "+N" (TAG-05).
final class TagChipsView: NSView {
    static let maxChipWidth: CGFloat = 90
    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let spacing: CGFloat = 4
    private static let padding: CGFloat = 7

    var tags: [Tag] = [] {
        didSet {
            needsDisplay = true
            toolTip = tags.isEmpty ? nil : tags.map(\.name).joined(separator: "、")
            setAccessibilityValue(tags.map(\.name).joined(separator: ","))
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let height: CGFloat = 18
        let y = (bounds.height - height) / 2
        var x: CGFloat = 2
        let limit = bounds.width - 2
        for (index, tag) in tags.enumerated() {
            var width = Self.chipWidth(tag.name)
            let remaining = tags.count - index - 1
            let reserve: CGFloat = remaining > 0 ? Self.badgeWidth(remaining) + Self.spacing : 0
            if x + width + reserve > limit {
                guard index == 0 else {
                    drawBadge("+\(tags.count - index)", x: x, y: y, height: height)
                    return
                }
                // Always show the first tag, truncated to the space left.
                width = max(limit - x - reserve, 28)
            }
            drawChip(tag, x: x, y: y, width: width, height: height)
            x += width + Self.spacing
        }
    }

    static func chipWidth(_ name: String) -> CGFloat {
        let text = (name as NSString).size(withAttributes: [.font: font]).width
        return min(ceil(text) + padding * 2, maxChipWidth)
    }

    private static func badgeWidth(_ count: Int) -> CGFloat {
        ceil(("+\(count)" as NSString).size(withAttributes: [.font: font]).width) + padding * 2
    }

    private func drawChip(_ tag: Tag, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let color = NSColor(hex: tag.colorHex)
        let rect = NSRect(x: x, y: y, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2)
        color.withAlphaComponent(0.22).setFill()
        path.fill()
        color.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 0.75
        path.stroke()
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let textColor = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? color.blended(withFraction: 0.45, of: .white) ?? color
            : color.blended(withFraction: 0.35, of: .black) ?? color
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: textColor, .paragraphStyle: style]
        let textRect = rect.insetBy(dx: Self.padding, dy: 0)
        let lineHeight = Self.font.boundingRectForFont.height
        (tag.name as NSString).draw(with: NSRect(x: textRect.minX, y: y + (height - lineHeight) / 2 + 1,
                                                 width: textRect.width, height: lineHeight),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                    attributes: attributes)
    }

    private func drawBadge(_ text: String, x: CGFloat, y: CGFloat, height: CGFloat) {
        let width = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width) + Self.padding * 2
        let rect = NSRect(x: x, y: y, width: width, height: height)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        let lineHeight = Self.font.boundingRectForFont.height
        (text as NSString).draw(at: NSPoint(x: x + Self.padding, y: y + (height - lineHeight) / 2 + 1),
                                withAttributes: [.font: Self.font, .foregroundColor: NSColor.secondaryLabelColor])
    }
}
