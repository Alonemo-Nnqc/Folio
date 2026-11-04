import CoreGraphics
import Foundation
import PDFKit

/// One character of a page: a glyph drawn by the content stream, with its text, position, size, font and colour.
struct PageChar: Sendable {
    var text: String
    /// The glyph's advance horizontally, a line's height vertically (from a fifth of an em below the baseline).
    var rect: CGRect
    var isSpace: Bool
    var isNewline: Bool
    /// Em size in page space.
    var size: Double
    var baseline: Double
    var font: FontInfo
    var color: RGBColor
    var run: Int?
    var isRotated: Bool
    var isMath = false
    /// Raised or lowered from the line's baseline: a superscript or subscript.
    var isScript = false
    /// The glyphs drawn for it (indexes into the page's glyphs): one, or more drawn on top of each other.
    var glyphs: [Int] = []
    /// Where the glyph's ink is, when it is not the em box on the baseline (TeX's big delimiters and operators).
    var ink: CGRect?
    /// The link annotation it is under (`PageLink.index`).
    var link: Int?
    /// What that link leads to (the same number for the same place).
    var linkTarget: Int?
    /// A picture set among the words, standing in for a character: its mark (index into the page's marks).
    var icon: Int?

    var center: CGPoint { CGPoint(x: rect.midX, y: baseline + size * 0.3) }

    /// The glyph's box from its baseline and size.
    var glyphBox: CGRect {
        if let ink { return ink }
        let width = min(rect.width, size * 1.1)
        return CGRect(x: rect.minX, y: baseline - size * 0.28, width: max(width, 0.1), height: size * 1.2)
    }

    /// Where the ink of the glyph is, from the shape of the character: for telling whether lines really touch.
    var inkBox: CGRect {
        if let ink { return ink }
        let (bottom, top) = Self.verticalExtent(of: text)
        return CGRect(x: rect.minX, y: baseline + size * bottom, width: max(min(rect.width, size * 1.1), 0.1), height: size * (top - bottom))
    }

    /// Bottom and top of a character's ink, in ems from the baseline.
    static func verticalExtent(of text: String) -> (Double, Double) {
        guard let c = text.first else { return (-0.02, 0.72) }
        switch c {
        case "a", "c", "e", "m", "n", "o", "r", "s", "u", "v", "w", "x", "z", "α", "ε", "ι", "κ", "ν", "ο", "π", "σ", "τ", "υ", "ω": return (-0.02, 0.48)
        case "g", "p", "q", "y", "γ", "η", "μ", "ρ", "φ", "χ", "ψ": return (-0.22, 0.48)
        case "j", "Q", "β", "ζ", "ξ", ",", ";": return (-0.22, c == "," || c == ";" ? 0.46 : 0.72)
        case "(", ")", "[", "]", "{", "}", "|", "/", "\\", "∥", "⟨", "⟩": return (-0.26, 0.76)
        case ".", ":", "·": return (-0.02, 0.46)
        case "-", "–", "—", "−", "=", "+", "<", ">", "~", "≈", "×", "≤", "≥", "→", "←", "↑", "↓", "∈", "⊂", "≠": return (0.02, 0.56)
        case "'", "\"", "′", "″", "^", "ˆ", "˜", "`", "´", "¯", "˙", "¨", "∗", "*": return (0.36, 0.76)
        default: return (-0.02, 0.72)
        }
    }
}

/// Serialises PDFKit text extraction with the rest of the app (PDFKit's attributed strings are not thread-safe).
public enum PDFKitAccess {
    nonisolated(unsafe) public static var serialize: (@Sendable (() -> Void) -> Void) = { body in
        lock.lock()
        defer { lock.unlock() }
        body()
    }
    private static let lock = NSRecursiveLock()
}

