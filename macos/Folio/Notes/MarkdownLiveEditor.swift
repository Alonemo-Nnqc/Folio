import AppKit

// MARK: - Text view

/// The editing behaviour of a Markdown editor: lists continue on Return, Tab nests them, task boxes toggle on
/// click, ⌘B / ⌘I / ⌘K wrap the selection, links open with a click on lines not being edited.
final class MarkdownTextView: NSTextView {
    var onFocusChange: (Bool) -> Void = { _ in }
    /// Keeps the text this wide at most and centres it (a document window); 0: use the full width.
    var readableWidth: CGFloat = 0 { didSet { updateInsets() } }
    /// Follows 文档宽度 (a document window).
    var limitsWidth = false
    /// In a side panel: it has a size and a zoom of its own.
    var inPanel = false
    var verticalInset: CGFloat = 8 { didSet { updateInsets() } }
    var horizontalInset: CGFloat = 4 { didSet { updateInsets() } }
    /// Less room at the right than at the left (a side panel).
    var trailingInset: CGFloat? { didSet { updateInsets() } }
    /// Handles beside the line under the pointer.
    var showsGutter = false
    /// What spans lines, as the text is now (the controller keeps it).
    var structure = MarkdownStructure()
    /// The views standing in for tables and the headers of code blocks.
    lazy var blockViews = MarkdownBlockViews(textView: self)
    var styler = MarkdownStyler()
    var isDraggingBlock = false
    private(set) lazy var gutter = MarkdownGutter(textView: self)
    /// Papers that can be cited (nil: citing is not offered).
    var references: ((String) -> [MarkdownReference])?
    /// Where "/" was typed, while its menu is open.
    private var slash: Int?
    /// The "/" was put there by a button, not typed: it goes again when nothing is picked.
    private var slashIsOurs = false
    private lazy var menuPanel = MarkdownMenuPopover()
    private var isMenuOpen: Bool { slash != nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
        blockViews.layout()
    }

    /// The room at the left is not that at the right.
    override var textContainerOrigin: NSPoint {
        var origin = super.textContainerOrigin
        origin.x += insetShift
        return origin
    }

    private var insetShift: CGFloat = 0

    private func updateInsets() {
        let centred = readableWidth > 0 ? (bounds.width - readableWidth) / 2 : 0
        let left = floor(max(horizontalInset, centred)), right = floor(max(trailingInset ?? horizontalInset, centred))
        insetShift = (left - right) / 2
        let inset = NSSize(width: (left + right) / 2, height: verticalInset)
        if textContainerInset != inset { textContainerInset = inset }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { closeMenu(); onFocusChange(false) }
        return accepted
    }

    private var nsString: NSString { string as NSString }

    // MARK: The pointer

