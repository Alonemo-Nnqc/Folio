import AppKit

/// Icon + name + count row. Groups with subgroups show a trailing chevron (SIDE-05).
final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarCell")

    let icon = NSImageView()
    let name = NSTextField(labelWithString: "")
    let count = NSTextField(labelWithString: "")
    let chevron = NSImageView()
    var onToggle: (() -> Void)?
    private var expanded = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        imageView = icon
        textField = name

        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        name.lineBreakMode = .byTruncatingTail
        name.font = .systemFont(ofSize: NSFont.systemFontSize)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "展开")
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggle)))
        chevron.setAccessibilityRole(.disclosureTriangle)
        chevron.setAccessibilityIdentifier("groupDisclosure")

        for view in [icon, name, count, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: count.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    func configure(symbol: String, tint: NSColor?, title: String, count value: Int?, expandable: Bool, isExpanded: Bool) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint ?? .controlAccentColor
        name.stringValue = title
        name.isEditable = false
        count.stringValue = value.map { $0 > 0 ? "\($0)" : "" } ?? ""
        chevron.isHidden = !expandable
        setExpanded(isExpanded, animated: false)
        setAccessibilityLabel(title)
    }

    func setExpanded(_ value: Bool, animated: Bool) {
        guard value != expanded || !animated else { return }
        expanded = value
        let image = NSImage(systemSymbolName: value ? "chevron.down" : "chevron.right", accessibilityDescription: value ? "折叠" : "展开")!
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            chevron.setSymbolImage(image, contentTransition: .replace.downUp)
        } else {
            chevron.image = image
        }
    }

    @objc private func toggle() { onToggle?() }
}

/// Section header ("分组", "标签") with a + button that creates an entry of that section.
/// The 分组 header also separates the built-in views from user groups (SIDE-03).
final class SidebarHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeader")
    let label = NSTextField(labelWithString: "")
    let add = NSButton()
    private var addTrailing: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        textField = label
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        add.isBordered = false
        add.bezelStyle = .accessoryBarAction
        add.contentTintColor = .secondaryLabelColor
        add.target = nil
        for view in [label, add] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            add.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])
        addTrailing = add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        addTrailing.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// `collapsible` headers leave room for the Show/Hide chevron AppKit adds to group rows.
    func configure(title: String, addTitle: String, action: Selector, identifier: String, collapsible: Bool = false) {
        addTrailing.constant = collapsible ? -26 : -4
        label.stringValue = title
        add.action = action
        add.toolTip = addTitle
        add.setAccessibilityLabel(addTitle)
        add.setAccessibilityIdentifier(identifier)
    }
}
