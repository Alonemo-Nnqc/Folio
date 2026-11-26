import AppKit

/// The handles beside the line the pointer is on: + adds a line below and opens the menu of tools; the
/// grip opens the line's own menu on a click and moves the line (with what belongs to it) on a drag.
final class MarkdownGutter: NSView {
    static let width: CGFloat = 44
    private let add = GutterButton(symbol: "plus", label: String(localized: "在下方添加（点按）"))
    private let grip = GutterButton(symbol: nil, label: String(localized: "点按打开菜单，拖动移动"))
    private weak var textView: MarkdownTextView?
    /// The block the handles stand beside.
    private(set) var block: NSRange?

    init(textView: MarkdownTextView) {
        self.textView = textView
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 22))
        add.frame = NSRect(x: 0, y: 0, width: 21, height: 22)
        grip.frame = NSRect(x: 22, y: 0, width: 20, height: 22)
        addSubview(add)
        addSubview(grip)
        add.onClick = { [weak self] in
            guard let self, let block = self.block else { return }
            self.textView?.addLine(below: block)
        }
        grip.onClick = { [weak self] in
            guard let self, let block = self.block, let view = self.textView else { return }
            view.showBlockMenu(for: block, at: NSPoint(x: self.frame.minX + self.grip.frame.minX, y: self.frame.maxY + 2))
        }
        grip.onDrag = { [weak self] event in
            guard let self, let block = self.block else { return }
            self.textView?.dragBlock(block, with: event)
        }
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { true }

    func show(block: NSRange, at origin: NSPoint) {
        self.block = block
        // From line to line the handles move at once; only coming and going fades.
        setFrameOrigin(origin)
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    func hide() {
        guard !isHidden else { return }
        block = nil
        alphaValue = 0
        isHidden = true
    }
}

/// A small flat button that lights up under the pointer.
private final class GutterButton: NSView {
    var onClick: () -> Void = {}
    var onDrag: ((NSEvent) -> Void)?
    private let image = NSImageView()
    private var hovering = false { didSet { needsDisplay = true } }

    /// `symbol` nil: the grip, six dots.
    init(symbol: String?, label: String) {
        super.init(frame: .zero)
        image.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? Self.grip
        image.contentTintColor = .tertiaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([image.centerXAnchor.constraint(equalTo: centerXAnchor), image.centerYAnchor.constraint(equalTo: centerYAnchor)])
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private static let grip: NSImage = {
        let image = NSImage(size: NSSize(width: 9, height: 14), flipped: false) { _ in
            NSColor.black.setFill()
            for column in 0..<2 {
                for row in 0..<3 { NSBezierPath(ovalIn: NSRect(x: 0.5 + Double(column) * 5, y: 0.5 + Double(row) * 5, width: 2.8, height: 2.8)).fill() }
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { (onDrag == nil ? NSCursor.arrow : NSCursor.openHand).set() }

    override func draw(_ dirtyRect: NSRect) {
        image.contentTintColor = hovering ? .secondaryLabelColor : .tertiaryLabelColor
        guard hovering else { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { onClick() }
                return
            }
            if let onDrag, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                onDrag(next)
                return
            }
        }
    }
}

/// Where a dragged block will land: a line between two lines of the text.
final class MarkdownDropLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1.25, yRadius: 1.25).fill()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Blocks

extension MarkdownTextView {
    private var text: NSString { string as NSString }

    /// The lines that go together with the one at `location`: a whole code block or table, a list item with what is nested
    /// under it, otherwise the line itself.
    func block(at location: Int) -> NSRange {
        let at = min(location, text.length)
        let line = text.paragraphRange(for: NSRange(location: at, length: 0))
        if let code = MarkdownStyler.codeBlocks(in: text).first(where: { NSLocationInRange(line.location, $0) }) { return code }
        if let table = MarkdownTable.all(in: text, outside: MarkdownCode.all(in: text)).first(where: { NSLocationInRange(line.location, $0.range) }) { return table.range }
        let item = MarkdownLine(in: text, at: line.location)
        if item.kind.isList {
            var range = line
            while NSMaxRange(range) < text.length {
                let below = MarkdownLine(in: text, at: NSMaxRange(range))
                guard below.kind == .continuation || (below.kind.isList && below.indent > item.indent) else { break }
                range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
            }
            return range
        }
        return line
    }

