import AppKit
import PDFKit

/// Every change the reader makes to annotations goes through here, so each one is undoable
/// (⌘Z), marks the document for saving and refreshes the sidebar (READER-04/05).
final class AnnotationEditor: NSObject, NSPopoverDelegate {
    weak var pdfView: ReaderPDFView?
    let state: ReaderState
    /// Written into new annotations (设置 ▸ 阅读 ▸ 批注作者).
    var author = NSFullUserName()
    /// Called after every change (schedules the save, refreshes the annotation list).
    var onChange: () -> Void = {}
    /// "添加到笔记" / "拷贝为引用" for a text selection (READER-08).
    var onAddToNote: (String, Int) -> Void = { _, _ in }
    var onCopyAsCitation: (String, Int) -> Void = { _, _ in }
    private var editing: (annotation: PDFAnnotation, textView: NSTextView, isNew: Bool, original: String?)?

    init(state: ReaderState) {
        self.state = state
    }

    private var undoManager: UndoManager? { pdfView?.window?.undoManager }
    private var color: NSColor { state.color.nsColor }

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
            annotation.color = type == .highlight ? color.withAlphaComponent(0.5) : color
            stamp(annotation)
            added.append(annotation)
            add(annotation, to: page)
        }
        if added.count > 1 { undoManager?.setActionName("添加\(state.tool.title)") }
    }

    /// Places a sticky note or a text box where the user clicked, then opens its editor.
    func place(_ tool: AnnotationTool, at point: NSPoint, on page: PDFPage) {
        let annotation: PDFAnnotation
        if tool == .note {
            annotation = PDFAnnotation(bounds: NSRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20),
                                       forType: .text, withProperties: nil)
            annotation.iconType = .comment
            annotation.color = color
        } else {
            annotation = PDFAnnotation(bounds: NSRect(x: point.x, y: point.y - 44, width: 220, height: 44),
                                       forType: .freeText, withProperties: nil)
            annotation.font = .systemFont(ofSize: 12)
            annotation.fontColor = .black
            annotation.color = color.withAlphaComponent(0.25)
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            annotation.contents = ""
        }
        stamp(annotation)
        add(annotation, to: page)
        pdfView?.selectAnnotation(annotation)
        edit(annotation, isNew: true)
        resetTool()
    }

    func addInk(points: [NSPoint], on page: PDFPage) {
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -3, dy: -3)
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            let relative = NSPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
            if index == 0 { path.move(to: relative) } else { path.line(to: relative) }
        }
        annotation.add(path)
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        annotation.color = color
        stamp(annotation)
        add(annotation, to: page)
    }

    private func stamp(_ annotation: PDFAnnotation) {
        annotation.userName = author.isEmpty ? nil : author
        annotation.modificationDate = Date()
    }

    // MARK: Undoable primitives

    func add(_ annotation: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { $0.remove(annotation) }
        undoManager?.setActionName("添加批注")
        changed(page)
    }

    func remove(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        if pdfView?.selectedAnnotation === annotation { pdfView?.selectAnnotation(nil) }
        // A note's popup is a separate annotation; it goes with it.
        if let popup = annotation.popup { page.removeAnnotation(popup) }
        page.removeAnnotation(annotation)
        undoManager?.registerUndo(withTarget: self) { $0.add(annotation, to: page) }
        undoManager?.setActionName("删除批注")
        changed(page)
    }

    /// Records a drag the view already performed.
    func didMove(_ annotation: PDFAnnotation, from original: NSRect) {
        let moved = annotation.bounds
        annotation.modificationDate = Date()
        undoManager?.registerUndo(withTarget: self) { $0.setBounds(annotation, original, redo: moved) }
        undoManager?.setActionName("移动批注")
        if let page = annotation.page { changed(page) }
    }

    private func setBounds(_ annotation: PDFAnnotation, _ bounds: NSRect, redo: NSRect) {
        annotation.bounds = bounds
        undoManager?.registerUndo(withTarget: self) { $0.setBounds(annotation, redo, redo: bounds) }
        if let page = annotation.page { changed(page) }
    }

    func setColor(_ annotation: PDFAnnotation, _ newColor: AnnotationColor) {
        let old = annotation.color
        apply(newColor.nsColor, to: annotation)
        undoManager?.registerUndo(withTarget: self) { editor in editor.restoreColor(annotation, old, redo: newColor) }
        undoManager?.setActionName("更改颜色")
        if let page = annotation.page { changed(page) }
    }

    private func restoreColor(_ annotation: PDFAnnotation, _ color: NSColor, redo: AnnotationColor) {
        annotation.color = color
        undoManager?.registerUndo(withTarget: self) { $0.setColor(annotation, redo) }
        if let page = annotation.page { changed(page) }
    }

    private func apply(_ color: NSColor, to annotation: PDFAnnotation) {
        switch annotation.type {
        case "Highlight": annotation.color = color.withAlphaComponent(0.5)
        case "FreeText": annotation.color = color.withAlphaComponent(0.25)
        default: annotation.color = color
        }
        annotation.modificationDate = Date()
    }

    func setContents(_ annotation: PDFAnnotation, _ text: String?) {
        let old = annotation.contents
        annotation.contents = text
        annotation.modificationDate = Date()
        undoManager?.registerUndo(withTarget: self) { $0.setContents(annotation, old) }
        undoManager?.setActionName("编辑批注")
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

    func edit(_ annotation: PDFAnnotation) { edit(annotation, isNew: false) }

    private func edit(_ annotation: PDFAnnotation, isNew: Bool) {
        guard let pdfView, let page = annotation.page else { return }
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.string = annotation.contents ?? ""
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scroll.frame = NSRect(x: 0, y: 0, width: 280, height: 140)
        let controller = NSViewController()
        controller.view = scroll
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        editing = (annotation, textView, isNew, annotation.contents)
        let rect = pdfView.convert(annotation.bounds, from: page)
        popover.show(relativeTo: rect, of: pdfView, preferredEdge: .maxY)
        pdfView.window?.makeFirstResponder(textView)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let editing else { return }
        self.editing = nil
        let text = editing.textView.string
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if editing.isNew && isEmpty && editing.annotation.type == "FreeText" {
            // An empty text box that was never filled in is discarded without an undo step.
            if let page = editing.annotation.page {
                page.removeAnnotation(editing.annotation)
                pdfView?.selectAnnotation(nil)
                changed(page)
            }
            return
        }
        if text != (editing.original ?? "") {
            if editing.isNew {
                editing.annotation.contents = text
                if let page = editing.annotation.page { changed(page) }
            } else {
                setContents(editing.annotation, isEmpty ? nil : text)
            }
        }
    }

    // MARK: Menus

    func menu(for annotation: PDFAnnotation) -> NSMenu {
        let menu = NSMenu()
        let current = AnnotationColor.nearest(to: annotation.color.withAlphaComponent(1))
        let colors = AnnotationColor.allCases
        menu.addItem(.colorSwatches(colors.map { .init(name: $0.title, color: $0.nsColor) }, selected: current.flatMap { colors.firstIndex(of: $0) }) {
            [weak self] index in self?.setColor(annotation, colors[index])
        })
        menu.addItem(.separator())
        let isTextual = annotation.type == "Text" || annotation.type == "FreeText"
        menu.addItem(.closure(isTextual ? "编辑内容…" : (annotation.contents ?? "").isEmpty ? "添加评论…" : "编辑评论…") { [weak self] in
            self?.edit(annotation)
        })
        if let text = Self.text(of: annotation), !text.isEmpty, let page = annotation.page,
           let index = page.document?.index(for: page) {
            menu.addItem(.closure("添加到笔记") { [weak self] in self?.onAddToNote(text, index) })
            menu.addItem(.closure("拷贝文字") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
        }
        menu.addItem(.separator())
        menu.addItem(.closure("删除批注") { [weak self] in self?.remove(annotation) })
        return menu
    }

    func menu(forSelection selection: PDFSelection, base: NSMenu) -> NSMenu {
        let menu = NSMenu()
        let text = Self.clean(selection.string ?? "")
        let index = selection.pages.first.flatMap { $0.document?.index(for: $0) } ?? 0
        menu.addItem(.closure("拷贝") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        menu.addItem(.closure("拷贝为引用") { [weak self] in self?.onCopyAsCitation(text, index) })
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
        menu.addItem(.closure("添加到笔记") { [weak self] in self?.onAddToNote(text, index) })
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
