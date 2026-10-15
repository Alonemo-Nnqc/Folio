import AppKit

/// Icon + name + count, laid out like Mail's mailbox rows. Fonts and icon sizes follow the system
/// "边栏图标大小" setting through the outline's row size style; nothing is hard-coded.
final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        imageView = icon
        textField = name
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, name, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
        ])
        applySizes()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var rowSizeStyle: NSTableView.RowSizeStyle {
        didSet { applySizes() }
    }

    /// Text and symbol sizes for the sidebar sizes (small / medium / large), matching Finder and Mail.
    private func applySizes() {
        let size: CGFloat = switch rowSizeStyle {
        case .small: 11
        case .large: 15
        default: 13
        }
        name.font = .systemFont(ofSize: size)
        count.font = .monospacedDigitSystemFont(ofSize: size - 1, weight: .regular)
        icon.symbolConfiguration = .init(pointSize: size + 2, weight: .regular)
    }

    func configure(symbol: String, tint: NSColor?, title: String, count value: Int?) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint ?? .controlAccentColor
        name.stringValue = title
        name.isEditable = false
        count.stringValue = value.map { $0 > 0 ? "\($0)" : "" } ?? ""
        setAccessibilityLabel(value.map { $0 > 0 ? String(localized: "\(title)，\($0) 项") : title } ?? title)
    }
}

/// Section header row ("文献库", "分组", "标签"). AppKit draws the Show/Hide control on hover; a +
/// button for the section's "new" command appears next to it, also only on hover (like Notes).
final class SidebarHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeader")
    let label = NSTextField(labelWithString: "")
    let add = NSButton()
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        textField = label
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        add.isBordered = false
        add.bezelStyle = .accessoryBarAction
        add.contentTintColor = .secondaryLabelColor
        add.target = nil
        add.isHidden = true
        for view in [label, add] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Leaves room for the Show/Hide chevron AppKit puts at the trailing edge of group rows.
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            add.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// `action` nil: the section has no + (文献库).
    func configure(title: String, addTitle: String?, action: Selector?, identifier: String?) {
        label.stringValue = title
        add.action = action
        add.toolTip = addTitle
        add.setAccessibilityLabel(addTitle)
        add.setAccessibilityIdentifier(identifier)
        add.isHidden = true
        // The + stays reachable for VoiceOver even while visually hidden on non-hover.
        add.setAccessibilityElement(action != nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { add.isHidden = add.action == nil }
    override func mouseExited(with event: NSEvent) { add.isHidden = true }
}
