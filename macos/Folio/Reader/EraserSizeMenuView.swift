import AppKit
import FolioCore

/// The eraser's sizes as a row of tiles in a menu (READER-30): each shows a ring as large as that eraser at 100 %
/// (8, 16 and 32 pt) with its name and size under it, so the choice is seen rather than read. The current size is
/// tinted with the accent colour; hovering lifts a tile; clicking chooses and closes the menu.
final class EraserSizeMenuView: NSView {
    private static let tile = NSSize(width: 58, height: 64)
    private static let spacing: CGFloat = 6
    private static let insets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)

    private let sizes = InkEraser.Size.allCases
    private let selected: InkEraser.Size
    private let onPick: (InkEraser.Size) -> Void
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(selected: InkEraser.Size, onPick: @escaping (InkEraser.Size) -> Void) {
        self.selected = selected
        self.onPick = onPick
        let count = CGFloat(InkEraser.Size.allCases.count)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.insets.left + Self.insets.right + count * Self.tile.width + (count - 1) * Self.spacing,
                                 height: Self.insets.top + Self.insets.bottom + Self.tile.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(String(localized: "橡皮擦大小"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }

    private func rect(at index: Int) -> NSRect {
        NSRect(x: Self.insets.left + CGFloat(index) * (Self.tile.width + Self.spacing), y: Self.insets.top,
               width: Self.tile.width, height: Self.tile.height)
    }

    private func index(at point: NSPoint) -> Int? { sizes.indices.first { rect(at: $0).contains(point) } }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for (index, size) in sizes.enumerated() {
            let tile = rect(at: index)
            let isSelected = size == selected
            if isSelected || index == hovered {
                let background = NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8)
                (isSelected ? accent.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.07)).setFill()
                background.fill()
                if isSelected {
                    accent.withAlphaComponent(0.55).setStroke()
                    background.lineWidth = 1
                    background.stroke()
                }
            }
            // The ring: its real size at 100 %, centred in the space above the caption.
            let d = size.diameter
            let circle = NSRect(x: tile.midX - d / 2, y: tile.minY + 20 - d / 2, width: d, height: d)
            let path = NSBezierPath(ovalIn: circle)
            (isSelected ? accent : NSColor.labelColor).withAlphaComponent(0.14).setFill()
            path.fill()
            (isSelected ? accent : NSColor.labelColor.withAlphaComponent(0.7)).setStroke()
            path.lineWidth = 1.25
            path.stroke()
            // Name and size.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let name = NSAttributedString(string: size.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular),
                .foregroundColor: isSelected ? accent : NSColor.labelColor, .paragraphStyle: paragraph,
            ])
            name.draw(in: NSRect(x: tile.minX, y: tile.minY + 38, width: tile.width, height: 14))
            let points = NSAttributedString(string: "\(Int(d)) pt", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ])
            points.draw(in: NSRect(x: tile.minX, y: tile.minY + 51, width: tile.width, height: 12))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        pick(sizes[index])
    }

    private func pick(_ size: InkEraser.Size) {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { [onPick] in onPick(size) }
    }

    override func accessibilityValue() -> Any? { selected.title }
}

extension NSMenuItem {
    /// A menu item holding the eraser's size tiles.
    static func eraserSizes(selected: InkEraser.Size, onPick: @escaping (InkEraser.Size) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = EraserSizeMenuView(selected: selected, onPick: onPick)
        return item
    }
}
