import AppKit

/// A Markdown editor in a side panel: what a document's tab is (the handles beside the lines, the tools in the middle
/// above, the number of words), as wide as the panel. Tools there is no room for are in the menu at the bar's end.
final class MarkdownPane: NSView {
    private static let barHeight: CGFloat = 42
    private static let gap: CGFloat = 6

    let editor: MarkdownEditorController
    private let bar = NSView()
    private let separator = NSBox()
    private let style = MarkdownFlatButton()
    private let more = MarkdownToolButton("ellipsis", String(localized: "更多工具"))
    private var groups: [ToolGroup] = []
    private let countLabel = NSTextField(labelWithString: "")
    private var countTask: Task<Void, Never>?
    /// 显示 ▸ 显示 Markdown 文档工具栏.
    var showsToolbar = true { didSet { if showsToolbar != oldValue { needsLayout = true } } }
    /// Where the tools are, for tests.
    var toolsFrame: NSRect { groups.filter { !$0.isHidden }.reduce(NSRect.null) { $0.union($1.frame) } }

    init(editor: MarkdownEditorController) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let text = editor.textView
        text.showsGutter = true
        // Room for the handles at the left; little at the right until the panel is wide enough to centre the text.
        text.horizontalInset = MarkdownGutter.width + 8
        text.trailingInset = 18
        text.limitsWidth = true
        text.readableWidth = MarkdownPreferences.current.readableWidth
        text.verticalInset = 14
        addSubview(editor.scrollView)
        separator.boxType = .separator
        style.imagePosition = .imageTrailing
        style.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        style.toolTip = String(localized: "段落样式")
        style.target = self
        style.action = #selector(chooseStyle(_:))
        style.setAccessibilityIdentifier("markdownPaneStyle")
        func tool(_ symbol: String, _ label: String, _ run: @escaping (MarkdownTextView) -> Void) -> MarkdownToolButton {
            let button = MarkdownToolButton(symbol, label)
            button.onClick = { [weak self] in
                guard let self else { return }
                let view = self.editor.textView
                // A table's cell keeps the keyboard (bold, italic… are for its text).
                if view.blockViews.activeCell == nil { self.window?.makeFirstResponder(view) }
                run(view)
            }
            return button
        }
        func menu(_ symbol: String, _ label: String, _ make: @escaping (MarkdownPane) -> NSMenu) -> MarkdownToolButton {
            let button = MarkdownToolButton(symbol, label)
            button.menuMaker = { [weak self] in self.map(make) ?? NSMenu() }
            return button
        }
        // In the order they stand; `rank`: which go first when there is no room (the highest).
        groups = [
            ToolGroup([style], rank: 0),
            ToolGroup([tool("bold", String(localized: "粗体（⌘B）")) { $0.toggleWrap("**") }, tool("italic", String(localized: "斜体（⌘I）")) { $0.toggleWrap("*") },
                       tool("strikethrough", String(localized: "删除线")) { $0.toggleWrap("~~") }, tool("highlighter", String(localized: "高亮")) { $0.toggleWrap("==") },
                       tool("chevron.left.forwardslash.chevron.right", String(localized: "行内代码")) { $0.toggleWrap("`") }], rank: 1),
            ToolGroup([tool("list.bullet", String(localized: "项目列表")) { $0.toggleLineStyle(.bullet) }, tool("list.number", String(localized: "编号列表")) { $0.toggleLineStyle(.numbered) },
                       tool("checklist", String(localized: "任务列表")) { $0.toggleLineStyle(.task) }], rank: 3),
            ToolGroup([tool("text.quote", String(localized: "引用块")) { $0.toggleLineStyle(.quote) }, tool("curlybraces", String(localized: "代码块")) { $0.insertCodeBlock() },
                       tool("tablecells", String(localized: "表格")) { $0.insertTable() }], rank: 4),
            ToolGroup([tool("link", String(localized: "链接（⌘K）")) { $0.insertLink() }, tool("quote.opening", String(localized: "引用文献")) { $0.openMenu(typingSlash: true, citing: true) },
                       tool("plus", String(localized: "插入（/）")) { $0.openMenu(typingSlash: true) }], rank: 2),
            ToolGroup([menu("textformat.size", String(localized: "文字大小、行高和宽度")) { $0.editor.textView.appearanceMenu() },
                       menu("list.bullet.indent", String(localized: "大纲")) { $0.outlineMenu() },
                       tool("magnifyingglass", String(localized: "查找（⌘F）")) { view in
                           let item = NSMenuItem()
                           item.tag = NSTextFinder.Action.showFindInterface.rawValue
                           view.performTextFinderAction(item)
                       }], rank: 5),
            ToolGroup([more], rank: -1),
        ]
        more.menuMaker = { [weak self] in self?.moreMenu() ?? NSMenu() }
        groups.forEach(bar.addSubview)
        bar.setAccessibilityIdentifier("markdownPaneToolbar")
        addSubview(bar)
        addSubview(separator)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.setAccessibilityIdentifier("markdownPaneWordCount")
        addSubview(countLabel)
        editor.onSelectionChange = { [weak self] in self?.updateStyle() }
        editor.onTextChange = { [weak self] in self?.textChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)), name: .folioMarkdownPreferencesDidChange, object: nil)
        textChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        bar.isHidden = !showsToolbar
        separator.isHidden = !showsToolbar
        let top: CGFloat = showsToolbar ? Self.barHeight : 0
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        separator.frame = NSRect(x: 4, y: Self.barHeight - 1, width: max(bounds.width - 8, 0), height: 1)
        editor.scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(bounds.height - top, 0))
        if showsToolbar { placeTools() }
        placeCount()
    }

    /// The tools there is room for, in the middle of the panel.
    private func placeTools() {
        let tools = groups.dropLast(), end = groups[groups.count - 1], room = bounds.width - 16
        func width(_ shown: [ToolGroup]) -> CGFloat { shown.reduce(-Self.gap) { $0 + $1.fittingWidth + Self.gap } }
        var shown = Array(tools)
        while shown.count > 1, width(shown.count < tools.count ? shown + [end] : shown) > room {
            shown.remove(at: shown.indices.max { shown[$0].rank < shown[$1].rank }!)
        }
        end.isHidden = shown.count == tools.count
        tools.forEach { group in group.isHidden = !shown.contains { $0 === group } }
        if !end.isHidden { shown.append(end) }
        var x = max((bounds.width - width(shown)) / 2, 4).rounded()
        for group in shown {
            group.frame = NSRect(x: x, y: (Self.barHeight - 1 - ToolGroup.height) / 2, width: group.fittingWidth, height: ToolGroup.height)
            x += group.fittingWidth + Self.gap
        }
    }

    private func placeCount() {
        countLabel.sizeToFit()
        countLabel.frame.origin = NSPoint(x: bounds.width - countLabel.frame.width - 14, y: bounds.height - countLabel.frame.height - 8)
    }

    private func updateStyle() {
        let title = editor.textView.styleTitle
        if style.title != title {
            style.setTitle(title)
            needsLayout = true
        }
    }

    /// The count a moment after typing stops.
    private func textChanged() {
        updateStyle()
        countTask?.cancel()
        countTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let count = self.editor.wordCount
            self.countLabel.stringValue = count == 0 || !MarkdownPreferences.current.showsWordCount ? "" : String(localized: "\(count) 字")
            self.placeCount()
        }
    }

    @objc private func preferencesDidChange(_ notification: Notification) { textChanged() }

    // MARK: Menus

    /// What there is no room for.
    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        for group in groups.dropLast() where group.isHidden {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            for case let button as MarkdownToolButton in group.buttons {
                let item = button.menuMaker == nil ? NSMenuItem.closure(button.label) { button.onClick() } : NSMenuItem(title: button.label, action: nil, keyEquivalent: "")
                item.image = button.image
                item.submenu = button.menuMaker?()
                menu.addItem(item)
            }
        }
        return menu
    }

    private func outlineMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let headings = editor.headings
        if headings.isEmpty {
            let empty = NSMenuItem(title: String(localized: "没有标题"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let top = headings.map(\.level).min() ?? 1
        for heading in headings {
            let item = NSMenuItem.closure(heading.title) { [weak self] in self?.editor.reveal(heading.location) }
            item.indentationLevel = min(heading.level - top, 5)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseStyle(_ sender: NSButton) {
        let menu = NSMenu()
        let current = editor.textView.blockStyle(at: editor.textView.selectedRange().location)
        for (index, command) in MarkdownCommand.all.enumerated() where command.style != nil {
            if index > 0, MarkdownCommand.all[index - 1].section != command.section { menu.addItem(.separator()) }
            let item = NSMenuItem(title: command.title, action: #selector(setStyle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = command.image
            item.state = command.style == current ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let style = MarkdownCommand.all[sender.tag].style else { return }
        window?.makeFirstResponder(editor.textView)
        editor.textView.setBlockStyle(style)
        updateStyle()
    }
}

/// Tools that stand together, on a capsule as in a window's toolbar.
private final class ToolGroup: NSView {
    static let height: CGFloat = 30
    private static let inset: CGFloat = 3
    let buttons: [NSButton]
    let rank: Int

    init(_ buttons: [NSButton], rank: Int) {
        self.buttons = buttons
        self.rank = rank
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = true
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor }
    }

    private func width(_ button: NSButton) -> CGFloat { button is MarkdownToolButton ? MarkdownToolButton.side.width : ceil(button.intrinsicContentSize.width) }

    var fittingWidth: CGFloat { buttons.reduce(Self.inset * 2) { $0 + width($1) } }

    override func layout() {
        super.layout()
        var x = Self.inset
        for button in buttons {
            button.frame = NSRect(x: x, y: (bounds.height - MarkdownToolButton.side.height) / 2, width: width(button), height: MarkdownToolButton.side.height)
            x += width(button)
        }
    }
}

/// A tool of the panel's bar.
private final class MarkdownToolButton: NSButton {
    static let side = NSSize(width: 27, height: 24)
    var onClick: () -> Void = {}
    /// A button that opens a menu.
    var menuMaker: (() -> NSMenu)?
    private var hovering = false { didSet { needsDisplay = true } }

    let label: String

    init(_ symbol: String, _ label: String) {
        self.label = label
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        contentTintColor = .labelColor
        refusesFirstResponder = true
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(clicked(_:))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    @objc private func clicked(_ sender: Any?) {
        guard let menuMaker else { return onClick() }
        menuMaker().popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        }
        super.draw(dirtyRect)
    }
}

extension MarkdownTextView {
    /// The name of the kind of line the caret is on.
    var styleTitle: String {
        switch blockStyle(at: selectedRange().location) {
        case .text: String(localized: "正文")
        case .heading(let level): String(localized: "标题 \(level)")
        case .bullet: String(localized: "项目列表")
        case .numbered: String(localized: "编号列表")
        case .task: String(localized: "任务列表")
        case .quote: String(localized: "引用块")
        case .code: String(localized: "代码块")
        }
    }
}
