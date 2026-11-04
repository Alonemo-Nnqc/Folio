import CoreGraphics
import Foundation

/// A line of text: characters on one baseline, between column gutters.
struct LayoutLine: Sendable {
    /// Characters, including single spaces between words (none at the ends).
    var chars: [PageChar]
    var inkRect: CGRect
    var baseline: Double
    /// Dominant em size.
    var size: Double
    var font: FontInfo
    var color: RGBColor
    var isRotated: Bool

    var minX: Double { inkRect.minX }
    var maxX: Double { inkRect.maxX }
    /// Line box from the baseline and em size, joined with the ink (sub- and superscripts).
    var rect: CGRect {
        let band = CGRect(x: inkRect.minX, y: baseline - size * 0.24, width: inkRect.width, height: size * 1.02)
        return band.union(inkRect)
    }
    var text: String { chars.map { $0.isSpace ? " " : $0.text }.joined() }
    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
    var visibleCount: Int { chars.lazy.filter { !$0.isSpace }.count }
    var mathRatio: Double {
        let visible = chars.filter { !$0.isSpace }
        guard !visible.isEmpty else { return 0 }
        return Double(visible.filter(\.isMath).count) / Double(visible.count)
    }
}

enum BlockKind: String, Sendable, CaseIterable {
    case title, heading, paragraph, caption, tableCell
    case formula, figure, header, reference, author, code, rotated, other

    /// Kinds translated by default.
    var isTranslatable: Bool {
        switch self {
        case .title, .heading, .paragraph, .caption, .tableCell: true
        default: false
        }
    }
}

/// A unit of text: a paragraph, heading, caption, table cell … with the lines it is made of.
struct LayoutBlock: Sendable {
    var kind: BlockKind
    var lines: [LayoutLine]
    var translate: Bool

    var rect: CGRect { lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) } }
    var size: Double {
        // The size most characters have.
        var counts: [Double: Int] = [:]
        for line in lines { counts[(line.size * 4).rounded() / 4, default: 0] += line.visibleCount }
        return counts.max { $0.value < $1.value }?.key ?? lines[0].size
    }
    /// Baseline distance between lines (one line: 1.2 em).
    var pitch: Double {
        guard lines.count > 1 else { return size * 1.2 }
        let gaps = zip(lines, lines.dropFirst()).map { $0.baseline - $1.baseline }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return size * 1.2 }
        return gaps[gaps.count / 2]
    }
    var font: FontInfo {
        var counts: [FontInfo: Int] = [:]
        for line in lines { counts[line.font, default: 0] += line.visibleCount }
        return counts.max { $0.value < $1.value }?.key ?? lines[0].font
    }
    var color: RGBColor {
        var counts: [RGBColor: Int] = [:]
        for line in lines { counts[line.color, default: 0] += line.visibleCount }
        return counts.max { $0.value < $1.value }?.key ?? lines[0].color
    }
    var text: String { lines.map(\.text).joined(separator: " ") }
    /// How far the first line starts right of the others.
    var firstLineIndent: Double {
        guard lines.count > 1 else { return 0 }
        let rest = lines.dropFirst().map(\.minX).min() ?? lines[0].minX
        return max(0, lines[0].minX - rest)
    }
    /// Lines centred in the block rather than flush left (headings, short captions).
    var isCentered: Bool {
        let r = rect
        return lines.allSatisfy { abs(($0.minX + $0.maxX) / 2 - r.midX) < size * 0.6 }
            && lines.contains { $0.minX - r.minX > size * 1.5 }
    }
}

/// The analysed page.
struct PageLayout: Sendable {
    var number: Int
    var mediaBox: CGRect
    var cropBox: CGRect
    var blocks: [LayoutBlock]
    var figures: [CGRect]
    var tables: [CGRect]
    /// Ink of everything drawn that is not text (for keeping translations clear of it).
    var graphics: [CGRect]
    var runs: [TextRun]
    /// Every glyph the page draws (`PageChar.glyphs` index into it).
    var glyphs: [Glyph] = []
}
