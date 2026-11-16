import AppKit
import PDFKit
import SwiftUI

/// Every change the reader makes to annotations goes through here, so each one is undoable
/// (⌘Z), marks the document for saving and refreshes the sidebar (READER-04/05).
final class AnnotationEditor: NSObject {
    weak var pdfView: ReaderPDFView?
    let state: ReaderState
    /// Written into new annotations (设置 ▸ 阅读 ▸ 批注作者).
    var author = NSFullUserName()
    /// Called after every change (schedules the save, refreshes the annotation list).
    var onChange: () -> Void = {}
    /// "添加到笔记" / "拷贝为引用" for a text selection (READER-08).
    var onAddToNote: (String, Int) -> Void = { _, _ in }
    var onCopyAsCitation: (String, Int) -> Void = { _, _ in }
    var onTranslateSelection: () -> Void = {}
    /// 自定义颜色… for an annotation (the reader opens the colour panel).
    var onMixColor: (PDFAnnotation) -> Void = { _ in }
    /// A colour mixed for an annotation joins the tools' choices.
    var onRememberColor: (ToolColor) -> Void = { _ in }
    /// The text box's bar changed its colour or size: the text tool keeps them for the next box.
    var onTextStyle: (ToolColor?, CGFloat?) -> Void = { _, _ in }
    private var editing: (annotation: PDFAnnotation, textView: NSTextView, isNew: Bool, original: String?)?

    init(state: ReaderState) {
        self.state = state
    }

    /// New text boxes' font size (文本框 ▸ 字号).
    var textSize: CGFloat = 13
    /// After a note or a text box is placed, the select tool comes back (设置 ▸ 阅读).
    var returnsToSelect = true

    private var undoManager: UndoManager? { pdfView?.window?.undoManager }
    private func color(_ tool: AnnotationTool) -> NSColor { state.color(for: tool).nsColor }

    /// The colours an annotation can take: its tool's choices.
    func choices(for annotation: PDFAnnotation) -> [ToolColor] {
        state.choices(for: AnnotationTool.forAnnotationType(annotation.type) ?? .highlight)
    }

    /// An annotation's own colour (a text box's is its text's).
    static func color(of annotation: PDFAnnotation) -> NSColor {
        (annotation.type == "FreeText" ? annotation.fontColor : nil) ?? annotation.color
    }

    // MARK: Creating

