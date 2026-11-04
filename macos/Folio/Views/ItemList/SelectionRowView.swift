import AppKit

/// Item list rows selected with a flat, translucent grey like the sidebar's selection, instead of the solid accent
/// fill, which turned the row's text white and drowned the coloured tag chips. No gradient or outline: just the
/// rounded shape, a little stronger while the list has focus. Text, icons and tags keep their colours; consecutive
/// selected rows read as one shape (a joined edge reaches past the row and is clipped).
final class SelectionRowView: NSTableRowView {
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
        let joinUp = isFlipped ? isPreviousRowSelected : isNextRowSelected
        let joinDown = isFlipped ? isNextRowSelected : isPreviousRowSelected
        let over = Self.radius + 2
        var shape = bounds.insetBy(dx: Self.inset, dy: 0)
        if joinDown { shape.origin.y -= over; shape.size.height += over }
        if joinUp { shape.size.height += over }
        let alpha: CGFloat = isEmphasized ? (dark ? 0.16 : 0.11) : (dark ? 0.11 : 0.075)
        NSColor(white: dark ? 1 : 0, alpha: alpha).setFill()
        NSBezierPath(roundedRect: shape, xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}
