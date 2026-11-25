import CoreGraphics
import Foundation

/// What only scans need: their recognised text says nothing of fonts, so formulas and running heads are told by what they
/// say and where they stand.
extension LayoutAnalyzer {
    // MARK: Running heads

    /// A line at the head or foot without its numbers and whatever recognition makes of the spaces.
    static func runningKey(_ text: String) -> String {
        var key = ""
        for c in text.lowercased() {
            if c.isNumber { if key.last != "#" { key.append("#") } } else if c.isLetter { key.append(c) }
        }
        return key
    }

    static func isAtEdge(_ line: LayoutLine, page: CGRect) -> Bool {
        line.rect.minY > page.maxY - page.height * 0.13 || line.rect.maxY < page.minY + page.height * 0.11
    }

    /// The lines several scanned pages have at their head or foot ("Team # 2505199", "Page 3 of 25").
    static func runningLines(_ pages: [(crop: CGRect, lines: [LayoutLine])]) -> Set<String> {
        var counts: [String: Int] = [:]
        for page in pages {
            let keys = page.lines.filter { !$0.isRotated && isAtEdge($0, page: page.crop) && $0.wordCount <= 16 }.map { runningKey($0.text) }
            for key in Set(keys) where key.count >= 3 { counts[key, default: 0] += 1 }
        }
        return Set(counts.filter { $0.value >= 2 && $0.value * 4 >= pages.count }.keys)
    }

    func isRunningLine(_ line: LayoutLine, page: CGRect) -> Bool {
        guard !runningLines.isEmpty, Self.isAtEdge(line, page: page) else { return false }
        let key = Self.runningKey(line.text)
        // (A letter or two may be read differently on one page.)
        return runningLines.contains(key) || key.count >= 5 && runningLines.contains { abs($0.count - key.count) <= 2 && Self.distance($0, key) <= 2 }
    }

