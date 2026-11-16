import AppKit
import FolioCore
import PDFKit

/// Pages that outline the selected annotation. PDFKit creates them through
/// `PDFDocumentDelegate.classForPage()` (the reader window controller).
/// PDFKit may draw pages off the main thread, so the class opts out of the app's MainActor default.
nonisolated final class ReaderPage: PDFPage {
    nonisolated(unsafe) weak var selectedAnnotation: PDFAnnotation?

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard let annotation = selectedAnnotation, annotation.page === self else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(annotation.bounds.insetBy(dx: -3, dy: -3))
        context.restoreGState()
    }
}


/// Draws the stroke being drawn with the ink tool, in view coordinates.
private final class InkOverlayView: NSView {
    var path: NSBezierPath? { didSet { needsDisplay = true } }
    var color = NSColor.systemRed
    var width: CGFloat = 2

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let path else { return }
        color.setStroke()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

/// PDFView with the reader's annotation tools (READER-04): markup from text selections, placing notes
/// and text boxes, ink, and selecting / moving / deleting existing annotations.
final class ReaderPDFView: PDFView {
    weak var editor: AnnotationEditor?
    var tool = AnnotationTool.select {
        didSet {
            if tool != .select { selectAnnotation(nil) }
            window?.invalidateCursorRects(for: self)
        }
    }
    var inkColor = NSColor.systemRed { didSet { if inkColor != oldValue { window?.invalidateCursorRects(for: self) } } }
    /// The pen's width in points (手绘 ▸ 粗细).
    var inkWidth: CGFloat = 2 { didSet { if inkWidth != oldValue { window?.invalidateCursorRects(for: self) } } }
    /// The note tool's colour: its pointer is a little note in it.
    var noteColor = NSColor.systemYellow { didSet { if noteColor != oldValue { window?.invalidateCursorRects(for: self) } } }
    /// Resting the pointer on a note or a commented annotation shows what it says (设置 ▸ 阅读).
    var showsTooltips = true
    /// The eraser's size (READER-30); the pointer is a ring this large at the current zoom.
    var eraserSize = InkEraser.Size.medium {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    /// The eraser's size menu (right-click while erasing) and stepping through the sizes with [ and ].
    var eraserSizeMenu: () -> NSMenu? = { nil }
    var onEraserSizeStep: (Int) -> Void = { _ in }
    /// 编辑 PDF 文字's layer while it is on: the pointer is its, not PDFKit's (cursor, hover, clicks on the margins).
    weak var editLayer: PDFTextEditMode?
    /// Esc while editing the text (no paragraph open): leave 编辑 PDF 文字.
    var onLeaveEditing: () -> Void = {}
    /// The mouse went down on the page / was released over a text selection made with the select tool (划词翻译).
    var onMouseDown: () -> Void = {}
    var onSelectionFinished: () -> Void = {}

    private(set) var selectedAnnotation: PDFAnnotation?
    private let inkOverlay = InkOverlayView()
    private var inkPoints: [NSPoint] = []
    private var inkPage: PDFPage?
    private var drag: (annotation: PDFAnnotation, page: PDFPage, start: NSPoint, original: NSRect, moved: Bool, opensCard: Bool)?
    private var erasing: InkEraseSession?

    /// Annotation kinds the reader edits; links, widgets and popups are left to PDFKit.
    static let editableTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "FreeText",
                                             "Ink", "Square", "Circle", "Line"]
    /// Kinds that can be dragged to a new place.
    static let movableTypes: Set<String> = ["Text", "FreeText", "Ink", "Square", "Circle", "Line"]

    /// The reader's own sharp drawing of notes, text boxes and ink over each page.
    let overlays = AnnotationOverlays()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        pageOverlayViewProvider = overlays
        inkOverlay.frame = bounds
        inkOverlay.autoresizingMask = [.width, .height]
        addSubview(inkOverlay)
        // The eraser's ring follows the zoom.
        NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // The annotations are drawn again for the new zoom; the eraser's ring and the pen's dot follow it.
                guard let self else { return }
                self.overlays.refreshAll()
                guard self.tool == .eraser || self.tool == .ink else { return }
                self.window?.invalidateCursorRects(for: self)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var acceptsFirstResponder: Bool { true }

    /// Every change to a page's annotations comes through here (the editor, drags, the eraser): the overlay follows.
    override func annotationsChanged(on page: PDFPage) {
        super.annotationsChanged(on: page)
        overlays.refresh(page)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        overlays.refreshAll()
    }