    /// The block without its final line break.
    private func inner(_ block: NSRange) -> NSRange {
        var range = block
        if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 10 { range.length -= 1 }
        return range
    }

    // MARK: The pointer

    /// The block beside the pointer (view coordinates), and where its first line is.
    private func block(under point: NSPoint) -> (range: NSRange, line: NSRect)? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        let y = point.y - origin.y
        let used = layout.usedRect(for: container)
        guard y >= -4, y <= used.maxY + 4, bounds.width > 0 else { return nil }
        var location = text.length
        if !layout.extraLineFragmentRect.isEmpty, y >= layout.extraLineFragmentRect.minY {
            return (NSRange(location: text.length, length: 0), layout.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y))
        }
        guard layout.numberOfGlyphs > 0 else { return nil }
        let glyph = layout.glyphIndex(for: NSPoint(x: container.size.width / 2, y: y), in: container)
        location = layout.characterIndexForGlyph(at: glyph)
        let range = block(at: location)
        let first = layout.glyphIndexForCharacter(at: min(range.location, max(text.length - 1, 0)))
        return (range, layout.lineFragmentUsedRect(forGlyphAt: first, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y))
    }

    func updateGutter(at point: NSPoint) {
        guard showsGutter, styler.preferences.showsHandles, isEditable, !isDraggingBlock, textContainerOrigin.x >= MarkdownGutter.width + 6,
              let (range, line) = block(under: point) else { return gutter.hide() }
        if gutter.superview == nil { addSubview(gutter) }
        // Beside the first line's text (headings are taller, code blocks start with their fence).
        let x = floor(textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0) - MarkdownGutter.width - 4)
        // Beside a table's first row, a code block's header.
        var y = line.midY
        if structure.table(at: range.location) != nil { y = line.minY + MarkdownTableView.overhang + 18 }
        else if structure.code(at: range.location)?.isClosed == true { y = line.maxY - MarkdownStyler.codeHeaderHeight / 2 + 1 }
        gutter.show(block: range, at: NSPoint(x: x, y: round(y - 11)))
    }

    // MARK: Adding

    /// An empty line below the block, with the menu of tools open on it.
    func addLine(below block: NSRange) {
        window?.makeFirstResponder(self)
        let range = inner(block)
        breakUndoCoalescing()
        if text.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty {
            setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        } else {
            replace(NSRange(location: NSMaxRange(range), length: 0), with: "\n")
            setSelectedRange(NSRange(location: NSMaxRange(range) + 1, length: 0))
        }
        scrollRangeToVisible(selectedRange())
        openMenu(typingSlash: true)
    }

    // MARK: The block's menu

    func showBlockMenu(for block: NSRange, at point: NSPoint) {
        window?.makeFirstResponder(self)
        setSelectedRange(inner(block))
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ symbol: String, key: String = "", flags: NSEvent.ModifierFlags = [], enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
            let target = BlockAction(action)
            let item = NSMenuItem(title: title, action: #selector(BlockAction.perform(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = flags
            item.isEnabled = enabled
            return item
        }
        let current = blockStyle(at: block.location)
        let isTable = structure.table(at: block.location) != nil
        if let code = structure.code(at: block.location), code.isClosed {
            let language = NSMenuItem(title: String(localized: "语言"), action: nil, keyEquivalent: "")
            language.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
            language.submenu = MarkdownCodeHeader.languageMenu(for: code, in: text, target: self, action: #selector(setLanguageFromMenu(_:)))
            menu.addItem(language)
            menu.addItem(item(String(localized: "拷贝代码"), "doc.on.clipboard") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self.text.substring(with: code.text), forType: .string)
            })
            menu.addItem(.separator())
        }
        if isTable, let index = structure.table(at: block.location) {
            menu.addItem(item(String(localized: "添加一行"), "plus.rectangle") { [weak self] in
                guard let table = self?.blockViews.tables[index] else { return }
                table.insertRow(at: table.table.rows.count)
            })
            menu.addItem(item(String(localized: "添加一列"), "plus.rectangle.portrait") { [weak self] in
                guard let table = self?.blockViews.tables[index] else { return }
                table.insertColumn(at: table.table.columns)
            })
            menu.addItem(.separator())
        }
        if !isTable { menu.addItem(.sectionHeader(title: String(localized: "转换为"))) }
        for command in MarkdownCommand.all where !isTable {
            guard let style = command.style else { continue }
            let entry = item(command.title, "") { [weak self] in
                guard let self else { return }
                self.setSelectedRange(self.inner(block))
                self.setBlockStyle(style)
            }
            entry.image = command.image
            entry.state = current == style ? .on : .off
            menu.addItem(entry)
        }
        if !isTable { menu.addItem(.separator()) }
        menu.addItem(item(String(localized: "在下方添加…"), "plus") { [weak self] in self?.addLine(below: block) })
        menu.addItem(item(String(localized: "在上方插入一行"), "arrow.up.to.line") { [weak self] in
            guard let self else { return }
            self.breakUndoCoalescing()
            self.replace(NSRange(location: block.location, length: 0), with: "\n")
            self.setSelectedRange(NSRange(location: block.location, length: 0))
        })
        menu.addItem(item(String(localized: "在下方插入一行"), "arrow.down.to.line") { [weak self] in
            guard let self else { return }
            let end = NSMaxRange(self.inner(block))
            self.breakUndoCoalescing()
            self.replace(NSRange(location: end, length: 0), with: "\n")
            self.setSelectedRange(NSRange(location: end + 1, length: 0))
        })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "上移"), "arrow.up", key: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), flags: [.control, .command],
                          enabled: block.location > 0) { [weak self] in self?.moveBlock(block, by: -1) })
        menu.addItem(item(String(localized: "下移"), "arrow.down", key: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), flags: [.control, .command],
                          enabled: NSMaxRange(block) < text.length) { [weak self] in self?.moveBlock(block, by: 1) })
        menu.addItem(item(String(localized: "创建副本"), "plus.square.on.square") { [weak self] in self?.duplicateBlock(block) })
        menu.addItem(item(String(localized: "拷贝"), "doc.on.doc") { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.text.substring(with: self.inner(block)), forType: .string)
        })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "删除"), "trash") { [weak self] in self?.deleteBlock(block) })
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func setLanguageFromMenu(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String, let code = structure.code(at: selectedRange().location) else { return }
        setLanguage(language, of: code)
    }

    func duplicateBlock(_ block: NSRange) {
        let range = inner(block)
        let copy = text.substring(with: range)
        breakUndoCoalescing()
        replace(NSRange(location: NSMaxRange(range), length: 0), with: "\n" + copy)
        setSelectedRange(NSRange(location: NSMaxRange(range) + 1 + (copy as NSString).length, length: 0))
    }

    func deleteBlock(_ block: NSRange) {
        breakUndoCoalescing()
        var range = block
        func isBlank(_ location: Int) -> Bool {
            MarkdownStyler.codeBlocks(in: text).allSatisfy { !NSLocationInRange(location, $0) }
                && text.substring(with: text.paragraphRange(for: NSRange(location: location, length: 0))).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Of the empty lines around it one stays.
        let above = range.location == 0 || isBlank(range.location - 1)
        if above, NSMaxRange(range) < text.length, isBlank(NSMaxRange(range)), !inner(block).isEmptyRange {
            range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
        }
        // The last line takes the line break before it along.
        if NSMaxRange(range) == text.length, range.location > 0, range.length == 0 || text.character(at: NSMaxRange(range) - 1) != 10 {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        let at = block.location
        replace(range, with: "")
        setSelectedRange(NSRange(location: min(at, text.length), length: 0))
        renumber(around: selectedRange().location)
    }

    // MARK: Moving

    /// Past the block above (-1) or below (1).
    func moveBlock(_ block: NSRange, by step: Int) {
        if step < 0, block.location > 0 {
            moveBlock(block, to: self.block(at: block.location - 1).location)
        } else if step > 0, NSMaxRange(block) < text.length {
            moveBlock(block, to: NSMaxRange(self.block(at: NSMaxRange(block))))
        }
    }

    /// Takes the block out and puts it before the character at `target` (the start of a line, or the end of the text), in one
    /// step for undo. The caret goes with it.
    func moveBlock(_ block: NSRange, to target: Int) {
        guard target < block.location || target > NSMaxRange(block) else { return }
        let moved = text.substring(with: block)
        let span: NSRange, others: String
        if target < block.location {
            span = NSRange(location: target, length: NSMaxRange(block) - target)
            others = text.substring(with: NSRange(location: target, length: block.location - target))
        } else {
            span = NSRange(location: block.location, length: target - block.location)
            others = text.substring(with: NSRange(location: NSMaxRange(block), length: target - NSMaxRange(block)))
        }
        // The text may end without a line break: whichever comes last gives its own up to the one before it.
        let endsBroken = text.substring(with: span).hasSuffix("\n")
        func line(_ part: String) -> String { part.hasSuffix("\n") ? part : part + "\n" }
        var result = target < block.location ? line(moved) + line(others) : line(others) + line(moved)
        if !endsBroken { result.removeLast() }
        breakUndoCoalescing()
        replace(span, with: result)
        let start = target < block.location ? target : span.location + (line(others) as NSString).length
        let length = (moved as NSString).length - (moved.hasSuffix("\n") ? 1 : 0)
        setSelectedRange(NSRange(location: min(start + length, text.length), length: 0))
        renumber(around: min(start, text.length))
        scrollRangeToVisible(NSRange(location: min(start, text.length), length: 0))
    }

    /// The caret's block past its neighbour (⌃⌘↑, ⌃⌘↓).
    func moveCaretBlock(by step: Int) { moveBlock(block(at: selectedRange().location), by: step) }

    func dragBlock(_ block: NSRange, with first: NSEvent) {
        guard let layout = layoutManager, let container = textContainer else { return }
        isDraggingBlock = true
        gutter.hide()
        let line = MarkdownDropLine()
        addSubview(line)
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.16), forCharacterRange: block)
        NSCursor.closedHand.push()
        defer {
            NSCursor.pop()
            line.removeFromSuperview()
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSIntersectionRange(block, NSRange(location: 0, length: text.length)))
            isDraggingBlock = false
        }
        var target: Int?
        var event: NSEvent? = first
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.04)
        defer { NSEvent.stopPeriodicEvents() }
        var last = first
        while let current = event {
            if current.type == .keyDown, current.keyCode == 53 { target = nil; break }
            if current.type == .leftMouseUp { break }
            if current.type == .leftMouseDragged { last = current }
            if current.type == .periodic { _ = autoscroll(with: last) }
            let point = convert(last.locationInWindow, from: nil)
            let origin = textContainerOrigin
            var y: CGFloat?
            if layout.numberOfGlyphs > 0 {
                let glyph = layout.glyphIndex(for: NSPoint(x: container.size.width / 2, y: point.y - origin.y), in: container)
                let under = self.block(at: layout.characterIndexForGlyph(at: glyph))
                let glyphs = layout.glyphRange(forCharacterRange: under, actualCharacterRange: nil)
                let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
                let before = point.y < rect.midY
                target = before ? under.location : NSMaxRange(under)
                y = before ? rect.minY : rect.maxY
            }
            let idle = target.map { $0 >= block.location && $0 <= NSMaxRange(block) } ?? true
            line.isHidden = idle
            if let y {
                line.frame = NSRect(x: origin.x + container.lineFragmentPadding, y: y - 1.25, width: container.size.width - container.lineFragmentPadding * 2, height: 2.5)
            }
            event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic, .keyDown])
        }
        if let target { moveBlock(block, to: target) }
    }
}

private extension NSRange {
    var isEmptyRange: Bool { length == 0 }
}

/// What a menu item of a block does (kept by the item).
final class BlockAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func perform(_ sender: Any?) { run() }
}
