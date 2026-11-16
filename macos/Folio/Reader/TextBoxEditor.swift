import AppKit
import PDFKit
import SwiftUI

/// Writing a text box in place, on the page (READER-04). The box becomes a field where it stands — transparent, its
/// text in its own font, size and colour at the page's zoom, a thin accent line around it — and a new box widens as
/// it is typed, wrapping only past `maxWidth`. A small bar above it changes the text's colour and size. Esc, ⌘↩, a
/// click elsewhere on the page, another tool, zooming or closing the window end it.
final class TextBoxEditor: NSObject, NSTextViewDelegate {
    private weak var pdfView: PDFView?
    let annotation: PDFAnnotation
    let isNew: Bool
    let original: String?
    let originalFont: NSFont?
    let originalColor: NSColor?
    let originalBounds: NSRect
    private let container = TextBoxEditorFrame()
    private let textView = TextBoxTextView()
    private let style: TextBoxStyleModel
    private var bar: TextBoxBarHost?
    private let scale: CGFloat
    /// The box ended: its text (the caller writes it, resizes the box, or drops an empty box).
    var onEnd: (String) -> Void = { _ in }
    /// The bar changed the colour or the size (the text tool keeps them for the next box).
    var onStyle: (ToolColor?, CGFloat?) -> Void = { _, _ in }
    var onMix: () -> Void = {}
    private(set) var styleChanged = false
    private var ended = false

    /// Room between the box's edge and its text, in page points, as the box is drawn (TextBoxAnnotation).
    static var inset: CGFloat { TextBoxAnnotation.inset }
    /// The widest a new box grows before its lines wrap, in page points.
    static let maxWidth: CGFloat = 280
    /// The band around the field that moves the box when dragged, in view points.
    static let grab: CGFloat = 8
    /// The sizes the bar steps through.
    static let sizes: [CGFloat] = [8, 9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 40, 48]

    init(annotation: PDFAnnotation, in pdfView: PDFView, isNew: Bool, choices: [ToolColor]) {
        self.annotation = annotation
        self.pdfView = pdfView
        self.isNew = isNew
        original = annotation.contents
        originalFont = annotation.font
        originalColor = annotation.fontColor
        originalBounds = annotation.bounds
        scale = pdfView.scaleFactor
        let color = annotation.fontColor ?? .black
        style = TextBoxStyleModel(color: ToolColor.matching(color, in: choices) ?? ToolColor(color), size: annotation.font?.pointSize ?? 13,
                                  palette: choices)
        super.init()
    }

    private var pageFont: NSFont { NSFont.systemFont(ofSize: style.size) }