    // MARK: Selection of annotations

    func selectAnnotation(_ annotation: PDFAnnotation?) {
        let previous = selectedAnnotation
        selectedAnnotation = annotation
        for page in [previous?.page, annotation?.page].compactMap({ $0 }) {
            (page as? ReaderPage)?.selectedAnnotation = annotation?.page === page ? annotation : nil
            annotationsChanged(on: page)
        }
    }

    /// Whether `point` (page space) is on one of the ink's strokes, give or take a few points.
    static func isNear(_ point: NSPoint, ink: PDFAnnotation) -> Bool {
        let reach = (ink.border?.lineWidth ?? 1) / 2 + 4
        let strokes = InkEraseSession.strokes(of: ink)
        for stroke in strokes {
            if stroke.count == 1, hypot(stroke[0].x - point.x, stroke[0].y - point.y) <= reach { return true }
            for (a, b) in zip(stroke, stroke.dropFirst()) {
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
                if hypot(a.x + t * dx - point.x, a.y + t * dy - point.y) <= reach { return true }
            }
        }
        return false
    }

    private func editableAnnotation(at point: NSPoint, on page: PDFPage) -> PDFAnnotation? {
        // Topmost first; small hit slop so thin underlines are still easy to click.
        page.annotations.reversed().first { annotation in
            guard let type = annotation.type, Self.editableTypes.contains(type) else { return false }
            guard annotation.bounds.insetBy(dx: -3, dy: -3).contains(point) else { return false }
            // A pen stroke is hit on its line, not anywhere in the box around it (a loop's box can cover half a column).
            if type == "Ink" { return Self.isNear(point, ink: annotation) }
            return true
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // While editing the text, a click outside the paragraphs does nothing (no selection, no annotation).
        if let editLayer {
            editLayer.window?.makeFirstResponder(self)
            if editLayer.isEditingBlock { editLayer.finish() }
            return
        }
        // A text box being written ends with a click elsewhere.
        if editor?.isWritingTextBox == true {
            editor?.finishTextBox()
            if tool == .select { return }
        }
        window?.makeFirstResponder(self)
        onMouseDown()
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true) else { return super.mouseDown(with: event) }
        let pagePoint = convert(point, to: page)
        switch tool {
        case .note, .text:
            // On a note (or a text box) of its own kind, the tool opens it rather than adding another.
            if let hit = editableAnnotation(at: pagePoint, on: page), hit.type == (tool == .note ? "Text" : "FreeText") {
                selectAnnotation(hit)
                if editor?.cardWasClosed(for: hit, by: event) != true { editor?.edit(hit) }
                return
            }
            editor?.place(tool, at: pagePoint, on: page)
        case .ink:
            inkPage = page
            inkPoints = [pagePoint]
            inkOverlay.color = inkColor
            inkOverlay.width = inkWidth * scaleFactor
            inkOverlay.path = nil
        case .eraser:
            beginErasing(at: pagePoint, on: page)
        case .select:
            if let hit = editableAnnotation(at: pagePoint, on: page) {
                selectAnnotation(hit)
                if event.clickCount == 2, hit.type == "FreeText" {
                    editor?.edit(hit)
                } else if let type = hit.type, Self.movableTypes.contains(type) {
                    // A note opens with one click (when it was not dragged); it can still be dragged.
                    let opens = type == "Text" && editor?.cardWasClosed(for: hit, by: event) != true
                    drag = (hit, page, pagePoint, hit.bounds, false, opens)
                }
                return
            }
            selectAnnotation(nil)
            super.mouseDown(with: event)
        case .highlight, .underline, .strikeOut:
            selectAnnotation(nil)
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if erasing != nil {
            eraserCursor.set()
            if let page = page(for: point, nearest: true) { continueErasing(to: convert(point, to: page), on: page) }
            return
        }
        if tool == .ink, let page = inkPage {
            inkPoints.append(convert(point, to: page))
            let path = NSBezierPath()
            for (index, pagePoint) in inkPoints.enumerated() {
                let viewPoint = convert(pagePoint, from: page)
                if index == 0 { path.move(to: viewPoint) } else { path.line(to: viewPoint) }
            }
            inkOverlay.path = path
            return
        }
        if var current = drag {
            let pagePoint = convert(point, to: current.page)
            let dx = pagePoint.x - current.start.x, dy = pagePoint.y - current.start.y
            current.annotation.bounds = current.original.offsetBy(dx: dx, dy: dy)
            current.moved = current.moved || abs(dx) + abs(dy) > 1
            drag = current
            annotationsChanged(on: current.page)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if erasing != nil {
            endErasing()
            return
        }
        if tool == .ink, let page = inkPage {
            inkOverlay.path = nil
            if inkPoints.count > 1 { editor?.addInk(points: inkPoints, on: page) }
            inkPoints = []
            inkPage = nil
            return
        }
        if let current = drag {
            drag = nil
            if current.moved { editor?.didMove(current.annotation, from: current.original) }
            else if current.opensCard { editor?.edit(current.annotation) }
            return
        }
        super.mouseUp(with: event)
        if let type = tool.markupType, let selection = currentSelection, !(selection.string ?? "").isEmpty {
            editor?.addMarkup(type, for: selection)
            clearSelection()
        } else if tool == .select, !(currentSelection?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onSelectionFinished()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // Not under the panels over the page (a text box being written, a note's card): they have pointers of their own,
        // and two pointers for one place flicker between them.
        let free = floatingPanels.reduce([visibleRect]) { rects, panel in rects.flatMap { $0.subtracting(panel.frame) } }
        if let cursor = toolCursor { free.forEach { addCursorRect($0, cursor: cursor) } }
        if tool == .eraser { free.forEach { addCursorRect($0, cursor: eraserCursor) } }
    }

    /// The panels over the page: a text box being written and its bar, a note's card.
    private var floatingPanels: [NSView] { subviews.filter { $0 is ReaderFloatingPanel && !$0.isHidden } }

    /// The pointer is over one of them: they answer it.
    private func isOverFloatingPanel(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        return floatingPanels.contains { $0.frame.contains(point) }
    }

    /// While editing the text, the layer over the pages answers first: PDFKit adds its page views over it as they come
    /// into view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let editLayer, let documentView = editLayer.superview, let superview,
           bounds.contains(convert(point, from: superview)),
           let hit = editLayer.hitTest(documentView.convert(point, from: superview)) {
            return hit
        }
        return super.hitTest(point)
    }

    override func mouseMoved(with event: NSEvent) {
        if let editLayer {
            editLayer.pointerMoved(event)
            return
        }
        if isOverFloatingPanel(event) { return }
        super.mouseMoved(with: event)
        updateTooltip(for: event)
        // PDFView resets the cursor while tracking; keep the tool cursor.
        toolCursor?.set()
        if tool == .eraser { eraserCursor.set() }
    }

    /// What a note or a commented annotation says, shown as the view's tooltip while the pointer rests on it.
    private func updateTooltip(for event: NSEvent) {
        guard showsTooltips, tool == .select else { if toolTip != nil { toolTip = nil }; return }
        let point = convert(event.locationInWindow, from: nil)
        var text: String?
        if let page = page(for: point, nearest: false), let hit = editableAnnotation(at: convert(point, to: page), on: page),
           hit.type != "FreeText", let contents = hit.contents?.trimmingCharacters(in: .whitespacesAndNewlines), !contents.isEmpty {
            text = contents.count > 400 ? String(contents.prefix(400)) + "…" : contents
        }
        if toolTip != text { toolTip = text }
    }

    // MARK: Eraser (READER-30)

    /// The pointer of the tools that put something down: an I-beam for a text box (it is typed where clicked), a
    /// little note in the note's colour, the pen's own dot. The markup tools keep PDFKit's (an I-beam over text).
    private var toolCursor: NSCursor? {
        switch tool {
        case .text: .iBeam
        case .note: ToolCursors.note(color: noteColor)
        case .ink: ToolCursors.pen(color: inkColor, diameter: inkWidth * scaleFactor)
        default: nil
        }
    }

    private var eraserCursor: NSCursor { EraserCursor.cursor(diameter: eraserSize.diameter * scaleFactor) }

    /// The eraser went down: what it covers is erased at once. (Also driven by the reader's self-test.)
    func beginErasing(at point: NSPoint, on page: PDFPage) {
        erasing = InkEraseSession(diameter: eraserSize.diameter)
        continueErasing(to: point, on: page)
    }

    func continueErasing(to point: NSPoint, on page: PDFPage) {
        guard let erasing, erasing.move(to: point, on: page) else { return }
        annotationsChanged(on: page)
    }

    /// Released: everything the drag erased becomes one undo step and is saved.
    func endErasing() {
        guard let session = erasing else { return }
        erasing = nil
        editor?.didErase(session.changes)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if editLayer != nil, event.keyCode == 53 {   // Esc
            onLeaveEditing()
            return
        }
        // [ and ] make the eraser smaller and larger, as in drawing apps.
        if tool == .eraser, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock]).isEmpty,
           let key = event.charactersIgnoringModifiers, key == "[" || key == "]" {
            onEraserSizeStep(key == "[" ? -1 : 1)
            return
        }
        if [51, 117].contains(event.keyCode), let annotation = selectedAnnotation {   // ⌫ / ⌦
            selectAnnotation(nil)
            editor?.remove(annotation)
            return
        }
        switch event.keyCode {
        case 53:                                          // Esc
            if selectedAnnotation != nil {
                selectAnnotation(nil)
            } else if tool != .select {
                editor?.resetTool()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Context menu (READER-04/08)

    override func menu(for event: NSEvent) -> NSMenu? {
        if tool == .eraser, let menu = eraserSizeMenu() { return menu }
        let base = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        if let page = page(for: point, nearest: false), let hit = editableAnnotation(at: convert(point, to: page), on: page) {
            selectAnnotation(hit)
            return editor?.menu(for: hit) ?? base
        }
        if let selection = currentSelection, !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return editor?.menu(forSelection: selection, base: base) ?? base
        }
        return base
    }
}


/// The pointers of the note and pen tools.
enum ToolCursors {
    /// A small upright note, its middle where it will be placed.
    static func note(color: NSColor) -> NSCursor {
        let size = NSSize(width: 16, height: 19)
        let image = NSImage(size: size, flipped: false) { _ in
            let card = NSRect(x: 2, y: 1.5, width: 12, height: 15)
            let fold: CGFloat = 4
            let path = NSBezierPath()
            path.move(to: NSPoint(x: card.minX + 2, y: card.minY))
            path.line(to: NSPoint(x: card.maxX - 2, y: card.minY))
            path.curve(to: NSPoint(x: card.maxX, y: card.minY + 2), controlPoint1: NSPoint(x: card.maxX, y: card.minY), controlPoint2: NSPoint(x: card.maxX, y: card.minY))
            path.line(to: NSPoint(x: card.maxX, y: card.maxY - fold))
            path.line(to: NSPoint(x: card.maxX - fold, y: card.maxY))
            path.line(to: NSPoint(x: card.minX + 2, y: card.maxY))
            path.curve(to: NSPoint(x: card.minX, y: card.maxY - 2), controlPoint1: NSPoint(x: card.minX, y: card.maxY), controlPoint2: NSPoint(x: card.minX, y: card.maxY))
            path.line(to: NSPoint(x: card.minX, y: card.minY + 2))
            path.curve(to: NSPoint(x: card.minX + 2, y: card.minY), controlPoint1: NSPoint(x: card.minX, y: card.minY), controlPoint2: NSPoint(x: card.minX, y: card.minY))
            path.close()
            NSColor.white.setStroke()
            path.lineWidth = 2.5
            path.stroke()
            color.withAlphaComponent(1).setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 0.8
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 9.5))
    }

    /// The pen's tip: a dot as wide as its line at this zoom, in its colour, with a light and a dark edge so it shows
    /// on any page.
    static func pen(color: NSColor, diameter: CGFloat) -> NSCursor {
        let dot = max(min(diameter, 40), 3)
        let side = ceil(dot + 6)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSRect(x: (rect.width - dot) / 2, y: (rect.height - dot) / 2, width: dot, height: dot)
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -1.25, dy: -1.25))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
            color.withAlphaComponent(1).setFill()
            NSBezierPath(ovalIn: circle).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let edge = NSBezierPath(ovalIn: circle.insetBy(dx: -2, dy: -2))
            edge.lineWidth = 0.5
            edge.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}

/// A view the reader floats over the page (a text box being written and its bar, a note's card): the page view leaves
/// the pointer to it.
protocol ReaderFloatingPanel: NSView {}

extension NSRect {
    /// What is left of the rectangle without `hole`: up to four rectangles around it.
    func subtracting(_ hole: NSRect) -> [NSRect] {
        let cut = intersection(hole)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [self] }
        return [NSRect(x: minX, y: minY, width: width, height: cut.minY - minY),
                NSRect(x: minX, y: cut.maxY, width: width, height: maxY - cut.maxY),
                NSRect(x: minX, y: cut.minY, width: cut.minX - minX, height: cut.height),
                NSRect(x: cut.maxX, y: cut.minY, width: maxX - cut.maxX, height: cut.height)]
            .filter { $0.width > 0 && $0.height > 0 }
    }
}
