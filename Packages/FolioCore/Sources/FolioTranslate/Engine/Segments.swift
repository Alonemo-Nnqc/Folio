import CoreGraphics
import Foundation

/// An inline formula kept as drawn: where it is on the original page.
struct FormulaSpan: Sendable, Hashable {
    var rect: CGRect
    var baseline: Double
}

/// One unit sent for translation: the text of a block, with formulas replaced by `{v1}`, `{v2}` …
struct TextSegment: Sendable, Hashable {
    var page: Int
    var block: Int
    var kind: BlockKind
    var source: String
    var formulas: [FormulaSpan]

    var id: String { "\(page)-\(block)" }
    /// Placeholder for formula `n` (1-based).
    static func placeholder(_ n: Int) -> String { "{v\(n)}" }
}

enum SegmentBuilder {
    static func segments(for layout: PageLayout) -> [TextSegment] {
        layout.blocks.enumerated().compactMap { index, block in
            guard block.translate else { return nil }
            let (text, formulas) = text(of: block)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TextSegment(page: layout.number, block: index, kind: block.kind, source: text, formulas: formulas)
        }
    }

    private static let ligatures: [String: String] = ["ﬁ": "fi", "ﬂ": "fl", "ﬀ": "ff", "ﬃ": "ffi", "ﬄ": "ffl", "ﬅ": "st", "ﬆ": "st"]

    /// The block's text with formulas as placeholders; lines joined, words hyphenated across lines rejoined.
    static func text(of block: LayoutBlock) -> (String, [FormulaSpan]) {
        var out = ""
        var formulas: [FormulaSpan] = []
        for (index, line) in block.lines.enumerated() {
            let chars = line.chars
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c.isMath && !c.isSpace {
                    var rect = c.glyphBox
                    var j = i
                    while j + 1 < chars.count, chars[j + 1].isMath {
                        j += 1
                        if !chars[j].isSpace { rect = rect.union(chars[j].glyphBox) }
                    }
                    formulas.append(FormulaSpan(rect: rect, baseline: line.baseline))
                    out += TextSegment.placeholder(formulas.count)
                    i = j + 1
                    continue
                }
                if c.isSpace {
                    if !out.hasSuffix(" ") { out += " " }
                } else {
                    out += ligatures[c.text] ?? c.text
                }
                i += 1
            }
            guard index < block.lines.count - 1 else { break }
            let next = block.lines[index + 1].text.first
            if out.hasSuffix("-"), out.dropLast().last?.isLetter == true, next?.isLowercase == true {
                out.removeLast()
            } else if !out.hasSuffix(" ") {
                out += " "
            }
        }
        return (out.trimmingCharacters(in: .whitespaces), formulas)
    }
}
