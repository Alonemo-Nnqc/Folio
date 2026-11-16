import AppKit
import PDFKit

/// Notes, text boxes and ink drawn by the reader itself, sharp at every zoom.
///
/// PDFKit shows these annotations as pictures of their own: each is drawn once into a bitmap at one pixel per page
/// point (`PDFPageLayerAnnotationEffect`, contents scale 1) and that bitmap is stretched with the page, while the page
/// around it is rendered for the screen and the zoom. They come out soft on a Retina screen and blurred when zoomed.
/// The reader leaves those pictures empty and draws the annotations in a layer of its own over each page
/// (`PDFPageOverlayViewProvider`), at the screen's resolution times the zoom. Thumbnails, printing, exports and the
/// preview snapshots still get the annotations' ordinary vector drawing.
nonisolated protocol CrispAnnotation: PDFAnnotation {
    /// Draws the annotation in page space (what `draw(with:in:)` draws).
    func drawContent(in context: CGContext)
    /// Room the drawing takes around the bounds (a note's shadow).
    var drawingOutset: CGFloat { get }
}

nonisolated enum CrispDrawing {
    /// Whether the reader's views draw these annotations themselves (set once a reader shows a document).
    nonisolated(unsafe) static var isActive = false

    /// Whether PDFKit is asking for its stretched picture of the annotation for the view on screen (on any thread): at
    /// one unit per point, moved to the annotation's corner (or where the corner was a moment ago, as a stroke is cut by
    /// the eraser), into a context of no pixels of its own or a bitmap just the annotation's size. Everything else
    /// (thumbnails, printing, page snapshots) draws a whole page, or at another scale.
    static func isScreenPicture(_ context: CGContext, of annotation: PDFAnnotation) -> Bool {
        guard isActive, (annotation.page?.rotation ?? 0) == 0 else { return false }
        let t = context.ctm, origin = annotation.bounds.origin
        guard abs(t.a - 1) < 0.0001, abs(t.d - 1) < 0.0001, abs(t.b) < 0.0001, abs(t.c) < 0.0001,
              abs(t.tx + origin.x) < 4, abs(t.ty + origin.y) < 4 else { return false }
        let looksLikeIt: Bool
        if context.width == 0 {
            looksLikeIt = true
        } else {
            let clip = context.boundingBoxOfClipPath
            looksLikeIt = abs(CGFloat(context.width) - clip.width) <= 2 && abs(CGFloat(context.height) - clip.height) <= 2
                && clip.width <= annotation.bounds.width + 10 && clip.height <= annotation.bounds.height + 10
        }
        // The same geometry is what PDFKit draws the annotation's appearance into when the file is written (a PDF
        // context, no pixels), and printing may look alike: an appearance left empty there makes the annotation invisible
        // in every other reader. So the picture is skipped only when it is surely the page layer's on screen.
        return looksLikeIt && drawnByPageLayer()
    }

    /// Whether PDFKit's page layer (its annotation pictures on screen) is the one drawing now.
    private static func drawnByPageLayer() -> Bool {
        Thread.callStackSymbols.contains { $0.contains("PDFPageLayer") }
    }
}

/// The overlays over the pages of one reader view.
final class AnnotationOverlays: NSObject, PDFPageOverlayViewProvider {
    private var overlays: [ObjectIdentifier: AnnotationOverlayView] = [:]

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        CrispDrawing.isActive = true
        let overlay = overlays[ObjectIdentifier(page)] ?? AnnotationOverlayView(page: page, pdfView: view)
        overlays[ObjectIdentifier(page)] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
        (overlayView as? AnnotationOverlayView)?.sync()
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        overlays[ObjectIdentifier(page)] = nil
    }

    /// The page's annotations changed (added, moved, recoloured, rewritten, removed).
    func refresh(_ page: PDFPage) { overlays[ObjectIdentifier(page)]?.sync() }

    /// The zoom or the screen changed: everything is drawn again at the new resolution.
    func refreshAll() { overlays.values.forEach { $0.sync() } }
}

/// The reader's own drawing of one page's notes, text boxes and ink. It takes no clicks: the page view answers them.
final class AnnotationOverlayView: NSView {
    private weak var page: PDFPage?
    private weak var pdfView: PDFView?
    private var pictures: [ObjectIdentifier: AnnotationPictureLayer] = [:]

