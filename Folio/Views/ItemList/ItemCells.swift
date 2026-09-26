import AppKit
import FolioCore

/// Title column: icon (or spinner while retrieving), title, and the "默认" badge on default files.
final class TitleCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("TitleCell")

    let icon = NSImageView()
    let spinner = NSProgressIndicator()
    let label = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "默认")

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
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 7
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setAccessibilityIdentifier("defaultFileBadge")

        for view in [icon, spinner, label, badge] as [NSView] {
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
            badge.widthAnchor.constraint(equalToConstant: 32),
            badge.heightAnchor.constraint(equalToConstant: 15),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// `origin` is the title of the item a trashed file was deleted from (TRASH-03).
    func configureItem(_ item: Item, fileURL: URL?, origin: String? = nil) {
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
            } else {
                label.stringValue = item.title
            }
        }
        badge.isHidden = true
        setAccessibilityLabel(item.title)
    }

    func configureFile(_ file: FileRecord, url: URL, isDefault: Bool) {
        spinner.stopAnimation(nil)
        icon.isHidden = false
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        icon.contentTintColor = nil
        label.stringValue = file.fileName
        label.font = .systemFont(ofSize: NSFont.systemFontSize - 1)
        badge.isHidden = !isDefault
        setAccessibilityLabel(file.fileName + (isDefault ? "（默认）" : ""))
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
