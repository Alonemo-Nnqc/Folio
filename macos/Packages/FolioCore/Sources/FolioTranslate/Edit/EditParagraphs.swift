import Foundation

/// The page's blocks as the PDF editor offers them (EDIT-01): one block per paragraph. The layout analysis is tuned for
/// translation, which tolerates blocks that run two paragraphs together or stop a line short; editing does not, so its
/// blocks are cut and joined again here:
///
/// - cut before a line that starts a paragraph (set in by a first-line indent after a line that stops short), before a
///   line far below the one before it (a page number swept into a column), and after a bold or larger line that stands
///   on its own (a heading run together with the text under it);
/// - joined when a block goes on from the one before it: the same column and size, the next baseline one line below,
///   its first line not set in, and the line before it either full or not the end of a sentence (a paragraph broken at a
///   line that starts with "Fig. 1.", a caption's second line, a paragraph's last line left on its own).
///
/// The Windows editor does the same (Folio.Core Translate/Edit/EditParagraphs.cs).
enum EditParagraphs {
    /// A space between two CJK characters (or their punctuation) taken out: where a line broke inside Chinese text.
    static func closingCJKBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<=[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u3000-\u303F\uFF00-\uFFEF]) (?=[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\u3000-\u303F\uFF00-\uFFEF])"#,
                                  with: "", options: .regularExpression)
    }

    /// Whether a line reads as words rather than math: two Chinese characters, or two words of letters.
    static func isWordy(_ line: LayoutLine) -> Bool {
        let text = line.text
        if text.unicodeScalars.filter({ (0x4E00...0x9FFF).contains($0.value) }).count >= 2 { return true }
        return text.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 3 }.count >= 2
    }

    static func isCaptionStart(_ line: LayoutLine) -> Bool {
        let start = line.text.trimmingCharacters(in: .whitespaces)
        return ["图", "表", "Fig", "Table", "TABLE", "FIG"].contains { start.hasPrefix($0) }
    }

    static func refine(_ blocks: [LayoutBlock]) -> [LayoutBlock] {
        // Text the analysis took for a formula (a caption full of labels, a line with a citation in superscript) is
        // text to edit: a formula is mostly symbols, not words.
        // A caption laid over or under its figure is a caption, not the figure's labels.
        let blocks = blocks.map { block -> LayoutBlock in
            guard block.kind == .formula || block.kind == .figure, block.lines.allSatisfy(isWordy) else { return block }
            var text = block
            if isCaptionStart(block.lines[0]) { text.kind = .caption } else if block.kind == .formula { text.kind = .paragraph }
            return text
        }
        return join(blocks.flatMap(cut))
    }

    /// Kinds whose lines are never cut apart or joined to others.
    private static let fixed: Set<BlockKind> = [.formula, .figure, .tableCell, .rotated, .code, .header]

    private static let terminal: Set<Character> = [".", "。", "!", "！", "?", "？", ":", "：", ";", "；", "…"]

    private static func endsSentence(_ line: LayoutLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        // A citation or a closing bracket after the full stop: "… problems [7,8]." / "(see Fig. 2.)"
        let stripped = text.replacingOccurrences(of: #"[\]\)）」”"'\s\d,\-–]+$"#, with: "", options: .regularExpression)
        guard let last = (stripped.isEmpty ? text : stripped).last else { return false }
        return terminal.contains(last)
    }

    // MARK: Cutting

    static func cut(_ block: LayoutBlock) -> [LayoutBlock] {
        guard block.lines.count > 1, !fixed.contains(block.kind) else { return [block] }
        let lines = block.lines
        let size = block.size
        let pitch = block.pitch
        let left = lines.map(\.minX).min()!, right = lines.map(\.maxX).max()!
        let centered = block.isCentered
        // A list item's lines all set in after its bullet; its first line runs full. (A short first line above set-in
        // text is a heading over a paragraph instead.)
        let hanging = block.hangingIndent > 0 && lines[0].maxX >= right - size * 1.5
        var pieces: [[LayoutLine]] = [[lines[0]]]
        for i in 1..<lines.count {
            let previous = lines[i - 1], line = lines[i]
            var starts = false
            // Far below the line before: not the same paragraph (a page number, a footnote swept in).
            if previous.baseline - line.baseline > max(pitch * 1.75, size * 2.4) { starts = true }
            // Further below than the paragraph's lines are apart, after a line that ends a sentence: the next paragraph
            // (or a heading) set off by space rather than an indent.
            if !starts, previous.baseline - line.baseline > pitch * 1.35, endsSentence(previous) || previous.maxX < right - size * 1.5 { starts = true }
            // A short line in another size: a page number or a footnote mark swept into the column.
            if !starts, abs(previous.size - line.size) > 0.8, line.maxX - line.minX < (right - left) * 0.3 { starts = true }
            // A heading on its own line above the text: bold or larger, short, then plain text.
            if !starts, previous.size - line.size > 0.8 || (previous.font.isBold && !line.font.isBold),
               previous.maxX < right - size * 2 || pieces.last!.count == 1 && previous.font.isBold {
                starts = true
            }
            // Centred lines in another style: authors in italics over their affiliations, a name over its address.
            if !starts, centered, previous.font.isItalic != line.font.isItalic || previous.font.isBold != line.font.isBold { starts = true }
            // A new paragraph: set in after a line that stops short (or ends a sentence).
            if !starts, !centered {
                let indent = line.minX - left
                let short = previous.maxX < right - size * 1.5
                // Not a list item's lines, all set in after its bullet (a hanging indent).
                if indent > size * 0.6, indent < size * 4.5, short || endsSentence(previous), !hanging,
                   abs(previous.minX - left) < size * 0.6 || short {
                    starts = true
                }
            }
            if starts { pieces.append([line]) } else { pieces[pieces.count - 1].append(line) }
        }
        guard pieces.count > 1 else { return [block] }
        return pieces.map { piece in
            var part = block
            part.lines = piece
            // A short bold line cut off the top reads as a heading.
            if piece.count == 1, piece[0].font.isBold, piece[0].maxX < right - size * 2, block.kind == .paragraph { part.kind = .heading }
            return part
        }
    }

    // MARK: Joining

    /// A title or heading set over two lines: the same kind, size and weight, one line below, centred alike or flush
    /// alike, the first line not ending a sentence.
    static func continuesTitle(_ a: LayoutBlock, with b: LayoutBlock) -> Bool {
        guard a.kind == b.kind, a.kind == .title || a.kind == .heading, let last = a.lines.last, let first = b.lines.first else { return false }
        let size = a.size
        guard abs(size - b.size) <= 0.5, last.font.isBold == first.font.isBold, last.font.isItalic == first.font.isItalic, !endsSentence(last) else { return false }
        let gap = last.baseline - first.baseline
        guard gap > size * 0.9, gap < size * 1.6 else { return false }
        let ra = a.rect, rb = b.rect
        let centred = abs(ra.midX - rb.midX) < size
        let flush = abs(ra.minX - rb.minX) < size * 0.5
        return centred || flush
    }

    private static let joinable: Set<BlockKind> = [.paragraph, .caption, .reference, .other, .author]

    /// Each block that goes on from another (wherever reading order put it: a paragraph's last line can come first)
    /// joins it; again until nothing changes.
    static func join(_ blocks: [LayoutBlock]) -> [LayoutBlock] {
        var result = blocks
        var changed = true
        while changed {
            changed = false
            outer: for b in result.indices {
                for a in result.indices where a != b && continues(result[a], with: result[b]) {
                    result[a].lines += result[b].lines
                    result.remove(at: b)
                    changed = true
                    break outer
                }
            }
        }
        return result
    }

    static func continues(_ a: LayoutBlock, with b: LayoutBlock) -> Bool {
        if continuesTitle(a, with: b) { return true }
        // A one-line "formula" that is mostly words (a paragraph's last line with a citation in superscript) goes on too.
        // (Chinese words beside a superscript can be taken for math, so any CJK counts as words.)
        let wordyFormula = b.kind == .formula && b.lines.count == 1
            && (b.lines[0].mathRatio < 0.5 || b.lines[0].text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
            && b.rect.width < a.rect.width * 0.5
        // A caption's next line, taken for part of the figure.
        let captionLine = a.kind == .caption && b.kind == .figure && b.lines.allSatisfy(isWordy)
        guard joinable.contains(a.kind), joinable.contains(b.kind) || wordyFormula || captionLine, let last = a.lines.last, let first = b.lines.first,
              !last.isRotated, !first.isRotated else { return false }
        let size = a.size
        guard abs(size - b.size) <= 0.6, last.font.isBold == first.font.isBold else { return false }
        // The same column: they overlap across most of the narrower one.
        let ra = a.rect, rb = b.rect
        let overlap = min(ra.maxX, rb.maxX) - max(ra.minX, rb.minX)
        guard overlap > min(ra.width, rb.width) * 0.7 else { return false }
        // The next line, one line below.
        let pitch = a.lines.count > 1 ? a.pitch : (b.lines.count > 1 ? b.pitch : size * 1.25)
        let gap = last.baseline - first.baseline
        guard gap > pitch * 0.6, gap < pitch * 1.35 else { return false }
        // Not a new paragraph: its first line is not set in, and the line before is full or mid-sentence.
        let left = a.lines.map(\.minX).min()!
        guard first.minX - left < size * 0.5 else { return false }
        let right = max(ra.maxX, rb.maxX)
        return last.maxX >= right - size * 1.5 || !endsSentence(last)
    }
}
