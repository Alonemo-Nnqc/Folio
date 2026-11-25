import AppKit

/// The views standing in a document's text: a header on every code block (its language, copying), and a table where
/// the lines of one are.
@MainActor
final class MarkdownBlockViews {
    enum Place { case start, end }

    private weak var textView: MarkdownTextView?
    private var headers: [MarkdownCodeHeader] = []
    private(set) var tables: [MarkdownTableView] = []
    var onHeightsChanged: () -> Void = {}
    private var isLayingOut = false
    private var heightsPending = false
    private var layoutPending = false

    init(textView: MarkdownTextView) { self.textView = textView }

    /// The cell being written in.
    var activeCell: MarkdownCellView? {
        guard let cell = textView?.window?.firstResponder as? MarkdownCellView, tables.contains(where: { $0 === cell.table }) else { return nil }
        return cell
    }

    private var tableWidth: CGFloat {
        guard let container = textView?.textContainer else { return 0 }
        return max(container.size.width - container.lineFragmentPadding * 2, 60)
    }

    /// After the text changed: a view for each table (those that stay keep theirs, and the cell being written in), a
    /// header for each block.
    func refresh() {
        guard let textView else { return }
        let found = textView.structure.tables
        var spare = tables
        var next: [MarkdownTableView?] = found.map { entry in
            spare.firstIndex { $0.table == entry.table }.map { spare.remove(at: $0) }
        }
        for index in next.indices where next[index] == nil {
            // What was edited elsewhere (undo, another window): the view in the same place.
            if found.count == tables.count, let same = spare.firstIndex(where: { $0 === tables[index] }) { next[index] = spare.remove(at: same) }
        }
        spare.forEach { $0.remove() }
        tables = next.enumerated().map { index, view in
            let view = view ?? MarkdownTableView(styler: textView.styler, owner: textView)
            view.show(found[index].table)
            if view.superview == nil { textView.addSubview(view, positioned: .below, relativeTo: textView.gutter.superview === textView ? textView.gutter : nil) }
            return view
        }
        for (index, view) in tables.enumerated() { textView.structure.tableHeights[index] = view.layout(width: tableWidth) }

        let codes = textView.structure.codes.filter(\.isClosed)
        while headers.count > codes.count { headers.removeLast().removeFromSuperview() }
        while headers.count < codes.count {
            let header = MarkdownCodeHeader(textView: textView)
            headers.append(header)
            textView.addSubview(header)
        }
        for (header, code) in zip(headers, codes) { header.show(code) }
        updateSelection()
    }

    /// Tables set anew (another font): `refresh` makes them again.
    func removeTables() {
        tables.forEach { $0.remove() }
        tables = []
    }

