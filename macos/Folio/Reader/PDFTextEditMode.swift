import AppKit
import CoreText
import FolioTranslate
import PDFKit

/// 编辑 PDF 文字 (EDIT-01): the page's own text, edited where it stands. A layer inside PDFView's document view, so it
/// scrolls and zooms with the pages (the scroll wheel, the trackpad and pinching work as they do without it).
///
/// A click in a paragraph puts the caret there; typing changes the text in place, drawn with the page's own fonts at
/// the page's own size and spacing (`PDFParagraph`): only the lines the change reaches are set again, the rest of the
/// page does not move. There is nothing to open or confirm: clicking elsewhere, Esc or Return keeps the change — it is
/// written into the file and only that page is shown again — and ⌘Z takes it back (while still typing, ⌘Z undoes the
/// typing). The input method's marked text is set inline, underlined, in the page's font too.
@MainActor
final class PDFTextEditMode: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    private weak var pdfView: PDFView?
    /// The file as it is now: its blocks per page, read in the background as pages come into view.
    private var editor: PDFTextEditor?
    private var blocks: [Int: [PDFTextBlock]] = [:]
    private var loading: Set<Int> = []
    private var generation = 0
    private var hovered: PDFTextBlock?
    private var tracking: NSTrackingArea?
    /// A click that came while the file was being read again: done once it is read.
    private var pendingClick: (point: NSPoint, page: Int)?

    /// The paragraph being edited.
    private final class Session {
        let block: PDFTextBlock
        let paragraph: PDFParagraph
        /// The selection in atoms (the caret when empty) and the end that stays when it is extended.
        var selection: Range<Int>
        var anchor: Int
        var marked: Range<Int>?
        var preview: PDFParagraph.Preview
        var undo: [(state: PDFParagraph.State, selection: Range<Int>)] = []
        var redo: [(state: PDFParagraph.State, selection: Range<Int>)] = []
        var lastEdit: (kind: Int, at: Date)?
        /// Where up and down arrows aim (page space), kept while moving line to line.
        var goalX: Double?

        init(block: PDFTextBlock, paragraph: PDFParagraph, caret: Int) {
            self.block = block
            self.paragraph = paragraph
            selection = caret..<caret
            anchor = caret
            preview = PDFParagraph.Preview(cover: [], page: nil, document: nil, fallback: [])
        }
    }

    private var session: Session?
    /// A paragraph just written: still drawn over the page until the page shows it.
    private var settling: (page: Int, preview: PDFParagraph.Preview, until: Date)?
    private var caretOn = true
    private var blink: Timer?

    /// Writes the new file data with page `page` changed (one undo step); true when it worked.
    var commit: (_ data: Data, _ page: Int, _ actionName: String) -> Bool = { _, _, _ in false }
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
    override var acceptsFirstResponder: Bool { session != nil }

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

    /// The file changed as a whole (an undo, annotations saved, another app): its blocks are read again.
    func reload() {
        session = nil
        stopBlinking()
        generation += 1
        editor = nil
        blocks = [:]
        loading = []
        hovered = nil
        attach()
        needsDisplay = true
        loadVisiblePages()
    }

    /// Page `page` of the file changed (an edit written, or taken back): it is read again; the other pages' blocks stay.
    func pageChanged(_ page: Int) {
        if session?.block.page == page { session = nil; stopBlinking() }
        generation += 1
        editor = nil
        blocks[page] = nil
        loading = []
        hovered = nil
        needsDisplay = true
        loadVisiblePages(force: true)
    }

    /// For the self-test: what the layer knows.
    var stateDescription: String {
        "pages visible \(visiblePages), blocks \(blocks.mapValues(\.count)), loading \(loading), editor \(editor != nil), editing \(session != nil), superview \(superview.map { String(describing: type(of: $0)) } ?? "nil")"
    }

    var isEditingBlock: Bool { session != nil }

    /// Keeps the paragraph being edited (written into the file when it changed) and leaves it.
    func finish() {
        endSession()
    }

    // MARK: Blocks

    private var visiblePages: [Int] {
        guard let pdfView, let document = pdfView.document else { return [] }
        let visible = pdfView.visiblePages.compactMap { document.index(for: $0) }
        // Right after the document is set PDFView may not know yet what it shows: the current page stands in.
        if visible.isEmpty, let page = pdfView.currentPage ?? document.page(at: 0) { return [document.index(for: page)] }
        return visible
    }

    private func loadVisiblePages(force: Bool = false) {
        let wanted = visiblePages.filter { blocks[$0] == nil && !loading.contains($0) }
        guard !wanted.isEmpty || (force && editor == nil), let data = data() else { return }
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
                if let click = self.pendingClick, self.blocks[click.page] != nil {
                    self.pendingClick = nil
                    self.click(at: click.point, count: 1, extend: false)
                }
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
    }

    // MARK: Geometry

    /// Page space of page `index` → this view.
    private func transform(page index: Int) -> CGAffineTransform? {
        guard let pdfView, let page = pdfView.document?.page(at: index) else { return nil }
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { convert(pdfView.convert(CGPoint(x: x, y: y), from: page), from: pdfView) }
        let o = point(0, 0), ex = point(100, 0), ey = point(0, 100)
        return CGAffineTransform(a: (ex.x - o.x) / 100, b: (ex.y - o.y) / 100, c: (ey.x - o.x) / 100, d: (ey.y - o.y) / 100, tx: o.x, ty: o.y)
    }

    private func rect(page index: Int, rect: CGRect) -> NSRect? {
        transform(page: index).map { rect.applying($0).standardized }
    }

    /// The block's rectangle in this view, with a little room around the text.
    private func rect(of block: PDFTextBlock) -> NSRect? {
        guard let r = rect(page: block.page, rect: block.rect) else { return nil }
        let pad = max(2, 2.5 * (pdfView?.scaleFactor ?? 1))
        return r.insetBy(dx: -pad, dy: -pad * 0.6)
    }

    private func page(at point: NSPoint) -> Int? {
        guard let pdfView, let document = pdfView.document,
              let page = pdfView.page(for: convert(point, to: pdfView), nearest: true) else { return nil }
        return document.index(for: page)
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

    /// Only the paragraphs (and, while one is edited, everything: a click elsewhere keeps it) take the mouse; the
    /// margins and figures stay PDFView's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        if session != nil { return self }
        return block(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func resetCursorRects() {
        for page in visiblePages {
            for block in blocks[page] ?? [] where !block.text.isEmpty {
                guard let rect = rect(of: block) else { continue }
                addCursorRect(rect, cursor: block.isEditable ? .iBeam : .arrow)
            }
        }
        if let session, let rect = rect(page: session.block.page, rect: session.paragraph.bounds) {
            addCursorRect(rect.insetBy(dx: -4, dy: -4), cursor: .iBeam)
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
        let hit = block(at: point)
        if hit != hovered {
            hovered = hit
            needsDisplay = true
        }
        cursor(at: point).set()
    }

    private func cursor(at point: NSPoint) -> NSCursor {
        if let session, let rect = rect(page: session.block.page, rect: session.paragraph.bounds), rect.insetBy(dx: -4, dy: -4).contains(point) {
            return .iBeam
        }
        guard let hit = block(at: point) else { return .arrow }
        return hit.isEditable ? .iBeam : .arrow
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func cursorUpdate(with event: NSEvent) { cursor(at: convert(event.locationInWindow, from: nil)).set() }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        click(at: point, count: event.clickCount, extend: event.modifierFlags.contains(.shift))
    }

    /// A click: in the paragraph being edited, the caret (a word, the paragraph); elsewhere that paragraph is kept and
    /// the one clicked is opened, with the caret where the click was.
    private func click(at point: NSPoint, count: Int, extend: Bool) {
        if let session, let index = index(at: point, in: session, strict: true) {
            switch count {
            case 2: select(wordAround(index, in: session), in: session)
            case 3...: select(0..<session.paragraph.count, in: session)
            default:
                if extend { extendSelection(to: index, in: session) } else { place(index, in: session) }
            }
            return
        }
        if session != nil { endSession() }
        guard let hit = block(at: point) else {
            window?.makeFirstResponder(pdfView)
            return
        }
        guard hit.isEditable else {
            NSSound.beep()
            showMessage(String(localized: "这里不能编辑：\(hit.reason ?? "")"))
            return
        }
        guard let editor else {
            // The file is being read again after an edit: the click waits for it.
            pendingClick = (point, hit.page)
            return
        }
        guard let paragraph = editor.paragraph(page: hit.page, block: hit.index) else {
            NSSound.beep()
            showMessage(String(localized: "这里不能编辑：这段文字的排版无法原样修改"))
            return
        }
        let session = Session(block: hit, paragraph: paragraph, caret: 0)
        self.session = session
        hovered = nil
        window?.makeFirstResponder(self)
        let caret = index(at: point, in: session, strict: false) ?? paragraph.count
        switch count {
        case 2: select(wordAround(caret, in: session), in: session)
        case 3...: select(0..<paragraph.count, in: session)
        default: place(caret, in: session)
        }
        startBlinking()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session else { return }
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        if let index = index(at: point, in: session, strict: false) { extendSelection(to: index, in: session) }
    }

    override func mouseUp(with event: NSEvent) {}

    // Scrolling and zooming are the scroll view's, as everywhere else on the pages.
    override func scrollWheel(with event: NSEvent) { enclosingScrollView?.scrollWheel(with: event) ?? super.scrollWheel(with: event) }

    // MARK: Caret and selection

    /// The caret position nearest `point` (nil, when `strict`, outside the paragraph).
    private func index(at point: NSPoint, in session: Session, strict: Bool) -> Int? {
        guard let t = transform(page: session.block.page) else { return nil }
        if strict, let r = rect(page: session.block.page, rect: session.paragraph.bounds), !r.insetBy(dx: -6, dy: -4).contains(point) { return nil }
        let p = point.applying(t.inverted())
        let lines = session.paragraph.shownLines
        guard let line = lines.min(by: { distance(p.y, $0) < distance(p.y, $1) }) else { return nil }
        return nearestStop(to: p.x, in: line, session)
    }

    private func distance(_ y: Double, _ line: PDFParagraph.ShownLine) -> Double {
        y > line.top ? y - line.top : (y < line.bottom ? line.bottom - y : 0)
    }

    private func nearestStop(to x: Double, in line: PDFParagraph.ShownLine, _ session: Session) -> Int? {
        line.stops.filter { session.paragraph.isStop($0.index) }.min { abs($0.x - x) < abs($1.x - x) }?.index
    }

    /// The line showing caret position `index` and its x there (a position at a line break goes with the next line).
    private func caretPlace(_ index: Int, in session: Session) -> (line: Int, x: Double)? {
        let lines = session.paragraph.shownLines
        var found: (Int, Double)?
        for (li, line) in lines.enumerated() {
            if let stop = line.stops.first(where: { $0.index == index }) {
                found = (li, stop.x)
                // At the end of a line that the next line goes on from: the next line's start.
                if line.stops.last?.index != index || li == lines.count - 1 { return found }
            }
        }
        if let found { return found }
        // Not a stop of its own (inside a line end): the nearest stop after it.
        for (li, line) in lines.enumerated() {
            if let stop = line.stops.first(where: { $0.index >= index }) { return (li, stop.x) }
        }
        return lines.last.flatMap { line in line.stops.last.map { (lines.count - 1, $0.x) } }
    }

    private func place(_ index: Int, in session: Session, keepGoal: Bool = false) {
        let index = min(max(index, 0), session.paragraph.count)
        session.selection = index..<index
        session.anchor = index
        if !keepGoal { session.goalX = nil }
        session.lastEdit = nil
        changed(session, text: false)
    }

    private func select(_ range: Range<Int>, in session: Session) {
        session.selection = range.clamped(to: 0..<session.paragraph.count)
        session.anchor = session.selection.lowerBound
        session.goalX = nil
        changed(session, text: false)
    }

    private func extendSelection(to index: Int, in session: Session, keepGoal: Bool = false) {
        let index = min(max(index, 0), session.paragraph.count)
        session.selection = min(index, session.anchor)..<max(index, session.anchor)
        if !keepGoal { session.goalX = nil }
        changed(session, text: false)
    }

    /// The moving end of the selection.
    private func head(_ session: Session) -> Int {
        session.selection.lowerBound == session.anchor ? session.selection.upperBound : session.selection.lowerBound
    }

    private func text(_ index: Int, _ session: Session) -> String {
        index >= 0 && index < session.paragraph.count ? session.paragraph.string(index..<index + 1) : ""
    }

    private func isWordCharacter(_ index: Int, _ session: Session) -> Bool {
        let t = text(index, session)
        guard let c = t.first else { return false }
        return c.isLetter || c.isNumber || t.count > 1   // a formula is a word
    }

    private func wordAround(_ index: Int, in session: Session) -> Range<Int> {
        var lower = index, upper = index
        if !isWordCharacter(index, session), index > 0, isWordCharacter(index - 1, session) { lower = index - 1; upper = index - 1 }
        guard isWordCharacter(lower, session) else { return index..<min(index + 1, session.paragraph.count) }
        while lower > 0, isWordCharacter(lower - 1, session) { lower -= 1 }
        while upper < session.paragraph.count, isWordCharacter(upper, session) { upper += 1 }
        return lower..<upper
    }

    private func wordStep(from index: Int, forward: Bool, in session: Session) -> Int {
        var i = index
        let count = session.paragraph.count
        if forward {
            while i < count, !isWordCharacter(i, session) { i += 1 }
            while i < count, isWordCharacter(i, session) { i += 1 }
        } else {
            while i > 0, !isWordCharacter(i - 1, session) { i -= 1 }
            while i > 0, isWordCharacter(i - 1, session) { i -= 1 }
        }
        return i
    }

    private func charStep(from index: Int, forward: Bool, in session: Session) -> Int {
        var i = index
        repeat { i += forward ? 1 : -1 } while i > 0 && i < session.paragraph.count && !session.paragraph.isStop(i)
        return min(max(i, 0), session.paragraph.count)
    }

    private func lineStep(from index: Int, by step: Int, in session: Session) -> Int {
        let lines = session.paragraph.shownLines
        guard let place = caretPlace(index, in: session) else { return index }
        let goal = session.goalX ?? place.x
        session.goalX = goal
        let target = place.line + step
        if target < 0 { return 0 }
        if target >= lines.count { return session.paragraph.count }
        return nearestStop(to: goal, in: lines[target], session) ?? index
    }

    private func lineEdge(of index: Int, end: Bool, in session: Session) -> Int {
        let lines = session.paragraph.shownLines
        guard let place = caretPlace(index, in: session) else { return index }
        let stops = lines[place.line].stops.filter { session.paragraph.isStop($0.index) }
        guard let stop = end ? stops.last : stops.first else { return index }
        // The end of a line that goes on: before the space it breaks at.
        if end, place.line < lines.count - 1, stops.count > 1, text(stop.index - 1, session).allSatisfy(\.isWhitespace) { return stops[stops.count - 2].index }
        return stop.index
    }

    // MARK: Editing

    /// Replaces the selection (or `range`) with `text`; the caret after it.
    private func replace(_ range: Range<Int>? = nil, with text: String, in session: Session, kind: Int) {
        let range = range ?? session.selection
        // One undo step for a run of typing (or of deleting), a new one after a pause, a move or another kind of edit.
        let now = Date()
        if let last = session.lastEdit, last.kind == kind, now.timeIntervalSince(last.at) < 1.5 {} else {
            session.undo.append((session.paragraph.snapshot, session.selection))
            session.redo = []
        }
        session.lastEdit = (kind, now)
        session.paragraph.replace(range, with: text)
        let inserted = text.filter { $0 != "\n" && $0 != "\r" }.count
        let caret = range.lowerBound + inserted
        session.selection = caret..<caret
        session.anchor = caret
        session.goalX = nil
        changed(session, text: true)
    }

    private func changed(_ session: Session, text: Bool) {
        if text { session.preview = session.paragraph.preview() }
        caretOn = true
        startBlinking()
        needsDisplay = true
        if text { window?.invalidateCursorRects(for: self) }
        inputContext?.invalidateCharacterCoordinates()
    }

    /// Keeps the paragraph: written into the file when it changed, and drawn over the page until the page shows it.
    private func endSession() {
        guard let session else { return }
        self.session = nil
        stopBlinking()
        if window?.firstResponder === self { window?.makeFirstResponder(pdfView) }
        inputContext?.discardMarkedText()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        guard session.paragraph.isModified, let editor else { return }
        let data: Data
        do {
            data = try editor.apply(session.paragraph)
        } catch {
            showMessage(String(localized: "无法修改这段文字：\(error.localizedDescription)"))
            return
        }
        if session.paragraph.overflows {
            showMessage(String(localized: "这段文字比原来长，已超出原有的位置"))
        }
        let page = session.block.page
        settling = (page, session.preview, Date().addingTimeInterval(0.6))
        if commit(data, page, String(localized: "编辑文字")) {
            pageChanged(page)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
            guard let self, let settling = self.settling, Date() >= settling.until else { return }
            self.settling = nil
            self.needsDisplay = true
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard session != nil else { return super.keyDown(with: event) }
        caretOn = true
        if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
    }

    override func doCommand(by selector: Selector) {
        guard let session else { return }
        let h = head(session)
        let collapsed = session.selection.isEmpty
        switch NSStringFromSelector(selector) {
        case "moveLeft:": place(collapsed ? charStep(from: h, forward: false, in: session) : session.selection.lowerBound, in: session)
        case "moveRight:": place(collapsed ? charStep(from: h, forward: true, in: session) : session.selection.upperBound, in: session)
        case "moveLeftAndModifySelection:": extendSelection(to: charStep(from: h, forward: false, in: session), in: session)
        case "moveRightAndModifySelection:": extendSelection(to: charStep(from: h, forward: true, in: session), in: session)
        case "moveWordLeft:", "moveWordBackward:": place(wordStep(from: h, forward: false, in: session), in: session)
        case "moveWordRight:", "moveWordForward:": place(wordStep(from: h, forward: true, in: session), in: session)
        case "moveWordLeftAndModifySelection:", "moveWordBackwardAndModifySelection:": extendSelection(to: wordStep(from: h, forward: false, in: session), in: session)
        case "moveWordRightAndModifySelection:", "moveWordForwardAndModifySelection:": extendSelection(to: wordStep(from: h, forward: true, in: session), in: session)
        case "moveUp:": place(lineStep(from: h, by: -1, in: session), in: session, keepGoal: true)
        case "moveDown:": place(lineStep(from: h, by: 1, in: session), in: session, keepGoal: true)
        case "moveUpAndModifySelection:": extendSelection(to: lineStep(from: h, by: -1, in: session), in: session, keepGoal: true)
        case "moveDownAndModifySelection:": extendSelection(to: lineStep(from: h, by: 1, in: session), in: session, keepGoal: true)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:": place(lineEdge(of: h, end: false, in: session), in: session)
        case "moveToEndOfLine:", "moveToRightEndOfLine:": place(lineEdge(of: h, end: true, in: session), in: session)
        case "moveToBeginningOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:":
            extendSelection(to: lineEdge(of: h, end: false, in: session), in: session)
        case "moveToEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:":
            extendSelection(to: lineEdge(of: h, end: true, in: session), in: session)
        case "moveToBeginningOfDocument:", "moveToBeginningOfParagraph:", "scrollToBeginningOfDocument:": place(0, in: session)
        case "moveToEndOfDocument:", "moveToEndOfParagraph:", "scrollToEndOfDocument:": place(session.paragraph.count, in: session)
        case "moveToBeginningOfDocumentAndModifySelection:", "moveParagraphBackwardAndModifySelection:": extendSelection(to: 0, in: session)
        case "moveToEndOfDocumentAndModifySelection:", "moveParagraphForwardAndModifySelection:": extendSelection(to: session.paragraph.count, in: session)
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:":
            if collapsed {
                guard h > 0 else { return }
                replace(charStep(from: h, forward: false, in: session)..<h, with: "", in: session, kind: 1)
            } else {
                replace(with: "", in: session, kind: 1)
            }
        case "deleteForward:":
            if collapsed {
                guard h < session.paragraph.count else { return }
                replace(h..<charStep(from: h, forward: true, in: session), with: "", in: session, kind: 2)
            } else {
                replace(with: "", in: session, kind: 2)
            }
        case "deleteWordBackward:":
            if collapsed { replace(wordStep(from: h, forward: false, in: session)..<h, with: "", in: session, kind: 3) } else { replace(with: "", in: session, kind: 3) }
        case "deleteWordForward:":
            if collapsed { replace(h..<wordStep(from: h, forward: true, in: session), with: "", in: session, kind: 3) } else { replace(with: "", in: session, kind: 3) }
        case "deleteToBeginningOfLine:":
            if collapsed { replace(lineEdge(of: h, end: false, in: session)..<h, with: "", in: session, kind: 3) } else { replace(with: "", in: session, kind: 3) }
        case "selectAll:": select(0..<session.paragraph.count, in: session)
        case "insertTab:": replace(with: " ", in: session, kind: 0)
        // Return, Esc: the paragraph is kept as it is now.
        case "insertNewline:", "insertLineBreak:", "insertNewlineIgnoringFieldEditor:", "cancelOperation:": endSession()
        default: NSSound.beep()
        }
    }

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) {
        guard let session, !session.selection.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.paragraph.string(session.selection), forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        guard let session, !session.selection.isEmpty else { return }
        copy(sender)
        replace(with: "", in: session, kind: 4)
    }

    @objc func paste(_ sender: Any?) {
        guard let session, let text = NSPasteboard.general.string(forType: .string) else { return }
        // One paragraph: line breaks become spaces.
        let flat = text.replacingOccurrences(of: #"\s*[\r\n]+\s*"#, with: " ", options: .regularExpression)
        replace(with: flat, in: session, kind: 5)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let session else { return }
        select(0..<session.paragraph.count, in: session)
    }

    /// ⌘Z while typing undoes the typing; with nothing typed, the paragraph is left and the window's undo (the edits
    /// written before) goes on.
    @objc func undo(_ sender: Any?) {
        guard let session else { return }
        guard let step = session.undo.popLast() else {
            endSession()
            window?.undoManager?.undo()
            return
        }
        session.redo.append((session.paragraph.snapshot, session.selection))
        session.paragraph.snapshot = step.state
        session.selection = step.selection.clamped(to: 0..<session.paragraph.count)
        session.anchor = session.selection.lowerBound
        session.lastEdit = nil
        changed(session, text: true)
    }

    @objc func redo(_ sender: Any?) {
        guard let session, let step = session.redo.popLast() else { return }
        session.undo.append((session.paragraph.snapshot, session.selection))
        session.paragraph.snapshot = step.state
        session.selection = step.selection.clamped(to: 0..<session.paragraph.count)
        session.anchor = session.selection.lowerBound
        session.lastEdit = nil
        changed(session, text: true)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let session else { return false }
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): return !session.selection.isEmpty
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        case #selector(undo(_:)):
            item.title = String(localized: "撤销键入")
            return !session.undo.isEmpty || window?.undoManager?.canUndo == true
        case #selector(redo(_:)): return !session.redo.isEmpty
        case #selector(selectAll(_:)): return true
        default: return true
        }
    }

    // MARK: NSTextInputClient (typing, the input method's marked text)

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let session else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let range = session.marked ?? session.selection
        session.marked = nil
        replace(range, with: text, in: session, kind: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let session else { return }
        let text = ((string as? NSAttributedString)?.string ?? (string as? String) ?? "").filter { $0 != "\n" && $0 != "\r" }
        let range = session.marked ?? session.selection
        if session.lastEdit?.kind != 0 || session.marked == nil && session.undo.isEmpty {
            session.undo.append((session.paragraph.snapshot, session.selection))
            session.redo = []
        }
        session.lastEdit = (0, Date())
        session.paragraph.replace(range, with: text)
        let count = text.count
        session.marked = count > 0 ? range.lowerBound..<range.lowerBound + count : nil
        let caret = range.lowerBound + min(max(selectedRange.location, 0), count)
        session.selection = caret..<caret
        session.anchor = caret
        changed(session, text: true)
    }

    func unmarkText() {
        session?.marked = nil
        needsDisplay = true
    }

    func selectedRange() -> NSRange {
        guard let session else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: session.selection.lowerBound, length: session.selection.count)
    }

    func markedRange() -> NSRange {
        guard let marked = session?.marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: marked.lowerBound, length: marked.count)
    }

    func hasMarkedText() -> Bool { session?.marked != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let session, range.location != NSNotFound else { return nil }
        let r = (range.location..<range.location + range.length).clamped(to: 0..<session.paragraph.count)
        actualRange?.pointee = NSRange(location: r.lowerBound, length: r.count)
        return NSAttributedString(string: session.paragraph.string(r))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let session, let window, let t = transform(page: session.block.page) else { return .zero }
        let index = range.location == NSNotFound ? head(session) : min(range.location, session.paragraph.count)
        let lines = session.paragraph.shownLines
        guard let place = caretPlace(index, in: session) else { return .zero }
        let line = lines[place.line]
        let r = CGRect(x: place.x, y: line.bottom, width: 1, height: line.top - line.bottom).applying(t).standardized
        return window.convertToScreen(convert(r, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let session, let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        return index(at: local, in: session, strict: false) ?? NSNotFound
    }

    // MARK: Drawing

    private func startBlinking() {
        blink?.invalidate()
        caretOn = true
        blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session, session.selection.isEmpty else { return }
                self.caretOn.toggle()
                if let r = self.caretRect(session) { self.setNeedsDisplay(r.insetBy(dx: -2, dy: -2)) }
            }
        }
    }

    private func stopBlinking() {
        blink?.invalidate()
        blink = nil
    }

    private func caretRect(_ session: Session) -> NSRect? {
        guard let t = transform(page: session.block.page), let place = caretPlace(head(session), in: session) else { return nil }
        let line = session.paragraph.shownLines[place.line]
        let r = CGRect(x: place.x, y: line.bottom, width: 0, height: line.top - line.bottom).applying(t).standardized
        let width = max(1.5, min(2, (pdfView?.scaleFactor ?? 1) * 0.9))
        return NSRect(x: (r.minX - width / 2).rounded(.down), y: r.minY, width: width, height: r.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor

        // A paragraph just written, until the page shows it.
        if let settling, Date() < settling.until, let t = transform(page: settling.page) {
            draw(settling.preview, with: t, in: context)
        }

        // The paragraph under the pointer: a faint outline (one that can't be edited, dashed).
        if let hovered, hovered != session?.block, let rect = rect(of: hovered) {
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = 1
            if hovered.isEditable {
                accent.withAlphaComponent(0.45).setStroke()
            } else {
                NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
                path.setLineDash([3, 3], count: 2, phase: 0)
            }
            path.stroke()
        }

        guard let session, let t = transform(page: session.block.page) else { return }
        // The text as it is now, over the page: white where lines went, the lines drawn with the page's glyphs.
        draw(session.preview, with: t, in: context)

        // The paragraph being edited: a quiet frame.
        if let bounds = rect(page: session.block.page, rect: session.paragraph.bounds) {
            let pad = max(2, 2.5 * (pdfView?.scaleFactor ?? 1))
            let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: -pad, dy: -pad * 0.6), xRadius: 3, yRadius: 3)
            frame.lineWidth = 1
            (session.paragraph.overflows ? NSColor.systemOrange : accent).withAlphaComponent(0.55).setStroke()
            frame.stroke()
        }

        // Selection.
        let lines = session.paragraph.shownLines
        if !session.selection.isEmpty {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55).setFill()
            for line in lines {
                guard let first = line.stops.first?.index, let last = line.stops.last?.index else { continue }
                let lower = max(session.selection.lowerBound, first), upper = min(session.selection.upperBound, last)
                guard lower < upper else { continue }
                let x0 = line.stops.first { $0.index >= lower }?.x ?? line.stops.first!.x
                let x1 = line.stops.first { $0.index >= upper }?.x ?? line.stops.last!.x
                let r = CGRect(x: x0, y: line.bottom, width: max(x1 - x0, 0), height: line.top - line.bottom).applying(t).standardized
                NSBezierPath(rect: r).fill()
            }
        }
        // The input method's marked text: underlined.
        if let marked = session.marked {
            accent.setFill()
            for line in lines {
                guard let first = line.stops.first?.index, let last = line.stops.last?.index else { continue }
                let lower = max(marked.lowerBound, first), upper = min(marked.upperBound, last)
                guard lower < upper else { continue }
                let x0 = line.stops.first { $0.index >= lower }?.x ?? line.stops.first!.x
                let x1 = line.stops.first { $0.index >= upper }?.x ?? line.stops.last!.x
                let y = line.baseline - (line.baseline - line.bottom) * 0.6
                let a = CGPoint(x: x0, y: y).applying(t), b = CGPoint(x: x1, y: y).applying(t)
                NSBezierPath(rect: NSRect(x: min(a.x, b.x), y: a.y - 0.75, width: abs(b.x - a.x), height: 1.5)).fill()
            }
        }
        // Caret.
        if session.selection.isEmpty, caretOn, let caret = caretRect(session) {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(rect: caret).fill()
        }
    }

    /// The paragraph's lines as they are now, in page space: white over the page's lines drawn again, the glyphs in
    /// their new places, characters no font of the page has in a system font.
    private func draw(_ preview: PDFParagraph.Preview, with t: CGAffineTransform, in context: CGContext) {
        guard !preview.cover.isEmpty || preview.page != nil || !preview.fallback.isEmpty else { return }
        context.saveGState()
        context.concatenate(t)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for r in preview.cover { context.fill(r) }
        if let page = preview.page { context.drawPDFPage(page) }
        context.textMatrix = .identity
        for run in preview.fallback {
            let attributed = NSAttributedString(string: run.text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: run.font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: run.color,
            ])
            context.textPosition = run.origin
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.restoreGState()
    }

    // MARK: Self-test

    /// Opens block `block` of page `page` with the caret at the end of `after` (its first occurrence), as a click there
    /// would; false when that can't be done.
    func selfTestOpen(page: Int, block index: Int, caretAfter after: String) -> Bool {
        guard let editor, let block = blocks[page]?.first(where: { $0.index == index }), let paragraph = editor.paragraph(page: page, block: index),
              let range = paragraph.range(of: after) else { return false }
        if session != nil { endSession() }
        let session = Session(block: block, paragraph: paragraph, caret: range.upperBound)
        self.session = session
        window?.makeFirstResponder(self)
        place(range.upperBound, in: session)
        return true
    }

    var selfTestEditable: [PDFTextBlock] { visiblePages.flatMap { blocks[$0] ?? [] }.filter { $0.isEditable && $0.text.count > 120 } }
    var selfTestText: String? { session?.paragraph.string }
    var selfTestRewritten: [Int] { session?.paragraph.rewrittenLines ?? [] }
}
