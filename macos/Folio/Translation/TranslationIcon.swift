import AppKit

/// 翻译全文's mark: a page with "文" on it and an "A" tile over its corner. It reads as translation, like 划词翻译's
/// `translate` symbol, without being the same: that one is two tiles, this one is a whole page. The Windows app draws
/// the same shape (windows/web/src/ui/icons.tsx, FullTextTranslateGlyph).
enum TranslationIcon {
    /// Stands for the mark where menus are given SF Symbol names.
    static let fullTextSymbol = "folio.translate.fulltext"

    /// A menu item's image: the mark for `fullTextSymbol`, the SF Symbol otherwise.
    static func menuImage(_ symbol: String) -> NSImage? {
        symbol == fullTextSymbol ? fullText(size: 17) : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    /// A template image, so toolbars tint it as they tint SF Symbols.
    static func fullText(size: CGFloat = 20, accessibilityDescription: String? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            let s = rect.width / 20
            NSColor.black.set()

            // The page, with its top right corner folded, open where the tile covers it.
            let page = NSBezierPath()
            page.move(to: NSPoint(x: 9.5 * s, y: 18.25 * s))
            page.line(to: NSPoint(x: 4 * s, y: 18.25 * s))
            page.appendArc(withCenter: NSPoint(x: 4 * s, y: 16.75 * s), radius: 1.5 * s, startAngle: 90, endAngle: 180)
            page.line(to: NSPoint(x: 2.5 * s, y: 3.25 * s))
            page.appendArc(withCenter: NSPoint(x: 4 * s, y: 3.25 * s), radius: 1.5 * s, startAngle: 180, endAngle: 270)
            page.line(to: NSPoint(x: 11 * s, y: 1.75 * s))
            page.line(to: NSPoint(x: 15.5 * s, y: 6.25 * s))
            page.line(to: NSPoint(x: 15.5 * s, y: 9 * s))
            page.move(to: NSPoint(x: 11 * s, y: 1.75 * s))
            page.line(to: NSPoint(x: 11 * s, y: 6.25 * s))
            page.line(to: NSPoint(x: 15.5 * s, y: 6.25 * s))
            page.lineWidth = 1.5 * s
            page.lineJoinStyle = .round
            page.lineCapStyle = .round
            page.stroke()

            // "文" on the page.
            let wen = NSAttributedString(string: "文", attributes: [
                .font: NSFont.systemFont(ofSize: 9.2 * s, weight: .heavy), .foregroundColor: NSColor.black])
            let wenSize = wen.size()
            wen.draw(at: NSPoint(x: 7.6 * s - wenSize.width / 2, y: 9.2 * s - wenSize.height / 2))

            // The "A" tile over the corner, cut out of the page with a thin gap, its letter cut out of the tile.
            let tile = NSBezierPath(roundedRect: NSRect(x: 10 * s, y: 10 * s, width: 9 * s, height: 9 * s), xRadius: 2.4 * s, yRadius: 2.4 * s)
            context.compositingOperation = .destinationOut
            let gap = NSBezierPath(roundedRect: NSRect(x: 8.9 * s, y: 8.9 * s, width: 11.2 * s, height: 11.2 * s), xRadius: 3.2 * s, yRadius: 3.2 * s)
            gap.fill()
            context.compositingOperation = .sourceOver
            tile.fill()
            context.compositingOperation = .destinationOut
            let letter = NSAttributedString(string: "A", attributes: [
                .font: NSFont.systemFont(ofSize: 7.6 * s, weight: .heavy), .foregroundColor: NSColor.black])
            let letterSize = letter.size()
            letter.draw(at: NSPoint(x: 14.5 * s - letterSize.width / 2, y: 14.6 * s - letterSize.height / 2))
            context.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