    func begin() {
        guard let pdfView, annotation.page != nil else { return }
        textView.font = NSFont.systemFont(ofSize: style.size * scale)
        textView.textColor = style.color.nsColor
        textView.insertionPointColor = style.color.nsColor
        textView.string = annotation.contents ?? ""
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.onKey = { [weak self] in self?.end() }
        textView.setAccessibilityLabel(String(localized: "文本框"))
        container.addSubview(textView)
        container.onDrag = { [weak self] delta in self?.move(by: delta) }
        pdfView.addSubview(container, positioned: .above, relativeTo: nil)

        style.onColor = { [weak self] color in self?.setColor(color) }
        style.onSize = { [weak self] size in self?.setSize(size) }
        style.onMix = { [weak self] in self?.onMix() }
        let bar = TextBoxBarHost(rootView: TextBoxFormatBar(model: style))
        bar.setFrameSize(bar.fittingSize)
        pdfView.addSubview(bar, positioned: .above, relativeTo: nil)
        self.bar = bar

        layout()
        annotation.shouldDisplay = false
        if let page = annotation.page { pdfView.annotationsChanged(on: page) }
        pdfView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        NotificationCenter.default.addObserver(self, selector: #selector(zoomed), name: .PDFViewScaleChanged, object: pdfView)
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSView.boundsDidChangeNotification, object: clip)
        }
        if let window = pdfView.window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosing), name: NSWindow.willCloseNotification, object: window)
        }
    }

    /// The field as wide as its longest line (a new box up to `maxWidth`, an old one keeps its width) and as tall as
    /// its lines; its top left corner on the box's.
    private func layout() {
        guard let font = textView.font else { return }
        let pad = Self.inset * scale
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let text = textView.string.isEmpty ? " " : textView.string
        let natural = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        let width: CGFloat
        if isNew {
            width = min(max(ceil(natural) + 3, font.pointSize * 1.5), Self.maxWidth * scale)
        } else {
            width = max(annotation.bounds.width * scale - 2 * pad, font.pointSize * 1.5)
        }
        let edge = pad + 2 + Self.grab
        textView.frame = NSRect(x: edge, y: edge, width: width, height: 10)
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 0
        textView.frame.size.height = max(ceil(used), lineHeight)
        container.setFrameSize(NSSize(width: width + 2 * edge, height: textView.frame.height + 2 * edge))
        place()
    }

    /// Where the box is on screen now (it follows scrolling), and the bar above it (below, near the top).
    @objc private func place() {
        guard let pdfView, let page = annotation.page else { return }
        let box = pdfView.convert(annotation.bounds, from: page)
        let flipped = pdfView.isFlipped
        var frame = container.frame
        let edge = 2 + Self.grab
        frame.origin.x = box.minX - edge
        frame.origin.y = flipped ? box.minY - edge : box.maxY + edge - frame.height
        container.frame = frame
        guard let bar else { return }
        let size = bar.fittingSize
        let x = min(max(frame.minX, 6), max(pdfView.bounds.width - size.width - 6, 6))
        let topEdge = flipped ? frame.minY : frame.maxY
        let roomAbove = flipped ? topEdge : pdfView.bounds.height - topEdge
        let above = roomAbove > size.height + 14
        let y: CGFloat = flipped
            ? (above ? frame.minY - size.height - 8 : frame.maxY + 8)
            : (above ? frame.maxY + 8 : frame.minY - size.height - 8)
        bar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        pdfView.window?.invalidateCursorRects(for: pdfView)
    }

    /// The box dragged by its edge (also while it is still empty): it moves on the page, and the field with it.
    private func move(by delta: NSSize) {
        guard let pdfView, let page = annotation.page else { return }
        let from = pdfView.convert(NSPoint.zero, to: page)
        let to = pdfView.convert(NSPoint(x: delta.width, y: pdfView.isFlipped ? -delta.height : delta.height), to: page)
        annotation.bounds = annotation.bounds.offsetBy(dx: to.x - from.x, dy: to.y - from.y)
        place()
    }

    private func setColor(_ color: ToolColor) {
        styleChanged = true
        if !style.palette.contains(color) { style.palette.append(color) }
        style.color = color
        textView.textColor = color.nsColor
        textView.insertionPointColor = color.nsColor
        annotation.fontColor = color.nsColor
        container.needsDisplay = true
        onStyle(color, nil)
        pdfView?.window?.makeFirstResponder(textView)
    }

    /// A colour mixed in the colour panel while the box is written.
    func mixed(_ color: NSColor) { setColor(ToolColor(color)) }

    private func setSize(_ size: CGFloat) {
        styleChanged = true
        style.size = size
        textView.font = NSFont.systemFont(ofSize: size * scale)
        annotation.font = pageFont
        layout()
        onStyle(nil, size)
        pdfView?.window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) { layout() }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { end(); return true }
        return false
    }

    @objc private func zoomed() { end() }
    @objc private func windowClosing() { end() }

    /// Preview hooks: text typed into the box.
    func previewType(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    /// Ends writing: the field and the bar go, the box shows again, and `onEnd` gets the text.
    func end() {
        guard !ended else { return }
        ended = true
        NotificationCenter.default.removeObserver(self)
        let text = textView.string
        container.removeFromSuperview()
        bar?.removeFromSuperview()
        annotation.shouldDisplay = true
        if let page = annotation.page { pdfView?.annotationsChanged(on: page) }
        if pdfView?.window?.firstResponder === textView { pdfView?.window?.makeFirstResponder(pdfView) }
        onEnd(text)
    }

    /// The bounds the box needs for `text`, its top left corner where it was: as wide as its longest line (wrapping past
    /// `maxWidth`, or keeping a width the box already had), as tall as its lines.
    static func fittingBounds(for text: String, font: NSFont, from bounds: NSRect, keepWidth: Bool) -> NSRect {
        let maxWidth = keepWidth ? bounds.width - 2 * inset : Self.maxWidth
        let attributed = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
        let natural = attributed.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = keepWidth ? bounds.width : ceil(max(natural.width, font.pointSize)) + 2 * inset + 1
        let height = ceil(natural.height) + 2 * inset
        return NSRect(x: bounds.minX, y: bounds.maxY - height, width: width, height: height)
    }
}

/// The field: ⌘↩ ends the box (a plain return is a new line).
private final class TextBoxTextView: NSTextView {
    var onKey: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) { onKey(); return }
        super.keyDown(with: event)
    }
}