    /// How many letters one has to change, add or leave out to get from one text to the other.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 0..<a.count {
            var last = row[0]
            row[0] = i + 1
            for j in 0..<b.count {
                let next = row[j + 1]
                row[j + 1] = a[i] == b[j] ? last : min(last, next, row[j]) + 1
                last = next
            }
        }
        return row[b.count]
    }

    /// Lines at the very top of a scanned page with nothing of the text right under them: what a publisher prints over it.
    func isTopNote(_ line: LayoutLine, page: CGRect, lines: [LayoutLine]) -> Bool {
        let top = page.maxY - page.height * 0.065
        guard line.rect.minY > top else { return false }
        // The lines under it, one by one, to where the group ends.
        var last = line
        for _ in 0..<6 {
            guard let next = lines.filter({ other in
                let drop = last.baseline - other.baseline
                return drop > last.size * 0.5 && drop < last.size * 2 && other.minX < last.maxX && other.maxX > last.minX
            }).max(by: { $0.baseline < $1.baseline }) else { return true }
            if next.rect.minY <= top { return false }
            last = next
        }
        return false
    }

    // MARK: Figures

    /// The drawings over the captions "Figure 3" of a scan: from the caption up to the text above it, what is there is labels,
    /// symbols and lines. (A chart of a few thin lines and dots is no drawing one could tell by its ink.)
    func captionedFigures(_ lines: [LayoutLine], marks: [GraphicMark], bits: [CGRect], tables: [CGRect]) -> [CGRect] {
        let flat = lines.filter { !$0.isRotated }
        guard !flat.isEmpty else { return [] }
        let width = flat.map(\.maxX).max()! - flat.map(\.minX).min()!
        let gutters = Self.gutters(flat, minX: flat.map(\.minX).min()!, width: width)
        let edges = Self.columnEdges(flat, gutters: gutters)
        let prose = flat.filter { Self.sentenceWords($0.text) >= 5 && $0.size >= bodySize * 0.85 }
        var found: [CGRect] = []
        for caption in flat where Self.isCaptionStart(caption.text) && caption.text.range(of: #"^\s*(fig|图|chart|scheme)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            // As wide as the caption, when that is as wide as a column; else as the sentences around it are.
            let mid = (caption.minX + caption.maxX) / 2
            let around = prose.filter { $0.minX < mid && $0.maxX > mid }
            let column = caption.inkRect.width > width * 0.38 && (around.isEmpty || around.contains { abs($0.inkRect.width - caption.inkRect.width) < caption.inkRect.width * 0.08 }) ? (lo: caption.minX, hi: caption.maxX)
                : around.isEmpty ? edges(mid) : (lo: around.map(\.minX).min()!, hi: around.map(\.maxX).max()!)
            let lo = min(column.lo, caption.minX), hi = max(column.hi, caption.maxX)
            var top = Double.infinity, underTable = false
            for line in flat where line.baseline > caption.baseline + caption.size * 0.6 {
                let overlap = min(line.maxX, hi) - max(line.minX, lo)
                guard overlap > min(line.inkRect.width, hi - lo) * 0.3 else { continue }
                let full = line.size >= bodySize * 0.95
                let starts = full && line.minX < lo + line.size * 3 && line.minX > lo - line.size && line.wordCount >= 2 && Self.sentenceWords(line.text) >= 1
                let wide = full && line.minX < lo - line.size * 2
                if wide || Self.sentenceWords(line.text) >= 6 && line.size >= bodySize * 0.88 || starts || Self.isCaptionStart(line.text) || full && Self.continuesText(line, in: flat)
                    || full && Self.isEquationNumber(line.text) {
                    if line.rect.minY < top {
                        top = line.rect.minY
                        underTable = Self.isCaptionStart(line.text) && line.text.range(of: #"^\s*(tab|表)"#, options: [.regularExpression, .caseInsensitive]) != nil
                    }
                }
            }
            guard top.isFinite, top - caption.rect.maxY > bodySize * 4, top - caption.rect.maxY < 700 else { continue }
            let area = CGRect(x: lo, y: caption.rect.maxY, width: hi - lo, height: top - caption.rect.maxY)
            var rect = CGRect.null
            for r in flat.map(\.rect) + bits + marks.map(\.rect) where area.insetBy(dx: -2, dy: 1).contains(r.center) && r.width < (hi - lo) * 1.2 { rect = rect.union(r) }
            rect = rect.intersection(area.insetBy(dx: -4, dy: 0))
            // (Boxes joined by lines look like a table; under a figure's caption they are a drawing, unless a table's caption is over them.)
            if underTable, tables.contains(where: { $0.intersection(rect).area > rect.area * 0.2 }) { continue }
            if !rect.isNull, rect.height > bodySize * 4, rect.width > bodySize * 6 { found.append(rect) }
        }
        return found
    }

    // MARK: Lists

    /// A short line with something as short on its row, read or not: a row of a table without rules, or of a list of
    /// symbols and what they mean.
    func isRowOfList(_ line: LayoutLine) -> Bool {
        // As far as the sentences over and under it reach: what stands in the next column is no part of the row.
        let mid = (line.minX + line.maxX) / 2
        let prose = pageLines.filter { Self.sentenceWords($0.text) >= 4 && $0.minX < mid && $0.maxX > mid && $0.inkRect.width > line.inkRect.width }
        let edge = columnOf?(mid) ?? (lo: line.minX, hi: line.maxX)
        let lo = prose.map(\.minX).min() ?? edge.lo, hi = prose.map(\.maxX).max() ?? edge.hi
        guard line.inkRect.width < (hi - lo) * 0.75 else { return false }
        func onRow(_ y: Double) -> Bool { y > line.baseline - line.size * 0.3 && y < line.baseline + line.size * 0.9 }
        let beside = pageLines.contains { other in
            onRow(other.baseline + other.size * 0.3) && other.visibleCount <= 14 && other.minX > lo - line.size && other.maxX < hi + line.size
                && (other.maxX < line.minX - line.size * 0.8 || other.minX > line.maxX + line.size * 0.8)
        }
        return beside || pageBits.contains { onRow($0.midY) && $0.width < line.size * 4 && $0.height > line.size * 0.25
            && ($0.maxX < line.minX - line.size * 0.8 && $0.maxX > max(line.minX - line.size * 16, lo - line.size)) }
    }

    /// A cell with a word in it, not a symbol misread as a few letters.
    static func isReadCell(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace).map { $0.trimmingCharacters(in: .punctuationCharacters) }
        if StandardCells.isKnown(text) || tokens.contains(where: { $0.unicodeScalars.contains(where: OCRTextLayer.isCJK) }) { return true }
        return tokens.contains { word in
            word.count >= 4 && word.allSatisfy { $0.isLetter || $0 == "-" } || word.count == 3 && word.first!.isUppercase && word.dropFirst().allSatisfy(\.isLowercase)
        }
    }

    // MARK: Formulas

    private static let mathSigns = Set<Character>("=+×÷·∙*/^_<>≤≥≈≠≡∝∞∑∏∫√∂∇∈∉⊂⊆∪∩∀∃→←↔⇒|±−∼~{}")

    /// Words a sentence is made of: three or more letters in lower case that are no function's name; Chinese counts by the
    /// two characters.
    static func sentenceWords(_ text: String) -> Int {
        var count = 0, han = 0
        for token in text.split(whereSeparator: \.isWhitespace) {
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            let letters = word.unicodeScalars.filter { OCRTextLayer.isCJK($0) && $0.properties.isAlphabetic && !(0xFF00...0xFFEF).contains($0.value) }.count
            if letters > 0 {
                han += letters
            } else if word.count >= 3, word.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" }), word.dropFirst().allSatisfy({ !$0.isUppercase }),
                      word.lowercased().contains(where: { "aeiouy".contains($0) }), !MathDetector.operatorNames.contains(word) {
                count += 1
            }
        }
        // (One or two among Latin letters are signs misread.)
        return count + (han >= 4 || count == 0 && han >= 2 && text.count <= han + 2 ? han / 2 : 0)
    }

    static func isEquationNumber(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).range(of: #"^[(（]\s?\d{1,3}([.\-]\d{1,2})?[a-z]?\s?[)）]$"#, options: .regularExpression) != nil
    }

    /// The lines of a scan's displayed formulas: signs and letters with hardly any words, and the pieces of them standing
    /// above, below and beside (limits, numerators, cases). They stay as they are in the picture.
    func scanFormulas(_ lines: [LayoutLine], marks: [GraphicMark], bits: [CGRect], column: (Double) -> (lo: Double, hi: Double)) -> Set<Int> {
        var found: Set<Int> = []
        let flat = lines.indices.filter { !lines[$0].isRotated }
        // Where the text a line stands among starts (formulas come apart in pieces that would look like columns).
        let prose = flat.filter { Self.sentenceWords(lines[$0].text) >= 5 }
        func left(_ line: LayoutLine) -> Double {
            let mid = (line.minX + line.maxX) / 2
            return prose.filter { lines[$0].minX < mid && lines[$0].maxX > mid }.map { lines[$0].minX }.min() ?? column(mid).lo
        }
        func right(_ line: LayoutLine) -> Double {
            let mid = (line.minX + line.maxX) / 2
            return prose.filter { lines[$0].minX < mid && lines[$0].maxX > mid }.map { lines[$0].maxX }.max() ?? column(mid).hi
        }
        // What a formula has besides letters: fraction bars, braces, signs nobody read.
        let pieces = bits.filter { $0.height > 1.2 || $0.width > 4 } + marks.filter { $0.kind != .image && max($0.rect.width, $0.rect.height) < 160 }.map(\.rect)
        func built(_ line: LayoutLine) -> Bool {
            let around = line.rect.insetBy(dx: -line.size * 1.2, dy: -line.size * 0.25)
            return pieces.contains { $0.intersects(around) }
        }
        func signs(_ text: String) -> Int { text.filter { Self.mathSigns.contains($0) }.count }
        for k in flat {
            let line = lines[k], text = line.text.trimmingCharacters(in: .whitespaces)
            if Self.isListItem(text), Self.sentenceWords(text) > 0 { continue }
            let words = Self.sentenceWords(text)
            // Displayed: set in from where the column's text starts.
            let set = line.minX > left(line) + line.size * 1.2
            let number = text.range(of: #"[(（]\s?\d{1,3}([.\-]\d{1,2})?[a-z]?\s?[)）]$"#, options: .regularExpression) != nil
            let beside = flat.contains { j in
                j != k && Self.isEquationNumber(lines[j].text) && lines[j].minX > line.maxX
                    && lines[j].baseline + lines[j].size * 0.3 > line.rect.minY - line.size * 0.2 && lines[j].baseline + lines[j].size * 0.3 < line.rect.maxY + line.size * 0.2
            }
            let equals = text.contains("=") || text.contains("≤") || text.contains("≥") || text.contains("≈")
            if Self.isEquationNumber(text), set { found.insert(k); continue }
            // "y = ax + b (3)", "Med = …"
            if equals, words <= 1 || words <= 3 && set && (number || beside) { found.insert(k); continue }
            if set, beside, words <= 2 || signs(text) >= 1 && words <= 4 { found.insert(k); continue }
            if set, number, signs(text) >= 1, words <= 3 { found.insert(k); continue }
            if set, signs(text) >= 2, words == 0 { found.insert(k); continue }
            // Set in from both sides.
            guard set, line.maxX < right(line) - line.size * 1.2, !Self.isCaptionStart(text) else { continue }
            let tokens = text.split(whereSeparator: \.isWhitespace)
            if words <= 3, tokens.prefix(3).contains(where: { $0.contains("=") || $0.contains("≤") || $0.contains("≥") }), words * 5 <= line.visibleCount { found.insert(k); continue }
            if let first = tokens.first?.trimmingCharacters(in: .punctuationCharacters), MathDetector.operatorNames.contains(first), words <= 2, built(line) { found.insert(k); continue }
            if words == 0, built(line), text.contains(where: \.isLetter), tokens.count <= 3 || signs(text) >= 1 || text.contains(where: \.isNumber) { found.insert(k); continue }
        }
        guard !found.isEmpty else { return found }
        // Pieces around them.
        var grew = true
        while grew {
            grew = false
            for k in flat where !found.contains(k) {
                let line = lines[k], text = line.text
                guard Self.sentenceWords(text) <= 1, line.wordCount <= 6, line.visibleCount <= 32, !Self.isListItem(text) else { continue }
                let set = line.minX > left(line) + line.size * 1.2
                guard set else { continue }
                let near = found.contains { j in
                    let other = lines[j]
                    let reach = max(other.size, line.size)
                    let apart = max(other.rect.minY - line.rect.maxY, line.rect.minY - other.rect.maxY)
                    let aside = max(other.minX - line.maxX, line.minX - other.maxX)
                    return apart < reach * 0.6 && aside < reach * 2.5
                }
                // The heading or caption right under a formula is no piece of it.
                if near, !line.font.isBold, !Self.isCaptionStart(text) { found.insert(k); grew = true }
            }
        }
        return found
    }
}
