import AppKit
import FolioCore

/// Where a paper stands, as one small ring: empty (未读), filled as far as it has been read (在读), a check (已读). The sidebar,
/// the list and its 阅读状态 column draw the same one.
enum ReadingRing {
    /// The ring the sidebar's 在读 shows.
    static let sample = 0.62

    static func image(_ status: ReadStatus, fraction: Double = sample, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(status, fraction: fraction, in: rect)
            return true
        }
        image.accessibilityDescription = status.displayName
        return image
    }

    static func draw(_ status: ReadStatus, fraction: Double, in rect: NSRect) {
        let line = max(rect.width * 0.115, 1.5)
        let ring = rect.insetBy(dx: line / 2 + 0.75, dy: line / 2 + 0.75)
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        switch status {
        case .unread:
            let path = NSBezierPath(ovalIn: ring)
            path.lineWidth = max(line * 0.8, 1.2)
            NSColor.tertiaryLabelColor.setStroke()
            path.stroke()
        case .reading:
            let track = NSBezierPath(ovalIn: ring)
            track.lineWidth = line
            NSColor.quaternaryLabelColor.setStroke()
            track.stroke()
            // Just opened still shows a beginning.
            let shown = min(max(fraction, 0.06), 1)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: ring.width / 2, startAngle: 90, endAngle: 90 - 360 * shown, clockwise: true)
            arc.lineWidth = line * 1.25
            arc.lineCapStyle = .round
            NSColor.controlAccentColor.setStroke()
            arc.stroke()
        case .read:
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75)).fill()
            let check = NSBezierPath()
            let s = rect.width
            check.move(to: NSPoint(x: rect.minX + s * 0.30, y: rect.minY + s * 0.49))
            check.line(to: NSPoint(x: rect.minX + s * 0.44, y: rect.minY + s * 0.35))
            check.line(to: NSPoint(x: rect.minX + s * 0.71, y: rect.minY + s * 0.65))
            check.lineWidth = max(s * 0.11, 1.4)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        }
    }

    /// "62%" for a paper being read, else the status' name.
    static func label(_ status: ReadStatus, fraction: Double) -> String {
        status == .reading && fraction > 0 ? percent(fraction) : status.displayName
    }

    static func percent(_ fraction: Double) -> String { "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%" }

    /// What a click on the ring does next.
    static func next(_ status: ReadStatus) -> ReadStatus {
        switch status {
        case .unread: .reading
        case .reading: .read
        case .read: .unread
        }
    }
}

/// The ring in a row of the list: a click moves the paper to the next status without selecting the row.
final class ReadingRingButton: NSButton {
    private(set) var status: ReadStatus = .unread
    private(set) var fraction = 0.0
    private var hovering = false { didSet { needsDisplay = true } }
    var onChange: (ReadStatus) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .accessoryBarAction
        setButtonType(.momentaryChange)
        target = self
        action = #selector(clicked)
        focusRingType = .none
        refusesFirstResponder = true
        setAccessibilityIdentifier("readingRing")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    func configure(_ status: ReadStatus, fraction: Double) {
        guard status != self.status || fraction != self.fraction || toolTip == nil else { return }
        self.status = status
        self.fraction = fraction
        let state = status == .reading && fraction > 0 ? String(localized: "在读 · 读到 \(ReadingRing.percent(fraction))") : status.displayName
        toolTip = String(localized: "\(state)，点按标为\(ReadingRing.next(status).displayName)")
        setAccessibilityLabel(String(localized: "阅读状态：\(state)"))
        needsDisplay = true
    }

    @objc private func clicked() { onChange(ReadingRing.next(status)) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 16
        let ring = NSRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        if hovering || isHighlighted {
            NSColor.quaternaryLabelColor.withAlphaComponent(isHighlighted ? 0.3 : 0.16).setFill()
            NSBezierPath(ovalIn: ring.insetBy(dx: -3, dy: -3)).fill()
        }
        // The check is a flipped view's: drawn upright whichever way the button's coordinates run.
        NSGraphicsContext.saveGraphicsState()
        if isFlipped {
            let turn = NSAffineTransform()
            turn.translateX(by: 0, yBy: ring.midY * 2)
            turn.scaleX(by: 1, yBy: -1)
            turn.concat()
        }
        ReadingRing.draw(status, fraction: fraction, in: ring)
        NSGraphicsContext.restoreGraphicsState()
    }
}