/// Around the field while it is written: only a thin accent line, so the page shows through as the box will. Its edge
/// is a handle, with a grip on top to say so: dragged, it moves the box. The pointer is an open hand over the edge
/// (a closed one while dragging) and the field's I-beam inside, the two never overlapping.
private final class TextBoxEditorFrame: NSView, ReaderFloatingPanel {
    var onDrag: (NSSize) -> Void = { _ in }
    private var last: NSPoint?

    override var isFlipped: Bool { true }

    /// The line around the text, half way into the band.
    private var line: NSRect { bounds.insetBy(dx: TextBoxEditor.grab - 2, dy: TextBoxEditor.grab - 2) }

    /// The grip in the middle of the top edge.
    private var grip: NSRect {
        let width: CGFloat = min(28, max(line.width - 12, 12))
        return NSRect(x: (bounds.midX - width / 2).rounded(), y: line.minY - 2.5, width: width, height: 5)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: line, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.withAlphaComponent(last == nil ? 0.75 : 1).setStroke()
        path.lineWidth = last == nil ? 1 : 1.5
        path.stroke()
        let pill = NSBezierPath(roundedRect: grip, xRadius: 2.5, yRadius: 2.5)
        NSColor.controlAccentColor.setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.9).setFill()
        for k in -1...1 {
            NSBezierPath(ovalIn: NSRect(x: grip.midX + CGFloat(k) * 5 - 1, y: grip.midY - 1, width: 2, height: 2)).fill()
        }
    }

    override func resetCursorRects() {
        let field = subviews.first?.frame ?? .zero
        let cursor: NSCursor = last == nil ? .openHand : .closedHand
        for rect in bounds.subtracting(field) { addCursorRect(rect, cursor: cursor) }
    }

    override func mouseDown(with event: NSEvent) {
        last = event.locationInWindow
        NSCursor.closedHand.set()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last else { return }
        let point = event.locationInWindow
        onDrag(NSSize(width: point.x - last.x, height: point.y - last.y))
        self.last = point
    }

    override func mouseUp(with event: NSEvent) {
        last = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }
}

/// The text box's bar over the page.
private final class TextBoxBarHost: NSHostingView<TextBoxFormatBar>, ReaderFloatingPanel {}

/// What the bar shows and changes.
@Observable
final class TextBoxStyleModel {
    var color: ToolColor
    var size: CGFloat
    var palette: [ToolColor]
    var onColor: (ToolColor) -> Void = { _ in }
    var onSize: (CGFloat) -> Void = { _ in }
    var onMix: () -> Void = {}

    init(color: ToolColor, size: CGFloat, palette: [ToolColor]) {
        self.color = color
        self.size = size
        self.palette = palette
    }
}

/// The text box's bar: its colours, 自定义颜色…, and its size, smaller and larger.
struct TextBoxFormatBar: View {
    @Bindable var model: TextBoxStyleModel

    var body: some View {
        HStack(spacing: 5) {
            ForEach(model.palette) { color in
                Button { model.onColor(color) } label: {
                    Circle()
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(model.color == color ? 0.55 : 0), lineWidth: 1.2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.title)
                .accessibilityLabel(color.title)
            }
            Button(action: model.onMix) {
                CustomColorSwatch().padding(2.5).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("自定义颜色…")
            .accessibilityLabel(Text("自定义颜色…"))
            Divider().frame(height: 14).padding(.horizontal, 3)
            // The size: smaller, the size itself (a menu of sizes), larger.
            HStack(spacing: 0) {
                SizeStepButton(letter: 9.5, help: "缩小字号") { step(-1) }
                    .disabled(model.size <= TextBoxEditor.sizes.first!)
                Menu {
                    ForEach(TextBoxEditor.sizes, id: \.self) { size in
                        Button { model.onSize(size) } label: {
                            if size == model.size { Label("\(Int(size)) pt", systemImage: "checkmark") } else { Text("\(Int(size)) pt") }
                        }
                    }
                } label: {
                    Text("\(Int(model.size))")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .frame(minWidth: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("字号")
                SizeStepButton(letter: 14, help: "放大字号") { step(1) }
                    .disabled(model.size >= TextBoxEditor.sizes.last!)
            }
            .padding(.horizontal, 2)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(6)
    }

    private func step(_ direction: Int) {
        let sizes = TextBoxEditor.sizes
        let next = direction > 0 ? sizes.first { $0 > model.size } : sizes.last { $0 < model.size }
        if let next { model.onSize(next) }
    }
}

/// A letter A, small or large, that makes the text smaller or larger.
private struct SizeStepButton: View {
    let letter: CGFloat
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text("A")
                .font(.system(size: letter, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: 24, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovered && isEnabled ? 0.1 : 0)).frame(width: 22, height: 22))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
