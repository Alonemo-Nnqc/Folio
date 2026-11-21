import AppKit
import CoreText

/// Tinted capsules with optically centred text: tag chips (TAG-05) and the "默认" file badge.
///
/// Text is laid out with Core Text and drawn at an explicit baseline. AppKit's string drawing puts the
/// baseline below the top of the line box, and Chinese text falls back to PingFang, whose taller line
/// metrics push the glyphs down; centring the ink of a Latin capital and a CJK ideograph instead keeps
/// "默认", "Mamba" and "综述" all visually centred and on the same baseline.
enum CapsuleLabel {
    static let tagFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let tagHeight: CGFloat = 18
    static let badgeHeight: CGFloat = 16
    static let tagPadding: CGFloat = 7
    static let badgePadding: CGFloat = 5
    /// Badges ("已翻译", "默认", journal ranks) are small rounded rectangles; tags are capsules.
    static let badgeRadius: CGFloat = 4.5

    /// How wide a capsule for `text` is.
    /// (`capsule`: a tag's round ends; tags carry their colour in the fill, with no dot taking room before the name.)
    static func width(_ text: String, font: NSFont, padding: CGFloat, dot: Bool) -> CGFloat {
        textWidth(text, font: font) + padding * 2
    }

    // MARK: Colours

    /// Text colour for a tint: darker in light mode, lighter in dark mode, readable on the tinted fill.
    static func textColor(_ tint: NSColor, dark: Bool) -> NSColor {
        dark ? tint.blended(withFraction: 0.45, of: .white) ?? tint : tint.blended(withFraction: 0.38, of: .black) ?? tint
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: Metrics

    /// Distance from the baseline up to the optical centre of mixed Latin / CJK text.
    static func opticalCenter(_ font: NSFont) -> CGFloat {
        let key = "\(font.fontName)-\(font.pointSize)" as NSString
        if let cached = centerCache.object(forKey: key) { return CGFloat(cached.doubleValue) }
        let bounds = CTLineGetImageBounds(line(String(localized: "H汉"), font: font), nil)
        let center = bounds.isNull ? (font.capHeight / 2) : bounds.midY
        centerCache.setObject(NSNumber(value: Double(center)), forKey: key)
        return center
    }

    nonisolated(unsafe) private static let centerCache = NSCache<NSString, NSNumber>()

    static func line(_ text: String, font: NSFont) -> CTLine {
        // Set once per text and font: list cells and headers draw the same few texts again and again.
        let key = "\(font.fontName)|\(font.pointSize)|\(text)" as NSString
        if let cached = lineCache.object(forKey: key) { return cached.line }
        // The colour comes from the context's fill colour (`drawText`), not from the string.
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
        lineCache.setObject(LineBox(line: line), forKey: key)
        return line
    }

    private final class LineBox {
        let line: CTLine
        init(line: CTLine) { self.line = line }
    }

    nonisolated(unsafe) private static let lineCache: NSCache<NSString, LineBox> = {
        let cache = NSCache<NSString, LineBox>()
        cache.countLimit = 4000
        return cache
    }()

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil))
    }

    // MARK: Drawing

    /// The tinted fill behind a tag or badge: soft, with no outline.
    static func fill(_ tint: NSColor, dark: Bool) -> NSColor { tint.withAlphaComponent(dark ? 0.24 : 0.13) }

    /// A tag's fill: a little stronger than a badge's, since it alone shows the tag's colour.
    static func tagFill(_ tint: NSColor, dark: Bool) -> NSColor { tint.withAlphaComponent(dark ? 0.3 : 0.17) }

    /// Draws a tag (`dot`: a capsule tinted with its colour) or a badge (a small rounded rectangle) in `rect` (in the
    /// current, flipped or unflipped, context) with `text` in it, truncated with "…" when it does not fit.
    static func draw(_ text: String, in rect: NSRect, tint: NSColor, font: NSFont, padding: CGFloat, dot: Bool = false,
                     appearance: NSAppearance, flipped: Bool, scale: CGFloat) {
        let dark = isDark(appearance)
        let radius = dot ? rect.height / 2 : min(badgeRadius, rect.height / 2)
        (dot ? tagFill(tint, dark: dark) : fill(tint, dark: dark)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let textRect = rect.insetBy(dx: padding, dy: 0)
        drawText(text, in: textRect, color: textColor(tint, dark: dark), font: font, flipped: flipped, scale: scale)
    }

    /// Draws one line of text horizontally and optically centred in `rect`.
    static func drawText(_ text: String, in rect: NSRect, color: NSColor, font: NSFont, flipped: Bool, scale: CGFloat,
                         centered: Bool = true) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        var line = line(text, font: font)
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > rect.width + 0.5 {
            let ellipsis = CapsuleLabel.line("…", font: font)
            if let truncated = CTLineCreateTruncatedLine(line, Double(rect.width), .end, ellipsis) {
                line = truncated
                width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
        let snap = { (value: CGFloat) in (value * scale).rounded() / scale }
        let x = snap(rect.minX + (centered ? max(0, (rect.width - width) / 2) : 0))
        let center = opticalCenter(font)
        let baseline = snap(flipped ? rect.midY + center : rect.midY - center)
        context.saveGState()
        context.textMatrix = flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity
        context.textPosition = CGPoint(x: x, y: baseline)
        context.setFillColor(color.cgColor)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The text alone as a resolution-independent image `height` points tall, its optical centre in the
    /// middle, for SwiftUI capsules (which add their own background and controls).
    static func textImage(_ text: String, font: NSFont, color: NSColor, height: CGFloat, maxWidth: CGFloat) -> NSImage {
        let width = min(textWidth(text, font: font), maxWidth)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
            let scale = NSGraphicsContext.current?.cgContext.userSpaceToDeviceSpaceTransform.a ?? 2
            drawText(text, in: rect, color: color, font: font, flipped: true, scale: abs(scale))
            return true
        }
        image.accessibilityDescription = text
        return image
    }
}
