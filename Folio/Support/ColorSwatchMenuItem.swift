import AppKit

/// A row of colour circles inside a menu, like the tag colours in Finder's context menu: the colours themselves
/// are the choices, not their names. Hovering rings a circle and shows its name as a tooltip; the current colour
/// carries a checkmark; clicking chooses and closes the menu. Each circle is a button for VoiceOver.
final class ColorSwatchMenuView: NSView {
    struct Swatch {
        let name: String
        let color: NSColor
    }

    private static let diameter: CGFloat = 18
    private static let spacing: CGFloat = 7
    private static let insets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14)

    private let swatches: [Swatch]
    private let selected: Int?
    private let onPick: (Int) -> Void
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    /// `selected`: the index of the current colour, if any.
    init(swatches: [Swatch], selected: Int?, onPick: @escaping (Int) -> Void) {
        self.swatches = swatches
        self.selected = selected
        self.onPick = onPick
        let width = Self.insets.left + Self.insets.right + CGFloat(swatches.count) * Self.diameter
            + CGFloat(max(swatches.count - 1, 0)) * Self.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.diameter + Self.insets.top + Self.insets.bottom))
        for index in swatches.indices { addToolTip(rect(at: index), owner: self, userData: nil) }
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel("颜色")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }

    private func rect(at index: Int) -> NSRect {
        NSRect(x: Self.insets.left + CGFloat(index) * (Self.diameter + Self.spacing), y: Self.insets.top,
               width: Self.diameter, height: Self.diameter)
    }

    private func index(at point: NSPoint) -> Int? {
        swatches.indices.first { rect(at: $0).insetBy(dx: -Self.spacing / 2, dy: -Self.insets.top).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for (index, swatch) in swatches.enumerated() {
            let circle = rect(at: index)
            if index == hovered {
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -3, dy: -3))
                NSColor.labelColor.withAlphaComponent(0.55).setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
            let path = NSBezierPath(ovalIn: circle)
            swatch.color.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(dark ? 0.3 : 0.15).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            if index == selected, let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
                let size = check.size
                let tinted = NSImage(size: size, flipped: false) { rect in
                    check.draw(in: rect)
                    NSColor.white.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2,
                                       width: size.width, height: size.height))
            }
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        pick(index)
    }

    fileprivate func pick(_ index: Int) {
        enclosingMenuItem?.menu?.cancelTracking()
        // After the menu has closed, so the change is not drawn under it.
        DispatchQueue.main.async { [onPick] in onPick(index) }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        swatches.indices.map { SwatchElement(view: self, index: $0, name: swatches[$0].name, selected: $0 == selected) }
    }

    fileprivate func accessibilityFrame(of index: Int) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(rect(at: index), to: nil))
    }
}

extension ColorSwatchMenuView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        index(at: point).map { swatches[$0].name } ?? ""
    }
}

/// One circle as a VoiceOver button. AppKit calls accessibility on the main thread; `NSAccessibilityElement`
/// itself is not marked so, hence the nonisolated overrides.
nonisolated private final class SwatchElement: NSAccessibilityElement {
    nonisolated(unsafe) private weak var view: ColorSwatchMenuView?
    private let index: Int

    nonisolated init(view: ColorSwatchMenuView, index: Int, name: String, selected: Bool) {
        self.view = view
        self.index = index
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(selected ? "\(name)（当前）" : name)
        setAccessibilityParent(view)
    }

    nonisolated override func accessibilityFrame() -> NSRect {
        let view = view, index = index
        return MainActor.assumeIsolated { view?.accessibilityFrame(of: index) ?? .zero }
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let view = view, index = index
        MainActor.assumeIsolated { view?.pick(index) }
        return true
    }
}

extension NSMenuItem {
    /// A menu item holding a row of colour circles.
    static func colorSwatches(_ swatches: [ColorSwatchMenuView.Swatch], selected: Int?, onPick: @escaping (Int) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = ColorSwatchMenuView(swatches: swatches, selected: selected, onPick: onPick)
        return item
    }
}
