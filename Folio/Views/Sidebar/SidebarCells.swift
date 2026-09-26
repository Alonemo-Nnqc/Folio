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

/// The hairline between built-in and user groups (SIDE-03).
final class SidebarDividerView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarDivider")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let scale = window?.backingScaleFactor ?? 2
        NSRect(x: 10, y: bounds.midY, width: bounds.width - 20, height: 1 / scale).fill()
    }
}

/// "标签" section header.
final class SidebarHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("SidebarHeader")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        let label = NSTextField(labelWithString: "标签")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
}
