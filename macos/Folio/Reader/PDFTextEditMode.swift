import AppKit
import FolioTranslate
import PDFKit

/// 编辑 PDF 文字 (EDIT-01): over the pages, the text blocks the editor offers light up under the pointer; a click opens
/// the block's text in place, set like the page (size, colour, alignment), and finishing writes it into the file — the
/// block's glyphs taken out and the new text set in their space (`PDFTextEditor`). Each edit is one undo step.
@MainActor
final class PDFTextEditMode: NSView, NSTextViewDelegate {
    private weak var pdfView: PDFView?
    /// The file as it is now: its blocks per page, read in the background as pages come into view.
    private var editor: PDFTextEditor?
    private var blocks: [Int: [PDFTextBlock]] = [:]
    private var loading: Set<Int> = []
    private var generation = 0
    private var hovered: PDFTextBlock?
    private var editing: (block: PDFTextBlock, view: NSTextView, frame: NSView)?
    private var busy = false
    private var tracking: NSTrackingArea?

    /// Writes new file data (and makes it one undo step); true when it worked.
    var commit: (_ data: Data, _ actionName: String) async -> Bool = { _, _ in false }
    var data: () -> Data? = { nil }
    var showMessage: (String) -> Void = { _ in }

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: pdfView.bounds)
        autoresizingMask = [.width, .height]
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewVisiblePagesChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(documentChanged), name: .PDFViewDocumentChanged, object: pdfView)
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The file changed (an edit, an undo, annotations saved): its blocks are read again.
    func reload() {
        generation += 1
        editor = nil
        blocks = [:]
        loading = []
        hovered = nil
        needsDisplay = true
        loadVisiblePages()
    }

    /// For the self-test: what the layer knows.
    var stateDescription: String {
        "pages visible \(visiblePages), blocks \(blocks.mapValues(\.count)), loading \(loading), editor \(editor != nil), editing \(editing != nil), busy \(busy), frame \(frame), superview \(superview.map { String(describing: type(of: $0)) } ?? "nil")"
    }

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
            }
        }
    }

    @objc private func documentChanged() { reload() }

    @objc private func viewMoved() {
        loadVisiblePages()
        needsDisplay = true
        if let editing { place(editing.frame, for: editing.block) }
    }

    /// The block's rectangle in this view.
    private func rect(of block: PDFTextBlock) -> NSRect? {
        guard let pdfView, let page = pdfView.document?.page(at: block.page) else { return nil }
        return convert(pdfView.convert(block.rect, from: page), from: pdfView)
    }

    private func block(at point: NSPoint) -> PDFTextBlock? {
        for page in visiblePages {
            for block in blocks[page] ?? [] where !block.text.isEmpty {
                if let rect = rect(of: block), rect.insetBy(dx: -3, dy: -2).contains(point) { return block }
            }
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for page in visiblePages {
            for block in blocks[page] ?? [] where !block.text.isEmpty {
                guard let rect = rect(of: block)?.insetBy(dx: -3, dy: -2), rect.intersects(dirtyRect) else { continue }
                if editing?.block == block { continue }
                let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                path.lineWidth = 1
                if block == hovered {
                    (block.isEditable ? accent.withAlphaComponent(0.10) : NSColor.secondaryLabelColor.withAlphaComponent(0.08)).setFill()
                    path.fill()
                    (block.isEditable ? accent.withAlphaComponent(0.75) : NSColor.secondaryLabelColor.withAlphaComponent(0.6)).setStroke()
                    if !block.isEditable { path.setLineDash([3, 3], count: 2, phase: 0) }
                    path.stroke()
                } else if block.isEditable {
                    accent.withAlphaComponent(0.18).setStroke()
                    path.stroke()
                }
            }
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = block(at: point)
        if hit != hovered {
            hovered = hit
            needsDisplay = true
            toolTip = hit.flatMap { $0.isEditable ? nil : $0.reason.map { String(localized: "这里不能编辑：\($0)") } }
        }
        (hit?.isEditable == true ? NSCursor.iBeam : .arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let editing, editing.frame.frame.contains(point) { return }
        if editing != nil { endEditing(save: true); return }
        guard !busy, let hit = block(at: point) else { return }
        guard hit.isEditable else {
            showMessage(String(localized: "这里不能编辑：\(hit.reason ?? "")"))
            return
        }
        beginEditing(hit)
    }

    // The rest of a click stays here: passed on, PDFView would take the focus back from the editor as the mouse comes up.
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) { pdfView?.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { pdfView?.magnify(with: event) }

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
        paragraph.minimumLineHeight = block.lineHeight * scale
        paragraph.maximumLineHeight = block.lineHeight * scale
        let color = NSColor(srgbRed: block.color.red, green: block.color.green, blue: block.color.blue, alpha: 1)
        let text = NSTextView()
        text.delegate = self
        text.isRichText = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 0, height: 0)
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.font = font
        text.textColor = color
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        text.string = block.text
        text.textStorage?.setAttributes([.font: font, .foregroundColor: color, .paragraphStyle: paragraph], range: NSRange(location: 0, length: (block.text as NSString).length))
        markPlaceholders(in: text)
        text.setAccessibilityIdentifier("pdfTextEditor")

        // A sheet of paper under the text (the page's text is hidden by it) with a ring of the accent colour.
        let frame = NSView()
        frame.wantsLayer = true
        frame.layer?.backgroundColor = NSColor.white.cgColor
        frame.layer?.cornerRadius = 3
        frame.layer?.borderColor = NSColor.controlAccentColor.cgColor
        frame.layer?.borderWidth = 1.5
        frame.layer?.shadowOpacity = 0.18
        frame.layer?.shadowRadius = 6
        frame.layer?.shadowOffset = CGSize(width: 0, height: -1)
        frame.addSubview(text)
        addSubview(frame)
        editing = (block, text, frame)
        place(frame, for: block)
        frame.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; frame.animator().alphaValue = 1 }
        window?.makeFirstResponder(text)
        text.selectAll(nil)
        // Once more after the click has ended, in case something took the focus on the way.
        DispatchQueue.main.async { [weak self, weak text] in
            guard let self, let text, self.editing?.view === text, self.window?.firstResponder !== text else { return }
            self.window?.makeFirstResponder(text)
        }
        hovered = nil
        needsDisplay = true
    }

    /// `{v1}` placeholders (formulas kept as drawn) in a quiet capsule colour, so they read as things, not text.
    private func markPlaceholders(in text: NSTextView) {
        guard let storage = text.textStorage else { return }
        let string = storage.string as NSString
        let regex = try? NSRegularExpression(pattern: #"\{v\d+\}"#)
        for match in regex?.matches(in: storage.string, range: NSRange(location: 0, length: string.length)) ?? [] {
            storage.addAttributes([.foregroundColor: NSColor.systemPurple, .backgroundColor: NSColor.systemPurple.withAlphaComponent(0.12)], range: match.range)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let editing else { return }
        place(editing.frame, for: editing.block)
    }

    /// The editor over the block, as wide as it, as tall as its text needs (never shorter than the block).
    private func place(_ frame: NSView, for block: PDFTextBlock) {
        guard let rect = rect(of: block), let text = editing?.view else { return }
        let width = max(rect.width, 40)
        text.frame = NSRect(x: 4, y: 3, width: width, height: 10)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? rect.height
        let height = max(rect.height, ceil(used))
        text.frame = NSRect(x: 4, y: 3, width: width, height: height)
        frame.frame = NSRect(x: rect.minX - 4, y: rect.maxY - height - 3, width: width + 8, height: height + 6)
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
        guard let (block, text, frame) = editing else { return }
        editing = nil
        let newText = text.string
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; frame.animator().alphaValue = 0 }, completionHandler: { frame.removeFromSuperview() })
        window?.makeFirstResponder(pdfView)
        needsDisplay = true
        guard save, newText != block.text, let editor else { return }
        busy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try editor.replace(block, with: newText) } }.value
            defer { self.busy = false }
            switch result {
            case .success(let data):
                if await self.commit(data, String(localized: "编辑文字")) { self.reload() }
            case .failure(let error):
                self.showMessage(String(localized: "无法修改这段文字：\(error.localizedDescription)"))
            }
        }
    }
}