    init(page: PDFPage, pdfView: PDFView) {
        self.page = page
        self.pdfView = pdfView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sync()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sync()
    }

    /// Each annotation the reader draws gets a layer where it stands, drawn again when it or the zoom changed.
    func sync() {
        guard let page, let pdfView, let root = layer, bounds.width > 0 else { return }
        let resolution = (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) * pdfView.scaleFactor
        var seen = Set<ObjectIdentifier>()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if page.rotation == 0 {
            for annotation in page.annotations {
                guard let crisp = annotation as? any CrispAnnotation, annotation.shouldDisplay else { continue }
                let id = ObjectIdentifier(annotation)
                seen.insert(id)
                let picture = pictures[id] ?? {
                    let new = AnnotationPictureLayer()
                    root.addSublayer(new)
                    pictures[id] = new
                    return new
                }()
                if let ink = annotation as? InkAnnotation, ink.opacity == nil {
                    ink.opacity = InkEraseSession.opacity(of: annotation, on: page) ?? 1
                }
                let pageRect = annotation.bounds.insetBy(dx: -crisp.drawingOutset, dy: -crisp.drawingOutset)
                let frame = convert(pdfView.convert(pageRect, from: page), from: pdfView)
                picture.show(crisp, pageRect: pageRect, frame: frame, resolution: resolution)
            }
        }
        for (id, picture) in pictures where !seen.contains(id) {
            picture.removeFromSuperlayer()
            pictures[id] = nil
        }
        CATransaction.commit()
    }
}

/// One annotation's picture, drawn at the screen's resolution times the zoom. Core Animation calls layers from any
/// thread, so the class opts out of the app's MainActor default; the reader only touches it on the main thread.
nonisolated final class AnnotationPictureLayer: CALayer {
    nonisolated(unsafe) private weak var annotation: PDFAnnotation?
    nonisolated(unsafe) private var pageRect = CGRect.zero
    nonisolated(unsafe) private var signature = ""
    /// The most pixels one picture takes (a page-wide scribble at a high zoom draws at a lower resolution).
    private static let pixelBudget: CGFloat = 24_000_000

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    func show(_ annotation: any CrispAnnotation, pageRect: CGRect, frame: CGRect, resolution: CGFloat) {
        let points = max(frame.width * frame.height, 1)
        let scale = min(resolution, max(1, (Self.pixelBudget / points).squareRoot()))
        let signature = Self.signature(of: annotation) + "|\(pageRect)|\(scale)"
        self.annotation = annotation
        self.pageRect = pageRect
        self.frame = frame
        if contentsScale != scale { contentsScale = scale }
        if signature != self.signature {
            self.signature = signature
            setNeedsDisplay()
        }
    }

    override func draw(in context: CGContext) {
        guard let annotation = annotation as? any CrispAnnotation, pageRect.width > 0, pageRect.height > 0 else { return }
        context.scaleBy(x: bounds.width / pageRect.width, y: bounds.height / pageRect.height)
        context.translateBy(x: -pageRect.minX, y: -pageRect.minY)
        annotation.drawContent(in: context)
    }

    /// What the picture shows: drawn again only when it changes.
    private static func signature(of annotation: PDFAnnotation) -> String {
        var parts = ["\(annotation.bounds)", annotation.contents ?? "", annotation.color.description]
        if annotation.type == "FreeText" {
            parts += [annotation.font?.description ?? "", annotation.fontColor?.description ?? "", "\(annotation.border?.lineWidth ?? 0)"]
        }
        if let paths = annotation.paths {
            parts.append("\(annotation.border?.lineWidth ?? 1)")
            parts += paths.map { "\($0.elementCount):\($0.bounds)" }
        }
        return parts.joined(separator: "|")
    }
}

