import AppKit

/// Item list rows selected with a sheet of grey glass instead of the solid accent fill, which turned the
/// row's text white and drowned the coloured tag chips: a translucent grey body lit from above, a light rim
/// along its upper edge and a hairline below, like the Liquid Glass of macOS controls. It is drawn rather than
/// an `NSGlassEffectView`, whose specular rim turned into bright brackets on a row this thin. Text, icons and
/// tags keep their colours; the glass is a little denser while the list has focus. Consecutive selected rows
/// read as one shape: a joined edge reaches past the row and is clipped, so only the outer corners are round.
final class GlassRowView: NSTableRowView {
    private static let radius: CGFloat = 8
    private static let inset: CGFloat = 4

    // Keep text, icons and tag colours as they are on an unselected row.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    /// `-FolioPreviewFocusedSelection YES` draws the focused look in background screenshots (PreviewHooks).
    private static let previewFocused = UserDefaults.standard.bool(forKey: "FolioPreviewFocusedSelection")

    override var isEmphasized: Bool {
        get { super.isEmphasized || Self.previewFocused }
        set { super.isEmphasized = newValue; if isSelected { needsDisplay = true } }
    }

    override var isPreviousRowSelected: Bool {
        didSet { if isSelected { needsDisplay = true } }
    }

    override var isNextRowSelected: Bool {
        didSet { if isSelected { needsDisplay = true } }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let focused = isEmphasized
        let pixel = 1 / max(window?.backingScaleFactor ?? 2, 1)
        let joinUp = isFlipped ? isPreviousRowSelected : isNextRowSelected
        let joinDown = isFlipped ? isNextRowSelected : isPreviousRowSelected
        let over = Self.radius + 2
        var shape = bounds.insetBy(dx: Self.inset, dy: 0)
        if joinDown { shape.origin.y -= over; shape.size.height += over }
        if joinUp { shape.size.height += over }
        shape = shape.insetBy(dx: pixel / 2, dy: pixel / 2)
        let path = NSBezierPath(roundedRect: shape, xRadius: Self.radius, yRadius: Self.radius)
        // In view coordinates "top" is maxY unless flipped.
        let topIsMax = !isFlipped
        let lit = topIsMax ? 90.0 : -90.0

        // Body: translucent grey, lighter at the top.
        let base = dark ? NSColor(white: 1, alpha: focused ? 0.13 : 0.085) : NSColor(white: 0.30, alpha: focused ? 0.11 : 0.07)
        let top = dark ? NSColor(white: 1, alpha: focused ? 0.17 : 0.11) : NSColor(white: 0.30, alpha: focused ? 0.07 : 0.045)
        NSGradient(starting: base, ending: top)?.draw(in: path, angle: lit)

        // Rim: a light edge on top fading out, and a faint hairline that defines the shape.
        NSColor(white: dark ? 1 : 0, alpha: dark ? 0.10 : (focused ? 0.10 : 0.07)).setStroke()
        path.lineWidth = pixel
        path.stroke()
        // Shine along the upper edge, fading out halfway down the sides.
        guard !joinUp, let context = NSGraphicsContext.current?.cgContext else { return }
        let rim = NSBezierPath(roundedRect: shape.insetBy(dx: pixel, dy: pixel), xRadius: Self.radius - pixel, yRadius: Self.radius - pixel)
        NSGraphicsContext.saveGraphicsState()
        context.addPath(rim.cgPath.copy(strokingWithWidth: pixel, lineCap: .butt, lineJoin: .round, miterLimit: 1))
        context.clip()
        let band = NSRect(x: shape.minX, y: topIsMax ? shape.midY : shape.minY, width: shape.width, height: shape.height / 2)
        let shine = NSColor.white.withAlphaComponent(dark ? 0.24 : 0.9)
        NSGradient(starting: shine, ending: shine.withAlphaComponent(0))?.draw(in: band, angle: -lit)
        NSGraphicsContext.restoreGraphicsState()
    }
}
