import AppKit
import FolioCore

/// Title column: icon (or spinner while retrieving), title, and the "默认" badge on default files.
final class TitleCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TitleCell")

    let icon = NSImageView()
    let spinner = NSProgressIndicator()
    let label = NSTextField(labelWithString: "")
    let badge = CapsuleBadge()
    /// Translation progress of the item (TRANS-04), at the right edge of the cell.
    let progress = NSProgressIndicator()
    /// "42%", or the stage ("等待翻译") before the engine reports progress.
    let progressLabel = NSTextField(labelWithString: "")
    private var labelBeforeProgress: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        imageView = icon
        textField = label
        icon.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityIdentifier("retrievalSpinner")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.wraps = false
        label.cell?.truncatesLastVisibleLine = true
        label.allowsExpansionToolTips = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.setAccessibilityIdentifier("translationProgressBar")
        progressLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.isHidden = true
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [icon, spinner, label, badge, progress, progressLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -6),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 64),
        ])
        labelBeforeProgress = label.trailingAnchor.constraint(lessThanOrEqualTo: progress.leadingAnchor, constant: -10)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// `origin` is the title of the item a trashed file was deleted from (TRASH-03); `translation` is the
    /// stage and progress of a running translation (TRANS-04), shown as text and a progress bar.
    func configureItem(_ item: Item, fileURL: URL?, origin: String? = nil, hasNote: Bool = false,
                       translation: (stage: String, fraction: Double?)? = nil) {
        progress.isHidden = translation == nil
        progressLabel.isHidden = translation == nil
        labelBeforeProgress.isActive = translation != nil
        if let translation {
            TranslationProgressBar.apply(translation.fraction, to: progress)
            progressLabel.stringValue = translation.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? translation.stage
            progress.toolTip = translation.stage
        } else {
            progress.stopAnimation(nil)
        }
        // Set the base font before any attributed text so the smaller secondary run survives.
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        let retrieving = item.kind == .standalone && item.metadataState == .pending
        if retrieving {
            icon.isHidden = true
            spinner.startAnimation(nil)
            label.attributedStringValue = Self.title(item.title, secondary: "正在检索元数据…")
        } else {
            spinner.stopAnimation(nil)
            icon.isHidden = false
            if item.kind == .standalone, let fileURL {
                icon.image = NSWorkspace.shared.icon(forFile: fileURL.path)
                icon.contentTintColor = nil
            } else {
                icon.image = NSImage(systemSymbolName: Self.symbol(for: item.type), accessibilityDescription: item.type.displayName)
                icon.contentTintColor = .secondaryLabelColor
            }
            if let origin {
                label.attributedStringValue = Self.title(item.title, secondary: "来自：\(origin)")
            } else if hasNote {
                label.attributedStringValue = Self.title(item.title, symbol: "note.text", label: "有笔记")
            } else {
                label.stringValue = item.title
            }
        }
        badge.isHidden = true
        setAccessibilityLabel(item.title + (hasNote ? "（有笔记）" : "")
                              + (translation.map { "（\($0.stage)\($0.fraction.map { " \(Int($0 * 100))%" } ?? "")）" } ?? ""))
    }

    func configureFile(_ file: FileRecord, url: URL, isDefault: Bool) {
        spinner.stopAnimation(nil)
        progress.isHidden = true
        progressLabel.isHidden = true
        labelBeforeProgress.isActive = false
        icon.isHidden = false
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.contentTintColor = nil
        label.stringValue = file.fileName
        label.font = .systemFont(ofSize: NSFont.systemFontSize - 1)
        let isTranslation = file.translationOf != nil
        badge.configure(isDefault ? "默认" : "译文", tint: isDefault ? .controlAccentColor : .systemTeal)
        badge.isHidden = !(isDefault || isTranslation)
        badge.setAccessibilityIdentifier(isDefault ? "defaultFileBadge" : "translationBadge")
        setAccessibilityLabel(file.fileName + (isDefault ? "（默认）" : isTranslation ? "（译文）" : ""))
    }

    /// Title followed by a small symbol (e.g. the note indicator, NOTE-03).
    static func title(_ title: String, symbol: String, label: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + "  ", attributes: [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.smallSystemFontSize, weight: .regular)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        return text
    }

    /// Title plus a smaller grey note, kept on one line and truncated at the tail.
    static func title(_ title: String, secondary: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .paragraphStyle: style])
        text.append(NSAttributedString(string: "   " + secondary, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: style]))
        return text
    }

    static func symbol(for type: ItemType) -> String {
        switch type {
        case .journalArticle: "doc.text"
        case .conferencePaper: "doc.richtext"
        case .preprint: "doc.plaintext"
        case .book, .bookChapter: "book.closed"
        case .thesis: "graduationcap"
        case .report: "doc.append"
        case .webpage: "globe"
        case .dataset: "tablecells"
        case .other: "doc"
        }
    }
}

/// Plain text column cell.
final class TextCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TextCell")
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        textField = label
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    func configure(_ text: String, secondary: Bool = false) {
        label.stringValue = text
        label.textColor = secondary || text == "—" ? .secondaryLabelColor : .labelColor
    }

    func configure(_ attributed: NSAttributedString) {
        label.attributedStringValue = attributed
    }
}

/// Tag chips column cell.
final class TagsCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TagsCell")
    let chips = TagChipsView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        chips.translatesAutoresizingMaskIntoConstraints = false
        chips.setAccessibilityIdentifier("tagChips")
        addSubview(chips)
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: trailingAnchor),
            chips.topAnchor.constraint(equalTo: topAnchor),
            chips.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
}

enum CellText {
    static func readStatus(_ item: Item) -> NSAttributedString {
        guard item.kind == .regular else { return NSAttributedString(string: "") }
        let (symbol, color): (String, NSColor) = switch item.readStatus {
        case .unread: ("●", .controlAccentColor)
        case .reading: ("◐", .secondaryLabelColor)
        case .read: ("", .clear)
        }
        return NSAttributedString(string: symbol, attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 10)])
    }

    static func rating(_ value: Int) -> NSAttributedString {
        guard value > 0 else { return NSAttributedString(string: "") }
        let text = NSMutableAttributedString(string: String(repeating: "★", count: value),
                                             attributes: [.foregroundColor: NSColor.systemOrange])
        text.append(NSAttributedString(string: String(repeating: "★", count: 5 - value),
                                       attributes: [.foregroundColor: NSColor.quaternaryLabelColor]))
        return text
    }
}

/// The "默认" / "译文" capsule after a file name.
final class CapsuleBadge: NSView {
    private(set) var text = ""
    private var tint: NSColor = .controlAccentColor

    override var isFlipped: Bool { true }

    func configure(_ text: String, tint: NSColor) {
        guard text != self.text || tint != self.tint else { return }
        self.text = text
        self.tint = tint
        setAccessibilityLabel(text)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CapsuleLabel.textWidth(text, font: CapsuleLabel.badgeFont) + CapsuleLabel.badgePadding * 2,
               height: CapsuleLabel.badgeHeight)
    }

    // Accent colour and dark mode resolve at draw time.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        CapsuleLabel.draw(text, in: bounds, tint: tint, font: CapsuleLabel.badgeFont, padding: CapsuleLabel.badgePadding,
                          appearance: effectiveAppearance, flipped: true, scale: window?.backingScaleFactor ?? 2)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