    /// One markup annotation per page, covering every line of the selection (like Preview).
    func addMarkup(_ type: PDFAnnotationSubtype, for selection: PDFSelection) {
        let lines = selection.selectionsByLine()
        var added: [PDFAnnotation] = []
        for page in selection.pages {
            let rects = lines.compactMap { line -> NSRect? in
                let rect = line.bounds(for: page)
                return rect.isEmpty || rect.width < 0.5 ? nil : rect
            }
            guard let union = rects.dropFirst().reduce(rects.first, { $0?.union($1) }) else { continue }
            let annotation = PDFAnnotation(bounds: union, forType: type, withProperties: nil)
            annotation.quadrilateralPoints = rects.flatMap { rect -> [NSValue] in
                let r = rect.offsetBy(dx: -union.minX, dy: -union.minY)
                return [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
                        NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY)].map { NSValue(point: $0) }
            }
            let tool: AnnotationTool = type == .highlight ? .highlight : type == .underline ? .underline : .strikeOut
            annotation.color = type == .highlight ? color(tool).withAlphaComponent(0.5) : color(tool)
            stamp(annotation)
            added.append(annotation)
            add(annotation, to: page)
        }
        if added.count > 1 { undoManager?.setActionName(String(localized: "添加\(state.tool.title)")) }
    }

    /// Places a sticky note or a text box where the user clicked, then opens it for writing: the note's card, the text
    /// box's caret right there. A note stays even if nothing is written in it (it can be deleted from its card).
    func place(_ tool: AnnotationTool, at point: NSPoint, on page: PDFPage) {
        finishTextBox()
        let annotation: PDFAnnotation
        if tool == .note {
            let side = NoteAnnotation.side
            annotation = NoteAnnotation(bounds: NSRect(x: point.x - side / 2, y: point.y - side * 0.6, width: side, height: side * 1.2),
                                        forType: .text, withProperties: nil)
            annotation.iconType = .comment
            annotation.color = color(.note)
        } else {
            // The text starts where the click was: its first line's middle there.
            let font = NSFont.systemFont(ofSize: textSize)
            let line = ceil(font.ascender - font.descender + font.leading) + 2 * TextBoxEditor.inset
            annotation = TextBoxAnnotation(bounds: NSRect(x: point.x - TextBoxEditor.inset, y: point.y - line / 2, width: textSize * 2, height: line),
                                           forType: .freeText, withProperties: nil)
            annotation.font = font
            annotation.fontColor = color(.text)
            annotation.color = .clear
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            annotation.contents = ""
        }
        stamp(annotation)
        add(annotation, to: page)
        pdfView?.selectAnnotation(annotation)
        edit(annotation, isNew: true)
        if returnsToSelect { resetTool() }
    }

    func addInk(points: [NSPoint], on page: PDFPage) {
        let width = pdfView?.inkWidth ?? 2
        // Only what is on the page: a stroke run off its edge would leave ink nobody can see, find or erase.
        let runs = Self.runs(of: points, inside: page.bounds(for: .cropBox))
        let all = runs.flatMap { $0 }
        guard !all.isEmpty else { return }
        let xs = all.map(\.x), ys = all.map(\.y)
        let bounds = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -(width + 1), dy: -(width + 1))
        let annotation = InkAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        for run in runs {
            let path = NSBezierPath()
            for (index, point) in run.enumerated() {
                let relative = NSPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
                if index == 0 { path.move(to: relative) } else { path.line(to: relative) }
            }
            if run.count == 1 { path.line(to: NSPoint(x: run[0].x - bounds.minX, y: run[0].y - bounds.minY)) }
            annotation.add(path)
        }
        let border = PDFBorder()
        border.lineWidth = width
        annotation.border = border
        annotation.color = color(.ink)
        stamp(annotation)
        add(annotation, to: page)
    }

    /// The parts of a stroke inside `box`, cut where it crosses the edge.
    static func runs(of points: [NSPoint], inside box: NSRect) -> [[NSPoint]] {
        guard let first = points.first else { return [] }
        var runs: [[NSPoint]] = []
        var current: [NSPoint] = box.contains(first) ? [first] : []
        for (a, b) in zip(points, points.dropFirst()) {
            let inA = box.contains(a), inB = box.contains(b)
            if inA && inB {
                current.append(b)
            } else if inA {
                current.append(edge(from: a, to: b, box: box))
                runs.append(current)
                current = []
            } else if inB {
                current = [edge(from: b, to: a, box: box), b]
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Where the segment from `inside` towards `outside` leaves `box`.
    private static func edge(from inside: NSPoint, to outside: NSPoint, box: NSRect) -> NSPoint {
        var t: CGFloat = 1
        let dx = outside.x - inside.x, dy = outside.y - inside.y
        if dx > 0 { t = min(t, (box.maxX - inside.x) / dx) } else if dx < 0 { t = min(t, (box.minX - inside.x) / dx) }
        if dy > 0 { t = min(t, (box.maxY - inside.y) / dy) } else if dy < 0 { t = min(t, (box.minY - inside.y) / dy) }
        return NSPoint(x: inside.x + dx * max(0, t), y: inside.y + dy * max(0, t))
    }

    private func stamp(_ annotation: PDFAnnotation) {
        annotation.userName = author.isEmpty ? nil : author
        annotation.modificationDate = Date()
    }

    // MARK: Undoable primitives

    func add(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { $0.remove(annotation) }
        undoManager?.setActionName(String(localized: "添加批注"))
        changed(page)
    }

    func remove(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        if pdfView?.selectedAnnotation === annotation { pdfView?.selectAnnotation(nil) }
        // A note's popup is a separate annotation; it goes with it.
        if let popup = annotation.popup { page.removeAnnotation(popup) }
        page.removeAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { $0.add(annotation, to: page) }
        undoManager?.setActionName(String(localized: "删除批注"))
        changed(page)
    }

    /// Records a drag the view already performed.
    func didMove(_ annotation: PDFAnnotation, from original: NSRect) {
        let moved = annotation.bounds
        annotation.modificationDate = Date()
        undoManager?.registerUndo(withTarget: self) { $0.setBounds(annotation, original, redo: moved) }
        undoManager?.setActionName(String(localized: "移动批注"))
        if let page = annotation.page { changed(page) }
    }

    /// Records an erase the view already performed (READER-30): one undo step for the whole drag.
    func didErase(_ changes: [InkEraseSession.Change]) {
        guard !changes.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { $0.exchange(changes, forward: false) }
        undoManager?.setActionName(String(localized: "擦除"))
        var pages: [PDFPage] = []
        for change in changes where !pages.contains(where: { $0 === change.page }) { pages.append(change.page) }
        pages.forEach(changed)
    }

    /// Puts the originals back (undo) or their erased replacements again (redo).
    private func exchange(_ changes: [InkEraseSession.Change], forward: Bool) {
        var pages: [PDFPage] = []
        for change in forward ? changes : changes.reversed() {
            let (out, back) = forward ? (change.original, change.replacement) : (change.replacement, change.original)
            if let out {
                if pdfView?.selectedAnnotation === out { pdfView?.selectAnnotation(nil) }
                change.page.removeAnnotation(out)
            }
            if let back { change.page.addAnnotation(back) }
            // A popup leaves and comes back with an annotation erased completely.
            if change.replacement == nil, let popup = change.original.popup {
                if forward { change.page.removeAnnotation(popup) } else { change.page.addAnnotation(popup) }
            }
            if !pages.contains(where: { $0 === change.page }) { pages.append(change.page) }
        }
        undoManager?.registerUndo(withTarget: self) { $0.exchange(changes, forward: !forward) }
        undoManager?.setActionName(String(localized: "擦除"))
        pages.forEach(changed)
    }

    private func setBounds(_ annotation: PDFAnnotation, _ bounds: NSRect, redo: NSRect) {
        annotation.bounds = bounds
        undoManager?.registerUndo(withTarget: self) { $0.setBounds(annotation, redo, redo: bounds) }
        if let page = annotation.page { changed(page) }
    }

    func setColor(_ annotation: PDFAnnotation, _ newColor: NSColor) {
        let isTextBox = annotation.type == "FreeText"
        let old = isTextBox ? (annotation.fontColor ?? .black) : annotation.color
        apply(newColor, to: annotation)
        undoManager?.registerUndo(withTarget: self) { editor in editor.restoreColor(annotation, old, redo: newColor) }
        undoManager?.setActionName(String(localized: "更改颜色"))
        if let page = annotation.page { changed(page) }
    }

    private func restoreColor(_ annotation: PDFAnnotation, _ color: NSColor, redo: NSColor) {
        if annotation.type == "FreeText" { annotation.fontColor = color } else { annotation.color = color }
        undoManager?.registerUndo(withTarget: self) { $0.setColor(annotation, redo) }
        if let page = annotation.page { changed(page) }
    }

    private func apply(_ color: NSColor, to annotation: PDFAnnotation) {
        switch annotation.type {
        case "Highlight": annotation.color = color.withAlphaComponent(0.5)
        // A text box's colour is its text's.
        case "FreeText": annotation.fontColor = color.withAlphaComponent(1)
        default: annotation.color = color.withAlphaComponent(1)
        }
        annotation.modificationDate = Date()
    }

    /// A text box's text, the bounds that fit it, and its font and colour, in one undoable step.
    func setTextBox(_ annotation: PDFAnnotation, contents: String?, bounds: NSRect, font: NSFont? = nil, color: NSColor? = nil) {
        let oldContents = annotation.contents, oldBounds = annotation.bounds, oldFont = annotation.font, oldColor = annotation.fontColor
        annotation.contents = contents
        annotation.bounds = bounds
        if let font { annotation.font = font }
        if let color { annotation.fontColor = color }
        annotation.modificationDate = Date()
        undoManager?.registerUndo(withTarget: self) { $0.setTextBox(annotation, contents: oldContents, bounds: oldBounds, font: oldFont, color: oldColor) }
        undoManager?.setActionName(String(localized: "编辑批注"))
        if let page = annotation.page { changed(page) }
    }

    func setContents(_ annotation: PDFAnnotation, _ text: String?) {
        let old = annotation.contents
        annotation.contents = text
        annotation.modificationDate = Date()
        undoManager?.registerUndo(withTarget: self) { $0.setContents(annotation, old) }
        undoManager?.setActionName(String(localized: "编辑批注"))
        if let page = annotation.page { changed(page) }
    }

    private func changed(_ page: PDFPage) {
        pdfView?.annotationsChanged(on: page)
        onChange()
    }

    func resetTool() {
        state.tool = .select
        pdfView?.tool = .select
    }

    // MARK: Editing text (notes, text boxes, comments on markup)

    private var card: (annotation: PDFAnnotation, model: AnnotationCardModel, isNew: Bool, original: String?, deleted: Bool)?
    private weak var cardPanel: AnnotationCardPanel?
    private var textBox: TextBoxEditor?

    func edit(_ annotation: PDFAnnotation) { edit(annotation, isNew: false) }

    /// Preview hooks: what is typed into the card or the text box being written.
    func previewType(_ text: String) {
        if let card { card.model.text = text }
        textBox?.previewType(text)
    }

    /// The comment card closes, keeping what it says.
    func finishCard() { cardPanel?.close() }
    var isShowingCard: Bool { cardPanel != nil }
    /// Preview hook: the open card dragged larger or smaller by its corner.
    func previewDragCard(by total: NSSize, steps: Int) { cardPanel?.previewDrag(by: total, steps: steps) }

    /// Whether this click just closed the card of `annotation` (so it does not open it again at once).
    func cardWasClosed(for annotation: PDFAnnotation, by event: NSEvent) -> Bool {
        guard let closing = AnnotationCardPanel.closingClick else { return false }
        return closing.annotation == ObjectIdentifier(annotation) && abs(closing.time - event.timestamp) < 0.001
    }

    /// A colour mixed in the colour panel for `annotation`: the box being written takes it at once, anything else
    /// is recoloured (an undo step).
    func mixed(_ color: NSColor, for annotation: PDFAnnotation) {
        if let textBox, textBox.annotation === annotation { textBox.mixed(color) } else { setColor(annotation, color) }
        if let card, card.annotation === annotation {
            let mixed = ToolColor(color.withAlphaComponent(1))
            if !card.model.palette.contains(mixed) { card.model.palette.append(mixed) }
            card.model.color = mixed
        }
        onRememberColor(ToolColor(color))
    }

    /// A text box being written ends (a click elsewhere, a tool chosen, the page changing).
    func finishTextBox() { textBox?.end() }
    var isWritingTextBox: Bool { textBox != nil }

    private func edit(_ annotation: PDFAnnotation, isNew: Bool) {
        guard let pdfView, let page = annotation.page else { return }
        if annotation.type == "FreeText" { return write(annotation, isNew: isNew) }
        cardPanel?.close()
        let type = annotation.type ?? ""
        let choices = choices(for: annotation)
        let model = AnnotationCardModel(
            text: annotation.contents ?? "", color: ToolColor.matching(annotation.color, in: choices) ?? ToolColor(annotation.color.withAlphaComponent(1)),
            quote: type == "Text" ? nil : Self.text(of: annotation),
            author: annotation.userName, date: annotation.modificationDate, palette: choices,
            placeholder: type == "Text" ? String(localized: "写点什么…") : String(localized: "添加评论…"))
        let panel = AnnotationCardPanel(model: model, annotation: annotation, in: pdfView)
        model.onColor = { [weak self] color in
            self?.setColor(annotation, color.nsColor)
            if color.preset == nil { self?.onRememberColor(color) }
        }
        // The colour panel opens beside the card, which stays open and takes the colour mixed.
        model.onMix = { [weak self] in self?.onMixColor(annotation) }
        model.onDone = { [weak panel] in panel?.close() }
        model.onDelete = { [weak self, weak panel] in
            self?.card?.deleted = true
            panel?.close()
            self?.remove(annotation)
        }
        // Written as typed: what is in the card is in the note, whatever closes it.
        model.onText = { [weak self] text in
            guard let self, let card = self.card, card.annotation === annotation else { return }
            annotation.contents = text.isEmpty ? nil : text
            annotation.modificationDate = Date()
            if let page = annotation.page { self.pdfView?.annotationsChanged(on: page) }
        }
        panel.onClose = { [weak self, weak panel] in if let panel { self?.cardDidClose(panel) } }
        card = (annotation, model, isNew, annotation.contents, false)
        cardPanel = panel
        _ = page
        panel.show()
    }

    private func cardDidClose(_ panel: AnnotationCardPanel) {
        guard let card, panel === cardPanel || cardPanel == nil else { return }
        self.card = nil
        cardPanel = nil
        // Done with it: no outline is left around it on the page.
        if pdfView?.selectedAnnotation === card.annotation { pdfView?.selectAnnotation(nil) }
        guard !card.deleted else { return }
        let text = card.model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : card.model.text
        guard let page = card.annotation.page else { return }
        if card.isNew {
            // New: the note itself is the undo step; what it says goes with it.
            card.annotation.contents = text
            changed(page)
        } else if text != card.original {
            // One undo step for the whole edit, from what it said before.
            card.annotation.contents = card.original
            setContents(card.annotation, text)
        }
    }

    /// A text box written on the page, in place.
    private func write(_ annotation: PDFAnnotation, isNew: Bool) {
        guard let pdfView else { return }
        finishTextBox()
        let editor = TextBoxEditor(annotation: annotation, in: pdfView, isNew: isNew,
                                   choices: state.choices(for: .text))
        editor.onStyle = { [weak self] color, size in
            if let color, color.preset == nil { self?.onRememberColor(color) }
            self?.onTextStyle(color, size)
        }
        editor.onMix = { [weak self] in self?.onMixColor(annotation) }
        editor.onEnd = { [weak self, weak editor] text in
            guard let self, let editor else { return }
            self.textBox = nil
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let page = annotation.page else { return }
            if trimmed.isEmpty {
                if editor.isNew {
                    // An empty new box is not kept (no undo step either).
                    page.removeAnnotation(annotation)
                    self.pdfView?.selectAnnotation(nil)
                    self.changed(page)
                } else if editor.original != nil {
                    self.remove(annotation)
                }
                return
            }
            let font = annotation.font ?? .systemFont(ofSize: self.textSize)
            let bounds = TextBoxEditor.fittingBounds(for: text, font: font, from: annotation.bounds, keepWidth: !editor.isNew)
            if editor.isNew {
                annotation.contents = text
                annotation.bounds = bounds
                self.changed(page)
            } else if text != (editor.original ?? "") || bounds != editor.originalBounds || editor.styleChanged {
                // The bar changed the box (or it was moved) as it was written: undo puts all of it back.
                let font = annotation.font, color = annotation.fontColor
                annotation.font = editor.originalFont
                annotation.fontColor = editor.originalColor
                annotation.bounds = editor.originalBounds
                self.setTextBox(annotation, contents: text, bounds: bounds, font: font, color: color)
            }
        }
        textBox = editor
        // The field's own edge shows the box; the dashed selection outline would double it.
        pdfView.selectAnnotation(nil)
        editor.begin()
    }

    // MARK: Menus

    func menu(for annotation: PDFAnnotation) -> NSMenu {
        let menu = NSMenu()
        let isTextBox = annotation.type == "FreeText"
        let colors = choices(for: annotation)
        let current = ToolColor.matching(Self.color(of: annotation), in: colors)
        menu.addItem(.colorSwatches(colors.map { .init(name: $0.title, color: $0.nsColor) } + [.custom], selected: current.flatMap { colors.firstIndex(of: $0) }) {
            [weak self] index in
            if index < colors.count { self?.setColor(annotation, colors[index].nsColor) } else { self?.onMixColor(annotation) }
        })
        menu.addItem(.separator())
        let isTextual = annotation.type == "Text" || annotation.type == "FreeText"
        menu.addItem(.closure(isTextBox ? String(localized: "编辑文字") : isTextual ? String(localized: "打开便签") : (annotation.contents ?? "").isEmpty ? String(localized: "添加评论…") : String(localized: "编辑评论…")) { [weak self] in
            self?.edit(annotation)
        })
        if let text = Self.text(of: annotation), !text.isEmpty, let page = annotation.page,
           let index = page.document?.index(for: page) {
            menu.addItem(.closure(String(localized: "添加到笔记")) { [weak self] in self?.onAddToNote(text, index) })
            menu.addItem(.closure(String(localized: "拷贝文字")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
        }
        menu.addItem(.separator())
        menu.addItem(.closure(String(localized: "删除批注")) { [weak self] in self?.remove(annotation) })
        return menu
    }

    func menu(forSelection selection: PDFSelection, base: NSMenu) -> NSMenu {
        let menu = NSMenu()
        let text = Self.clean(selection.string ?? "")
        let index = selection.pages.first.flatMap { $0.document?.index(for: $0) } ?? 0
        let translate = NSMenuItem.closure(String(localized: "翻译")) { [weak self] in self?.onTranslateSelection() }
        translate.image = NSImage(systemSymbolName: "translate", accessibilityDescription: nil)
        menu.addItem(translate)
        menu.addItem(.separator())
        menu.addItem(.closure(String(localized: "拷贝")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        menu.addItem(.closure(String(localized: "拷贝为引用")) { [weak self] in self?.onCopyAsCitation(text, index) })
        menu.addItem(.separator())
        for tool in [AnnotationTool.highlight, .underline, .strikeOut] {
            let item = NSMenuItem.closure(tool.title) { [weak self, weak pdfView] in
                guard let type = tool.markupType else { return }
                self?.addMarkup(type, for: selection)
                pdfView?.clearSelection()
            }
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.closure(String(localized: "添加到笔记")) { [weak self] in self?.onAddToNote(text, index) })
        // Keep PDFKit's own items (look up, zoom, display modes) after ours.
        let extras = base.items.filter { $0.action != #selector(NSText.copy(_:)) }
        if !extras.isEmpty {
            menu.addItem(.separator())
            for item in extras {
                base.removeItem(item)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Text under a markup annotation.
    static func text(of annotation: PDFAnnotation) -> String? {
        guard let page = annotation.page, ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(annotation.type ?? "") else {
            return annotation.contents
        }
        return clean(page.selection(for: annotation.bounds.insetBy(dx: 1, dy: 1))?.string ?? "")
    }

    /// Joins hyphenated line breaks and collapses whitespace.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "-\n", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
