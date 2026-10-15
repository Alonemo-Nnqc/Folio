import AppKit
import FolioCore

/// Sizes of the item list: roomier than AppKit's defaults so a long library does not feel crowded, like Mail's
/// and Finder's larger list sizes.
enum ItemListMetrics {
    static let rowHeight: CGFloat = 32
    static let columnSpacing: CGFloat = 12
    static let iconSize: CGFloat = 18
    /// Item titles.
    static let titleFont = NSFont.systemFont(ofSize: 14)
    /// Other columns and file rows.
    static let bodyFont = NSFont.systemFont(ofSize: 13)
    /// Notes after a title ("正在检索元数据…", "来自：…"), translation stages.
    static let secondaryFont = NSFont.systemFont(ofSize: 12)
}

/// Title column: icon (or spinner while retrieving), title, and the "默认" / "译文" badges on files (a translation
/// that is the default file shows both).
final class TitleCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TitleCell")

    let icon = NSImageView()
    let spinner = NSProgressIndicator()
    let label = NSTextField(labelWithString: "")
    let badge = CapsuleBadge()
    /// "译文" / "双语" on translated files, after "默认".
    let translationBadge = CapsuleBadge()
    private let badges = NSStackView()
    /// Translation progress of the item (TRANS-04), at the right edge of the cell.
    let progress = NSProgressIndicator()
    /// What the engine is doing ("翻译段落 34/120"), before the bar.
    let stageLabel = NSTextField(labelWithString: "")
    /// "42%" after the bar, while the engine reports progress.
    let progressLabel = NSTextField(labelWithString: "")
    private var labelBeforeProgress: NSLayoutConstraint!
    /// While translating, the title keeps some room; the stage text truncates first in a narrow column.
    private var titleRoom: NSLayoutConstraint!

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
        for capsule in [badge, translationBadge] {
            capsule.setContentHuggingPriority(.required, for: .horizontal)
            capsule.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        badges.orientation = .horizontal
        badges.spacing = 4
        badges.detachesHiddenViews = true
        badges.addArrangedSubview(badge)
        badges.addArrangedSubview(translationBadge)

        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progress.setAccessibilityIdentifier("translationProgressBar")
        stageLabel.font = ItemListMetrics.secondaryFont
        stageLabel.textColor = .secondaryLabelColor
        stageLabel.lineBreakMode = .byTruncatingTail
        stageLabel.isHidden = true
        // In a narrow column the title gives way first, then the bar narrows;
        // what the engine is doing stays readable longest.
        stageLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(740), for: .horizontal)
        stageLabel.setContentHuggingPriority(.required, for: .horizontal)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: ItemListMetrics.secondaryFont.pointSize, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.isHidden = true
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [icon, spinner, label, badges, stageLabel, progress, progressLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: ItemListMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: ItemListMetrics.iconSize),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badges.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            badges.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            badges.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            progressLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -6),
            stageLabel.trailingAnchor.constraint(equalTo: progress.leadingAnchor, constant: -8),
            stageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            { let width = progress.widthAnchor.constraint(equalToConstant: 64); width.priority = NSLayoutConstraint.Priority(720); return width }(),
        ])
        labelBeforeProgress = label.trailingAnchor.constraint(lessThanOrEqualTo: stageLabel.leadingAnchor, constant: -8)
        titleRoom = label.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        titleRoom.priority = .defaultHigh
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// `origin` is the title of the item a trashed file was deleted from (TRASH-03); `translation` is the
    /// stage and progress of a running translation (TRANS-04), shown as text and a progress bar.
    func configureItem(_ item: Item, fileURL: URL?, origin: String? = nil, hasNote: Bool = false,
                       translation: (stage: String, fraction: Double?)? = nil) {
        progress.isHidden = translation == nil
        stageLabel.isHidden = translation == nil
        progressLabel.isHidden = translation?.fraction == nil
        labelBeforeProgress.isActive = translation != nil
        titleRoom.isActive = translation != nil
        if let translation {
            TranslationProgressBar.apply(translation.fraction, to: progress)
            stageLabel.stringValue = translation.stage
            stageLabel.toolTip = translation.stage
            progressLabel.stringValue = translation.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
            progress.toolTip = translation.stage
        } else {
            progress.stopAnimation(nil)
        }
        // Set the base font before any attributed text so the smaller secondary run survives.
        label.font = ItemListMetrics.titleFont
        let retrieving = item.kind == .standalone && item.metadataState == .pending
        if retrieving {
            icon.isHidden = true
            spinner.startAnimation(nil)
            label.attributedStringValue = Self.title(item.title, secondary: String(localized: "正在检索元数据…"))
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
                label.attributedStringValue = Self.title(item.title, secondary: String(localized: "来自：\(origin)"))
            } else if hasNote {
                label.attributedStringValue = Self.title(item.title, symbol: "note.text", label: String(localized: "有笔记"))
            } else {
                label.stringValue = item.title
            }
        }
        badge.isHidden = true
        translationBadge.isHidden = true
        setAccessibilityLabel(item.title + (hasNote ? String(localized: "（有笔记）") : "")
                              + (translation.map { job in
                                  let percent = job.fraction.map { " \(Int($0 * 100))%" } ?? ""
                                  return String(localized: "（\(job.stage)\(percent)）")
                              } ?? ""))
    }

    func configureFile(_ file: FileRecord, url: URL, isDefault: Bool) {
        spinner.stopAnimation(nil)
        progress.isHidden = true
        stageLabel.isHidden = true
        progressLabel.isHidden = true
        labelBeforeProgress.isActive = false
        titleRoom.isActive = false
        icon.isHidden = false
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.contentTintColor = nil
        label.stringValue = file.fileName
        label.font = ItemListMetrics.bodyFont
        let translation = file.translationOf == nil ? nil : (file.translationKind == .dual ? String(localized: "双语") : String(localized: "译文"))
        badge.configure(String(localized: "默认"), tint: .controlAccentColor)
        badge.isHidden = !isDefault
        badge.setAccessibilityIdentifier("defaultFileBadge")
        translationBadge.configure(translation ?? "", tint: .systemTeal)
        translationBadge.isHidden = translation == nil
        translationBadge.setAccessibilityIdentifier("translationBadge")
        setAccessibilityLabel(file.fileName + (isDefault ? String(localized: "（默认）") : "") + (translation.map { String(localized: "（\($0)）") } ?? ""))
    }

    /// Title followed by a small symbol (e.g. the note indicator, NOTE-03).
    static func title(_ title: String, symbol: String, label: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title + "  ", attributes: [
            .foregroundColor: NSColor.labelColor, .font: ItemListMetrics.titleFont])
        let configuration = NSImage.SymbolConfiguration(pointSize: ItemListMetrics.secondaryFont.pointSize, weight: .regular)
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
            .foregroundColor: NSColor.labelColor, .font: ItemListMetrics.titleFont, .paragraphStyle: style])
        text.append(NSAttributedString(string: "   " + secondary, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor, .font: ItemListMetrics.secondaryFont,
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
        label.font = ItemListMetrics.bodyFont
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
