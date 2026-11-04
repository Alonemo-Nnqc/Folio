import AppKit
import FolioTranslate

/// Floating capsule at the bottom of the reader while its paper is being translated (TRANS-04): what the
/// engine is doing, a progress bar and the percentage, on Liquid Glass so the page shows through.
final class TranslationProgressHUD: NSView {
    private var glass: NSView!
    private let stage = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private let bar = TranslationBar()

    /// Liquid Glass on macOS 26, a HUD material before that.
    private static func capsule(around content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.contentView = content
            glass.cornerRadius = cornerRadius
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = cornerRadius
        material.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        return material
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        // Digits of one width in a box of one width: the capsule stays put while the count goes up.
        stage.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
        stage.lineBreakMode = .byTruncatingTail
        stage.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stage.setContentHuggingPriority(.defaultLow, for: .horizontal)
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        let stack = NSStackView(views: [icon, stage, bar, percent])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 160),
            bar.heightAnchor.constraint(equalToConstant: TranslationBar.height),
            percent.widthAnchor.constraint(equalToConstant: 34),
            stage.widthAnchor.constraint(equalToConstant: TranslationProgressBar.stageWidth(font: stage.font!)),
        ])
        glass = Self.capsule(around: stack, cornerRadius: 18)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.heightAnchor.constraint(equalToConstant: 36),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityIdentifier("translationProgress")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// `fraction` nil: the engine has not reported progress yet (starting, waiting in the queue).
    func update(stage text: String, fraction: Double?) {
        stage.stringValue = text
        TranslationProgressBar.apply(fraction, to: bar)
        percent.stringValue = "\(Int(((fraction ?? 0) * 100).rounded()))%"
        setAccessibilityLabel(String(localized: "翻译：\(text)"))
        setAccessibilityValue(percent.stringValue)
    }
}

enum TranslationProgressBar {
    /// Room for any stage's text: it changes as the translation goes on, and what is beside it must not move.
    static func stageWidth(font: NSFont) -> CGFloat {
        let texts = TranslationStageText.widest + [String(localized: "正在启动翻译"), String(localized: "等待翻译")]
        let widest = texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 100
        return min(ceil(widest) + 2, 220)
    }

    /// Room for "100%".
    static func percentWidth(font: NSFont) -> CGFloat {
        ceil(("100%" as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    /// How far the translation is; nothing done yet shows as an empty bar, never as an animation.
    static func apply(_ fraction: Double?, to bar: TranslationBar) {
        bar.fraction = fraction ?? 0
    }
}

/// A bar that only says how much is done: it fills as the translation goes on and does nothing else. The system's bar
/// animates on its own (an indeterminate bar slides back and forth; a determinate one eases between values), which reads
/// as "busy" rather than "this far".
final class TranslationBar: NSView {
    static let height: CGFloat = 5

    private let track = CALayer()
    private let fill = CALayer()

    /// 0…1.
    var fraction: Double = 0 {
        didSet {
            let value = min(max(fraction, 0), 1)
            guard value != oldValue else { return }
            fraction = value
            needsLayout = true
            setAccessibilityValue(NSNumber(value: value))
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        for layer in [track, fill] {
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull()]
            layer.cornerCurve = .continuous
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityMinValue(NSNumber(value: 0))
        setAccessibilityMaxValue(NSNumber(value: 1))
        setAccessibilityValue(NSNumber(value: 0))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = min(bounds.height, Self.height)
        let y = (bounds.height - h) / 2
        track.frame = CGRect(x: 0, y: y, width: bounds.width, height: h)
        fill.frame = CGRect(x: 0, y: y, width: (bounds.width * fraction).rounded(.toNearestOrAwayFromZero), height: h)
        track.cornerRadius = h / 2
        fill.cornerRadius = h / 2
        CATransaction.commit()
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            fill.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Where the fill ends, for tests.
    var fillWidth: CGFloat { fill.frame.width }
}
