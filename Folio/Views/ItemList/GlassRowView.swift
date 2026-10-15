import AppKit

/// Item list rows with a light, translucent selection instead of the solid accent fill: the solid fill
/// turned the row's text white and drowned the coloured tag chips. A faint tint (accent while the list
/// has focus, neutral otherwise), a hairline edge and a soft top highlight, like a sheet of glass laid over
/// the row; consecutive selected rows merge into one shape.
final class GlassRowView: NSTableRowView {
    private static let radius: CGFloat = 7
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
        let pixel = 1 / max(window?.backingScaleFactor ?? 2, 1)
        // Joined edges reach past the row, so the corners and the outline there are clipped away.
        let joinTop = isPreviousRowSelected, joinBottom = isNextRowSelected
        let over = Self.radius + 1
        var shape = bounds.insetBy(dx: Self.inset, dy: 0)
        if isFlipped {
            if joinTop { shape.origin.y -= over; shape.size.height += over }
            if joinBottom { shape.size.height += over }
        } else {
            if joinTop { shape.size.height += over }
            if joinBottom { shape.origin.y -= over; shape.size.height += over }
        }
        shape = shape.insetBy(dx: pixel / 2, dy: pixel / 2)
        let path = NSBezierPath(roundedRect: shape, xRadius: Self.radius, yRadius: Self.radius)

        let tint: NSColor = isEmphasized ? .controlAccentColor : .labelColor
        let fill = isEmphasized ? (dark ? 0.24 : 0.13) : (dark ? 0.10 : 0.06)
        tint.withAlphaComponent(fill).setFill()
        path.fill()
        tint.withAlphaComponent(isEmphasized ? (dark ? 0.42 : 0.30) : (dark ? 0.16 : 0.10)).setStroke()
        path.lineWidth = pixel
        path.stroke()

        // Soft highlight along the top edge of the selection.
        guard !joinTop else { return }
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let top = isFlipped ? shape.minY : shape.maxY
        let band = NSRect(x: shape.minX, y: isFlipped ? top : top - bounds.height / 2,
                          width: shape.width, height: bounds.height / 2)
        let gradient = NSGradient(colors: [NSColor.white.withAlphaComponent(dark ? 0.07 : 0.35), NSColor.white.withAlphaComponent(0)])
        gradient?.draw(in: band, angle: isFlipped ? 90 : -90)
        NSGraphicsContext.restoreGraphicsState()
    }
}
