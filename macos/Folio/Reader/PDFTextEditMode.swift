import AppKit
import FolioTranslate
import PDFKit

/// 编辑 PDF 文字 (EDIT-01). A layer inside PDFView's document view, so it scrolls and zooms with the pages and the
/// scroll wheel, the trackpad and pinching work as they do without it. The paragraphs the editor offers are outlined
/// faintly; under the pointer one lights up with a "点击编辑" tag (or why it can't be edited). A click opens its text in
/// place, set like the page, with 取消 / 完成 under it; finishing writes it into the file — the paragraph's glyphs taken
/// out and the new text set in their space (`PDFTextEditor`) — while the paragraph shows that it is being written, and
/// it flashes once when done. Each edit is one undo step.
@MainActor
final class PDFTextEditMode: NSView, NSTextViewDelegate {
    private weak var pdfView: PDFView?
    /// The file as it is now: its blocks per page, read in the background as pages come into view.
    private var editor: PDFTextEditor?
    private var blocks: [Int: [PDFTextBlock]] = [:]
    private var loading: Set<Int> = []
    private var generation = 0
    private var hovered: PDFTextBlock?
    private var editing: Editing?
    /// The block being written into the file, and one just written (flashed).
    private var writing: PDFTextBlock?
    private var flashed: (page: Int, rect: CGRect, until: Date)?
    private var tracking: NSTrackingArea?

    private struct Editing {
        var block: PDFTextBlock
        var text: NSTextView
        var sheet: NSView
        var bar: NSView
    }