    /// Where the text has its blocks now.
    func layout() {
        guard let textView, let manager = textView.layoutManager as? MarkdownLayoutManager, let container = textView.textContainer, !isLayingOut else { return }
        guard textView.textStorage?.editedMask.isEmpty == true, !textView.isChangingText else { return layoutSoon(now: false) }
        isLayingOut = true
        defer { isLayingOut = false }
        let structure = textView.structure
        let length = (textView.string as NSString).length
        guard structure.tables.count == tables.count, (structure.codes.map(\.range) + structure.tables.map(\.range)).allSatisfy({ NSMaxRange($0) <= length }) else { return }
        var changed = false
        for (index, view) in tables.enumerated() {
            let height = view.layout(width: tableWidth)
            if abs(height - structure.tableHeights[index]) > 0.5 {
                textView.structure.tableHeights[index] = height
                changed = true
            }
        }
        if changed, !heightsPending {
            // Not while the text is being laid out.
            heightsPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightsPending = false
                self.onHeightsChanged()
                self.layout()
            }
        }
        let origin = textView.textContainerOrigin
        for (view, entry) in zip(tables, structure.tables) {
            var rect = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: entry.range.location), effectiveRange: nil)
            // Laid out while the text was still being edited, with the height its line had then.
            let wanted = (textView.textStorage?.attribute(.paragraphStyle, at: entry.range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? rect.height
            if rect.height + 0.5 < wanted || rect.height > wanted + 8 {
                manager.invalidateLayout(forCharacterRange: entry.range, actualCharacterRange: nil)
                rect = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: entry.range.location), effectiveRange: nil)
            }
            view.setFrameOrigin(NSPoint(x: origin.x + container.lineFragmentPadding - MarkdownTableView.overhang, y: round(origin.y + rect.maxY - view.frame.height)))
        }
        for (header, code) in zip(headers, structure.codes.filter(\.isClosed)) {
            guard let box = manager.codeBox(code.range) else { continue }
            header.frame = NSRect(x: origin.x + box.minX, y: origin.y + box.minY, width: box.width, height: MarkdownStyler.codeHeaderHeight)
        }
    }

    /// Again once the edit is through: what is laid out during one is not yet what it will be.
    func layoutSoon(now: Bool = true) {
        if now { layout() }
        guard !layoutPending, !tables.isEmpty || !headers.isEmpty else { return }
        layoutPending = true
        DispatchQueue.main.async { [weak self] in
            self?.layoutPending = false
            // By now an edit is through, even one AppKit only asked about.
            self?.textView?.editIsOver()
            self?.layout()
        }
    }

    func focusTable(_ index: Int, at place: Place, selecting: Bool = false) {
        guard tables.indices.contains(index) else { return }
        tables[index].focus(place, selecting: selecting)
    }

    /// A table's cells were edited: its lines become the table as it is now.
    /// Only what differs is changed, in the text's own undo: typing in a cell is undone as typing.
    func write(_ view: MarkdownTableView, _ table: MarkdownTable?, typing: Bool = false) {
        guard let textView, let index = tables.firstIndex(where: { $0 === view }), textView.structure.tables.indices.contains(index) else { return }
        var range = textView.structure.tables[index].range
        let string = textView.string as NSString
        guard let table else {
            textView.window?.makeFirstResponder(textView)
            textView.deleteBlock(range)
            return
        }
        if range.length > 0, string.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        let new = table.markdown as NSString, old = string.substring(with: range) as NSString
        guard new as String != old as String else { return }
        var head = 0, tail = 0
        let shorter = min(new.length, old.length)
        while head < shorter, new.character(at: head) == old.character(at: head) { head += 1 }
        while tail < shorter - head, new.character(at: new.length - 1 - tail) == old.character(at: old.length - 1 - tail) { tail += 1 }
        // Not between the halves of a character.
        if head > 0, UTF16.isLeadSurrogate(new.character(at: head - 1)) { head -= 1 }
        if tail > 0, UTF16.isTrailSurrogate(new.character(at: new.length - tail)) { tail -= 1 }
        textView.writeFromTable(new.substring(with: NSRange(location: head, length: new.length - head - tail)),
                                in: NSRange(location: range.location + head, length: old.length - head - tail), typing: typing)
    }

    /// The whole table selected, to be deleted or copied as one.
    func selectTable(_ view: MarkdownTableView) {
        guard let textView, let index = tables.firstIndex(where: { $0 === view }) else { return }
        textView.selectBlock(textView.structure.tables[index].range)
    }

    /// Tables the selection covers show it.
    func updateSelection() {
        guard let textView else { return }
        let selection = textView.window?.firstResponder === textView ? textView.selectedRange() : NSRange(location: 0, length: 0)
        func covers(_ range: NSRange) -> Bool { selection.length > 0 && selection.location <= range.location && NSMaxRange(selection) >= NSMaxRange(range) - 1 }
        for (view, entry) in zip(tables, textView.structure.tables) { view.isSelected = covers(entry.range) }
    }

    /// The caret leaves a table, up or down.
    func leave(_ view: MarkdownTableView, _ place: Place) {
        guard let textView, let index = tables.firstIndex(where: { $0 === view }) else { return }
        let range = textView.structure.tables[index].range
        let string = textView.string as NSString
        textView.window?.makeFirstResponder(textView)
        switch place {
        case .start:
            if range.location == 0 {
                textView.breakUndoCoalescing()
                textView.replace(NSRange(location: 0, length: 0), with: "\n")
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            } else { textView.setSelectedRange(NSRange(location: range.location - 1, length: 0)) }
        case .end:
            if NSMaxRange(range) == string.length, string.character(at: string.length - 1) != 10 { textView.appendLine() }
            else { textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0)) }
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}

// MARK: - Code blocks

/// The top of a code block: its language, chosen from a menu (or found from the code), and a button that copies it.
final class MarkdownCodeHeader: NSView, NSMenuDelegate {
    private weak var textView: MarkdownTextView?
    private let language = MarkdownFlatButton()
    private let copy = MarkdownFlatButton()
    private var code: MarkdownCode?

