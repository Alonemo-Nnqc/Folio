import AppKit

/// Floating capsule at the bottom of the reader while its paper is being translated (TRANS-04): what the
/// engine is doing, a progress bar and the percentage, on Liquid Glass so the page shows through.
final class TranslationProgressHUD: NSView {
    private let glass = NSGlassEffectView()
    private let stage = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        stage.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
        stage.lineBreakMode = .byTruncatingTail
        stage.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        stage.setContentHuggingPriority(.required, for: .horizontal)
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        let stack = NSStackView(views: [icon, stage, bar, percent])
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 160),
            percent.widthAnchor.constraint(equalToConstant: 34),
            stage.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        glass.contentView = stack
        glass.cornerRadius = 18
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
        percent.stringValue = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
        setAccessibilityLabel("翻译：\(text)")
        setAccessibilityValue(percent.stringValue)
    }
}

enum TranslationProgressBar {
    /// Determinate with a fraction, otherwise animated.
    static func apply(_ fraction: Double?, to bar: NSProgressIndicator) {
        if let fraction {
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
            bar.doubleValue = min(max(fraction, 0), 1)
        } else if !bar.isIndeterminate {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        } else {
            bar.startAnimation(nil)
        }
    }
}
