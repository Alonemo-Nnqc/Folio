import AppKit
import PDFKit
import SwiftUI

/// What the card edits. The note takes what is typed as it is typed (`onText`); the card only shows it.
@Observable
final class AnnotationCardModel {
    var text: String { didSet { if text != oldValue { onText(text) } } }
    var color: ToolColor
    let quote: String?
    let author: String?
    let date: Date?
    var palette: [ToolColor]
    let placeholder: String
    var onText: (String) -> Void = { _ in }
    var onColor: (ToolColor) -> Void = { _ in }
    var onMix: () -> Void = {}
    var onDelete: () -> Void = {}
    var onDone: () -> Void = {}

    init(text: String, color: ToolColor, quote: String?, author: String?, date: Date?, palette: [ToolColor], placeholder: String) {
        self.text = text
        self.color = color
        self.quote = quote
        self.author = author
        self.date = date
        self.palette = palette
        self.placeholder = placeholder
    }
}

/// A circle of every hue: 自定义颜色…, beside the colours themselves.
struct CustomColorSwatch: View {
    var diameter: CGFloat = 12

    var body: some View {
        Circle()
            .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .mint, .cyan, .blue, .purple, .pink, .red], center: .center))
            .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.85), .white.opacity(0)], center: .center, startRadius: 0, endRadius: diameter / 2)))
            .overlay(Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
            .frame(width: diameter, height: diameter)
    }
}

/// A sticky note's or a highlight's comment: a quiet card in the note's colour, with nothing on it but the words.
/// What is typed is kept at once; the card closes with Esc, ⌘↩ or a click elsewhere. Its colours, when it was
/// written, and deleting it, sit in one low line under the text. It takes the size of its panel (which can be dragged
/// larger or smaller from its corner).
struct AnnotationCard: View {
    @Bindable var model: AnnotationCardModel
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let quote = model.quote, !quote.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Capsule()
                        .fill(Color(nsColor: model.color.nsColor))
                        .frame(width: 3)
                    Text(quote)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ZStack(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text(model.placeholder)
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $model.text)
                    .font(.system(size: 14))
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                ForEach(model.palette) { color in
                    Button {
                        model.color = color
                        model.onColor(color)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                            .padding(2.5)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(model.color == color ? 0.5 : 0), lineWidth: 1.2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(color.title)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(model.color == color ? .isSelected : [])
                }
                Button(action: model.onMix) {
                    CustomColorSwatch().padding(2.5).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("自定义颜色…")
                .accessibilityLabel(Text("自定义颜色…"))
                Spacer(minLength: 6)
                if let line = byline {
                    Text(line)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(model.author ?? "")
                }
                Button(action: model.onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除批注")
                .accessibilityLabel(Text("删除批注"))
                // Room for the panel's resize corner.
                Color.clear.frame(width: 6, height: 1)
            }
            // ⌘↩ closes the card (what is typed is already kept).
            .background(Button("", action: model.onDone).keyboardShortcut(.return, modifiers: .command).hidden())
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: model.color.nsColor).opacity(colorScheme == .dark ? 0.12 : 0.14))
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: model.onDone)
        .onAppear { focused = true }
    }

    /// When it was written, short (who wrote it shows on hover).
    private var byline: String? {
        model.date.map { $0.formatted(.dateTime.month(.abbreviated).day()) }
    }
}

/// The card on the page, beside its annotation: it stays with the annotation as the page scrolls and zooms, and it
/// can be made larger or smaller from its lower right corner (the size is remembered for the next card). It lies over
/// the reader (not inside the zoomed page), so its text is as sharp as the rest of the window.
final class AnnotationCardPanel: NSView, ReaderFloatingPanel {
    private weak var pdfView: PDFView?
    private weak var annotation: PDFAnnotation?
    private let content = NSView()
    private let hosting: NSHostingView<AnnotationCard>
    private let grip = CardResizeGrip()
    /// Where the card sits from the annotation's top right corner (view points), fixed when it opens.
    private var offset = CGPoint.zero
    private var monitor: Any?
    private var closed = false
    /// Closed by a click elsewhere, Esc, ⌘↩, deleting, or the annotation going.
    var onClose: () -> Void = {}

    static let minimumSize = NSSize(width: 230, height: 130)
    static let maximumSize = NSSize(width: 640, height: 640)
    private static let sizeKey = "annotationCardSize"

    /// The size the last card was left at.
    static var rememberedSize: NSSize {
        get {
            let stored = UserDefaults.standard.string(forKey: sizeKey).map(NSSizeFromString) ?? .zero
            return stored.width > 0 ? stored : NSSize(width: 290, height: 168)
        }
        set { UserDefaults.standard.set(NSStringFromSize(newValue), forKey: sizeKey) }
    }

