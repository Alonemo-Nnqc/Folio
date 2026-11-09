import AppKit

/// 设置 ▸ 通用 ▸ 背景透明度: frosted glass behind a pane (the list, the inspector, the reader's page background), with a
/// veil of the pane's usual colour over it. `amount` 0 hides it all: the pane looks as it always did.
final class TranslucentBackdrop: NSView {
    private let effect = NSVisualEffectView()
    private let veil = VeilView()

    /// 0 opaque … 1 the most glass.
    var amount: Double = 0 { didSet { update() } }
    /// The colour the pane has when opaque.
    var baseColor: NSColor = .controlBackgroundColor { didSet { veil.color = baseColor } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        for view in [effect, veil] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isActive: Bool { amount > 0.001 }

    private func update() {
        isHidden = !isActive
        // A gentle curve: the first steps already show the desktop, the last ones leave little veil.
        veil.alphaValue = isActive ? CGFloat(0.94 * pow(1 - amount, 1.3)) : 1
    }

    private final class VeilView: NSView {
        var color: NSColor = .controlBackgroundColor { didSet { needsDisplay = true } }
        override var wantsUpdateLayer: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