enum PageText {
    /// The characters of a page, one per glyph drawn (duplicates drawn on top of each other count once), in the
    /// order they were drawn, with spaces where words are apart and line breaks where the drawing jumps.
    ///
    /// Position, size, font and colour are the glyph's own; the text is what the font says the glyph is
    /// (ToUnicode, glyph names, its encoding). Where the font does not say, the text PDFKit reads at that
    /// place is used; glyphs nobody can read are kept as unknown symbols (formula parts, drawn as they are).
    static func characters(of page: PDFPage, interpreter: ContentInterpreter) -> [PageChar] {
        let glyphs = interpreter.glyphs
        let fonts = interpreter.fonts
        var fallback: FallbackText?
        if glyphs.contains(where: { $0.isVisible && !$0.reliable }) { fallback = FallbackText(page: page) }

        // Letter-spaced runs: their usual gap between glyphs is not a word space.
        var runSpacing: [Int: Double] = [:]
        for (r, run) in interpreter.runs.enumerated() where run.glyphs.count > 3 {
            var gaps: [Double] = []
            var previous: Glyph?
            for g in glyphs[run.glyphs] where g.isVisible && g.text != " " {
                if let p = previous, p.size > 0 { gaps.append((g.origin.x - p.end.x) / p.size) }
                previous = g
            }
            let small = gaps.filter { $0 > -0.2 && $0 < 0.5 }.sorted()
            if small.count >= 3, small[small.count / 2] > 0.04 { runSpacing[r] = small[small.count / 2] }
        }

        var chars: [PageChar] = []
        chars.reserveCapacity(glyphs.count + glyphs.count / 4)
        // Glyphs already placed, by position: a glyph drawn again on top (fake bold, fill then stroke) joins them.
        struct Cell: Hashable { var x: Int, y: Int }
        var placed: [Cell: [Int]] = [:]
        func key(_ x: Double, _ y: Double) -> Cell { Cell(x: Int((x / 2).rounded(.down)), y: Int((y / 2).rounded(.down))) }
        var anchorBaseline = 0.0
        var anchorSize = 0.0
        var last: PageChar?
        var spaceSince = false

        for (index, g) in glyphs.enumerated() {
            guard g.isVisible, g.size > 0.5, g.size < 400 else { continue }
            var text = g.text
            if !g.reliable || text == nil {
                if let read = fallback?.text(at: g) { text = read }
            }
            if let t = text, t.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) }) {
                spaceSince = true
                continue
            }
            let horizontal = g.isHorizontal
            var origin = g.origin
            let end = g.end
            if let depth = g.depth, horizontal {
                // A hanging glyph is centred on the maths axis, a quarter em above the baseline of its line.
                origin.y -= ((depth - 0.04) / 2 + 0.25) * g.size
            }
            var rect = horizontal
                ? CGRect(x: origin.x, y: origin.y - g.size * 0.22, width: max(end.x - origin.x, 0), height: g.size * 1.2)
                : g.box
            if g.depth != nil, horizontal { rect = rect.union(g.box) }
            let label = text ?? "\u{FFFD}"
            // The same glyph drawn again at (almost) the same place.
            let probe = key(rect.minX, origin.y)
            var duplicate: Int?
            search: for dx in -1...1 {
                for dy in -1...1 {
                    for c in placed[Cell(x: probe.x + dx, y: probe.y + dy)] ?? [] where chars[c].text == label && abs(chars[c].rect.minX - rect.minX) < g.size * 0.15
                        && abs(chars[c].baseline - origin.y) < g.size * 0.15 && abs(chars[c].size - g.size) < g.size * 0.1 {
                        duplicate = c
                        break search
                    }
                }
            }
            if let duplicate {
                chars[duplicate].glyphs.append(index)
                continue
            }
            let metrics = g.font >= 0 && g.font < fonts.count ? fonts[g.font] : nil
            var font = metrics?.info ?? .unknown
            // Filled and stroked: bold made from a regular font.
            if g.renderMode == 2 { font.isBold = true }
            var char = PageChar(text: label, rect: rect, isSpace: false, isNewline: false, size: g.size, baseline: origin.y,
                                font: font, color: g.color, run: g.run, isRotated: !horizontal)
            char.glyphs = [index]
            if g.depth != nil, horizontal { char.ink = g.box }
            // Unknown glyphs are symbols: kept as drawn. So are glyphs of a symbol font that only PDFKit has a guess for
            // (an arrow it reads as "A").
            if text == nil || (g.text == nil && metrics?.info.isSymbolic == true) { char.isMath = true }

            if let p = last {
                let newLine: Bool
                if p.isRotated != char.isRotated {
                    newLine = true
                } else if char.isRotated {
                    newLine = hypot(rect.midX - p.rect.midX, rect.midY - p.rect.midY) > max(p.size, char.size) * 3
                } else {
                    let dy = abs(origin.y - anchorBaseline)
                    // Scripts sit up to most of an em off the line (a superscript after a prime is raised further).
                    let reach = char.size < anchorSize * 0.9 ? anchorSize * 0.95 : max(anchorSize, char.size) * 0.6
                    newLine = dy > reach || rect.minX < p.rect.minX - max(p.size, char.size) * 1.5
                        || rect.minX - p.rect.maxX > max(p.size, char.size) * 3
                }
                if newLine {
                    var br = p
                    br.text = "\n"
                    br.isNewline = true
                    br.isMath = false
                    br.glyphs = []
                    br.run = nil
                    br.link = nil
                    br.linkTarget = nil
                    chars.append(br)
                    anchorBaseline = origin.y
                    anchorSize = char.size
                } else if !char.isRotated {
                    let gap = rect.minX - p.rect.maxX
                    let size = min(p.size, char.size)
                    let threshold = size * (0.15 + (p.run == char.run ? runSpacing[char.run ?? -1] ?? 0 : 0))
                    if gap > threshold || (spaceSince && gap > size * 0.05) {
                        var space = p
                        space.text = " "
                        space.isSpace = true
                        space.isMath = false
                        space.glyphs = []
                        space.run = nil
                        space.link = nil
                        space.linkTarget = nil
                        space.rect = CGRect(x: p.rect.maxX, y: p.rect.minY, width: max(gap, 0), height: p.rect.height)
                        chars.append(space)
                    }
                    if char.size > anchorSize * 1.15 { anchorBaseline = origin.y; anchorSize = char.size }
                }
            } else {
                anchorBaseline = origin.y
                anchorSize = char.size
            }
            spaceSince = false
            placed[probe, default: []].append(chars.count)
            chars.append(char)
            last = char
        }
        return chars
    }

    /// PDFKit's text and where it is, for glyphs whose font does not say what they are.
    private struct FallbackText {
        var items: [(text: String, rect: CGRect)] = []
        var buckets: [Int: [Int]] = [:]
        static let bucketHeight = 6.0

        init(page: PDFPage) {
            var string: String?
            PDFKitAccess.serialize { string = page.string }
            guard let string, !string.isEmpty else { return }
            let ns = string as NSString
            var i = 0
            while i < ns.length {
                let range = ns.rangeOfComposedCharacterSequence(at: i)
                i = range.location + range.length
                let text = ns.substring(with: range)
                guard !text.isEmpty, text.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { continue }
                var rect = CGRect.zero
                PDFKitAccess.serialize { rect = page.selection(for: range)?.bounds(for: page) ?? .zero }
                guard rect.width > 0 || rect.height > 0 else { continue }
                let k = items.count
                items.append((text, rect))
                let b = Int((rect.midY / Self.bucketHeight).rounded(.down))
                buckets[b, default: []].append(k)
            }
        }

        /// The text PDFKit has inside the glyph's box (several characters for a ligature).
        func text(at g: Glyph) -> String? {
            let box = g.box
            var found: [(Double, String)] = []
            let lo = Int(((box.minY - 2) / Self.bucketHeight).rounded(.down)), hi = Int(((box.maxY + 2) / Self.bucketHeight).rounded(.down))
            guard hi - lo < 200 else { return nil }
            for b in lo...hi {
                for k in buckets[b] ?? [] {
                    let item = items[k]
                    let center = CGPoint(x: item.rect.midX, y: item.rect.midY)
                    if box.insetBy(dx: -0.3, dy: -1).contains(center) { found.append((Double(item.rect.minX), item.text)) }
                }
            }
            guard !found.isEmpty else { return nil }
            let text = found.sorted { $0.0 < $1.0 }.map(\.1).joined()
            return FontEncoding.usable(text) ? text : nil
        }
    }
}

extension TextRun {
    /// The run's em box in page space (rotated runs: the bounding box of the rotated box).
    var box: CGRect {
        let up = CGPoint(x: -sin(angle) * fontSize, y: cos(angle) * fontSize)
        let down = CGPoint(x: -up.x * 0.25, y: -up.y * 0.25)
        let points = [
            CGPoint(x: origin.x + down.x, y: origin.y + down.y), CGPoint(x: end.x + down.x, y: end.y + down.y),
            CGPoint(x: origin.x + up.x, y: origin.y + up.y), CGPoint(x: end.x + up.x, y: end.y + up.y),
        ]
        return ContentInterpreter.bounds(of: points)
    }
}