    private var pointerArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        pointerArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if showsGutter {
            updateGutter(at: point)
            // Over the handles the pointer is theirs, not the text's.
            if !gutter.isHidden, gutter.frame.contains(point) { return }
        }
        let task = task(at: point)
        if let layout = layoutManager as? MarkdownLayoutManager, layout.hoveredTask != task {
            layout.hoveredTask = task
            needsDisplay = true
        }
        if task != nil { NSCursor.pointingHand.set(); return }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === pointerArea {
            gutter.hide()
            if let layout = layoutManager as? MarkdownLayoutManager, layout.hoveredTask != nil { layout.hoveredTask = nil; needsDisplay = true }
        } else { super.mouseExited(with: event) }
    }

    // MARK: The menu of tools ("/")

    /// Opens the menu at the caret. `typingSlash`: puts the "/" there (+, the toolbar), to type after it and to find it by.
    func openMenu(typingSlash: Bool, citing: Bool = false) {
        guard window != nil, !isMenuOpen else { return }
        window?.makeFirstResponder(self)
        if typingSlash {
            let at = selectedRange().location
            insertText("/", replacementRange: selectedRange())
            slash = at
            slashIsOurs = true
        } else {
            slash = selectedRange().location - 1
            slashIsOurs = false
        }
        menuPanel.state.isCiting = citing
        menuPanel.state.pick = { [weak self] in self?.pick($0) }
        updateMenu()
    }

    private func closeMenu() {
        guard let start = slash else { return }
        slash = nil
        menuPanel.dismiss()
        if slashIsOurs, start < nsString.length, nsString.character(at: start) == 47, selectedRange().location == start + 1 {
            replace(NSRange(location: start, length: 1), with: "")
        }
    }

    /// Follows what is typed after the "/" (what an input method is composing counts too: "biao ti" finds 标题).
    private func updateMenu() {
        guard let start = slash, let window else { return }
        let caret = NSMaxRange(selectedRange())
        guard start < nsString.length, caret > start, !nsString.substring(with: NSRange(location: start, length: caret - start)).contains("\n") else { return closeMenu() }
        let query = nsString.substring(with: NSRange(location: start + 1, length: caret - start - 1))
        let state = menuPanel.state
        let before = state.entries.map(\.id)
        if state.isCiting {
            state.entries = (references?(query) ?? []).map { .reference($0) }
            guard query.count < 60 else { return closeMenu() }
        } else {
            // "/ " is a slash in a sentence, not a menu.
            guard !query.hasPrefix(" ") else { return closeMenu() }
            state.entries = MarkdownCommand.matching(query).filter { $0.id != "cite" || references != nil }.map { .command($0) }
            guard !state.entries.isEmpty else { return closeMenu() }
        }
        state.showsSections = query.isEmpty
        if before != state.entries.map(\.id) { state.selected = 0 }
        let rect = firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
        menuPanel.show(at: rect, of: window)
    }

    private func pick(_ index: Int) {
        guard let start = slash, menuPanel.state.entries.indices.contains(index) else { return }
        let entry = menuPanel.state.entries[index]
        if hasMarkedText() { unmarkText(); inputContext?.discardMarkedText() }
        let caret = NSMaxRange(selectedRange())
        let typed = NSRange(location: start, length: max(min(caret, nsString.length) - start, 0))
        if case .command(let command) = entry, command.id == "cite" {
            // On to the papers: what was typed to find 引用文献 goes, the "/" stays for what is typed next.
            menuPanel.state.isCiting = true
            menuPanel.state.selected = 0
            slashIsOurs = true
            replace(NSRange(location: start + 1, length: max(typed.length - 1, 0)), with: "")
            setSelectedRange(NSRange(location: start + 1, length: 0))
            updateMenu()
            return
        }
        slash = nil
        menuPanel.dismiss()
        breakUndoCoalescing()
        replace(typed, with: "")
        setSelectedRange(NSRange(location: start, length: 0))
        switch entry {
        case .command(let command): command.run(in: self)
        case .reference(let reference): insertText(reference.markdown, replacementRange: selectedRange())
        }
    }

    /// The character typed opens the menu: "/" (or the "、" a Chinese input method types on that key) at the start of a line
    /// or after a space, outside code.
    private func opensMenu(_ typed: String) -> Bool {
        guard styler.preferences.slashMenu, ["/", "、", "／"].contains(typed), !isMenuOpen, !hasMarkedText() else { return false }
        let at = selectedRange().location - 1
        guard at >= 0, at < nsString.length else { return false }
        let line = nsString.paragraphRange(for: NSRange(location: at, length: 0))
        let before = nsString.substring(with: NSRange(location: line.location, length: at - line.location))
        let atStart = before.range(of: #"^[ \t]*(?:>[ \t]?)*(?:[-*+][ \t]+(?:\[[ xX]\][ \t]+)?|\d{1,9}[.)][ \t]+|#{1,6}[ \t]+)?$"#, options: .regularExpression) != nil
        // In a sentence "、" is punctuation.
        guard atStart || (typed == "/" && before.last?.isWhitespace == true) else { return false }
        return !MarkdownStyler.codeBlocks(in: nsString).contains { NSLocationInRange(at, $0) }
    }

    private var isWritingFromTable = false

    /// What was written in a table's cell, in its lines.
    func writeFromTable(_ text: String, in range: NSRange, typing: Bool) {
        isWritingFromTable = true
        defer { isWritingFromTable = false }
        if typing, range.length == 0 { super.insertText(text, replacementRange: range) }
        else {
            if !typing { breakUndoCoalescing() }
            replace(range, with: text)
        }
    }

    /// The text does not scroll to what a cell writes: the cell is where it is.
    override func scrollRangeToVisible(_ range: NSRange) {
        if !isWritingFromTable { super.scrollRangeToVisible(range) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        if opensMenu(typed) { openMenu(typingSlash: false) }
        else if typed == " " || typed == "\u{3000}", !hasMarkedText(), styler.preferences.completesSymbols { completeSymbols() }
    }

    /// An address pasted over text makes it a link.
    override func paste(_ sender: Any?) {
        let range = selectedRange()
        if styler.preferences.pastesLinks, range.length > 0, structure.code(at: range.location) == nil, let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil, !nsString.substring(with: range).contains("\n") {
            breakUndoCoalescing()
            let link = "[\(nsString.substring(with: range))](\(text))"
            replace(range, with: link)
            setSelectedRange(NSRange(location: range.location + (link as NSString).length, length: 0))
            return
        }
        super.paste(sender)
    }

    /// ⌘A in a code block: its code first, then everything.
    override func selectAll(_ sender: Any?) {
        if let code = structure.code(at: selectedRange().location), code.isClosed, code.text.length > 0, selectedRange() != code.text { return setSelectedRange(code.text) }
        super.selectAll(sender)
    }

    override func didChangeText() {
        isChangingText = false
        super.didChangeText()
        if isMenuOpen { updateMenu() }
        gutter.hide()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard let start = slash else { return }
        // The caret left what is being typed.
        let range = selectedRange()
        if range.location <= start || range.length > 0 && !hasMarkedText() { closeMenu() }
    }

    override func keyDown(with event: NSEvent) {
        if isMenuOpen {
            let state = menuPanel.state
            switch event.keyCode {
            case 125, 126:
                if !state.entries.isEmpty {
                    state.selected = (state.selected + (event.keyCode == 125 ? 1 : state.entries.count - 1)) % state.entries.count
                }
                return
            case 36, 76, 48:
                if state.entries.isEmpty { closeMenu() } else { pick(state.selected) }
                return
            case 53:
                if hasMarkedText() { break }
                closeMenu()
                return
            default: break
            }
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == [.command, .control], event.keyCode == 125 || event.keyCode == 126 {
            moveCaretBlock(by: event.keyCode == 125 ? 1 : -1)
            return
        }
        if flags == .command, event.keyCode == 36 {
            let caret = selectedRange().location
            // ⌘Return: done or not, in a task; on to a line below, in a code block.
            if let code = structure.code(at: caret), code.isClosed {
                let end = NSMaxRange(code.range)
                if end == nsString.length, nsString.character(at: end - 1) != 10 { appendLine() } else { setSelectedRange(NSRange(location: end, length: 0)) }
                return
            }
            if case .task = MarkdownLine(in: nsString, at: caret).kind { return toggleTask(at: caret) }
        }
        super.keyDown(with: event)
    }

    private func task(at point: NSPoint) -> Int? {
        guard let layout = layoutManager as? MarkdownLayoutManager else { return nil }
        let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        return layout.taskBoxes.first { $0.rect.insetBy(dx: -4, dy: -4).contains(local) }?.location
    }

    override func mouseDown(with event: NSEvent) {
        closeMenu()
        let point = convert(event.locationInWindow, from: nil)
        if let location = task(at: point) { return toggleTask(at: location) }
        // Below a document that ends in a table or a code block there is nowhere to write: a line is added.
        if let layout = layoutManager, let container = textContainer, point.y > textContainerOrigin.y + layout.usedRect(for: container).maxY, endsInBlock {
            window?.makeFirstResponder(self)
            return appendLine()
        }
        super.mouseDown(with: event)
    }

    /// The last thing is a code block or a table, without a line after it.
    private var endsInBlock: Bool {
        let end = nsString.length
        guard end > 0, nsString.character(at: end - 1) != 10 else { return false }
        return structure.codes.contains { $0.isClosed && NSMaxRange($0.range) == end } || structure.tables.contains { NSMaxRange($0.range) == end }
    }

    /// An empty line at the end, the caret on it.
    func appendLine() {
        breakUndoCoalescing()
        replace(NSRange(location: nsString.length, length: 0), with: "\n")
        setSelectedRange(NSRange(location: nsString.length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Zooming

    /// Pinching zooms the page as a whole: text, spacing, tables, pictures and the column they stand in.
    var onZoom: ((Double, NSPoint?) -> Void)?
    private var isFixedSize: Bool { !isEditable }

    override func magnify(with event: NSEvent) {
        guard !isFixedSize, let scroll = enclosingScrollView else { return super.magnify(with: event) }
        if event.phase == .began { pinched = scroll.magnification }
        pinched = min(max(pinched * (1 + event.magnification), MarkdownPreferences.zooms.lowerBound), MarkdownPreferences.zooms.upperBound)
        // Actual size holds a little, so it can be found again.
        let zoom = abs(pinched - 1) < 0.025 ? 1 : pinched
        onZoom?(zoom, convert(event.locationInWindow, from: nil))
        if event.phase == .ended || event.phase == .cancelled { keepZoom() }
    }

    private var pinched: CGFloat = 1

    override func smartMagnify(with event: NSEvent) { actualSize(nil) }

    @objc func zoomIn(_ sender: Any?) { step(to: MarkdownPreferences.zoomSteps.first { $0 > zoomFactor + 0.005 } ?? MarkdownPreferences.zooms.upperBound) }
    @objc func zoomOut(_ sender: Any?) { step(to: MarkdownPreferences.zoomSteps.last { $0 < zoomFactor - 0.005 } ?? MarkdownPreferences.zooms.lowerBound) }
    @objc func actualSize(_ sender: Any?) { step(to: 1) }

    var zoomFactor: Double { Double(enclosingScrollView?.magnification ?? 1) }

    func step(to zoom: Double) {
        guard !isFixedSize else { return }
        onZoom?(zoom, nil)
        keepZoom()
    }

    private func keepZoom() {
        guard let settings = AppDelegate.shared.model?.settings else { return }
        settings.markdown.setZoom(zoomFactor, inPanel: inPanel)
    }

    /// Sizes, spacing, typeface and width, as in 设置 ▸ Markdown.
    func appearanceMenu() -> NSMenu {
        let menu = NSMenu()
        let preferences = MarkdownPreferences.current
        let size = preferences.size(inPanel: inPanel)
        func item(_ title: String, _ key: String = "", on: Bool = false, _ run: @escaping (inout MarkdownPreferences) -> Void) -> NSMenuItem {
            let item = NSMenuItem.closure(title) {
                guard let settings = AppDelegate.shared.model?.settings else { return }
                run(&settings.markdown)
            }
            item.keyEquivalent = key
            item.state = on ? .on : .off
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            items.forEach(sub.addItem)
            entry.submenu = sub
            menu.addItem(entry)
        }
        let panel = inPanel
        func zoomItem(_ title: String, _ key: String, _ run: @escaping (MarkdownTextView) -> Void) {
            let item = NSMenuItem.closure(title) { [weak self] in if let self { run(self) } }
            item.keyEquivalent = key
            menu.addItem(item)
        }
        zoomItem(String(localized: "放大"), "+") { $0.zoomIn(nil) }
        zoomItem(String(localized: "缩小"), "-") { $0.zoomOut(nil) }
        zoomItem(String(localized: "实际大小（现为 \(Int((zoomFactor * 100).rounded()))%）"), "0") { $0.actualSize(nil) }
        menu.addItem(.separator())
        submenu(String(localized: "字号"), [11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24].map { value in item("\(value) pt", on: size == Double(value)) { $0.setSize(Double(value), inPanel: panel) } })
        submenu(String(localized: "行高"), [1.3, 1.45, 1.6, 1.75, 1.9, 2.1].map { value in item(String(format: "%.2f", value), on: abs(preferences.lineHeight - value) < 0.01) { $0.lineHeight = value } })
        submenu(String(localized: "段落间距"), [0, 0.2, 0.4, 0.6, 0.8, 1].map { value in item(String(format: "%.1f", value), on: abs(preferences.paragraphSpacing - value) < 0.01) { $0.paragraphSpacing = value } })
        submenu(String(localized: "字体"), MarkdownPreferences.Typeface.allCases.map { face in item(face.title, on: preferences.typeface == face) { $0.typeface = face } })
        submenu(String(localized: "文档宽度"), MarkdownPreferences.widths.map { entry in item(entry.title, on: preferences.readableWidth == entry.width) { $0.readableWidth = entry.width } })
        menu.addItem(.separator())
        menu.addItem(.closure(String(localized: "Markdown 设置…")) {
            AppDelegate.shared.showSettings(nil)
            AppDelegate.shared.settingsWindow?.select(pane: "markdown")
        })
        return menu
    }

    /// The handles stand beside a line that moved.
    func gutterIsStale() { gutter.hide() }

    private static let taskPattern = try! NSRegularExpression(pattern: #"^([ \t]*(?:>[ \t]?)*[ \t]*[-*+][ \t]+\[)([ xX])(\])"#)

    func toggleTask(at location: Int) {
        let line = nsString.paragraphRange(for: NSRange(location: min(location, nsString.length), length: 0))
        guard let match = Self.taskPattern.firstMatch(in: string, range: line) else { return }
        let mark = match.range(at: 2)
        let done = nsString.substring(with: mark) != " "
        replace(mark, with: done ? " " : "x")
    }

    /// An undoable edit, as if typed.
    func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }

    /// Between an edit and the end of it.
    private(set) var isChangingText = false

    func editIsOver() { isChangingText = false }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let allowed = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if allowed, replacementStrings != nil { isChangingText = true }
        return allowed
    }

    // MARK: Where the caret can be

    /// The symbols at the start of a line, the fences of a code block and a rule are not drawn: the caret passes them.
    func caretLocation(for proposed: Int, from old: Int) -> Int {
        var location = proposed
        for _ in 0..<4 {
            let next = step(location, from: old)
            if next == location { break }
            location = next
        }
        return location
    }

    private func step(_ location: Int, from old: Int) -> Int {
        let forward = location >= old
        let text = nsString
        if let code = structure.code(at: location) {
            guard let close = code.close, NSMaxRange(code.range) <= text.length else { return location }
            if NSLocationInRange(location, code.open) {
                return !forward && code.range.location > 0 ? code.range.location - 1 : code.body.location
            }
            if location >= close.location, location <= NSMaxRange(close) {
                let ends = NSMaxRange(close) > close.location && text.character(at: NSMaxRange(close) - 1) == 10
                return forward && ends && !NSLocationInRange(old, NSRange(location: close.location, length: 1)) ? NSMaxRange(close) : max(close.location - 1, code.body.location)
            }
            return location
        }
        // The end of a document that ends with a fence.
        if location == text.length, location > 0, let code = structure.codes.last, let close = code.close, NSMaxRange(close) == location, text.character(at: location - 1) != 10 {
            return max(close.location - 1, code.body.location)
        }
        if structure.table(at: location) != nil { return location }
        let line = MarkdownLine(in: text, at: location)
        if line.kind == .rule {
            let whole = text.paragraphRange(for: NSRange(location: location, length: 0))
            // A rule just typed keeps the caret until it leaves.
            if NSLocationInRange(old, whole) || (old == NSMaxRange(whole) && old == text.length && NSMaxRange(line.content) == old) { return location }
            if forward, NSMaxRange(whole) > NSMaxRange(line.content) { return NSMaxRange(whole) }
            return !forward && whole.location > 0 ? whole.location - 1 : location
        }
        guard location < line.textStart else { return location }
        if old == line.textStart, location == old - 1 { return line.content.location > 0 ? line.content.location - 1 : line.textStart }
        return line.textStart
    }

    /// A selection takes tables whole, and code blocks it does not lie inside of; made smaller, it leaves them whole. It
    /// never begins or ends among the symbols of a line.
    func selection(for proposed: NSRange, from old: NSRange) -> NSRange {
        guard proposed.length > 0, NSMaxRange(proposed) <= nsString.length else { return proposed }
        var range = proposed
        let shrinks = old.length > proposed.length && NSIntersectionRange(old, proposed) == proposed
        func take(_ block: NSRange) {
            var inner = block
            if inner.length > 0, nsString.character(at: NSMaxRange(inner) - 1) == 10 { inner.length -= 1 }
            guard range.location < NSMaxRange(inner), NSMaxRange(range) > inner.location,
                  !(range.location <= inner.location && NSMaxRange(range) >= NSMaxRange(inner)) else { return }
            if shrinks, range.location < inner.location { range.length = inner.location - range.location }
            else if shrinks, NSMaxRange(range) > NSMaxRange(inner) { range = NSRange(location: NSMaxRange(inner), length: NSMaxRange(range) - NSMaxRange(inner)) }
            else { range = NSUnionRange(range, inner) }
        }
        for table in structure.tables { take(table.range) }
        for code in structure.codes where code.isClosed {
            if range.location >= code.text.location, NSMaxRange(range) <= NSMaxRange(code.text) { continue }
            take(code.range)
        }
        guard range.length > 0 else { return range }
        func symbols(_ location: Int) -> MarkdownLine? {
            guard structure.code(at: location) == nil, structure.table(at: location) == nil else { return nil }
            let line = MarkdownLine(in: nsString, at: location)
            return location > line.content.location && location < line.textStart ? line : nil
        }
        if let line = symbols(range.location) { range = NSRange(location: line.textStart, length: max(NSMaxRange(range) - line.textStart, 0)) }
        if let line = symbols(NSMaxRange(range)) { range.length = (shrinks ? line.content.location : line.textStart) - range.location }
        return range.length > 0 ? range : NSRange(location: max(range.location, 0), length: 0)
    }

    /// The table, code block or rule that is selected, and nothing else.
    private var selectedBlock: NSRange? {
        let selection = selectedRange()
        guard selection.length > 0 else { return nil }
        func matches(_ block: NSRange) -> Bool {
            var inner = block
            if inner.length > 0, nsString.character(at: NSMaxRange(inner) - 1) == 10 { inner.length -= 1 }
            return selection == inner || selection == block
        }
        return (structure.tables.map(\.range) + structure.codes.filter(\.isClosed).map(\.range)).first(where: matches)
    }

    /// Selects a table or code block, to be deleted, copied or moved as one.
    func selectBlock(_ block: NSRange) {
        window?.makeFirstResponder(self)
        var inner = block
        if inner.length > 0, nsString.character(at: NSMaxRange(inner) - 1) == 10 { inner.length -= 1 }
        setSelectedRange(inner)
        scrollRangeToVisible(NSRange(location: inner.location, length: 0))
    }

    override func cut(_ sender: Any?) {
        guard let block = selectedBlock else { return super.cut(sender) }
        copy(sender)
        deleteBlock(block)
    }

    override func moveDown(_ sender: Any?) {
        let before = selectedRange()
        super.moveDown(sender)
        // Out of a code block that ends the document.
        guard endsInBlock, let code = structure.codes.last, NSMaxRange(code.range) == nsString.length, code.isClosed,
              before.length == 0, before.location >= code.body.location else { return }
        let last = nsString.paragraphRange(for: NSRange(location: NSMaxRange(code.text), length: 0))
        if NSLocationInRange(before.location, last), NSLocationInRange(selectedRange().location, last) { appendLine() }
    }

    // MARK: Return, Tab, Backspace

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else { return super.insertNewline(sender) }
        let caret = selectedRange().location
        if let code = MarkdownCode.all(in: nsString).first(where: { NSLocationInRange(caret, $0.range) || (!$0.isClosed && caret == NSMaxRange($0.range)) }) {
            if !code.isClosed, caret >= code.open.location, caret <= NSMaxRange(code.open),
               nsString.substring(with: code.open).trimmingCharacters(in: .newlines).count == caret - code.open.location || code.open.length == caret - code.open.location {
                // The fence just typed becomes a block, its end with it.
                let fence = nsString.substring(with: code.open).trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0 == "`" || $0 == "~" }
                breakUndoCoalescing()
                insertText("\n\n" + fence + (NSMaxRange(code.open) >= nsString.length ? "\n" : ""), replacementRange: selectedRange())
                setSelectedRange(NSRange(location: caret + 1, length: 0))
                return
            }
            // Inside a code block Return keeps the indentation, one step more after an opening bracket or a colon.
            let line = nsString.paragraphRange(for: NSRange(location: caret, length: 0))
            let before = nsString.substring(with: NSRange(location: line.location, length: caret - line.location))
            var indent = String(before.prefix { $0 == " " || $0 == "\t" })
            let step = indent.contains("\t") ? "\t" : codeStep
            let last = before.trimmingCharacters(in: .whitespaces).last
            let next = caret < nsString.length ? nsString.substring(with: NSRange(location: caret, length: 1)) : ""
            let opens = last.map { "{[(:".contains($0) } ?? false
            let pair = (last == "{" && next == "}") || (last == "[" && next == "]") || (last == "(" && next == ")")
            let outer = indent
            if opens { indent += step }
            insertText("\n" + indent + (pair ? "\n" + outer : ""), replacementRange: selectedRange())
            if pair { setSelectedRange(NSRange(location: caret + 1 + (indent as NSString).length, length: 0)) }
            return
        }
        let line = MarkdownLine(in: nsString, at: caret)
        // What a Chinese keyboard types for a fence.
        if nsString.substring(with: line.content) == "···" {
            replace(line.content, with: "")
            return insertCodeBlock()
        }
        let quote = nsString.substring(with: NSRange(location: line.content.location, length: line.quoteLength))
        // 回车延续列表和引用 is off: an empty item or quote still ends with Return.
        if !styler.preferences.continuesLists, line.kind.isList || line.quoteDepth > 0, !line.isEmpty { return super.insertNewline(sender) }
        switch line.kind {
        case .bullet, .numbered, .task:
            if line.isEmpty { return leave(line) }
            // At the start of the text: an empty item above.
            let marker = nsString.substring(with: line.marker)
            var next = quote + String(repeating: " ", count: line.indent)
            switch line.kind {
            case .numbered(let number): next += "\(number + 1)" + marker.suffix(1) + " "
            case .task: next += marker + " [ ] "
            default: next += marker + " "
            }
            breakUndoCoalescing()
            insertText("\n" + next, replacementRange: selectedRange())
            renumber(around: selectedRange().location)
        case .heading where caret == line.textStart && !line.isEmpty:
            replace(NSRange(location: line.content.location, length: 0), with: "\n")
        case .heading where line.isEmpty:
            leave(line)
        default:
            if line.quoteDepth > 0 {
                if line.isEmpty { return leave(line) }
                insertText("\n" + quote, replacementRange: selectedRange())
            } else { super.insertNewline(sender) }
        }
    }

    /// Shift-Return: a line of the same item or quote.
    override func insertLineBreak(_ sender: Any?) {
        guard !hasMarkedText(), structure.code(at: selectedRange().location) == nil else { return insertNewline(sender) }
        let line = MarkdownLine(in: nsString, at: selectedRange().location)
        let quote = nsString.substring(with: NSRange(location: line.content.location, length: line.quoteLength))
        if line.kind.isList { insertText("\n" + quote + String(repeating: " ", count: line.childIndent), replacementRange: selectedRange()) }
        else if line.kind == .continuation {
            insertText("\n" + nsString.substring(with: line.prefix), replacementRange: selectedRange())
        } else { insertText("\n" + quote, replacementRange: selectedRange()) }
    }

    /// Takes a line one step towards plain text: out one level of its list, out of the list, out of the quote.
    private func leave(_ line: MarkdownLine) {
        breakUndoCoalescing()
        let start = line.content.location + line.quoteLength
        if line.kind.isList, line.indent > 0, MarkdownLine.level(of: line, in: nsString) > 0 {
            _ = indentListLines(by: -1)
        } else if line.kind != .text, line.kind != .rule {
            replace(NSRange(location: start, length: line.textStart - start), with: "")
            setSelectedRange(NSRange(location: start, length: 0))
            renumber(around: min(NSMaxRange(nsString.paragraphRange(for: NSRange(location: start, length: 0))), nsString.length))
        } else if line.quoteDepth > 0 {
            var quote = nsString.substring(with: NSRange(location: line.content.location, length: line.quoteLength))
            if let last = quote.lastIndex(of: ">") { quote = String(quote[..<last]) }
            // The line itself becomes text: a quote ends where its symbol does, no empty line is put between.
            replace(NSRange(location: line.content.location, length: line.quoteLength), with: quote)
            setSelectedRange(NSRange(location: line.content.location + (quote as NSString).length, length: 0))
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if !hasMarkedText(), let block = selectedBlock { return deleteBlock(block) }
        guard !hasMarkedText(), selection.length == 0 else {
            super.deleteBackward(sender)
            return renumber(around: selectedRange().location)
        }
        let caret = selection.location
        let text = nsString
        if let code = structure.code(at: caret), code.isClosed {
            if caret == code.body.location {
                // An empty block goes; a block's code never runs into what is above it.
                if code.text.length == 0 {
                    breakUndoCoalescing()
                    var range = code.range
                    if text.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
                    replace(range, with: "")
                    setSelectedRange(NSRange(location: range.location, length: 0))
                }
                return
            }
            // Back over a step of indentation at once.
            let line = text.paragraphRange(for: NSRange(location: caret, length: 0))
            let before = text.substring(with: NSRange(location: line.location, length: caret - line.location))
            if !before.isEmpty, before.allSatisfy({ $0 == " " }) {
                let count = (before.count - 1) % codeStep.count + 1
                return replace(NSRange(location: caret - count, length: count), with: "")
            }
            return super.deleteBackward(sender)
        }
        let line = MarkdownLine(in: text, at: caret)
        if line.prefix.length > 0, line.kind != .rule, caret == line.textStart {
            if line.kind == .continuation {
                // Up to the end of the line above, its indentation with it.
                return replace(NSRange(location: line.content.location - 1, length: line.prefix.length + 1), with: "")
            }
            return leave(line)
        }
        if caret == line.content.location, caret > 0 {
            let above = caret - 1
            // After a table or a code block: first it is selected, then (Backspace again) it goes.
            if let block = (structure.codes.filter(\.isClosed).map(\.range) + structure.tables.map(\.range)).first(where: { NSMaxRange($0) == caret }) {
                return selectBlock(block)
            }
            let before = MarkdownLine(in: text, at: above)
            if before.kind == .rule {
                return replace(NSRange(location: before.content.location, length: caret - before.content.location), with: "")
            }
        }
        super.deleteBackward(sender)
        renumber(around: selectedRange().location)
    }

    override func deleteForward(_ sender: Any?) {
        let selection = selectedRange()
        if !hasMarkedText(), let block = selectedBlock { return deleteBlock(block) }
        guard !hasMarkedText(), selection.length == 0, selection.location < nsString.length, nsString.character(at: selection.location) == 10 else { return super.deleteForward(sender) }
        let below = selection.location + 1
        if let code = structure.code(at: selection.location), let close = code.close, below == close.location { return }
        if let block = (structure.tables.map(\.range) + structure.codes.filter(\.isClosed).map(\.range)).first(where: { $0.location == below }) {
            return selectBlock(block)
        }
        // The symbols of the line below go with the line break.
        let line = MarkdownLine(in: nsString, at: below)
        replace(NSRange(location: selection.location, length: 1 + (line.kind == .rule ? line.content.length : line.prefix.length)), with: "")
        renumber(around: selection.location)
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertTab(sender) }
        if let code = structure.code(at: selectedRange().location) { return indentCode(code, by: 1) }
        if indentListLines(by: 1) { return }
        // A tab at the start of a line would make it code.
        let line = MarkdownLine(in: nsString, at: selectedRange().location)
        if selectedRange().length == 0, selectedRange().location > line.textStart { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText() else { return super.insertBacktab(sender) }
        if let code = structure.code(at: selectedRange().location) { return indentCode(code, by: -1) }
        _ = indentListLines(by: -1)
    }

    private var codeStep: String { String(repeating: " ", count: styler.preferences.codeIndent) }

    /// A step of spaces at the caret, or before each line selected (or taken away).
    private func indentCode(_ code: MarkdownCode, by step: Int) {
        let selection = selectedRange()
        if step > 0, selection.length == 0 { return insertText(codeStep, replacementRange: selection) }
        let lines = nsString.paragraphRange(for: NSIntersectionRange(selection, code.text).length > 0 ? NSIntersectionRange(selection, code.text) : NSRange(location: selection.location, length: 0))
        var body = NSIntersectionRange(lines, code.body)
        if body.length > 0, nsString.character(at: NSMaxRange(body) - 1) == 10 { body.length -= 1 }
        let parts = nsString.substring(with: body).components(separatedBy: "\n")
        let changed = parts.map { line -> String in
            if step > 0 { return line.isEmpty ? line : codeStep + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            return String(line.dropFirst(min(line.prefix { $0 == " " }.count, codeStep.count)))
        }
        let first = (changed[0] as NSString).length - (parts[0] as NSString).length
        let text = changed.joined(separator: "\n")
        guard text != nsString.substring(with: body) else { return }
        breakUndoCoalescing()
        replace(body, with: text)
        if selection.length == 0 { setSelectedRange(NSRange(location: max(selection.location + first, body.location), length: 0)) }
        else { setSelectedRange(NSRange(location: body.location, length: (text as NSString).length)) }
    }

    /// Nests (or un-nests) the list items the selection touches, with what is under them. False when it touches none.
    @discardableResult private func indentListLines(by step: Int) -> Bool {
        let selection = selectedRange()
        var starts: [Int] = []
        let touched = nsString.paragraphRange(for: selection)
        var at = touched.location
        repeat {
            let line = MarkdownLine(in: nsString, at: at)
            guard line.kind.isList || line.kind == .continuation else { return false }
            starts.append(at)
            at = NSMaxRange(nsString.paragraphRange(for: NSRange(location: at, length: 0)))
        } while at < NSMaxRange(touched)
        let first = MarkdownLine(in: nsString, at: starts[0])
        guard first.kind.isList else { return true }
        var target: Int
        if step > 0 {
            // Under the item above on the same level; a first item has nothing to be nested under.
            var above: MarkdownLine?
            var back = first.content.location
            while back > 0 {
                let line = MarkdownLine(in: nsString, at: back - 1)
                guard line.kind.isList || line.kind == .continuation, line.quoteDepth == first.quoteDepth else { break }
                if line.kind.isList, line.indent <= first.indent { above = line; break }
                back = line.content.location
            }
            guard let above, above.indent == first.indent || above.childIndent > first.indent else { return true }
            target = above.childIndent
        } else {
            guard first.indent > 0 else { return true }
            target = 0
            var back = first.content.location
            while back > 0 {
                let line = MarkdownLine(in: nsString, at: back - 1)
                guard line.kind.isList || line.kind == .continuation else { break }
                if line.kind.isList, line.indent < first.indent { target = line.indent; break }
                back = line.content.location
            }
        }
        let change = target - first.indent
        guard change != 0 else { return true }
        // What is under the last item goes along.
        let lastLevel = MarkdownLine(in: nsString, at: starts.last!).indent
        while at < nsString.length {
            let line = MarkdownLine(in: nsString, at: at)
            guard line.kind.isList && line.indent > lastLevel || line.kind == .continuation else { break }
            starts.append(at)
            at = NSMaxRange(nsString.paragraphRange(for: NSRange(location: at, length: 0)))
        }
        breakUndoCoalescing()
        var shift = 0, caretShift = 0, endShift = 0
        for start in starts {
            let line = MarkdownLine(in: nsString, at: start + shift)
            let white = NSRange(location: line.content.location + line.quoteLength, length: 0)
            let content = nsString.substring(with: NSRange(location: white.location, length: NSMaxRange(line.content) - white.location))
            let lead = content.prefix { $0 == " " || $0 == "\t" }
            let columns = max(MarkdownLine.columns(String(lead)) + change, 0)
            let delta = columns - (lead as NSString).length
            replace(NSRange(location: white.location, length: (lead as NSString).length), with: String(repeating: " ", count: columns))
            shift += delta
            if start <= selection.location { caretShift += delta }
            if start < NSMaxRange(selection) || start <= selection.location { endShift += delta }
        }
        setSelectedRange(NSRange(location: max(selection.location + caretShift, 0), length: max(selection.length + endShift - caretShift, 0)))
        renumber(around: selectedRange().location)
        return true
    }

    /// Numbers the list around `location` again: each level from its first item's number, one by one.
    func renumber(around location: Int) {
        guard structure.code(at: location) == nil, !(undoManager?.isUndoing ?? false), !(undoManager?.isRedoing ?? false) else { return }
        let list = MarkdownLine.list(around: location, in: nsString)
        var counts: [(indent: Int, next: Int)] = []
        var at = list.location, end = NSMaxRange(list)
        var selection = selectedRange()
        while at < end {
            let line = MarkdownLine(in: nsString, at: at)
            guard line.kind.isList else {
                at = NSMaxRange(nsString.paragraphRange(for: NSRange(location: at, length: 0)))
                continue
            }
            while let last = counts.last, last.indent > line.indent { counts.removeLast() }
            if case .numbered(let number) = line.kind {
                // A nested list begins with 1.
                let follows = counts.last.map { $0.indent == line.indent && $0.next > 0 } ?? false
                if !follows, !counts.isEmpty, counts.last?.indent != line.indent { counts.append((line.indent, 1)) }
                if let last = counts.last, last.indent == line.indent, last.next > 0 {
                    if number != last.next {
                        let mark = NSRange(location: line.marker.location, length: line.marker.length - 1)
                        let text = "\(last.next)"
                        let delta = (text as NSString).length - mark.length
                        replace(mark, with: text)
                        if selection.location > mark.location { selection.location += delta }
                        end += delta
                    }
                    counts[counts.count - 1].next += 1
                } else {
                    if counts.last?.indent == line.indent { counts.removeLast() }
                    counts.append((line.indent, number + 1))
                }
            } else {
                // Another kind of list on this level: numbers begin anew after it.
                if counts.last?.indent == line.indent { counts[counts.count - 1].next = 0 } else { counts.append((line.indent, 0)) }
            }
            at = NSMaxRange(nsString.paragraphRange(for: NSRange(location: at, length: 0)))
        }
        if selection != selectedRange() { setSelectedRange(selection) }
    }

    /// What typing a space completes: the symbols a Chinese keyboard types for Markdown's, and a task without its dash.
    private func completeSymbols() {
        let caret = selectedRange().location
        let line = MarkdownLine(in: nsString, at: caret)
        guard line.kind == .text || line.kind == .bullet, structure.code(at: caret) == nil else { return }
        let before = NSRange(location: line.textStart, length: max(caret - line.textStart, 0))
        let symbols = ["》 ": "> ", "》　": "> ", "【】 ": "- [ ] ", "[] ": "- [ ] ", "[ ] ": "- [ ] ", "・ ": "- ", "· ": "- "]
        guard let markdown = symbols[nsString.substring(with: before)] else { return }
        breakUndoCoalescing()
        var range = before
        // "- []" is a task already begun.
        if line.kind == .bullet {
            guard markdown == "- [ ] " else { return }
            range = NSRange(location: line.marker.location, length: caret - line.marker.location)
        }
        replace(range, with: markdown)
        setSelectedRange(NSRange(location: range.location + (markdown as NSString).length, length: 0))
    }

    /// Wraps the selection in `marker` (or unwraps it); with nothing selected, puts the caret between a pair.
    func toggleWrap(_ marker: String) {
        if let cell = blockViews.activeCell { return cell.toggleWrap(marker) }
        let range = selectedRange()
        let m = (marker as NSString).length
        let selected = nsString.substring(with: range)
        if selected.hasPrefix(marker), selected.hasSuffix(marker), (selected as NSString).length >= 2 * m {
            replace(range, with: String(selected.dropFirst(marker.count).dropLast(marker.count)))
            setSelectedRange(NSRange(location: range.location, length: range.length - 2 * m))
            return
        }
        if range.location >= m, NSMaxRange(range) + m <= nsString.length,
           nsString.substring(with: NSRange(location: range.location - m, length: m)) == marker,
           nsString.substring(with: NSRange(location: NSMaxRange(range), length: m)) == marker {
            replace(NSRange(location: NSMaxRange(range), length: m), with: "")
            replace(NSRange(location: range.location - m, length: m), with: "")
            setSelectedRange(NSRange(location: range.location - m, length: range.length))
            return
        }
        replace(range, with: marker + selected + marker)
        setSelectedRange(NSRange(location: range.location + m, length: range.length))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": toggleWrap("**"); return true
        case "i": toggleWrap("*"); return true
        case "k":
            insertLink()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Formatting (the document toolbar)

    /// `[text](https://)` around the selection, the address selected (or the caret in the brackets).
    func insertLink() {
        let range = selectedRange()
        let text = nsString.substring(with: range)
        replace(range, with: "[\(text)](https://)")
        let urlStart = range.location + (text as NSString).length + 3
        setSelectedRange(text.isEmpty ? NSRange(location: range.location + 1, length: 0) : NSRange(location: urlStart, length: 8))
    }

    /// The lines the selection touches, without their line breaks, and the range they span.
    private func selectedLines() -> (range: NSRange, lines: [String]) {
        var range = nsString.paragraphRange(for: selectedRange())
        if range.length > 0, nsString.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return (range, nsString.substring(with: range).components(separatedBy: "\n"))
    }

    private func replaceLines(_ range: NSRange, with lines: [String]) {
        let text = lines.joined(separator: "\n")
        breakUndoCoalescing()
        replace(range, with: text)
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        window?.makeFirstResponder(self)
    }

    /// 标题 1–3 for the lines touched; the same level again makes them plain text (0: plain text).
    func toggleHeading(_ level: Int) {
        let (range, lines) = selectedLines()
        let pattern = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)
        let marker = String(repeating: "#", count: level) + " "
        let all = level > 0 && lines.allSatisfy { $0.hasPrefix(marker) }
        replaceLines(range, with: lines.map { line in
            let body = pattern.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            return all || level == 0 ? body : marker + body
        })
    }

    /// What kind of block a line is.
    enum BlockStyle: Equatable { case text, heading(Int), bullet, numbered, task, quote, code }

    /// The kind of the line at `location`.
    func blockStyle(at location: Int) -> BlockStyle {
        let at = min(location, nsString.length)
        if MarkdownStyler.codeBlocks(in: nsString).contains(where: { NSLocationInRange(at, $0) }) { return .code }
        let line = nsString.substring(with: nsString.paragraphRange(for: NSRange(location: at, length: 0)))
        func matches(_ pattern: String) -> Bool { line.range(of: pattern, options: .regularExpression) != nil }
        if let range = line.range(of: #"^#{1,6}(?=[ \t])"#, options: .regularExpression) { return .heading(line.distance(from: range.lowerBound, to: range.upperBound)) }
        if matches(#"^[ \t]*[-*+][ \t]+\[[ xX]\]"#) { return .task }
        if matches(#"^[ \t]*[-*+][ \t]"#) { return .bullet }
        if matches(#"^[ \t]*\d{1,9}[.)][ \t]"#) { return .numbered }
        if matches(#"^[ \t]{0,3}>"#) { return .quote }
        return .text
    }

    /// Makes the lines touched this kind of block, whatever they were.
    func setBlockStyle(_ style: BlockStyle) {
        var (range, lines) = selectedLines()
        // Out of a code block first: its fences go.
        if blockStyle(at: range.location) == .code, style != .code,
           let code = MarkdownStyler.codeBlocks(in: nsString).first(where: { NSLocationInRange(range.location, $0) }) {
            range = code
            if range.length > 0, nsString.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
            lines = nsString.substring(with: range).components(separatedBy: "\n")
            func isFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") }
            if let first = lines.first, isFence(first) { lines.removeFirst() }
            if let last = lines.last, isFence(last) { lines.removeLast() }
            if lines.isEmpty { lines = [""] }
        }
        if style == .code {
            guard blockStyle(at: range.location) != .code else { return }
            if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { insertCodeBlock() } else { replaceLines(range, with: ["```"] + lines + ["```"]) }
            return
        }
        let marker = try! NSRegularExpression(pattern: #"^([ \t]*)(?:#{1,6}[ \t]+|[-*+][ \t]+\[[ xX]\][ \t]*|[-*+][ \t]+|\d{1,9}[.)][ \t]+|>[ \t]?)"#)
        var number = 0
        // The caret stays in its text, the line's new symbols before it or not.
        let caret = selectedRange()
        let fromEnd = NSMaxRange(range) - NSMaxRange(caret)
        defer {
            let end = selectedRange().location
            if fromEnd > 0, lines.count == 1 { setSelectedRange(NSRange(location: max(end - fromEnd, MarkdownLine(in: nsString, at: end).textStart), length: 0)) }
            renumber(around: selectedRange().location)
        }
        replaceLines(range, with: lines.map { line in
            var body = line
            while let match = marker.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                let indent = (body as NSString).substring(with: match.range(at: 1))
                body = indent + (body as NSString).substring(from: NSMaxRange(match.range))
            }
            let indent = String(body.prefix { $0 == " " || $0 == "\t" })
            let text = String(body.dropFirst(indent.count))
            number += 1
            switch style {
            case .text: return text
            case .heading(let level): return String(repeating: "#", count: level) + " " + text
            case .bullet: return indent + "- " + text
            case .numbered: return indent + "\(number). " + text
            case .task: return indent + "- [ ] " + text
            case .quote: return "> " + text
            case .code: return line
            }
        })
    }

    func insertTable() {
        let table = MarkdownTable(rows: [["", "", ""], ["", "", ""], ["", "", ""]],
                                  alignments: [.none, .none, .none])
        insertBlock(table.markdown, caretOffset: 2)
        if let index = structure.table(at: selectedRange().location) { blockViews.focusTable(index, at: .start) }
    }

    enum LineStyle { case bullet, numbered, task, quote }

    /// Makes the lines touched a list, a task list or a quote (or plain lines again, when they all are one already).
    func toggleLineStyle(_ style: LineStyle) {
        let wanted: BlockStyle = switch style {
        case .bullet: .bullet
        case .numbered: .numbered
        case .task: .task
        case .quote: .quote
        }
        let (range, lines) = selectedLines()
        var at = range.location
        let already = lines.allSatisfy { line in
            defer { at += (line as NSString).length + 1 }
            return blockStyle(at: at) == wanted
        }
        if already, style == .quote {
            replaceLines(range, with: lines.map { $0.replacingOccurrences(of: #"^[ \t]*>[ \t]?"#, with: "", options: .regularExpression) })
        } else { setBlockStyle(already ? .text : wanted) }
    }

    /// A fenced code block around the lines touched (an empty one at the caret).
    func insertCodeBlock() {
        if selectedRange().length == 0 {
            insertBlock("```\n\n```", caretOffset: 4)
        } else {
            let (range, lines) = selectedLines()
            replaceLines(range, with: ["```"] + lines + ["```"])
        }
    }

    /// Inserts a block (a rule, a table) on lines of its own after the caret's line.
    func insertBlock(_ block: String, caretOffset: Int? = nil) {
        var line = nsString.paragraphRange(for: selectedRange())
        if line.length > 0, nsString.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        let empty = nsString.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty
        let text = (empty ? "" : "\n\n") + block + "\n"
        let at = empty ? line.location : NSMaxRange(line)
        breakUndoCoalescing()
        replace(NSRange(location: at, length: empty ? line.length : 0), with: text)
        let start = at + (empty ? 0 : 2)
        setSelectedRange(NSRange(location: caretOffset.map { start + $0 } ?? at + (text as NSString).length, length: 0))
        window?.makeFirstResponder(self)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return }
        // A cited paper opens here, in the copy of Folio the document is in.
        if url.scheme == "folio" { AppDelegate.shared.open(folioLink: url.absoluteString) } else { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Controller

/// Where a Markdown editor's text comes from and goes to: an item's note, or a .md file.
/// "125%", for a moment, while a document is zoomed.
private final class ZoomLabel: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        addSubview(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ percent: Int, over view: NSView) {
        label.stringValue = "\(percent)%"
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 24, height: 28)
        frame = NSRect(x: view.frame.midX - size.width / 2, y: (superview?.isFlipped == true ? view.frame.minY + 14 : view.frame.maxY - 14 - size.height), width: size.width, height: size.height)
        label.frame.origin = NSPoint(x: 12, y: (size.height - label.frame.height) / 2)
        alphaValue = 1
        isHidden = false
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self?.animator().alphaValue = 0 }, completionHandler: { if self?.alphaValue == 0 { self?.isHidden = true } })
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

struct MarkdownSource {
    /// Identifies the document in change notifications.
    var key: String
    var load: () -> String
    var save: (String) -> Void
    /// Posted (object: `key`) after any editor saved it.
    var notification: Notification.Name
}

/// A live-preview Markdown editor: the text view, its styling, and saving 0.8 s after typing stops.
final class MarkdownEditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let scrollView = NSScrollView()
    let textView: MarkdownTextView
    private let layout = MarkdownLayoutManager()
    private(set) var styler: MarkdownStyler
    private var source: MarkdownSource?
    private var saveTask: Task<Void, Never>?
    private(set) var isDirty = false
    private var isLoading = false
    private var lastFocusRequest = 0
    private var pending: NSRange?
    private var structure: MarkdownStructure {
        get { textView.structure }
        set {
            textView.structure = newValue
            layout.codes = newValue.codes.map(\.range)
        }
    }
    /// The selection the lines were styled for.
    private var caret: NSRange?
    /// How long the text was when it was styled last.
    private var styledLength = 0
    private var observedName: Notification.Name?
    /// For the window around the editor: its toolbar follows the line the caret is on, its count the text.
    var onSelectionChange: () -> Void = {}
    var onTextChange: () -> Void = {}

    /// `inPanel`: in a side panel, not a document's window.
    init(inPanel: Bool = true, placeholder: String = "") {
        let preferences = MarkdownPreferences.current
        styler = MarkdownStyler(fontSize: preferences.size(inPanel: inPanel), preferences: preferences)
        layout.fontSize = styler.fontSize
        layout.lastLine = styler.metrics()
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = MarkdownTextView(frame: .zero, textContainer: container)
        super.init()
        textView.styler = styler
        textView.inPanel = inPanel
        textView.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)), name: .folioMarkdownPreferencesDidChange, object: nil)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Its width is the controller's to set (`fitWidth`): what AppKit would make of it knows nothing of magnification.
        textView.autoresizingMask = []
        scrollView.documentView = textView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = MarkdownPreferences.zooms.lowerBound
        scrollView.maxMagnification = MarkdownPreferences.zooms.upperBound
        textView.onZoom = { [weak self] in self?.setZoom($0, at: $1, showing: true) }
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(clipDidChange(_:)), name: name, object: scrollView.contentView)
        }
        textView.delegate = self
        storage.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = styler.bodyFont
        textView.textColor = .labelColor
        textView.typingAttributes = styler.baseAttributes
        textView.defaultParagraphStyle = styler.baseAttributes[.paragraphStyle] as? NSParagraphStyle
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textView.onFocusChange = { [weak self] focused in self?.updateCaret(force: true, focused: focused) }
        textView.blockViews.onHeightsChanged = { [weak self] in self?.restyleTables() }
        textView.setAccessibilityIdentifier("noteEditor")
        textView.setAccessibilityLabel(String(localized: "笔记"))
        let attributed = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.placeholderTextColor, .font: styler.bodyFont])
        if textView.responds(to: Selector(("setPlaceholderAttributedString:"))) {
            textView.setValue(attributed, forKey: "placeholderAttributedString")
        }
    }

    // MARK: Zoom

    /// Off for a sample of the look.
    var followsZoom = true
    private var zoom = 1.0
    private var zoomLabel: ZoomLabel?

    /// Shows the page `zoom` times as large, `point` (of the text) staying where it is; the text is set as wide as fits.
    func setZoom(_ value: Double, at point: NSPoint?, showing: Bool = false) {
        guard followsZoom, abs(value - zoom) > 0.0005 || abs(Double(scrollView.magnification) - value) > 0.0005 else { return }
        zoom = value
        let clip = scrollView.contentView
        let visible = clip.bounds
        let anchor = point ?? NSPoint(x: visible.midX, y: visible.minY + min(visible.height / 2, 200))
        let length = (textView.string as NSString).length
        // The line under it, to find it again when the lines break elsewhere.
        func line() -> (index: Int, y: CGFloat)? {
            guard let manager = textView.layoutManager, let container = textView.textContainer, length > 0 else { return nil }
            let index = min(textView.characterIndexForInsertion(at: anchor), length - 1)
            manager.ensureLayout(for: container)
            return (index, manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil).minY)
        }
        let before = line(), width = textView.textContainer?.size.width ?? 0
        let at = textView.convert(anchor, to: nil).y
        scrollView.magnification = value
        fitWidth()
        var y = anchor.y
        if let before, abs((textView.textContainer?.size.width ?? 0) - width) > 0.5, let manager = textView.layoutManager, let container = textView.textContainer {
            manager.ensureLayout(for: container)
            y += manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: before.index), effectiveRange: nil).minY - before.y
            textView.sizeToFit()
        }
        // (Where it is on the screen now, whatever the scroll view made of it.)
        let moved = (textView.convert(NSPoint(x: anchor.x, y: y), to: nil).y - at) / value
        clip.setBoundsOrigin(NSPoint(x: 0, y: min(max(clip.bounds.minY - moved, 0), max(textView.frame.height - clip.bounds.height, 0))))
        scrollView.reflectScrolledClipView(clip)
        textView.gutterIsStale()
        if showing { showZoom() }
    }

    @objc private func clipDidChange(_ notification: Notification) { fitWidth() }

    private var isFitting = false

    /// The text view is as wide as the part of it that shows, and at least as high. In whole points: a text view rounds what
    /// it is given, and a width asked for that it never has is asked for without end.
    private func fitWidth() {
        let size = NSSize(width: floor(scrollView.contentView.bounds.width), height: floor(scrollView.contentView.bounds.height))
        guard !isFitting, size.width > 0 else { return }
        isFitting = true
        defer { isFitting = false }
        if textView.minSize.height != size.height { textView.minSize = NSSize(width: 0, height: size.height) } else if textView.frame.width == size.width { return }
        if textView.frame.width != size.width { textView.setFrameSize(NSSize(width: size.width, height: textView.frame.height)) }
        textView.sizeToFit()
        if textView.frame.width != size.width { textView.setFrameSize(NSSize(width: size.width, height: textView.frame.height)) }
    }

    private func showZoom() {
        let label = zoomLabel ?? ZoomLabel()
        zoomLabel = label
        if label.superview == nil, let host = scrollView.superview { host.addSubview(label, positioned: .above, relativeTo: scrollView) }
        label.show(Int((zoom * 100).rounded()), over: scrollView)
    }

    /// 设置 ▸ Markdown changed: what is at the top (or the caret) stays where it is on the screen.
    @objc private func preferencesDidChange(_ notification: Notification) {
        let preferences = MarkdownPreferences.current
        setZoom(preferences.zoom(inPanel: textView.inPanel), at: nil)
        guard !preferences.looksLike(styler.preferences) else { return }
        // A cell being written in is made anew: it keeps what was written, not the keyboard.
        if textView.blockViews.activeCell != nil { textView.window?.makeFirstResponder(textView) }
        textView.unmarkText()
        let clip = scrollView.contentView
        let visible = clip.bounds
        let length = (textView.string as NSString).length
        let anchor = textView.window?.firstResponder === textView ? min(textView.selectedRange().location, length) : textView.characterIndexForInsertion(at: NSPoint(x: visible.midX, y: visible.minY + 8))
        func y() -> CGFloat? {
            guard let manager = textView.layoutManager, let container = textView.textContainer, length > 0 else { return nil }
            manager.ensureLayout(for: container)
            return manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: min(anchor, length - 1)), effectiveRange: nil).minY
        }
        let before = y()
        styler = MarkdownStyler(fontSize: preferences.size(inPanel: textView.inPanel), preferences: preferences)
        textView.styler = styler
        layout.fontSize = styler.fontSize
        layout.lastLine = styler.metrics()
        textView.font = styler.bodyFont
        textView.defaultParagraphStyle = styler.baseAttributes[.paragraphStyle] as? NSParagraphStyle
        textView.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        if textView.limitsWidth { textView.readableWidth = preferences.readableWidth }
        textView.blockViews.removeTables()
        isLoading = true
        restyleAll()
        isLoading = false
        textView.gutterIsStale()
        if let before, let after = y(), abs(after - before) > 0.5 {
            let top = min(max(visible.minY + after - before, 0), max(textView.frame.height - visible.height, 0))
            clip.setBoundsOrigin(NSPoint(x: 0, y: top))
            scrollView.reflectScrolledClipView(clip)
        }
        textView.needsDisplay = true
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var text: String { textView.string }

    /// Shows a document (saving the one shown before).
    func load(_ source: MarkdownSource) {
        setZoom(MarkdownPreferences.current.zoom(inPanel: textView.inPanel), at: nil)
        guard source.key != self.source?.key else { return }
        saveNow()
        self.source = source
        if observedName != source.notification {
            if let observedName { NotificationCenter.default.removeObserver(self, name: observedName, object: nil) }
            NotificationCenter.default.addObserver(self, selector: #selector(documentDidChange(_:)), name: source.notification, object: nil)
            observedName = source.notification
        }
        reload(keepSelection: false)
        textView.undoManager?.removeAllActions()
        textView.scroll(.zero)
    }

    @objc private func documentDidChange(_ notification: Notification) {
        // Our own saves come back here too; only another editor's change (or an append from the reader) reloads.
        guard let key = notification.object as? String, key == source?.key,
              (notification.userInfo?["sender"] as? ObjectIdentifier) != ObjectIdentifier(self), !isDirty else { return }
        reload(keepSelection: true)
    }

    private func reload(keepSelection: Bool) {
        guard let source else { return }
        let text = source.load()
        guard text != textView.string else { return }
        isLoading = true
        let selection = textView.selectedRanges
        textView.string = text
        restyleAll()
        let length = (text as NSString).length
        let kept = selection.filter { $0.rangeValue.upperBound <= length }
        onTextChange()
        textView.selectedRanges = keepSelection && !kept.isEmpty ? kept : [NSValue(range: NSRange(location: keepSelection ? length : 0, length: 0))]
        isLoading = false
    }

    func focus(request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.textView.window?.makeFirstResponder(self.textView)
        }
    }

    // MARK: Styling

    private func restyleAll() {
        guard let storage = textView.textStorage else { return }
        structure = MarkdownStructure(storage.string as NSString)
        caret = currentCaret()
        styledLength = storage.length
        textView.blockViews.refresh()
        styler.style(storage, range: NSRange(location: 0, length: storage.length), caret: caret, structure: structure)
        textView.typingAttributes = typingAttributes()
        textView.blockViews.layoutSoon()
    }

    /// The selection, while the editor has the keyboard.
    private func currentCaret(focused: Bool? = nil) -> NSRange? {
        guard focused ?? (textView.window?.firstResponder === textView), textView.selectedRange().location <= (textView.string as NSString).length else { return nil }
        return textView.selectedRange()
    }

    private func lines(of caret: NSRange?) -> NSRange? {
        guard let storage = textView.textStorage, let caret, NSMaxRange(caret) <= storage.length else { return nil }
        return (storage.string as NSString).paragraphRange(for: caret)
    }

    /// Styles the lines the caret left and came to: their symbols, and what stands for an empty line's text.
    private func updateCaret(force: Bool = false, focused: Bool? = nil) {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        let new = currentCaret(focused: focused)
        guard force || new != caret else { return }
        let before = lines(of: caret), after = lines(of: new)
        // Within a line without symbols nothing changes; in code nothing ever does.
        let same = before == after && before != nil
        let plain = after.map { line in
            structure.code(at: line.location) != nil
                || (storage.string as NSString).rangeOfCharacter(from: CharacterSet(charactersIn: "*_~=`[<"), options: [], range: line).location == NSNotFound
        } ?? true
        caret = new
        if !(same && plain) {
            for range in [before, after].compactMap({ $0 }) where structure.code(at: range.location) == nil {
                styler.style(storage, range: range, caret: new, structure: structure)
            }
            textView.setNeedsDisplay(textView.visibleRect)
        }
        textView.typingAttributes = typingAttributes()
        if let new, new.length == 0, let table = structure.table(at: new.location), !isLoading, textView.window?.firstResponder === textView {
            // The caret goes on in the table's cells.
            let source = structure.tables[table].range
            let first = (storage.string as NSString).paragraphRange(for: NSRange(location: source.location, length: 0))
            let atTop = NSLocationInRange(new.location, first)
            let fromBelow = before.map { $0.location >= NSMaxRange(source) } ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.textView.window?.firstResponder === self.textView, self.textView.selectedRange() == new else { return }
                self.textView.blockViews.focusTable(table, at: atTop && !fromBelow ? .start : .end)
            }
        }
    }

    /// What new text looks like before styling catches up — and, while an input method composes, what the
    /// composition is drawn with: the look of the line the caret is on. A new empty line under a heading is body text
    /// (it used to take the heading's line break's style, with its space above, so the candidates sat lower than the
    /// committed text); inside a heading, typed text is heading-sized from the first character.
    private func typingAttributes() -> [NSAttributedString.Key: Any] {
        var attributes = styler.baseAttributes
        guard let storage = textView.textStorage, storage.length > 0 else { return attributes }
        let string = storage.string as NSString
        let caret = min(textView.selectedRange().location, storage.length)
        let line = string.paragraphRange(for: NSRange(location: caret, length: 0))
        var content = line
        while content.length > 0, let last = UnicodeScalar(string.character(at: NSMaxRange(content) - 1)),
              CharacterSet.newlines.contains(last) { content.length -= 1 }
        // An empty line (or the empty last line after a final line break): body text.
        guard content.length > 0, line.location < storage.length else { return attributes }
        if structure.code(at: caret) != nil {
            let source = storage.attributes(at: min(line.location, storage.length - 1), effectiveRange: nil)
            attributes[.mdMetrics] = nil
            attributes[.font] = styler.monoFont
            if let style = source[.paragraphStyle] { attributes[.paragraphStyle] = style }
            return attributes
        }
        let found = MarkdownLine(in: string, at: caret)
        if found.prefix.length > 0, found.isEmpty {
            if case .heading(let level) = found.kind { attributes[.font] = styler.headingFont(level) }
            attributes[.paragraphStyle] = storage.attribute(.paragraphStyle, at: line.location, effectiveRange: nil) ?? attributes[.paragraphStyle]!
            return attributes
        }
        // The character before the caret on this line, else the line's first one; syntax characters lend their
        // paragraph and size, not their colour or hiding.
        let at = caret > content.location ? min(caret - 1, NSMaxRange(content) - 1) : content.location
        var source = storage.attributes(at: at, effectiveRange: nil)
        if source[.mdHidden] != nil {
            // A hidden marker has a hair-thin font: take the size from the line's visible text instead.
            var visible: Int?
            storage.enumerateAttribute(.mdHidden, in: content) { value, range, stop in
                if value == nil { visible = range.location; stop.pointee = true }
            }
            if let visible { source = storage.attributes(at: visible, effectiveRange: nil) }
        }
        if let font = source[.font] as? NSFont, font.pointSize > 1 { attributes[.font] = font }
        if let style = source[.paragraphStyle] { attributes[.paragraphStyle] = style }
        return attributes
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            pending = pending.map { NSUnionRange($0, editedRange) } ?? editedRange
        }
    }

    func textDidChange(_ notification: Notification) {
        applyPendingStyle()
        onTextChange()
        guard !isLoading else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func applyPendingStyle() {
        guard let storage = textView.textStorage, let edited = pending else { return }
        // While an input method composes, its marked text keeps the look it has; styling follows the commit.
        guard !textView.hasMarkedText() else { return }
        pending = nil
        let string = storage.string as NSString
        let old = structure
        var new = MarkdownStructure(string)
        // Tables keep the height their views have, until those are laid out again.
        for (index, table) in new.tables.enumerated() {
            if let same = old.tables.firstIndex(where: { $0.table == table.table }) { new.tableHeights[index] = old.tableHeights[same] }
        }
        var range = NSRange(location: min(edited.location, storage.length), length: 0)
        range.length = min(NSMaxRange(edited), storage.length) - range.location
        // Blocks that came, went or became something else: what they were in and are in now is styled again.
        let before = old.blocks, after = new.blocks
        func same(_ a: (range: NSRange, isTable: Bool), _ b: (range: NSRange, isTable: Bool)) -> Bool { a.range.length == b.range.length && a.isTable == b.isTable }
        var head = 0, tail = 0
        while head < min(before.count, after.count), same(before[head], after[head]), before[head].range.location == after[head].range.location { head += 1 }
        while tail < min(before.count, after.count) - head, same(before[before.count - 1 - tail], after[after.count - 1 - tail]),
              styledLength - before[before.count - 1 - tail].range.location == storage.length - after[after.count - 1 - tail].range.location { tail += 1 }
        let gone = before[head..<(before.count - tail)], come = after[head..<(after.count - tail)]
        if !gone.isEmpty || !come.isEmpty {
            let start = min(range.location, (gone.map(\.range.location) + come.map(\.range.location)).min() ?? range.location)
            let rest = min(storage.length - NSMaxRange(range), (gone.map { styledLength - NSMaxRange($0.range) } + come.map { storage.length - NSMaxRange($0.range) }).min() ?? 0)
            range = NSRange(location: max(start, 0), length: max(storage.length - max(rest, 0) - max(start, 0), 0))
        }
        styledLength = storage.length
        structure = new
        textView.blockViews.refresh()
        // The line the caret was on before is styled again too, and what hangs together with what changed.
        let left = caret.map { NSRange(location: min($0.location, storage.length), length: 0) }
        caret = currentCaret()
        var union = lines(of: caret).map { NSUnionRange($0, range) } ?? range
        if let left { union = NSUnionRange(union, string.paragraphRange(for: left)) }
        styler.style(storage, range: group(around: union, in: string), caret: caret, structure: structure)
        for (index, table) in structure.tables.enumerated() {
            let shown = (storage.attribute(.paragraphStyle, at: table.range.location, effectiveRange: nil) as? NSParagraphStyle)?.minimumLineHeight ?? 0
            if abs(shown - structure.tableHeights[index]) > 0.5 { styler.style(storage, range: table.range, caret: caret, structure: structure) }
        }
        textView.typingAttributes = typingAttributes()
        // What is drawn reaches beyond the lines that changed (a quote's bar goes on to the next line, a block has a box).
        textView.setNeedsDisplay(textView.visibleRect)
        textView.blockViews.layoutSoon()
        settleCaret()
    }

    /// The lines around a change that depend on each other (the levels of a list, the lines of an item): up to two empty
    /// lines, above and below.
    private func group(around range: NSRange, in string: NSString) -> NSRange {
        var group = string.paragraphRange(for: NSRange(location: min(range.location, string.length), length: min(range.length, string.length - min(range.location, string.length))))
        func isBlank(_ line: NSRange) -> Bool { string.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var blanks = 0
        while group.location > 0, blanks < 2 {
            let line = string.paragraphRange(for: NSRange(location: group.location - 1, length: 0))
            blanks = isBlank(line) ? blanks + 1 : 0
            group = NSUnionRange(group, line)
        }
        blanks = 0
        while NSMaxRange(group) < string.length, blanks < 2 {
            let line = string.paragraphRange(for: NSRange(location: NSMaxRange(group), length: 0))
            blanks = isBlank(line) ? blanks + 1 : 0
            group = NSUnionRange(group, line)
        }
        return group
    }

    /// After an edit the caret may be among symbols that were just completed: on to where it can be.
    private func settleCaret() {
        guard !isLoading, !textView.hasMarkedText() else { return }
        let selection = textView.selectedRange()
        if selection.length > 0 {
            let allowed = textView.selection(for: selection, from: NSRange(location: selection.location, length: 0))
            if allowed != selection { textView.setSelectedRange(allowed) }
            return
        }
        let caret = textView.selectedRange().location
        // The fence just typed closed a block: on to the line after it.
        let string = textView.string as NSString
        let replays = textView.undoManager.map { $0.isUndoing || $0.isRedoing } ?? false
        if !replays, let close = structure.codes.compactMap(\.close).first(where: { caret > $0.location && caret <= NSMaxRange($0) && !(caret == NSMaxRange($0) && string.character(at: caret - 1) == 10) }) {
            if string.character(at: NSMaxRange(close) - 1) == 10 { textView.setSelectedRange(NSRange(location: NSMaxRange(close), length: 0)) } else { textView.appendLine() }
            return
        }
        let allowed = textView.caretLocation(for: caret, from: caret)
        if allowed != caret { textView.setSelectedRange(NSRange(location: allowed, length: 0)) }
    }

    /// Table views have another height than their lines: the lines take it.
    func restyleTables() {
        guard let storage = textView.textStorage, !textView.hasMarkedText(), pending == nil else { return }
        for table in structure.tables where NSMaxRange(table.range) <= storage.length {
            styler.style(storage, range: table.range, caret: caret, structure: structure)
        }
    }

    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
        guard !isLoading, !self.textView.hasMarkedText(), pending == nil, NSMaxRange(new) <= (textView.string as NSString).length else { return new }
        if new.length > 0 { return self.textView.selection(for: new, from: old) }
        return NSRange(location: self.textView.caretLocation(for: new.location, from: old.location), length: 0)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isLoading else { return }
        // While the text is being edited nothing may be styled or laid out: that follows the edit (`textDidChange`).
        if pending != nil {
            guard textView.textStorage?.editedMask.isEmpty == true, !textView.isChangingText else { return }
            applyPendingStyle()
        }
        updateCaret()
        textView.blockViews.updateSelection()
        onSelectionChange()
    }

    func textDidEndEditing(_ notification: Notification) { saveNow() }

    /// The headings of the document, for its outline.
    var headings: [(level: Int, title: String, location: Int)] {
        let string = textView.string as NSString
        var result: [(Int, String, Int)] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { [codes = structure.codes] line, range, _, _ in
            guard let line, let mark = line.range(of: #"^#{1,6}(?=[ \t]+\S)"#, options: .regularExpression),
                  !codes.contains(where: { NSLocationInRange(range.location, $0.range) }) else { return }
            let title = line[mark.upperBound...].replacingOccurrences(of: #"[*_`~=]+|\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            result.append((line.distance(from: mark.lowerBound, to: mark.upperBound), title, range.location))
        }
        return result
    }

    /// Shows a heading at the top, the caret on it.
    func reveal(_ location: Int) {
        guard let layout = textView.layoutManager, let container = textView.textContainer, location <= (textView.string as NSString).length else { return }
        textView.window?.makeFirstResponder(textView)
        let line = (textView.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let end = line.length > 0 && (textView.string as NSString).character(at: NSMaxRange(line) - 1) == 10 ? NSMaxRange(line) - 1 : NSMaxRange(line)
        textView.setSelectedRange(NSRange(location: end, length: 0))
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
        let y = layout.boundingRect(forGlyphRange: glyphs, in: container).minY + textView.textContainerOrigin.y
        let top = min(max(y - 16, 0), max(textView.bounds.height - scrollView.contentView.bounds.height, 0))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: top))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Characters of Chinese (and the like) and words of other scripts, as a word processor counts them.
    var wordCount: Int {
        var count = 0
        var inWord = false
        for scalar in textView.string.unicodeScalars {
            let wide = (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
            if wide { count += 1; inWord = false }
            else if CharacterSet.alphanumerics.contains(scalar) { if !inWord { count += 1; inWord = true } }
            else if scalar != "'" && scalar != "-" { inWord = false }
        }
        return count
    }

    func saveNow() {
        saveTask?.cancel()
        guard isDirty, let source else { return }
        isDirty = false
        source.save(textView.string)
        NotificationCenter.default.post(name: source.notification, object: source.key, userInfo: ["sender": ObjectIdentifier(self)])
    }
}
