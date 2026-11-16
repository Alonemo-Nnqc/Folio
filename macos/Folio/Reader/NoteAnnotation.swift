import AppKit
import PDFKit

/// A sticky note (PDF "Text" annotation) as the reader draws it: a small upright card in the note's colour with a
/// folded corner and a soft shadow, and two lines on it once something is written. PDFKit's own comment icon is a
/// dated speech bubble. Other readers draw notes their own way; the file keeps the standard annotation.
/// PDFKit may draw pages off the main thread, so the class opts out of the app's MainActor default.
nonisolated final class NoteAnnotation: PDFAnnotation, CrispAnnotation {
    /// The card's width in page points; it is a fifth taller than wide.
    static let side: CGFloat = 16

    var drawingOutset: CGFloat { 4 }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // On screen the reader draws it sharp itself (CrispAnnotations); PDFKit's stretched picture of it stays empty.
        if CrispDrawing.isScreenPicture(context, of: self) { return }
        drawContent(in: context)
    }

    func drawContent(in context: CGContext) {
        // Upright in the annotation's bounds, from its top left (other apps make them 20–24 pt squares).
        var width = min(Self.side, bounds.width)
        var height = width * 1.2
        if height > bounds.height { height = bounds.height; width = height / 1.2 }
        let card = CGRect(x: bounds.minX + (bounds.width - width) / 2, y: bounds.maxY - height, width: width, height: height)
        let base = (color.usingColorSpace(.sRGB) ?? .systemYellow).withAlphaComponent(1)
        let fold = width * 0.32
        let radius = width * 0.16

        let path = CGMutablePath()
        path.move(to: CGPoint(x: card.minX + radius, y: card.minY))
        path.addLine(to: CGPoint(x: card.maxX - radius, y: card.minY))
        path.addQuadCurve(to: CGPoint(x: card.maxX, y: card.minY + radius), control: CGPoint(x: card.maxX, y: card.minY))
        path.addLine(to: CGPoint(x: card.maxX, y: card.maxY - fold))
        path.addLine(to: CGPoint(x: card.maxX - fold, y: card.maxY))
        path.addLine(to: CGPoint(x: card.minX + radius, y: card.maxY))
        path.addQuadCurve(to: CGPoint(x: card.minX, y: card.maxY - radius), control: CGPoint(x: card.minX, y: card.maxY))
        path.addLine(to: CGPoint(x: card.minX, y: card.minY + radius))
        path.addQuadCurve(to: CGPoint(x: card.minX + radius, y: card.minY), control: CGPoint(x: card.minX, y: card.minY))
        path.closeSubpath()

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -width * 0.06), blur: width * 0.22,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
        context.addPath(path)
        context.setFillColor(base.cgColor)
        context.fillPath()
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor((base.blended(withFraction: 0.4, of: .black) ?? base).withAlphaComponent(0.35).cgColor)
        context.setLineWidth(max(width * 0.03, 0.4))
        context.strokePath()

        // The folded corner, a shade darker.
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: card.maxX, y: card.maxY - fold))
        flap.addLine(to: CGPoint(x: card.maxX - fold * 0.85, y: card.maxY - fold * 0.85))
        flap.addLine(to: CGPoint(x: card.maxX - fold, y: card.maxY))
        flap.closeSubpath()
        context.addPath(flap)
        context.setFillColor((base.blended(withFraction: 0.18, of: .black) ?? base).cgColor)
        context.fillPath()

        // Two lines of writing, once the note says something.
        guard !(contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        context.setStrokeColor((base.blended(withFraction: 0.55, of: .black) ?? .black).withAlphaComponent(0.55).cgColor)
        context.setLineWidth(width * 0.075)
        context.setLineCap(.round)
        for (y, length) in [(0.52, 0.56), (0.32, 0.4)] as [(CGFloat, CGFloat)] {
            let start = card.minX + width * 0.22
            context.move(to: CGPoint(x: start, y: card.minY + height * y))
            context.addLine(to: CGPoint(x: start + width * length, y: card.minY + height * y))
        }
        context.strokePath()
    }
}

/// A text box (PDF "FreeText" annotation) as the reader draws it: its text set as vector glyphs at whatever zoom, in
/// its font and colour, with the box's fill and edge if it has them. PDFKit's own drawing comes out soft when zoomed.
nonisolated final class TextBoxAnnotation: PDFAnnotation, CrispAnnotation {
    /// Room between the box's edge and its text, in page points.
    static let inset: CGFloat = 2

    var drawingOutset: CGFloat { 1 }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if CrispDrawing.isScreenPicture(context, of: self) { return }
        drawContent(in: context)
    }

    func drawContent(in context: CGContext) {
        let rect = bounds
        if let fill = color.usingColorSpace(.sRGB), fill.alphaComponent > 0.01 {
            context.setFillColor(fill.cgColor)
            context.fill(rect)
        }
        if let border, border.lineWidth > 0 {
            context.setStrokeColor((color.usingColorSpace(.sRGB)?.withAlphaComponent(1) ?? .black).cgColor)
            context.setLineWidth(border.lineWidth)
            context.stroke(rect.insetBy(dx: border.lineWidth / 2, dy: border.lineWidth / 2))
        }
        guard let text = contents, !text.isEmpty else { return }
        let font = self.font ?? .systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: fontColor ?? .black, .paragraphStyle: paragraph,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let inset = Self.inset
        attributed.draw(with: rect.insetBy(dx: inset, dy: inset), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }
}
