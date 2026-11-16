import AppKit

extension AnnotationTool {
    /// Tools whose colour shows on their toolbar button: the ones picked up and put down all the time. The others
    /// (strike-through, note, text box) choose theirs where they are used — the note's card, the text box's bar — or
    /// in their menu.
    var showsColorOnToolbar: Bool { self == .highlight || self == .underline || self == .ink }

    /// Tools with a menu on the toolbar (opened by clicking the tool once it is chosen).
    var hasToolbarMenu: Bool { hasColor || self == .eraser }
}

/// A tool's toolbar image. The symbols differ in shape (a tall arrow, a wide text box), so each is sized by its ink to
/// look as big as the others and centred by its ink in the same box; the tools that show their colour are drawn in
/// it, as Preview shows its pens, a little lighter or darker where the colour would not stand out from the toolbar.
enum AnnotationToolImage {
    static let size = NSSize(width: 27, height: 20)

    static func make(_ tool: AnnotationTool, color: NSColor?) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let tint = color.map { legible($0, dark: dark) } ?? .labelColor
            guard let (symbol, ink) = symbol(tool, color: tint) else { return true }
            symbol.draw(in: NSRect(x: ((rect.width - ink.width) / 2 - ink.minX).rounded(),
                                   y: ((rect.height - ink.height) / 2 - ink.minY).rounded(),
                                   width: symbol.size.width, height: symbol.size.height))
            return true
        }
        image.accessibilityDescription = tool.title
        return image
    }

    /// The symbol at the size that matches the others, and where its ink is in it.
    private static func symbol(_ tool: AnnotationTool, color: NSColor) -> (NSImage, NSRect)? {
        guard let measured = measure(tool) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: measured.pointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)?
            .withSymbolConfiguration(configuration) else { return nil }
        return (symbol, measured.ink)
    }

    private static var measures: [AnnotationTool: (pointSize: CGFloat, ink: NSRect)] = [:]

    /// The point size giving the symbol about the same area of ink as the others, as large as the toolbar's other
    /// symbols (no taller than 19.5 points, no wider than 25; the toolbar fits the image to its own height), and its ink's rectangle at that size.
    private static func measure(_ tool: AnnotationTool) -> (pointSize: CGFloat, ink: NSRect)? {
        if let known = measures[tool] { return known }
        guard let base = ink(tool, pointSize: 15), base.width > 0, base.height > 0 else { return nil }
        let k = min(19 / (base.width * base.height).squareRoot(), 19.5 / base.height, 25 / base.width)
        let pointSize = (15 * k * 4).rounded() / 4
        guard let ink = ink(tool, pointSize: pointSize) else { return nil }
        measures[tool] = (pointSize, ink)
        return (pointSize, ink)
    }

    /// Where the symbol's ink is, in points from its bottom left.
    private static func ink(_ tool: AnnotationTool, pointSize: CGFloat) -> NSRect? {
        guard let symbol = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) else { return nil }
        let scale: CGFloat = 4
        let width = Int((symbol.size.width * scale).rounded(.up)), height = Int((symbol.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: NSRect(x: 0, y: 0, width: symbol.size.width * scale, height: symbol.size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        let alpha = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where alpha[(row * width + column) * 4 + 3] > 50 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX else { return nil }
        // The bitmap's rows run from the top.
        return NSRect(x: CGFloat(minX) / scale, y: symbol.size.height - CGFloat(maxY + 1) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// The tool's colour as it shows on the toolbar: a black pen in the dark, or a pale colour in the light, would not
    /// show, so those are taken toward the toolbar's text colour until they do.
    static func legible(_ color: NSColor, dark: Bool) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
        if dark, luminance < 0.12 {
            return c.blended(withFraction: min(1, (0.12 - luminance) / 0.12 * 0.85), of: .white) ?? c
        }
        if !dark, luminance > 0.45 {
            return c.blended(withFraction: min(0.5, (luminance - 0.45) / 0.55 * 0.6), of: .black) ?? c
        }
        return c
    }
}

/// The pen's widths and the text box's sizes the tools offer.
enum AnnotationToolOptions {
    static let inkWidths: [(title: String, width: Double)] = [
        (String(localized: "细"), 1), (String(localized: "中"), 2), (String(localized: "粗"), 3.5), (String(localized: "特粗"), 6),
    ]
    static let textSizes: [(title: String, size: Double)] = [
        (String(localized: "小"), 11), (String(localized: "中"), 13), (String(localized: "大"), 16), (String(localized: "特大"), 20),
    ]
}