    init(model: AnnotationCardModel, annotation: PDFAnnotation, in pdfView: PDFView) {
        self.pdfView = pdfView
        self.annotation = annotation
        hosting = NSHostingView(rootView: AnnotationCard(model: model))
        var size = Self.rememberedSize
        if model.quote != nil { size.height += 40 }
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            return shadow
        }()
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        hosting.sizingOptions = []
        hosting.frame = content.bounds
        hosting.autoresizingMask = [.width, .height]
        content.addSubview(hosting)
        grip.frame = NSRect(x: bounds.width - 16, y: 0, width: 16, height: 16)
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        grip.onDrag = { [weak self] delta in self?.resize(by: delta) }
        grip.onEnd = { [weak self] in if let self { Self.rememberedSize = NSSize(width: self.frame.width, height: self.frame.height - (model.quote != nil ? 40 : 0)) } }
        content.addSubview(grip)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "便签"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func updateLayer() {
        super.updateLayer()
        content.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// Opens beside the annotation: to its right, or its left where there is no room; level with its top.
    func show() {
        guard let pdfView, let anchor = anchorRect() else { return }
        let room = pdfView.bounds.insetBy(dx: 10, dy: 10)
        var x = anchor.maxX + 12
        if x + frame.width > room.maxX { x = anchor.minX - 12 - frame.width }
        x = min(max(x, room.minX), max(room.maxX - frame.width, room.minX))
        let topInset = pdfView.documentView?.enclosingScrollView?.contentInsets.top ?? 0
        var top = anchor.maxY + 10
        top = min(top, room.maxY - topInset)
        top = max(top, room.minY + frame.height)
        offset = CGPoint(x: x - anchor.maxX, y: top - anchor.maxY)
        pdfView.addSubview(self, positioned: .above, relativeTo: nil)
        place()
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSView.boundsDidChangeNotification, object: clip)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(place), name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: pdfView)
        // A click anywhere else in the window closes the card (the colour panel and menus are other windows).
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                AnnotationCardPanel.closingClick = (self.annotation.map(ObjectIdentifier.init), event.timestamp)
                self.close()
            }
            return event
        }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    /// The click that closed a card, so the same click on its own note does not open it again.
    static var closingClick: (annotation: ObjectIdentifier?, time: TimeInterval)?

    private func anchorRect() -> NSRect? {
        guard let pdfView, let annotation, let page = annotation.page else { return nil }
        return pdfView.convert(annotation.bounds, from: page)
    }

    /// Stays where it was put relative to the annotation as the page moves under it.
    @objc private func place() {
        guard let anchor = anchorRect() else { return close() }
        setFrameOrigin(NSPoint(x: anchor.maxX + offset.x, y: anchor.maxY + offset.y - frame.height))
        if let pdfView { window?.invalidateCursorRects(for: pdfView) }
    }

    /// Preview hook: dragged by the corner in small steps, as a hand does.
    func previewDrag(by total: NSSize, steps: Int) {
        for _ in 0..<steps { resize(by: NSSize(width: total.width / CGFloat(steps), height: total.height / CGFloat(steps))) }
    }

    private func resize(by delta: NSSize) {
        let top = frame.maxY
        let width = min(max(frame.width + delta.width, Self.minimumSize.width), Self.maximumSize.width)
        let height = min(max(frame.height - delta.height, Self.minimumSize.height), Self.maximumSize.height)
        frame = NSRect(x: frame.minX, y: top - height, width: width, height: height)
        // Laid out again at once (not after the drag), and the words kept in view: where they all fit, from their first
        // line, rather than left scrolled away when the card was smaller.
        hosting.layoutSubtreeIfNeeded()
        if let scroll = Self.textScrollView(in: hosting), let text = scroll.documentView {
            if text.frame.height <= scroll.contentView.bounds.height + 1 {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            text.needsDisplay = true
        }
    }

    private static func textScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
        for sub in view.subviews { if let found = textScrollView(in: sub) { return found } }
        return nil
    }

    func close() {
        guard !closed else { return }
        closed = true
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: self) ?? false }) == true { window?.makeFirstResponder(pdfView) }
        removeFromSuperview()
        onClose()
    }
}

/// The card's lower right corner: dragged, the card grows or shrinks.
private final class CardResizeGrip: NSView {
    var onDrag: (NSSize) -> Void = { _ in }
    var onEnd: () -> Void = {}
    private var last: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        for length in [4.0, 8.0] as [CGFloat] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: bounds.maxX - 4 - length, y: 4))
            line.line(to: NSPoint(x: bounds.maxX - 4, y: 4 + length))
            line.lineWidth = 1
            line.lineCapStyle = .round
            line.stroke()
        }
    }

    override func resetCursorRects() {
        if #available(macOS 15, *) {
            addCursorRect(bounds, cursor: NSCursor.frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    override func mouseDown(with event: NSEvent) { last = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let last else { return }
        let point = event.locationInWindow
        onDrag(NSSize(width: point.x - last.x, height: point.y - last.y))
        self.last = point
    }

    override func mouseUp(with event: NSEvent) {
        last = nil
        onEnd()
    }
}