    /// Writes new file data (and makes it one undo step); true when it worked.
    var commit: (_ data: Data, _ actionName: String) async -> Bool = { _, _ in false }
    var data: () -> Data? = { nil }
    var showMessage: (String) -> Void = { _ in }

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
        // Drawn over the pages whatever order PDFKit adds them in (ReaderPDFView gives it the clicks first, too).
        wantsLayer = true
        layer?.zPosition = 100
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewVisiblePagesChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(documentChanged), name: .PDFViewDocumentChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewDisplayModeChanged, object: pdfView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { superview?.isFlipped ?? false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Puts the layer into PDFView's document view (again, after a reload replaced it), as large as it.
    func attach() {
        guard let pdfView, let documentView = pdfView.documentView else { return }
        // On top of the pages, which PDFKit adds as they come into view.
        if superview !== documentView || documentView.subviews.last !== self {
            documentView.addSubview(self, positioned: .above, relativeTo: nil)
        }
        frame = documentView.bounds
        autoresizingMask = [.width, .height]
    }

    /// The file changed (an edit, an undo, annotations saved): its blocks are read again.
    func reload() {
        generation += 1
        editor = nil
        blocks = [:]
        loading = []
        hovered = nil
        attach()
        needsDisplay = true
        loadVisiblePages()
    }

    /// For the self-test: what the layer knows.
    var stateDescription: String {
        "pages visible \(visiblePages), blocks \(blocks.mapValues(\.count)), loading \(loading), editor \(editor != nil), editing \(editing != nil), writing \(writing != nil), superview \(superview.map { String(describing: type(of: $0)) } ?? "nil")"
    }

    var isEditingBlock: Bool { editing != nil }

    func finish() {
        if editing != nil { endEditing(save: true) }
    }

    // MARK: Blocks

    private var visiblePages: [Int] {
        guard let pdfView, let document = pdfView.document else { return [] }
        let visible = pdfView.visiblePages.compactMap { document.index(for: $0) }
        // Right after the document is set PDFView may not know yet what it shows: the current page stands in.
        if visible.isEmpty, let page = pdfView.currentPage ?? document.page(at: 0) { return [document.index(for: page)] }
        return visible
    }

    private func loadVisiblePages() {
        let wanted = visiblePages.filter { blocks[$0] == nil && !loading.contains($0) }
        guard !wanted.isEmpty, let data = data() else { return }
        wanted.forEach { loading.insert($0) }
        let run = generation
        let existing = editor
        Task.detached(priority: .userInitiated) {
            let editor = existing ?? (try? PDFTextEditor(data: data))
            let found = wanted.map { ($0, editor?.blocks(onPage: $0) ?? []) }
            await MainActor.run { [weak self] in
                guard let self, self.generation == run else { return }
                if self.editor == nil { self.editor = editor }
                for (page, list) in found {
                    self.blocks[page] = list
                    self.loading.remove(page)
                }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    @objc private func documentChanged() {
        // PDFView builds a new document view for the new document: the layer goes into it once it is there.
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    @objc private func viewMoved() {
        attach()
        loadVisiblePages()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if let editing { place(editing) }
    }

    /// The block's rectangle in this view, with a little room around the text.
    private func rect(of block: PDFTextBlock) -> NSRect? {
        rect(page: block.page, rect: block.rect)
    }

    private func rect(page index: Int, rect: CGRect) -> NSRect? {
        guard let pdfView, let page = pdfView.document?.page(at: index) else { return nil }
        let r = convert(pdfView.convert(rect, from: page), from: pdfView)
        let pad = max(2, 3 * (pdfView.scaleFactor))
        return r.insetBy(dx: -pad, dy: -pad * 0.6)
    }

    private func block(at point: NSPoint) -> PDFTextBlock? {
        for page in visiblePages {
            // The smallest block under the pointer (a caption inside a figure's area wins over the area).
            let hits = (blocks[page] ?? []).filter { !$0.text.isEmpty && (rect(of: $0)?.contains(point) ?? false) }
            if let best = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) { return best }
        }
        return nil
    }

    // MARK: Pointer and cursor

    /// Only the blocks and the open editor take the mouse: everything else (margins, figures) stays PDFView's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        if let editing {
            if let hit = super.hitTest(point), hit !== self { return hit }
            if editing.sheet.frame.contains(local) || editing.bar.frame.contains(local) { return self }
            return self   // a click anywhere else finishes the edit
        }
        return block(at: local) != nil ? self : nil
    }

    override func resetCursorRects() {
        guard editing == nil else { return }
        for page in visiblePages {
            for block in blocks[page] ?? [] where !block.text.isEmpty {
                guard let rect = rect(of: block) else { continue }
                addCursorRect(rect, cursor: block.isEditable ? .iBeam : .operationNotAllowed)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    /// The pointer moved over the pages (ReaderPDFView sends it here while editing, instead of letting PDFKit set
    /// its own cursor).
    func pointerMoved(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = editing == nil ? block(at: point) : nil
        if hit != hovered {
            if let hovered, let old = rect(of: hovered) { setNeedsDisplay(old.insetBy(dx: -4, dy: -30)) }
            hovered = hit
            if let hit, let new = rect(of: hit) { setNeedsDisplay(new.insetBy(dx: -4, dy: -30)) }
        }
        cursor(at: point).set()
    }

    private func cursor(at point: NSPoint) -> NSCursor {
        if let editing {
            let local = convert(point, to: editing.sheet)
            return editing.sheet.bounds.contains(local) ? .iBeam : .arrow
        }
        guard let hit = block(at: point) else { return .arrow }
        return hit.isEditable ? .iBeam : .operationNotAllowed
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func cursorUpdate(with event: NSEvent) { cursor(at: convert(event.locationInWindow, from: nil)).set() }

    override func mouseExited(with event: NSEvent) {
        if let hovered, let old = rect(of: hovered) { setNeedsDisplay(old.insetBy(dx: -4, dy: -30)) }
        hovered = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let editing {
            if editing.sheet.frame.contains(point) || editing.bar.frame.contains(point) { return }
            endEditing(save: true)
            return
        }
        guard writing == nil, let hit = block(at: point) else { return }
        guard hit.isEditable else {
            NSSound.beep()
            showMessage(String(localized: "这里不能编辑：\(hit.reason ?? "")"))
            return
        }
        beginEditing(hit)
    }

    // The rest of a click stays here: passed on, PDFView would take the focus back from the editor as the mouse comes up.
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}

    // Scrolling and zooming are the scroll view's, as everywhere else on the pages.
    override func scrollWheel(with event: NSEvent) { enclosingScrollView?.scrollWheel(with: event) ?? super.scrollWheel(with: event) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let radius: CGFloat = 4
        for page in visiblePages {
            for block in blocks[page] ?? [] where !block.text.isEmpty {
                guard let rect = rect(of: block), rect.intersects(dirtyRect.insetBy(dx: -40, dy: -40)) else { continue }
                if editing?.block == block { continue }
                let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                if block == writing {
                    accent.withAlphaComponent(0.12).setFill()
                    path.fill()
                    accent.withAlphaComponent(0.5).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                    tag(String(localized: "正在写入…"), symbol: "arrow.triangle.2.circlepath", over: rect, color: accent)
                } else if block == hovered {
                    if block.isEditable {
                        accent.withAlphaComponent(0.07).setFill()
                        path.fill()
                        accent.withAlphaComponent(0.85).setStroke()
                        path.lineWidth = 1.5
                        path.stroke()
                        tag(String(localized: "点击编辑"), symbol: "pencil", over: rect, color: accent)
                    } else {
                        NSColor.secondaryLabelColor.withAlphaComponent(0.06).setFill()
                        path.fill()
                        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
                        path.setLineDash([4, 3], count: 2, phase: 0)
                        path.lineWidth = 1
                        path.stroke()
                        tag(block.reason ?? String(localized: "这里不能编辑"), symbol: "lock", over: rect, color: .secondaryLabelColor)
                    }
                } else if block.isEditable {
                    accent.withAlphaComponent(0.2).setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
            }
        }
        // The paragraph just written, for a moment.
        if let flashed, Date() < flashed.until, let rect = rect(page: flashed.page, rect: flashed.rect) {
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.systemGreen.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.systemGreen.withAlphaComponent(0.8).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// A small capsule above the block's top right corner: what a click will do.
    private func tag(_ text: String, symbol: String, over rect: NSRect, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold))
        let iconWidth: CGFloat = icon == nil ? 0 : 14
        let size = label.size()
        let width = min(size.width + iconWidth + 16, max(rect.width, 80))
        let height: CGFloat = 20
        let y = isFlipped ? rect.minY - height - 3 : rect.maxY + 3
        let capsule = NSRect(x: rect.maxX - width, y: y, width: width, height: height)
        let path = NSBezierPath(roundedRect: capsule, xRadius: height / 2, yRadius: height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: isFlipped ? 1 : -1)
        shadow.set()
        color.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if let icon {
            let tinted = NSImage(size: icon.size, flipped: false) { r in
                icon.draw(in: r)
                NSColor.white.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: capsule.minX + 8, y: capsule.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        label.draw(with: NSRect(x: capsule.minX + 8 + iconWidth, y: capsule.midY - size.height / 2 + (isFlipped ? 0 : 1),
                                width: capsule.width - 14 - iconWidth, height: size.height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Editing in place

    private var scale: CGFloat { pdfView?.scaleFactor ?? 1 }

    private func font(for block: PDFTextBlock) -> NSFont {
        let size = max(6, block.fontSize * scale)
        var font = NSFont.systemFont(ofSize: size, weight: block.isBold ? .semibold : .regular)
        if block.isSerif, let serif = font.fontDescriptor.withDesign(.serif).flatMap({ NSFont(descriptor: $0, size: size) }) { font = serif }
        if block.isItalic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private func beginEditing(_ block: PDFTextBlock) {
        let font = font(for: block)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch block.alignment {
        case .center: .center
        case .right: .right
        case .justified: .justified
        case .left: .left
        }
        let lineHeight = max(block.lineHeight, block.fontSize * 1.05) * scale
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.firstLineHeadIndent = block.firstLineIndent * scale
        let color = NSColor(srgbRed: block.color.red, green: block.color.green, blue: block.color.blue, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]

        let text = NSTextView()
        text.delegate = self
        text.isRichText = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.insertionPointColor = .controlAccentColor
        text.typingAttributes = attributes
        text.defaultParagraphStyle = paragraph
        text.textStorage?.setAttributedString(NSAttributedString(string: block.text, attributes: attributes))
        markPlaceholders(in: text)
        text.setAccessibilityIdentifier("pdfTextEditor")
        text.setAccessibilityLabel(String(localized: "编辑文字"))

        // A sheet of paper over the paragraph (its old text hidden under it), ringed in the accent colour.
        let sheet = NSView()
        sheet.wantsLayer = true
        sheet.layer?.backgroundColor = NSColor.white.cgColor
        sheet.layer?.cornerRadius = 5
        sheet.layer?.borderColor = NSColor.controlAccentColor.cgColor
        sheet.layer?.borderWidth = 1.5
        sheet.layer?.shadowColor = NSColor.black.cgColor
        sheet.layer?.shadowOpacity = 0.22
        sheet.layer?.shadowRadius = 10
        sheet.layer?.shadowOffset = CGSize(width: 0, height: isFlipped ? 3 : -3)
        sheet.layer?.masksToBounds = false
        sheet.addSubview(text)

        let bar = Self.actionBar(hasPlaceholders: block.text.contains("{v"), cancel: { [weak self] in self?.endEditing(save: false) },
                                 done: { [weak self] in self?.endEditing(save: true) })
        addSubview(sheet)
        addSubview(bar)
        let current = Editing(block: block, text: text, sheet: sheet, bar: bar)
        editing = current
        place(current)
        for view in [sheet, bar] {
            view.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            sheet.animator().alphaValue = 1
            bar.animator().alphaValue = 1
        }
        window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        // Once more after the click has ended, in case something took the focus on the way.
        DispatchQueue.main.async { [weak self, weak text] in
            guard let self, let text, self.editing?.text === text, self.window?.firstResponder !== text else { return }
            self.window?.makeFirstResponder(text)
        }
        hovered = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// 取消 and 完成 under the editor, with their keys, and a word about the purple placeholders when there are any.
    private static func actionBar(hasPlaceholders: Bool, cancel: @escaping () -> Void, done: @escaping () -> Void) -> NSView {
        let cancelButton = ClosureButton(title: String(localized: "取消"), action: cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.toolTip = "Esc"
        // 完成 in the accent colour, ⌘↩ (a plain Return belongs to the input method and to the text).
        let doneButton = AccentButton(title: String(localized: "完成"), action: done)
        doneButton.keyEquivalent = "\r"
        doneButton.keyEquivalentModifierMask = .command
        doneButton.toolTip = "⌘↩"
        let hint = NSTextField(labelWithString: hasPlaceholders ? String(localized: "紫色的 {v1} 是公式或引用，保留它们即可原样保留") : String(localized: "Esc 取消 · ⌘↩ 完成"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [hint, cancelButton, doneButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 6)
        let bar = NSVisualEffectView()
        bar.material = .popover
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 8
        bar.layer?.borderWidth = 0.5
        bar.layer?.borderColor = NSColor.separatorColor.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        bar.setFrameSize(stack.fittingSize)
        return bar
    }

    /// `{v1}` placeholders (formulas and citations kept as drawn) in a quiet purple capsule, so they read as things.
    private func markPlaceholders(in text: NSTextView) {
        guard let storage = text.textStorage else { return }
        let string = storage.string as NSString
        let regex = try? NSRegularExpression(pattern: #"\{v\d+\}"#)
        storage.beginEditing()
        for match in regex?.matches(in: storage.string, range: NSRange(location: 0, length: string.length)) ?? [] {
            storage.addAttributes([.foregroundColor: NSColor.systemPurple, .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.12)], range: match.range)
        }
        storage.endEditing()
    }

    func textDidChange(_ notification: Notification) {
        guard let editing else { return }
        // Placeholders typed or pasted get their colour too; the rest keeps the paragraph's.
        if let storage = editing.text.textStorage {
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            storage.addAttribute(.foregroundColor, value: NSColor(srgbRed: editing.block.color.red, green: editing.block.color.green, blue: editing.block.color.blue, alpha: 1),
                                 range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            markPlaceholders(in: editing.text)
        }
        place(editing)
    }

    /// The editor over the block, as wide as it, as tall as its text needs (never shorter than the block), the bar
    /// under it, right-aligned.
    private func place(_ editing: Editing) {
        guard let rect = rect(of: editing.block) else { return }
        let inset: CGFloat = 4
        let width = max(rect.width - inset * 2, 60)
        let text = editing.text
        text.frame = NSRect(x: inset, y: inset, width: width, height: 10)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = ceil(text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0)
        let height = max(rect.height - inset * 2, used)
        text.frame = NSRect(x: inset, y: inset, width: width, height: height)
        let sheetHeight = height + inset * 2
        let sheet = NSRect(x: rect.minX, y: isFlipped ? rect.minY : rect.maxY - sheetHeight, width: width + inset * 2, height: sheetHeight)
        editing.sheet.frame = sheet
        // NSTextView is flipped; inside an unflipped sheet its origin is the bottom: put it at the top.
        if !editing.sheet.isFlipped { text.frame.origin.y = inset }
        let barSize = editing.bar.frame.size
        let barY = isFlipped ? sheet.maxY + 6 : sheet.minY - 6 - barSize.height
        editing.bar.frame = NSRect(x: max(sheet.minX, sheet.maxX - barSize.width), y: barY, width: barSize.width, height: barSize.height)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) { endEditing(save: false); return true }
        if selector == #selector(insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true {
            endEditing(save: true)
            return true
        }
        return false
    }

    private func endEditing(save: Bool) {
        guard let current = editing else { return }
        editing = nil
        let newText = current.text.string
        let sheet = current.sheet, bar = current.bar
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            sheet.animator().alphaValue = 0
            bar.animator().alphaValue = 0
        }, completionHandler: {
            sheet.removeFromSuperview()
            bar.removeFromSuperview()
        })
        window?.makeFirstResponder(pdfView)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        let block = current.block
        guard save, newText != block.text, let editor else { return }
        writing = block
        needsDisplay = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try editor.replace(block, with: newText) } }.value
            switch result {
            case .success(let data):
                let written = await self.commit(data, String(localized: "编辑文字"))
                self.writing = nil
                if written {
                    self.flashed = (block.page, block.rect, Date().addingTimeInterval(1.2))
                    self.reload()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in self?.needsDisplay = true }
                }
            case .failure(let error):
                self.writing = nil
                self.needsDisplay = true
                self.showMessage(String(localized: "无法修改这段文字：\(error.localizedDescription)"))
            }
        }
    }
}

/// A push button that runs a closure.
private final class ClosureButton: NSButton {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    @objc private func fire() { run() }
}

/// A small filled button in the accent colour (the edit's 完成).
private final class AccentButton: NSButton {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white])
        target = self
        self.action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var intrinsicContentSize: NSSize {
        let size = attributedTitle.size()
        return NSSize(width: ceil(size.width) + 22, height: 20)
    }

    override func updateLayer() {
        layer?.backgroundColor = (isHighlighted ? NSColor.controlAccentColor.blended(withFraction: 0.2, of: .black) : NSColor.controlAccentColor)?.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @objc private func fire() { run() }
}
