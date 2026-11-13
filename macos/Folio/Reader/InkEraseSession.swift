import AppKit
import FolioCore
import PDFKit

/// One drag of the eraser (READER-30). The ink under the eraser is cut as the pointer moves: each ink annotation it
/// touches is swapped on its page for a working copy whose strokes follow the erasing (an annotation with nothing left
/// is taken off the page). The originals are kept untouched, so releasing records all of it as one undo step that puts
/// them back exactly as they were. Only ink is affected, whoever wrote it.
final class InkEraseSession {
    /// What happened to one original annotation: replaced by a copy with less ink, or (nil) erased completely.
    struct Change {
        let page: PDFPage
        let original: PDFAnnotation
        var replacement: PDFAnnotation?
    }

    let diameter: CGFloat
    private(set) var changes: [Change] = []
    /// Working copy → index in `changes`.
    private var copies: [ObjectIdentifier: Int] = [:]
    /// Strokes of the working copies in page coordinates (kept, so they are not read back from paths every move).
    private var strokes: [ObjectIdentifier: [[CGPoint]]] = [:]
    private var last: (page: PDFPage, point: CGPoint)?

    init(diameter: CGFloat) {
        self.diameter = diameter
    }

    /// Erases from the last point to this one (a new track when the pointer moved to another page). True when the
    /// page's ink changed.
    @discardableResult
    func move(to point: CGPoint, on page: PDFPage) -> Bool {
        let track = last.map { $0.page === page ? [$0.point, point] : [point] } ?? [point]
        last = (page, point)
        let reach = InkEraser.bounds(of: track).insetBy(dx: -diameter / 2, dy: -diameter / 2)
        var changed = false
        for annotation in page.annotations where annotation.type == "Ink" {
            let width = Self.lineWidth(of: annotation)
            guard annotation.bounds.insetBy(dx: -width, dy: -width).intersects(reach) else { continue }
            let id = ObjectIdentifier(annotation)
            let current = strokes[id] ?? Self.strokes(of: annotation)
            guard let left = InkEraser.erase(current, along: track, radius: diameter / 2 + width / 2) else { continue }
            changed = true
            if let index = copies[id] {
                // Already a working copy: cut it further, or take it away.
                if left.isEmpty {
                    page.removeAnnotation(annotation)
                    if let popup = changes[index].original.popup { page.removeAnnotation(popup) }
                    copies[id] = nil
                    strokes[id] = nil
                    changes[index].replacement = nil
                } else {
                    Self.setStrokes(left, of: annotation, width: width)
                    strokes[id] = left
                }
                continue
            }
            // First touch: the original leaves the page, a copy with what is left takes its place.
            var change = Change(page: page, original: annotation, replacement: nil)
            page.removeAnnotation(annotation)
            if let popup = annotation.popup, left.isEmpty { page.removeAnnotation(popup) }
            if !left.isEmpty, let copy = annotation.copy() as? PDFAnnotation {
                // Its picture shows the old strokes: PDFKit draws (and saves) a new one from the paths without it.
                copy.removeValue(forAnnotationKey: .appearanceDictionary)
                if let opacity = Self.opacity(of: annotation, on: page), opacity < 1, copy.color.alphaComponent >= 1 {
                    copy.color = copy.color.withAlphaComponent(opacity)
                }
                copy.modificationDate = Date()
                Self.setStrokes(left, of: copy, width: width)
                page.addAnnotation(copy)
                copies[ObjectIdentifier(copy)] = changes.count
                strokes[ObjectIdentifier(copy)] = left
                change.replacement = copy
            }
            changes.append(change)
        }
        return changed
    }

    // MARK: Ink geometry

    /// An ink annotation's line width (PDF default 1).
    static func lineWidth(of annotation: PDFAnnotation) -> CGFloat {
        annotation.border.map { max(0, $0.lineWidth) } ?? 1
    }

