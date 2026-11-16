import AppKit

/// A row of choices inside a menu, like the tag colours in Finder's context menu: the choices are shown, not named.
/// Colours are circles (the last, many-coloured one mixes a colour of one's own), a pen's widths are dots as thick as
/// its line, an eraser's sizes rings as large, text sizes letters as large. Hovering marks a choice and shows its name
/// as a tooltip; the current one carries a checkmark (colours) or a soft background (sizes); clicking chooses and
/// closes the menu. Each choice is a button for VoiceOver.
final class ColorSwatchMenuView: NSView {
    struct Swatch {
        enum Kind {
            case color(NSColor)
            /// 自定义颜色…: a circle of every hue.
            case custom
            /// A dot this many points across, in this colour (a pen's width).
            case dot(CGFloat, NSColor)
            /// A ring this many points across (an eraser's size).
            case ring(CGFloat)
            /// The letter A at this size (a text size).
            case letter(CGFloat)
        }
        let name: String
        let kind: Kind

        init(name: String, color: NSColor) { self.name = name; kind = .color(color) }
        init(name: String, kind: Kind) { self.name = name; self.kind = kind }
        static var custom: Swatch { Swatch(name: String(localized: "自定义颜色…"), kind: .custom) }

        var isColor: Bool { if case .dot = kind { return false }; if case .ring = kind { return false }; if case .letter = kind { return false }; return true }
    }

    private let cell: CGFloat
    private let spacing: CGFloat
    /// Sizes spread over the menu's whole width (colours stay together from the left).
    private let spreads: Bool
    private static let insets = NSEdgeInsets(top: 5, left: 14, bottom: 5, right: 14)

    private let swatches: [Swatch]
    private let selected: Int?
    private let onPick: (Int) -> Void
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    /// `selected`: the index of the current choice, if any.
    init(swatches: [Swatch], selected: Int?, label: String = String(localized: "颜色"), onPick: @escaping (Int) -> Void) {
        self.swatches = swatches
        self.selected = selected
        self.onPick = onPick
        let colors = swatches.allSatisfy(\.isColor)
        cell = colors ? 18 : 28
        spacing = colors ? 7 : 6
        spreads = !colors
        let width = Self.insets.left + Self.insets.right + CGFloat(swatches.count) * cell + CGFloat(max(swatches.count - 1, 0)) * spacing
        super.init(frame: NSRect(x: 0, y: 0, width: max(width, colors ? 150 : 120), height: cell + Self.insets.top + Self.insets.bottom))
        // The menu widens the row to its own width.
        autoresizingMask = [.width]
        addToolTips()
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }

    private func rect(at index: Int) -> NSRect {
        if spreads, !swatches.isEmpty {
            // Each size in an equal share of the width, in its middle.
            let share = (bounds.width - Self.insets.left - Self.insets.right) / CGFloat(swatches.count)
            return NSRect(x: (Self.insets.left + share * (CGFloat(index) + 0.5) - cell / 2).rounded(), y: Self.insets.top, width: cell, height: cell)
        }
        return NSRect(x: Self.insets.left + CGFloat(index) * (cell + spacing), y: Self.insets.top, width: cell, height: cell)
    }

    private func index(at point: NSPoint) -> Int? {
        swatches.indices.first { rect(at: $0).insetBy(dx: -spacing / 2, dy: -Self.insets.top).contains(point) }
    }

    private func addToolTips() {
        removeAllToolTips()
        for index in swatches.indices { addToolTip(rect(at: index), owner: self, userData: nil) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        addToolTips()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for (index, swatch) in swatches.enumerated() {
            let box = rect(at: index)
            switch swatch.kind {
            case .color(let color):
                drawCircle(in: box, hovered: index == hovered, dark: dark) { color.setFill(); $0.fill() }
                if index == selected { drawCheck(in: box, color: color) }
            case .custom:
                drawCircle(in: box, hovered: index == hovered, dark: dark) { path in Self.fillHues(path, in: box) }
            case .dot, .ring, .letter:
                if index == selected || index == hovered {
                    let back = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
                    (index == selected ? NSColor.controlAccentColor.withAlphaComponent(dark ? 0.35 : 0.2) : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
                    back.fill()
                }
                drawSize(swatch.kind, in: box, dark: dark)
            }
        }
    }

    private func drawCircle(in box: NSRect, hovered: Bool, dark: Bool, fill: (NSBezierPath) -> Void) {
        if hovered {
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: -3, dy: -3))
            NSColor.labelColor.withAlphaComponent(0.55).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let path = NSBezierPath(ovalIn: box)
        fill(path)
        NSColor.black.withAlphaComponent(dark ? 0.3 : 0.15).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    /// Every hue around the circle, whiter towards its middle.
    static func fillHues(_ path: NSBezierPath, in box: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let center = NSPoint(x: box.midX, y: box.midY), radius = box.width / 2 + 1
        let steps = 48
        for step in 0..<steps {
            let start = CGFloat(step) / CGFloat(steps) * 360, end = CGFloat(step + 1) / CGFloat(steps) * 360 + 0.8
            let wedge = NSBezierPath()
            wedge.move(to: center)
            wedge.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
            wedge.close()
            NSColor(hue: CGFloat(step) / CGFloat(steps), saturation: 0.75, brightness: 1, alpha: 1).setFill()
            wedge.fill()
        }
        NSGradient(colors: [.white.withAlphaComponent(0.85), .white.withAlphaComponent(0)])?
            .draw(in: NSBezierPath(ovalIn: box), relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCheck(in box: NSRect, color: NSColor) {
        guard let check = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) else { return }
        // White on dark colours, dark on light ones.
        let light = (color.usingColorSpace(.sRGB).map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent } ?? 0.5) > 0.8
        let size = check.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            check.draw(in: rect)
            (light ? NSColor.black.withAlphaComponent(0.7) : .white).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func drawSize(_ kind: Swatch.Kind, in box: NSRect, dark: Bool) {
        switch kind {
        case .dot(let diameter, let color):
            let d = min(max(diameter, 3), box.width - 6)
            let dot = NSBezierPath(ovalIn: NSRect(x: box.midX - d / 2, y: box.midY - d / 2, width: d, height: d))
            // As the pen shows on the toolbar: a black pen stays visible in the dark.
            AnnotationToolImage.legible(color.withAlphaComponent(1), dark: dark).setFill()
            dot.fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            dot.lineWidth = 0.5
            dot.stroke()
        case .ring(let diameter):
            let d = min(max(diameter, 4), box.width - 6)
            let ring = NSBezierPath(ovalIn: NSRect(x: box.midX - d / 2, y: box.midY - d / 2, width: d, height: d))
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            ring.fill()
            NSColor.labelColor.withAlphaComponent(0.8).setStroke()
            ring.lineWidth = 1.2
            ring.stroke()
        case .letter(let size):
            let text = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                                                                   .foregroundColor: NSColor.labelColor])
            let bounds = text.size()
            text.draw(at: NSPoint(x: box.midX - bounds.width / 2, y: box.midY - bounds.height / 2))
        default: break
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
        setAccessibilityLabel(selected ? String(localized: "\(name)（当前）") : name)
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

    /// A row of sizes (a pen's widths, an eraser's sizes, text sizes) shown as what they look like.
    static func sizeRow(_ swatches: [ColorSwatchMenuView.Swatch], selected: Int?, label: String, onPick: @escaping (Int) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = ColorSwatchMenuView(swatches: swatches, selected: selected, label: label, onPick: onPick)
        return item
    }
}