    init(textView: MarkdownTextView) {
        self.textView = textView
        super.init(frame: .zero)
        language.imagePosition = .imageTrailing
        language.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        language.toolTip = String(localized: "语言")
        language.target = self
        language.action = #selector(chooseLanguage(_:))
        language.setAccessibilityIdentifier("codeLanguage")
        copy.imagePosition = .imageOnly
        copy.toolTip = String(localized: "拷贝代码")
        copy.setAccessibilityLabel(String(localized: "拷贝代码"))
        copy.target = self
        copy.action = #selector(copyCode(_:))
        showCopy("doc.on.doc")
        for button in [language, copy] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            button.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        NSLayoutConstraint.activate([
            language.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            language.trailingAnchor.constraint(lessThanOrEqualTo: copy.leadingAnchor, constant: -4),
            copy.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), copy.widthAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Between the buttons it is the block's: a click puts the caret on its first line.
    override func mouseDown(with event: NSEvent) {
        guard let textView, let code else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: code.body.location, length: 0))
    }

    func show(_ code: MarkdownCode) {
        self.code = code
        guard let textView else { return }
        let (id, isDetected) = code.language(in: textView.string as NSString)
        let name = id.map { CodeHighlighter.shared.title(of: $0) }
        let title = isDetected ? name ?? String(localized: "自动检测") : name ?? code.info
        if language.title != title { language.setTitle(title) }
    }

    private func showCopy(_ symbol: String) {
        copy.image = NSImage(systemSymbolName: symbol, accessibilityDescription: String(localized: "拷贝代码"))?.withSymbolConfiguration(.init(pointSize: 11.5, weight: .regular))
    }

    @objc private func copyCode(_ sender: Any?) {
        guard let textView, let code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((textView.string as NSString).substring(with: code.text), forType: .string)
        showCopy("checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.showCopy("doc.on.doc") }
    }

    static func languageMenu(for code: MarkdownCode, in string: NSString, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        let (current, isDetected) = code.language(in: string)
        let detected = CodeHighlighter.shared.detect(string.substring(with: code.text)).map { CodeHighlighter.shared.title(of: $0) }
        let auto = NSMenuItem(title: detected.map { String(localized: "自动检测（\($0)）") } ?? String(localized: "自动检测"), action: action, keyEquivalent: "")
        auto.representedObject = ""
        auto.state = isDetected ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        for language in CodeHighlighter.shared.languages {
            let item = NSMenuItem(title: language.id == "plaintext" ? String(localized: "纯文本") : language.title, action: action, keyEquivalent: "")
            item.representedObject = language.id
            item.state = !isDetected && current == language.id ? .on : .off
            menu.addItem(item)
        }
        menu.items.forEach { $0.target = target }
        return menu
    }

    @objc private func chooseLanguage(_ sender: NSButton) {
        guard let textView, let code else { return }
        Self.languageMenu(for: code, in: textView.string as NSString, target: self, action: #selector(setLanguage(_:)))
            .popUp(positioning: nil, at: NSPoint(x: language.frame.minX, y: language.frame.maxY + 4), in: self)
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let textView, let code, let language = sender.representedObject as? String else { return }
        textView.setLanguage(language, of: code)
    }
}

extension MarkdownTextView {
    /// Names the language of a code block in its fence ("": found from the code).
    func setLanguage(_ language: String, of code: MarkdownCode) {
        let string = self.string as NSString
        guard NSMaxRange(code.open) <= string.length else { return }
        let line = string.substring(with: code.open) as NSString
        let fence = line.range(of: #"^\s*(`{3,}|~{3,})"#, options: .regularExpression)
        guard fence.location != NSNotFound else { return }
        let end = (line as String).trimmingCharacters(in: .newlines) as NSString
        breakUndoCoalescing()
        replace(NSRange(location: code.open.location + NSMaxRange(fence), length: end.length - NSMaxRange(fence)), with: language)
    }
}

/// A small flat button that lights up under the pointer.
final class MarkdownFlatButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        contentTintColor = .secondaryLabelColor
        refusesFirstResponder = true
        imageHugsTitle = true
        setTitle("")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    func setTitle(_ text: String) {
        attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
        title = text
        attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor])
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 12
        return size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, isEnabled {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
