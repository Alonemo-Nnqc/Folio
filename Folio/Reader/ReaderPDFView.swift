import AppKit
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let path else { return }
        color.setStroke()
        path.lineWidth = 2
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
    var inkColor = NSColor.systemRed

    private(set) var selectedAnnotation: PDFAnnotation?
    private let inkOverlay = InkOverlayView()
    private var inkPoints: [NSPoint] = []
    private var inkPage: PDFPage?
    private var drag: (annotation: PDFAnnotation, page: PDFPage, start: NSPoint, original: NSRect, moved: Bool)?

    /// Annotation kinds the reader edits; links, widgets and popups are left to PDFKit.
    static let editableTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "FreeText",
                                             "Ink", "Square", "Circle", "Line"]
    /// Kinds that can be dragged to a new place.
    static let movableTypes: Set<String> = ["Text", "FreeText", "Ink", "Square", "Circle", "Line"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        inkOverlay.frame = bounds
        inkOverlay.autoresizingMask = [.width, .height]
        addSubview(inkOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Selection of annotations

    func selectAnnotation(_ annotation: PDFAnnotation?) {
        let previous = selectedAnnotation
        selectedAnnotation = annotation
        for page in [previous?.page, annotation?.page].compactMap({ $0 }) {
            (page as? ReaderPage)?.selectedAnnotation = annotation?.page === page ? annotation : nil
            annotationsChanged(on: page)
        }
    }

    private func editableAnnotation(at point: NSPoint, on page: PDFPage) -> PDFAnnotation? {
        // Topmost first; small hit slop so thin underlines are still easy to click.
        page.annotations.reversed().first { annotation in
            guard let type = annotation.type, Self.editableTypes.contains(type) else { return false }
            return annotation.bounds.insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true) else { return super.mouseDown(with: event) }
        let pagePoint = convert(point, to: page)
        switch tool {
        case .note, .text:
            editor?.place(tool, at: pagePoint, on: page)
        case .ink:
            inkPage = page
            inkPoints = [pagePoint]
            inkOverlay.color = inkColor
            inkOverlay.path = nil
        case .select:
            if let hit = editableAnnotation(at: pagePoint, on: page) {
                selectAnnotation(hit)
                if event.clickCount == 2, let type = hit.type, type == "Text" || type == "FreeText" {
                    editor?.edit(hit)
                } else if let type = hit.type, Self.movableTypes.contains(type) {
                    drag = (hit, page, pagePoint, hit.bounds, false)
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
            return
        }
        super.mouseUp(with: event)
        if let type = tool.markupType, let selection = currentSelection, !(selection.string ?? "").isEmpty {
            editor?.addMarkup(type, for: selection)
            clearSelection()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if [.note, .text, .ink].contains(tool) { addCursorRect(visibleRect, cursor: .crosshair) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // PDFView resets the cursor while tracking; keep the tool cursor.
        if [.note, .text, .ink].contains(tool) { NSCursor.crosshair.set() }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
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