    /// The strokes of an ink annotation in page coordinates (its paths are relative to its bounds), curves flattened.
    static func strokes(of annotation: PDFAnnotation) -> [[CGPoint]] {
        let origin = annotation.bounds.origin
        var result: [[CGPoint]] = []
        for path in annotation.paths ?? [] {
            var stroke: [CGPoint] = []
            let flat = path.flattened
            var points = [NSPoint](repeating: .zero, count: 3)
            func page(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x + origin.x, y: point.y + origin.y) }
            for index in 0..<flat.elementCount {
                switch flat.element(at: index, associatedPoints: &points) {
                case .moveTo:
                    if !stroke.isEmpty { result.append(stroke) }
                    stroke = [page(points[0])]
                case .lineTo:
                    stroke.append(page(points[0]))
                case .curveTo, .cubicCurveTo:
                    // Flattening leaves none; the end point, should one remain.
                    stroke.append(page(points[2]))
                case .quadraticCurveTo:
                    stroke.append(page(points[1]))
                case .closePath:
                    if let first = stroke.first { stroke.append(first) }
                @unknown default:
                    break
                }
            }
            if !stroke.isEmpty { result.append(stroke) }
        }
        return result
    }

    /// Replaces the annotation's paths and fits its bounds around them.
    static func setStrokes(_ strokes: [[CGPoint]], of annotation: PDFAnnotation, width: CGFloat) {
        let all = strokes.flatMap { $0 }
        let bounds = InkEraser.bounds(of: all).insetBy(dx: -(width / 2 + 1), dy: -(width / 2 + 1))
        for path in annotation.paths ?? [] { annotation.remove(path) }
        annotation.bounds = bounds
        for stroke in strokes {
            let path = NSBezierPath()
            for (index, point) in stroke.enumerated() {
                let relative = NSPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
                if index == 0 { path.move(to: relative) } else { path.line(to: relative) }
            }
            if stroke.count == 1 { path.line(to: NSPoint(x: stroke[0].x - bounds.minX, y: stroke[0].y - bounds.minY)) }
            annotation.add(path)
        }
    }

    /// The opacity (/CA) the file gives an ink annotation. PDFKit keeps it only in the annotation's picture, which the
    /// working copy draws anew, so it is read from the page as the file has it (matched by kind and rectangle).
    static func opacity(of annotation: PDFAnnotation, on page: PDFPage) -> CGFloat? {
        guard let dictionary = page.pageRef?.dictionary else { return nil }
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annots), let annots else { return nil }
        for index in 0..<CGPDFArrayGetCount(annots) {
            var entry: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, index, &entry), let entry else { continue }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(entry, "Subtype", &subtype), let subtype, String(cString: subtype) == "Ink" else { continue }
            var rectArray: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(entry, "Rect", &rectArray), let rectArray, CGPDFArrayGetCount(rectArray) == 4 else { continue }
            var values = [CGPDFReal](repeating: 0, count: 4)
            for i in 0..<4 { CGPDFArrayGetNumber(rectArray, i, &values[i]) }
            let rect = CGRect(x: min(values[0], values[2]), y: min(values[1], values[3]),
                              width: abs(values[2] - values[0]), height: abs(values[3] - values[1]))
            let bounds = annotation.bounds
            guard abs(rect.minX - bounds.minX) < 0.5, abs(rect.minY - bounds.minY) < 0.5,
                  abs(rect.width - bounds.width) < 0.5, abs(rect.height - bounds.height) < 0.5 else { continue }
            var opacity: CGPDFReal = 1
            return CGPDFDictionaryGetNumber(entry, "CA", &opacity) ? max(0, min(1, opacity)) : nil
        }
        return nil
    }
}

/// The eraser's pointer: a ring as large as the eraser at the current zoom, readable on light and dark pages.
enum EraserCursor {
    private static var cache: [Int: NSCursor] = [:]

    static func cursor(diameter: CGFloat) -> NSCursor {
        let size = Int(min(max(diameter, 6), 240).rounded())
        if let cursor = cache[size] { return cursor }
        let side = CGFloat(size) + 4
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let ring = rect.insetBy(dx: 2, dy: 2)
            let outer = NSBezierPath(ovalIn: ring)
            NSColor.white.withAlphaComponent(0.22).setFill()
            outer.fill()
            NSColor.black.withAlphaComponent(0.65).setStroke()
            outer.lineWidth = 1
            outer.stroke()
            let inner = NSBezierPath(ovalIn: ring.insetBy(dx: 1, dy: 1))
            NSColor.white.withAlphaComponent(0.9).setStroke()
            inner.lineWidth = 1
            inner.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
        cache[size] = cursor
        return cursor
    }
}