/// A pen stroke (PDF "Ink" annotation) as the reader draws it: its paths in its colour and width, round at the ends
/// and the corners, exactly as the stroke looked while it was drawn.
nonisolated final class InkAnnotation: PDFAnnotation, CrispAnnotation {
    /// The stroke's opacity as the file has it (/CA), read once on the main thread; nil until then.
    ///
    /// Kept beside the annotation, not in it: PDFKit makes the annotations a file has through an initializer of its
    /// own, which skips Swift's property defaults, and a stored `CGFloat?` then reads as 0 — every stroke a file had
    /// was drawn fully transparent.
    var opacity: CGFloat? {
        get { Self.lock.withLock { (Self.opacities.object(forKey: self) as? NSNumber).map { CGFloat($0.doubleValue) } } }
        set { Self.lock.withLock { Self.opacities.setObject(newValue.map { NSNumber(value: Double($0)) }, forKey: self) } }
    }

    nonisolated(unsafe) private static let opacities = NSMapTable<InkAnnotation, AnyObject>.weakToStrongObjects()
    private static let lock = NSLock()

    var drawingOutset: CGFloat { 1 }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if CrispDrawing.isScreenPicture(context, of: self) { return }
        drawContent(in: context)
    }

    func drawContent(in context: CGContext) {
        let width = border.map { max(0, $0.lineWidth) } ?? 1
        guard width > 0, let paths, !paths.isEmpty else { return }
        let base = color.usingColorSpace(.sRGB) ?? color
        let alpha = base.alphaComponent * (opacity ?? 1)
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if alpha < 1 {
            // One transparency for the whole annotation: where its strokes cross, it does not get darker.
            context.setAlpha(alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setStrokeColor(base.withAlphaComponent(1).cgColor)
        } else {
            context.setStrokeColor(base.cgColor)
        }
        for path in paths {
            context.addPath(path.cgPath)
            context.strokePath()
        }
        if alpha < 1 { context.endTransparencyLayer() }
        context.restoreGState()
    }
}

/// Notes, text boxes and ink that an earlier build saved with an empty appearance ("q Q" in a box of no size): the
/// picture every other reader draws them with, so they showed nowhere but in Folio. Taken off when the file is opened,
/// so that writing the file draws them anew.
enum AppearanceRepair {
    /// How many annotations of `document` had their empty appearance taken off.
    static func repair(_ document: PDFDocument) -> Int {
        var repaired = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let empty = emptyAppearances(on: page)
            guard !empty.isEmpty else { continue }
            for annotation in page.annotations {
                guard let type = annotation.type, ["Ink", "Text", "FreeText"].contains(type) else { continue }
                let bounds = annotation.bounds
                guard empty.contains(where: { $0.subtype == type && abs($0.rect.minX - bounds.minX) < 0.5 && abs($0.rect.minY - bounds.minY) < 0.5
                    && abs($0.rect.width - bounds.width) < 0.5 && abs($0.rect.height - bounds.height) < 0.5 }) else { continue }
                annotation.removeValue(forAnnotationKey: .appearanceDictionary)
                repaired += 1
            }
        }
        return repaired
    }

    /// The kind and rectangle of each note, text box or ink on the page whose normal appearance draws nothing.
    static func emptyAppearances(on page: PDFPage) -> [(subtype: String, rect: CGRect)] {
        guard let dictionary = page.pageRef?.dictionary else { return [] }
        var annots: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annots), let annots else { return [] }
        var found: [(String, CGRect)] = []
        for index in 0..<CGPDFArrayGetCount(annots) {
            var entry: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, index, &entry), let entry else { continue }
            var name: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(entry, "Subtype", &name), let name else { continue }
            let subtype = String(cString: name)
            guard ["Ink", "Text", "FreeText"].contains(subtype) else { continue }
            var appearance: CGPDFDictionaryRef?
            var normal: CGPDFStreamRef?
            guard CGPDFDictionaryGetDictionary(entry, "AP", &appearance), let appearance,
                  CGPDFDictionaryGetStream(appearance, "N", &normal), let normal else { continue }
            var format = CGPDFDataFormat.raw
            let data = (CGPDFStreamCopyData(normal, &format) as Data?) ?? Data()
            let content = String(decoding: data, as: UTF8.self).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let drawsNothing = content.allSatisfy { $0 == "q" || $0 == "Q" }
            guard drawsNothing, let rect = rectangle(entry) else { continue }
            found.append((subtype, rect))
        }
        return found
    }

    private static func rectangle(_ entry: CGPDFDictionaryRef) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(entry, "Rect", &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var v = [CGPDFReal](repeating: 0, count: 4)
        for i in 0..<4 { CGPDFArrayGetNumber(array, i, &v[i]) }
        return CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
    }
}
