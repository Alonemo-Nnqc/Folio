import CoreGraphics
import Foundation
import PDFKit

/// Finds the blocks of text on each page and decides which of them to translate.
///
/// Works from exact geometry rather than a learned model: glyph positions (PDFKit), the fonts and positions of
/// text operators, and the bounds of images and vector paths (`ContentInterpreter`). Drawings are found from their
/// paths and images, so labels inside figures stay untouched; tables from their rules, so each cell is handled on
/// its own.
struct LayoutAnalyzer {
    struct Options: Sendable {
        var translateTables = true
        var translateReferences = false
    }

    var options = Options()

    /// State carried from page to page.
    private var inReferences = false
    private(set) var bodySize = 10.0
    /// Where the text of the column at a position starts and ends, on the page being analysed.
    private var columnOf: ((Double) -> (lo: Double, hi: Double))?
    /// How wide the page's lines of body text usually are.
    private var typicalWidth = Double.infinity
    /// Horizontal rules of the page being analysed.
    private var pageRules: [CGRect] = []
    /// The page being analysed.
    private var currentPage = 0

    init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Document

    /// Analyses `pages` (1-based numbers) of the document.
    mutating func analyze(document: PDFDocument, cgDocument: CGPDFDocument, pages: [Int]) -> [PageLayout] {
        var prepared: [(Int, ContentInterpreter, [PageChar])] = []
        var sizeCounts: [Double: Int] = [:]
        // Pages before the selection too: the body size is the document's, and whether a page is in the references
        // depends on the pages before it.
        let selected = Set(pages)
        let through = min(pages.max() ?? 0, cgDocument.numberOfPages)
        for number in through > 0 ? Array(1...through) : [] {
            guard let cgPage = cgDocument.page(at: number), let page = document.page(at: number - 1) else { continue }
            let interpreter = ContentInterpreter()
            interpreter.run(page: cgPage)
            let chars = PageText.characters(of: page, interpreter: interpreter)
            for c in chars where !c.isSpace && !c.isNewline && !c.isRotated {
                sizeCounts[(c.size * 2).rounded() / 2, default: 0] += 1
            }
            prepared.append((number, interpreter, chars))
        }
        bodySize = sizeCounts.max { $0.value < $1.value }?.key ?? 10
        inReferences = false
        return prepared.compactMap { number, interpreter, chars in
            let layout = analyzePage(number: number, cgPage: cgDocument.page(at: number)!, interpreter: interpreter, chars: chars)
            return selected.contains(number) ? layout : nil
        }
    }

    // MARK: Page

    mutating func analyzePage(number: Int, cgPage: CGPDFPage, interpreter: ContentInterpreter, chars rawChars: [PageChar]) -> PageLayout {
        let media = cgPage.getBoxRect(.mediaBox)
        var crop = cgPage.getBoxRect(.cropBox).intersection(media)
        if crop.isNull || crop.width < 1 { crop = media }
        currentPage = number
        var chars = rawChars
        MathDetector.mark(&chars)
        let links = PageLinks.links(of: cgPage)
        PageLinks.assign(links, to: &chars, page: crop)

        var marks = interpreter.marks.filter { !$0.isWhite && $0.rect.width * $0.rect.height < crop.width * crop.height * 0.6 }
        // Regions first, from lines not yet split into cells; then the final lines.
        var lines = buildLines(chars, tables: [], pageWidth: crop.width)
        // Small pictures among the words of a line (an emoji, an icon) are part of it, not drawings.
        let icons = Self.inlineIcons(interpreter: interpreter, lines: lines)
        if !icons.isEmpty {
            Self.insert(icons, into: &chars)
            let taken = Set(icons.map { interpreter.marks[$0.mark].location })
            marks.removeAll { taken.contains($0.location) }
        }
        // A rule right under words is an underline (a link in the references), not part of a table.
        let rules = marks.filter { ($0.kind == .fill || $0.kind == .stroke) && $0.rect.height < 2.5 && $0.rect.width > 30 }.map(\.rect).filter { rule in
            !lines.contains { line in
                let below = line.baseline - rule.midY
                return below > -0.5 && below < line.size * 0.17 && rule.minX >= line.minX - 1 && rule.maxX <= line.maxX + 1
            }
        }
        var tables = Self.tableFrames(rules: rules, lines: lines).map { Self.trimCaptions($0, lines: lines) }.filter { isTable($0, lines: lines, marks: marks) }
        let figures = figureRegions(marks: marks, lines: lines, tables: tables, page: crop)
        tables.removeAll { table in figures.contains { $0.intersection(table).area > table.area * 0.4 } }
        let gutters = tables.map { Self.columnGutters(in: $0, lines: lines) }
        lines = buildLines(chars, tables: tables, gutters: gutters, pageWidth: crop.width).map(Self.markScripts)
        Self.joinWordFractions(&lines, marks: marks)
        Self.markChips(&lines, marks: marks)
        lines = Self.readingOrder(lines)
        // Algorithms are framed by rules like tables, but their lines are code: keep them as they are.
        var algorithms: [CGRect] = []
        tables.removeAll { table in
            let first = lines.filter { table.insetBy(dx: -1, dy: -bodySize * 1.6).contains($0.rect.center) }.max { $0.baseline < $1.baseline }
            guard let first, Self.isAlgorithmStart(first.text) else { return false }
            algorithms.append(table)
            return true
        }

        // Equation numbers set apart at the margin mark the line they sit on as an equation.
        let numbers = lines.filter { $0.text.trimmingCharacters(in: .whitespaces).range(of: #"^\(\d{1,3}[a-z]?\)$"#, options: .regularExpression) != nil }
        var equations: Set<Int> = []
        let flat = lines.filter { !$0.isRotated }
        let columnGutters = flat.isEmpty ? [] : Self.gutters(flat, minX: flat.map(\.minX).min()!, width: flat.map(\.maxX).max()! - flat.map(\.minX).min()!)
        for number in numbers {
            for (k, line) in lines.enumerated() where line.maxX < number.minX && abs(line.baseline - number.baseline) < number.size * 0.6 {
                // Only in the number's own column.
                if columnGutters.contains(where: { line.maxX <= $0.upperBound && number.minX >= $0.lowerBound }) { continue }
                // An equation in text type ("Cable+SC+MMH = 5*24,000  (8)"): an equals sign and hardly any prose words.
                let prose = line.text.split(separator: " ").filter { $0.count >= 3 && $0.allSatisfy { $0.isLowercase } }.count
                if Self.textWords(line) <= 3 || line.text.contains("=") && prose <= 1 { equations.insert(k) }
            }
        }
        // Rows of a display set off from the text around them ("φ(u, v),  otherwise" under "0,  if I(u, v) = 0").
        for (k, line) in lines.enumerated() where !equations.contains(k) && line.mathRatio >= 0.3 && Self.textWords(line) <= 2 {
            let setOff = lines.contains { other in
                other.inkRect.width > line.inkRect.width + other.size * 4 && abs(other.baseline - line.baseline) < other.size * 4
                    && other.minX + other.size * 1.5 < line.minX && line.maxX < other.maxX - other.size * 1.5
            }
            let firstIsMath = line.chars.first { !$0.isSpace }?.isMath == true
            if setOff, firstIsMath { equations.insert(k) }
        }
        Self.growDisplays(&equations, lines: lines, gutters: columnGutters, bodySize: bodySize)
        let pseudocode = Self.pseudocodeLines(lines)
        let edges = Self.columnEdges(lines, gutters: columnGutters)
        pageRules = marks.filter { $0.kind != .image && $0.rect.height < 2.5 && $0.rect.width > 8 }.map(\.rect)
        columnOf = edges
        let bodyWidths = flat.filter { abs($0.size - bodySize) < bodySize * 0.12 }.map(\.inkRect.width).sorted()
        typicalWidth = bodyWidths.count >= 8 ? bodyWidths[bodyWidths.count * 4 / 5] : .infinity
        // The further lines of a caption that a drawing's area took in ("TABLE 8" / "Ablation Study …", or a narrow caption
        // under a narrow figure): the same type, right under it, starting where it starts or centred with it.
        var captionLines: Set<Int> = []
        for (k, line) in lines.enumerated() where Self.isCaptionStart(line.text) {
            var last = line
            var claimed = 0
            while claimed < 12, let j = lines.indices.first(where: { j in
                let next = lines[j]
                let drop = last.baseline - next.baseline
                return j != k && !captionLines.contains(j) && drop > last.size * 0.5 && drop < last.size * 1.7 && next.font == line.font
                    && abs(next.size - last.size) < last.size * 0.1 && !Self.isCaptionStart(next.text)
                    && (abs(next.minX - line.minX) < line.size || abs((next.minX + next.maxX) - (line.minX + line.maxX)) < line.size * 4)
                    && figures.contains { $0.contains(next.rect.center) }
            }) {
                captionLines.insert(j)
                last = lines[j]
                claimed += 1
            }
        }
        // A paper's title stays text, whatever drawing is beside it (a journal's banner, a badge).
        for (k, line) in lines.enumerated() where number == 1 && line.size >= bodySize * 1.25 && Self.textWords(line) >= 3 { captionLines.insert(k) }

        // Lines that are not running text.
        var blocks: [LayoutBlock] = []
        var flowing: [LayoutLine] = []
        for (k, line) in lines.enumerated() {
            let center = line.rect.center
            if line.isRotated {
                blocks.append(LayoutBlock(kind: .rotated, lines: [line], translate: false))
            } else if algorithms.contains(where: { $0.insetBy(dx: -1, dy: -2).contains(center) }) || (Self.isAlgorithmStart(line.text)
                        && algorithms.contains(where: { $0.insetBy(dx: -1, dy: -bodySize * 1.6).contains(center) })) {
                blocks.append(LayoutBlock(kind: .code, lines: [line], translate: false))
            } else if figures.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(center) }) && !Self.isCaptionStart(line.text) && !captionLines.contains(k) {
                blocks.append(LayoutBlock(kind: .figure, lines: [line], translate: false))
            } else if pseudocode.contains(k) {
                blocks.append(LayoutBlock(kind: .code, lines: [line], translate: false))
            } else if tables.contains(where: { $0.insetBy(dx: -1, dy: -2).contains(center) }) {
                let translate = options.translateTables && Self.hasWords(line.text) && !line.font.isMonospace && Self.isCellText(line.text)
                blocks.append(LayoutBlock(kind: .tableCell, lines: [line], translate: translate))
            } else if isMarginal(line, page: crop, lines: lines) {
                blocks.append(LayoutBlock(kind: .header, lines: [line], translate: false))
            } else if isDisplayMath(line) || equations.contains(k) || numbers.contains(where: { $0.inkRect == line.inkRect }) {
                blocks.append(LayoutBlock(kind: .formula, lines: [line], translate: false))
            } else {
                flowing.append(line)
            }
        }

        // Running text → paragraphs, headings, captions. A line continues the latest block it fits under; side by side
        // blocks (sub-captions, cells set as text) are read line by line across, so a few earlier blocks are tried too.
        var textBlocks: [LayoutBlock] = []
        for line in flowing {
            if let k = textBlocks.indices.reversed().prefix(12).first(where: { canJoin(textBlocks[$0], line) }) {
                textBlocks[k].lines.append(line)
            } else {
                textBlocks.append(LayoutBlock(kind: .paragraph, lines: [line], translate: true))
            }
        }
        // Text that narrows beside a table or drawing (or widens past it) is laid out in separate pieces.
        let beside = tables + figures + marks.filter { $0.rect.width * $0.rect.height > 20 }.map(\.rect)
            + blocks.filter { !$0.translate }.map(\.rect)
        textBlocks = textBlocks.flatMap { block in
            let others = textBlocks.filter { $0.rect != block.rect }.map(\.rect)
            return Self.splitBesideObstacles(block, obstacles: beside + others)
        }
        // Shaded boxes (a journal's banner) do not hold the paper's title.
        let boxes = marks.filter { $0.kind == .fill && $0.rect.width * $0.rect.height > 3000 }.map(\.rect)
        classify(&textBlocks, page: number, crop: crop, boxes: boxes)
        let textLeft = flat.map(\.minX).min() ?? crop.minX, textRight = flat.map(\.maxX).max() ?? crop.maxX
        for k in textBlocks.indices {
            let r = textBlocks[k].rect, size = textBlocks[k].size
            let column = edges(r.midX)
            let inColumn = abs(r.midX - (column.lo + column.hi) / 2) < size * 0.8 && r.minX - column.lo > size * 1.5
            let onPage = abs(r.midX - (textLeft + textRight) / 2) < size * 0.8 && r.minX - textLeft > size * 1.5
            textBlocks[k].centeredInColumn = inColumn || onPage
        }
        blocks.append(contentsOf: textBlocks)

        Self.mergeInterleaved(&blocks)
        Self.absorbStrays(&blocks)
        Self.mergeTableCells(&blocks, tables: tables, rules: rules)
        let graphics = marks.map(\.rect) + figures
        return PageLayout(number: number, mediaBox: media, cropBox: crop, blocks: blocks, figures: figures, tables: tables,
                          graphics: graphics, runs: interpreter.runs, glyphs: interpreter.glyphs, links: links)
    }

    // MARK: Inline pictures

    /// Pictures the size of a character on a line with words beside them, and the character standing in for each.
    static func inlineIcons(interpreter: ContentInterpreter, lines: [LayoutLine]) -> [(mark: Int, anchor: PageChar?, char: PageChar)] {
        var result: [(mark: Int, anchor: PageChar?, char: PageChar)] = []
        let flat = lines.filter { !$0.isRotated && $0.wordCount >= 5 }
        var shapes: [(result: Int, line: Double)] = []
        for (index, mark) in interpreter.marks.enumerated() {
            let isImage = mark.kind == .image && interpreter.images[index] != nil
            let isShape = mark.kind == .fill && !mark.isWhite && mark.hasCurves && mark.segmentCount >= 6 && interpreter.paths[index] != nil
            guard isImage || isShape else { continue }
            let r = mark.rect
            let candidates = flat.filter { line in
                r.width <= line.size * 2.6 && r.height <= line.size * 1.9 && r.height >= line.size * 0.5
                    && r.midY > line.baseline - line.size * 0.35 && r.midY < line.baseline + line.size * 0.85
                    && line.chars.contains { !$0.isSpace && ($0.rect.maxX <= r.midX && r.minX - $0.rect.maxX < line.size * 1.5 || $0.rect.minX >= r.midX && $0.rect.minX - r.maxX < line.size * 1.5) }
            }
            guard let line = candidates.min(by: { abs($0.baseline + $0.size * 0.3 - r.midY) < abs($1.baseline + $1.size * 0.3 - r.midY) }),
                  let template = line.chars.first(where: { !$0.isSpace }) else { continue }
            var char = template
            char.text = "\u{FFFC}"
            char.rect = CGRect(x: r.minX, y: line.baseline - line.size * 0.22, width: r.width, height: line.size * 1.2)
            char.ink = r
            char.size = line.size
            char.baseline = line.baseline
            char.isMath = true
            char.isScript = false
            char.glyphs = []
            char.run = nil
            char.link = nil
            char.linkTarget = nil
            char.icon = index
            if isShape { shapes.append((result.count, line.baseline)) }
            result.append((index, line.chars.last { !$0.isSpace && $0.rect.maxX <= r.midX }, char))
        }
        // Many small shapes on a line, or on the page, are not icons: text set as outlines, or marks of a drawing.
        var perLine: [Double: Int] = [:]
        for shape in shapes { perLine[shape.line, default: 0] += 1 }
        let tooMany = shapes.count > 12 ? Set(shapes.map(\.result)) : Set(shapes.filter { perLine[$0.line]! > 3 }.map(\.result))
        return result.indices.filter { !tooMany.contains($0) }.map { result[$0] }
    }

    /// Puts the stand-ins among the characters, each after the one to its left in the line.
    static func insert(_ icons: [(mark: Int, anchor: PageChar?, char: PageChar)], into chars: inout [PageChar]) {
        for icon in icons {
            let place = icon.anchor.flatMap { anchor in chars.firstIndex { !$0.isSpace && !$0.isNewline && $0.glyphs == anchor.glyphs && $0.icon == anchor.icon } }
            if let place {
                chars.insert(icon.char, at: place + 1)
            } else if let first = chars.firstIndex(where: { !$0.isSpace && !$0.isNewline && abs($0.baseline - icon.char.baseline) < icon.char.size * 0.3 && $0.rect.minX >= icon.char.rect.minX }) {
                chars.insert(icon.char, at: first)
            }
        }
    }

    // MARK: Displays

    /// Where each column's text starts and ends, for telling lines set off from it.
    private static func columnEdges(_ lines: [LayoutLine], gutters: [ClosedRange<Double>]) -> (Double) -> (lo: Double, hi: Double) {
        let flat = lines.filter { !$0.isRotated }
        guard let minX = flat.map(\.minX).min(), let maxX = flat.map(\.maxX).max() else { return { _ in (0, 0) } }
        var bounds = [minX]
        for g in gutters.sorted(by: { $0.lowerBound < $1.lowerBound }) { bounds.append((g.lowerBound + g.upperBound) / 2) }
        bounds.append(maxX)
        var edges: [(from: Double, to: Double, lo: Double, hi: Double)] = []
        for (a, b) in zip(bounds, bounds.dropFirst()) {
            let inside = flat.filter { $0.minX >= a - 2 && $0.maxX <= b + 2 && $0.inkRect.width > (b - a) * 0.4 }
            // The edges most long lines share.
            let los = inside.map(\.minX).sorted(), his = inside.map(\.maxX).sorted()
            edges.append((a, b, los.isEmpty ? a : los[los.count / 5], his.isEmpty ? b : his[his.count * 4 / 5]))
        }
        return { x in
            let column = edges.first { x >= $0.from && x <= $0.to } ?? edges.last!
            return (column.lo, column.hi)
        }
    }

    /// Words on a coloured chip inside a line (a class name set on its colour): chip and word move together, as a formula.
    static func markChips(_ lines: inout [LayoutLine], marks: [GraphicMark]) {
        for mark in marks where mark.kind == .fill && !mark.isWhite && !mark.hasCurves && mark.rect.height < 40 && mark.rect.width > 4 {
            let box = mark.rect
            for k in lines.indices where !lines[k].isRotated {
                let line = lines[k]
                guard box.height > line.size * 0.7, box.height < line.size * 2, box.width < line.inkRect.width * 0.5, line.visibleCount >= 20,
                      box.minY <= line.baseline, box.maxY >= line.baseline + line.size * 0.5 else { continue }
                for c in line.chars.indices where !line.chars[c].isSpace && box.contains(CGPoint(x: line.chars[c].rect.midX, y: line.baseline + line.size * 0.25)) {
                    lines[k].chars[c].isMath = true
                }
            }
        }
    }

    /// Words set as a fraction inside a line of text ("Foreground Pixels" over "Total Pixels"): both go into the line,
    /// as one formula.
    static func joinWordFractions(_ lines: inout [LayoutLine], marks: [GraphicMark]) {
        for mark in marks where mark.kind != .image && mark.rect.height < 1.5 && mark.rect.width > 6 && mark.rect.width < 200 {
            let rule = mark.rect
            func holds(_ line: LayoutLine) -> Bool { line.minX >= rule.minX - 1.5 && line.maxX <= rule.maxX + 1.5 && line.inkRect.width > rule.width * 0.5 && !line.isRotated }
            guard let upper = lines.firstIndex(where: { holds($0) && $0.baseline > rule.midY && $0.baseline - rule.midY < $0.size * 1.1 }),
                  let lower = lines.firstIndex(where: { holds($0) && $0.baseline < rule.midY && rule.midY - $0.baseline < $0.size * 1.3 }), upper != lower else { continue }
            let size = lines[upper].size
            // Beside it, a bigger line whose baseline runs between the two.
            let hosts = lines.indices.filter { k in
                k != upper && k != lower && !lines[k].isRotated && lines[k].size >= size * 1.05 && abs(lines[k].baseline + lines[k].size * 0.25 - rule.midY) < lines[k].size * 0.5
                    && (lines[k].maxX <= rule.minX + 1 && rule.minX - lines[k].maxX < lines[k].size * 1.5 || lines[k].minX >= rule.maxX - 1 && lines[k].minX - rule.maxX < lines[k].size * 1.5)
            }
            guard !hosts.isEmpty else { continue }
            var parts = lines[upper].chars + lines[lower].chars
            for c in parts.indices where !parts[c].isSpace { parts[c].isMath = true }
            for k in hosts { parts += lines[k].chars }
            guard let joined = makeLine(parts) else { continue }
            let gone = Set(hosts + [upper, lower])
            let keep = hosts.min()!
            lines[keep] = joined
            lines = lines.indices.filter { $0 == keep || !gone.contains($0) }.map { lines[$0] }
        }
    }

    /// Lines belonging to a displayed formula, from the lines already known to: rows set off from the text like them
    /// ("0,  otherwise"), words set as a fraction ("Foreground Pixels" over "Total Pixels"), a denominator or a
    /// limit under them. New displays are found too: set off on both sides, with hardly any prose.
    static func growDisplays(_ equations: inout Set<Int>, lines: [LayoutLine], gutters: [ClosedRange<Double>], bodySize: Double) {
        let edges = columnEdges(lines, gutters: gutters)
        func prose(_ line: LayoutLine) -> Int {
            var count = 0, run = 0
            for c in line.chars {
                if !c.isMath, !c.isSpace, c.text.first?.isLowercase == true {
                    run += 1
                } else {
                    if run >= 3 { count += 1 }
                    run = 0
                }
            }
            return count + (run >= 3 ? 1 : 0)
        }
        func isSetOff(_ line: LayoutLine) -> Bool {
            let column = edges((line.minX + line.maxX) / 2)
            return line.minX - column.lo > line.size && column.hi - line.maxX > line.size
        }
        for (k, line) in lines.enumerated() where !line.isRotated && !equations.contains(k) && !isCaptionStart(line.text) {
            guard isSetOff(line), line.visibleCount >= 3, prose(line) <= 2 else { continue }
            if line.mathRatio >= 0.4 || (line.mathRatio >= 0.15 && line.text.contains("=") && prose(line) <= 1) { equations.insert(k) }
        }
        var changed = true
        var rounds = 0
        while changed, rounds < 8 {
            changed = false
            rounds += 1
            for (k, line) in lines.enumerated() where !line.isRotated && !equations.contains(k) && !isCaptionStart(line.text) {
                let column = edges((line.minX + line.maxX) / 2)
                guard line.minX - column.lo > line.size * 0.5 else { continue }
                let tiny = line.visibleCount <= 4 && line.text.last.map { !".:;,".contains($0) } ?? true
                let row = isSetOff(line) && prose(line) <= 3 && !(line.text.hasSuffix(".") && prose(line) >= 2)
                guard tiny || row else { continue }
                let next = equations.contains { e in
                    let other = lines[e]
                    let drop = abs(other.baseline - line.baseline)
                    let shared = min(other.maxX, line.maxX + line.size) - max(other.minX, line.minX - line.size)
                    return drop < max(other.size, line.size) * 2.2 && shared >= line.inkRect.width * 0.8
                }
                if next {
                    equations.insert(k)
                    changed = true
                }
            }
        }
    }

    /// Lines of pseudocode: three or more lines numbered in sequence, some of them reading like code; with the lines
    /// between them, and the "Input:" and "Output:" lines above them.
    static func pseudocodeLines(_ lines: [LayoutLine]) -> Set<Int> {
        func number(_ line: LayoutLine) -> Int? {
            guard let match = line.text.firstMatch(of: /^\s*(\d{1,3})[:.)]?\s/) else { return nil }
            return Int(match.output.1)
        }
        func readsLikeCode(_ line: LayoutLine) -> Bool {
            let text = line.text.replacingOccurrences(of: #"^\s*\d{1,3}[:.)]?\s*"#, with: "", options: .regularExpression)
            return text.range(of: #"^(for|foreach|if|else|elif|while|repeat|until|end|return|function|procedure|def|break|continue)\b|(\bdo|\bthen)\s*;?\s*$|←|:=|▷"#, options: .regularExpression) != nil
        }
        var result: Set<Int> = []
        var k = 0
        while k < lines.count {
            guard !lines[k].isRotated, let start = number(lines[k]) else { k += 1; continue }
            var expected = start + 1
            var last = k, numbered = [k]
            var j = k + 1
            while j < lines.count, j - last <= 6, !lines[j].isRotated {
                let drop = lines[last].baseline - lines[j].baseline
                guard drop > 0, drop < lines[last].size * Double(3 + (j - last)), abs(lines[j].size - lines[k].size) < lines[k].size * 0.3 else { break }
                if number(lines[j]) == expected {
                    numbered.append(j)
                    last = j
                    expected += 1
                }
                j += 1
            }
            let evidence = (k...last).filter { readsLikeCode(lines[$0]) }.count
            // Right under an "Algorithm 1" heading, numbered lines need no more proof.
            let underHeading = lines[max(0, k - 6)..<k].contains { isAlgorithmStart($0.text) && $0.baseline > lines[k].baseline && $0.baseline - lines[k].baseline < lines[k].size * 10 }
            if numbered.count >= 2 && underHeading || numbered.count >= 3 && (evidence >= 2 || evidence * 4 >= numbered.count) {
                result.formUnion(k...last)
                // What comes before the first step: from under the heading, or from its "Input:" line.
                if let heading = (max(0, k - 8)..<k).last(where: { isAlgorithmStart(lines[$0].text) }) {
                    if heading + 1 < k { result.formUnion((heading + 1)..<k) }
                } else if let input = (max(0, k - 8)..<k).first(where: { lines[$0].text.range(of: #"^\s*(Input|Output|Require|Ensure)\b"#, options: .regularExpression) != nil }) {
                    result.formUnion(input..<k)
                }
                k = last + 1
            } else {
                k += 1
            }
        }
        return result
    }

    // MARK: Table cells

    /// Lines of one table cell joined: a cell's text may run over several lines. A line goes with the one above when
    /// it starts or stays in line with it, no rule separates them, and it reads on (or its row has nothing else in it).
    /// Then each cell learns how its column is aligned.
    static func mergeTableCells(_ blocks: inout [LayoutBlock], tables: [CGRect], rules: [CGRect]) {
        for table in tables {
            let area = table.insetBy(dx: -1, dy: -2)
            var indices = blocks.indices.filter { blocks[$0].kind == .tableCell && area.contains(blocks[$0].rect.center) }
            indices.sort { blocks[$0].lines[0].baseline > blocks[$1].lines[0].baseline }
            var removed: Set<Int> = []
            func isNumeric(_ text: String) -> Bool {
                text.range(of: #"^[\s\d.,±%()\-–+*†‡/×~<>≤≥]*$"#, options: .regularExpression) != nil
            }
            for a in indices where !removed.contains(a) {
                while true {
                    let upper = blocks[a].lines.last!
                    guard upper.text.contains(where: \.isLetter) else { break }
                    let below = indices.filter { b in
                        guard b != a, !removed.contains(b), blocks[b].lines.count == 1 else { return false }
                        let lower = blocks[b].lines[0]
                        let drop = upper.baseline - lower.baseline
                        return drop > upper.size * 0.5 && drop < upper.size * 1.5 && lower.minX < upper.maxX && lower.maxX > upper.minX
                    }
                    // The line right under it, and nothing else at that height in the cell's width.
                    guard below.count == 1, let b = below.first else { break }
                    let lower = blocks[b].lines[0]
                    let aligned = abs(lower.minX - upper.minX) < upper.size * 0.6 || abs((lower.minX + lower.maxX) - (upper.minX + upper.maxX)) < upper.size * 1.2
                    guard aligned, abs(lower.size - upper.size) < upper.size * 0.1, lower.font.isBold == upper.font.isBold,
                          !isNumeric(lower.text), lower.text.contains(where: \.isLetter) else { break }
                    let separated = rules.contains { rule in
                        rule.midY < upper.baseline && rule.midY > lower.baseline + lower.size * 0.6 && rule.minX < upper.maxX && rule.maxX > upper.minX
                    }
                    guard !separated else { break }
                    // What else is on each of the two rows.
                    func peers(_ line: LayoutLine) -> [LayoutLine] {
                        indices.filter { k in !removed.contains(k) && k != a && k != b }.flatMap { blocks[$0].lines }.filter { abs($0.baseline - line.baseline) < line.size * 0.3 }
                    }
                    let lowerPeers = peers(lower), upperPeers = peers(upper)
                    if lowerPeers.contains(where: { isNumeric($0.text) }) { break }
                    let startsLow = lower.text.trimmingCharacters(in: .whitespaces).first?.isLowercase == true
                    let endsOpen = upper.text.range(of: #"(-|,|\b(and|or|of|the|for|to|with|in|on|by|a|an))\s*$"#, options: .regularExpression) != nil
                    guard startsLow || endsOpen || (lowerPeers.isEmpty && !upperPeers.isEmpty) else { break }
                    blocks[a].lines.append(lower)
                    blocks[a].translate = blocks[a].translate || blocks[b].translate
                    removed.insert(b)
                }
            }
            // Alignment: which edge the cells of a column share.
            let cells = indices.filter { !removed.contains($0) }
            for c in cells {
                let block = blocks[c]
                let r = block.rect
                let others = cells.filter { $0 != c }.map { blocks[$0].rect }.filter { $0.minX < r.maxX + block.size && $0.maxX > r.minX - block.size }
                let left = others.filter { abs($0.minX - r.minX) < 1 }.count
                let right = others.filter { abs($0.maxX - r.maxX) < 1 }.count
                let middle = others.filter { abs($0.midX - r.midX) < 1 }.count
                if left > 0, left >= middle, left >= right {
                    blocks[c].cellAlignment = .left
                } else if right > 0, right > left, right >= middle {
                    blocks[c].cellAlignment = .right
                } else {
                    blocks[c].cellAlignment = .center
                }
            }
            for k in removed.sorted(by: >) { blocks.remove(at: k) }
        }
    }

    /// Splits a block where its lines change width around something beside them (a table or figure the text
    /// flows around): each piece keeps the width it was set in.
    static func splitBesideObstacles(_ block: LayoutBlock, obstacles: [CGRect]) -> [LayoutBlock] {
        let lines = block.lines
        guard lines.count >= 2 else { return [block] }
        let margin = block.size * 4
        var cuts: [Int] = []
        for k in 1..<lines.count {
            let previous = lines[k - 1], line = lines[k]
            let narrows = line.maxX < previous.maxX - margin || line.minX > previous.minX + margin
            let widens = line.maxX > previous.maxX + margin || line.minX < previous.minX - margin
            guard narrows || widens else { continue }
            // The run of narrow lines on the near side of the change, and the wide line it is measured against.
            let wide = narrows ? previous : line
            var run: [LayoutLine] = []
            var j = narrows ? k : k - 1
            while j >= 0, j < lines.count, lines[j].maxX < wide.maxX - margin || lines[j].minX > wide.minX + margin, run.count < 4 {
                run.append(lines[j])
                j += narrows ? 1 : -1
            }
            guard !run.isEmpty else { continue }
            let top = run.map(\.rect.maxY).max()!, bottom = run.map(\.rect.minY).min()!
            let right = CGRect(x: run.map(\.maxX).max()! + 1, y: bottom, width: 0, height: top - bottom)
            let rightSide = CGRect(x: right.minX, y: bottom, width: max(wide.maxX - right.minX - 1, 0), height: top - bottom)
            let leftEdge = run.map(\.minX).min()!
            let leftSide = CGRect(x: wide.minX + 1, y: bottom, width: max(leftEdge - wide.minX - 2, 0), height: top - bottom)
            // Something really there: more than an em wide and over a line high, and not behind the wide line as well.
            let found = obstacles.contains { o in
                !o.insetBy(dx: 1, dy: 1).intersects(wide.inkRect) && [rightSide, leftSide].contains { side in
                    let shared = o.intersection(side)
                    return side.width > 0 && !shared.isNull && shared.width > block.size && shared.height > block.size * 0.8
                }
            }
            if found { cuts.append(k) }
        }
        guard !cuts.isEmpty else { return [block] }
        var pieces: [LayoutBlock] = []
        var start = 0
        for cut in cuts + [lines.count] where cut > start {
            pieces.append(LayoutBlock(kind: block.kind, lines: Array(lines[start..<cut]), translate: block.translate))
            start = cut
        }
        return pieces
    }

    /// Paragraph blocks whose areas run through each other are one paragraph PDFKit read in pieces (stacked
    /// scripts break its lines): their lines are joined again by baseline.
    static func mergeInterleaved(_ blocks: inout [LayoutBlock]) {
        var changed = true
        while changed {
            changed = false
            outer: for a in blocks.indices where blocks[a].kind == .paragraph && blocks[a].translate {
                for b in blocks.indices where b != a && blocks[b].kind == .paragraph && blocks[b].translate {
                    let ra = blocks[a].rect.insetBy(dx: 0, dy: blocks[a].size * 0.2)
                    let rb = blocks[b].rect.insetBy(dx: 0, dy: blocks[b].size * 0.2)
                    let shared = ra.intersection(rb).area
                    guard shared > min(ra.area, rb.area) * 0.25, abs(blocks[a].size - blocks[b].size) < blocks[a].size * 0.15 else { continue }
                    let all = (blocks[a].lines + blocks[b].lines).sorted { $0.baseline > $1.baseline }
                    var lines: [LayoutLine] = []
                    for line in all {
                        if let last = lines.last, abs(last.baseline - line.baseline) < min(last.size, line.size) * 0.45,
                           let merged = makeLine(last.chars + [spacer(after: last)] + line.chars) {
                            lines[lines.count - 1] = merged
                        } else {
                            lines.append(line)
                        }
                    }
                    let keep = min(a, b)
                    blocks[keep].lines = lines
                    blocks.remove(at: max(a, b))
                    changed = true
                    break outer
                }
            }
        }
    }

    /// A space to put between two pieces of a line.
    static func spacer(after line: LayoutLine) -> PageChar {
        var space = line.chars.last!
        space.text = " "
        space.isSpace = true
        space.isMath = false
        space.link = nil
        space.rect = CGRect(x: line.maxX, y: space.rect.minY, width: 0.1, height: space.rect.height)
        return space
    }

    /// Small formula pieces left inside a translated paragraph (lines PDFKit could not place) join the paragraph
    /// line they sit on, so they move with the translation instead of showing through it.
    static func absorbStrays(_ blocks: inout [LayoutBlock]) {
        var removed: Set<Int> = []
        // A drop cap: one big letter just left of a paragraph's first lines starts that paragraph.
        for (i, cap) in blocks.enumerated() where cap.lines.count == 1 && cap.lines[0].visibleCount == 1 && !cap.translate {
            guard let letter = cap.lines[0].chars.first(where: { !$0.isSpace }), letter.text.first?.isLetter == true else { continue }
            guard let p = blocks.indices.first(where: { j in
                j != i && blocks[j].translate && blocks[j].kind == .paragraph && letter.size > blocks[j].size * 1.8
                    && blocks[j].lines[0].minX - cap.rect.maxX < blocks[j].size * 1.5 && blocks[j].lines[0].minX > cap.rect.minX
                    && abs(blocks[j].lines[0].rect.maxY - cap.rect.maxY) < letter.size * 0.5
            }) else { continue }
            var plain = letter
            plain.size = blocks[p].lines[0].size
            plain.baseline = blocks[p].lines[0].baseline
            var chars = blocks[p].lines[0].chars
            chars.insert(plain, at: 0)
            if let merged = makeLine(chars) {
                blocks[p].lines[0] = merged
                removed.insert(i)
            }
        }
        for (i, stray) in blocks.enumerated() where !removed.contains(i) && (stray.kind == .formula || stray.kind == .other) && stray.lines.count <= 2 {
            // The paragraph with a line on the stray's baseline, right beside it.
            let line = stray.lines[0]
            guard let p = blocks.indices.filter({ j in
                j != i && blocks[j].translate && blocks[j].kind == .paragraph && stray.rect.width < max(blocks[j].rect.width * 0.6, 1)
                    && blocks[j].lines.contains { host in
                        abs(host.baseline - line.baseline) < host.size * 0.6
                            && line.minX < host.maxX + host.size * 0.3 && line.maxX > host.minX - host.size * 0.3
                    }
            }).min(by: { a, b in
                func distance(_ j: Int) -> Double { blocks[j].lines.map { abs($0.baseline - line.baseline) }.min() ?? 99 }
                return distance(a) < distance(b)
            }) else { continue }
            for line in stray.lines {
                guard let k = blocks[p].lines.indices.min(by: { abs(blocks[p].lines[$0].baseline - line.baseline) < abs(blocks[p].lines[$1].baseline - line.baseline) }),
                      abs(blocks[p].lines[k].baseline - line.baseline) < blocks[p].lines[k].size * 1.2 else { continue }
                var chars = line.chars
                for c in chars.indices where !chars[c].isSpace { chars[c].isMath = true }
                if let merged = makeLine(blocks[p].lines[k].chars + chars) { blocks[p].lines[k] = merged }
            }
            removed.insert(i)
        }
        blocks = blocks.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }

    // MARK: Lines

    /// Groups characters (in reading order) into lines; a big horizontal gap also ends a line — in tables a
    /// gap of under an em does, so each cell is its own line.
    func buildLines(_ chars: [PageChar], tables: [CGRect], gutters: [[ClosedRange<Double>]] = [], pageWidth: Double) -> [LayoutLine] {
        var lines: [LayoutLine] = []
        var current: [PageChar] = []
        var mainSize = 0.0
        var mainBaseline = 0.0

        func flush() {
            while current.last?.isSpace == true { current.removeLast() }
            if !current.isEmpty, let line = Self.makeLine(current) { lines.append(line) }
            current = []
            mainSize = 0
        }

        for c in chars {
            if c.isNewline {
                flush()
                continue
            }
            if c.isSpace {
                if !current.isEmpty, current.last?.isSpace == false { current.append(c) }
                continue
            }
            if c.rect.width <= 0 && c.rect.height <= 0 { continue }
            if let last = current.last(where: { !$0.isSpace }) {
                let small = c.size < mainSize * 0.85
                let dy = abs(c.baseline - mainBaseline)
                let overlap = min(c.rect.maxY, mainBaseline + mainSize) - max(c.rect.minY, mainBaseline - mainSize * 0.3)
                let sameLine = dy < mainSize * 0.5 || (small && dy < mainSize * 0.9 && overlap > 0)
                let gap = c.rect.minX - last.rect.maxX
                let table = tables.firstIndex { $0.insetBy(dx: -1, dy: -2).contains(c.center) }
                let limit = (table != nil ? 0.75 : 2.2) * max(mainSize, c.size)
                // In a table, a gap over a column gutter ends the cell however narrow it is.
                let acrossGutter = table.map { t in
                    t < gutters.count && gutters[t].contains { last.rect.maxX <= $0.lowerBound + 0.5 && c.rect.minX >= $0.upperBound - 0.5 }
                } ?? false
                if !sameLine || gap > limit || acrossGutter || gap < -max(mainSize, 4) * 1.5 || c.isRotated != last.isRotated {
                    flush()
                }
            }
            if current.isEmpty || c.size > mainSize * 1.15 || (c.size >= mainSize * 0.85 && current.count < 3) {
                if c.size >= mainSize * 0.85 || current.isEmpty {
                    mainSize = max(mainSize, c.size)
                    mainBaseline = c.baseline
                }
            }
            current.append(c)
        }
        flush()
        return Self.regroup(lines, tables: tables, pageWidth: pageWidth)
    }

    /// Repairs PDFKit's lines geometrically: sub- and superscripts go to the line they sit on, and pieces of one
    /// line (split around a formula or a script) are joined again, in reading order of the first piece.
    static func regroup(_ input: [LayoutLine], tables: [CGRect], pageWidth: Double) -> [LayoutLine] {
        var lines = input
        func inTable(_ r: CGRect) -> Bool { tables.contains { $0.insetBy(dx: -1, dy: -2).contains(r.center) } }
        // 1. Scripts outside their line's band move to the line whose band holds them.
        var moved: [(PageChar, Int)] = []
        for k in lines.indices where !lines[k].isRotated {
            let line = lines[k]
            var keep: [PageChar] = []
            for c in line.chars {
                let inBand = c.center.y > line.baseline - line.size * 0.45 && c.center.y < line.baseline + line.size * 1.0
                if c.isSpace || inBand || c.size >= line.size * 0.85 {
                    keep.append(c)
                    continue
                }
                let host = lines.indices.filter { j in
                    j != k && !lines[j].isRotated && lines[j].size > c.size * 1.1
                        && c.center.y > lines[j].baseline - lines[j].size * 0.45 && c.center.y < lines[j].baseline + lines[j].size * 1.0
                        && c.rect.midX > lines[j].minX - lines[j].size * 1.5 && c.rect.midX < lines[j].maxX + lines[j].size * 1.5
                }.min { a, b in
                    // The nearest line horizontally (the letter the script belongs to), then by baseline.
                    func distance(_ j: Int) -> Double { max(lines[j].minX - c.rect.midX, c.rect.midX - lines[j].maxX, 0) }
                    let da = distance(a), db = distance(b)
                    return da != db ? da < db : abs(lines[a].baseline - c.baseline) < abs(lines[b].baseline - c.baseline)
                }
                if let host { moved.append((c, host)) } else { keep.append(c) }
            }
            if keep.count != line.chars.count, let rebuilt = makeLine(trimSpaces(keep)) { lines[k] = rebuilt }
        }
        for (c, host) in moved {
            var chars = lines[host].chars
            let at = chars.firstIndex { !$0.isSpace && $0.rect.midX > c.rect.midX } ?? chars.count
            chars.insert(c, at: at)
            if let rebuilt = makeLine(chars) { lines[host] = rebuilt }
        }
        lines.removeAll { $0.chars.allSatisfy(\.isSpace) }

        // 2. Pieces on one baseline, close together, become one line.
        var merged = true
        while merged {
            merged = false
            let order = lines.indices.sorted { lines[$0].baseline < lines[$1].baseline }
            let window = (lines.map(\.size).max() ?? 10) * 0.75
            var removed = Set<Int>()
            for (p, a) in order.enumerated() where !removed.contains(a) {
                var candidates: [Int] = []
                var q = p - 1
                while q >= 0, lines[a].baseline - lines[order[q]].baseline < window { candidates.append(order[q]); q -= 1 }
                q = p + 1
                while q < order.count, lines[order[q]].baseline - lines[a].baseline < window { candidates.append(order[q]); q += 1 }
                for b in candidates where !removed.contains(b) {
                    guard let line = mergePieces(lines[a], lines[b], tables: tables, pageWidth: pageWidth) else { continue }
                    lines[a] = line
                    removed.insert(b)
                    merged = true
                }
            }
            if !removed.isEmpty { lines = lines.indices.filter { !removed.contains($0) }.map { lines[$0] } }
        }
        return lines
    }

    /// `l` and `r` as one line, when `r` is a piece of the same line to the right of `l` (or interleaved with it).
    static func mergePieces(_ l: LayoutLine, _ r: LayoutLine, tables: [CGRect], pageWidth: Double) -> LayoutLine? {
        func inTable(_ rect: CGRect) -> Bool { tables.contains { $0.insetBy(dx: -1, dy: -2).contains(rect.center) } }
        // A short piece of formula may sit off the baseline (only its scripts on the line); so may scripts alone.
        func formulaPiece(_ line: LayoutLine, other: LayoutLine) -> Bool {
            line.visibleCount <= 8 && (line.mathRatio >= 0.5 || line.chars.contains { $0.isScript || $0.size < line.size * 0.85 })
                || line.visibleCount <= 12 && line.size < other.size * 0.85
        }
        let piece = formulaPiece(l, other: r) || formulaPiece(r, other: l)
        // A piece of formula sits up to about half an em off its host line's baseline, scripts up to most of an em.
        let host = l.visibleCount >= r.visibleCount ? l : r
        let small = min(l.size, r.size) < max(l.size, r.size) * 0.85
        let baselineTolerance = piece ? host.size * (small ? 0.95 : 0.7) : min(l.size, r.size) * 0.3
        guard !l.isRotated, !r.isRotated, r.minX >= l.minX,
              abs(l.baseline - r.baseline) < baselineTolerance,
              piece || abs(l.size - r.size) < max(l.size, r.size) * 0.2 else { return nil }
        let gap = r.minX - l.maxX
        guard !inTable(l.rect), !inTable(r.rect) else { return nil }
        // Scripts may overlap (a subscript under a superscript); full-size text may not.
        let lMain = l.chars.filter { !$0.isSpace && $0.size >= l.size * 0.85 }.map { Double($0.rect.maxX) }.max() ?? l.maxX
        let rMain = r.chars.filter { !$0.isSpace && $0.size >= r.size * 0.85 }.map { Double($0.rect.minX) }.min() ?? r.minX
        let scriptsUnder = piece && small && rMain - lMain > -min(l.size, r.size) * 0.5
        if gap < -min(l.size, r.size) * 0.5, !scriptsUnder {
            guard abs(l.baseline - r.baseline) < min(l.size, r.size) * 0.3, abs(l.size - r.size) < max(l.size, r.size) * 0.2 else { return nil }
            // Interleaved pieces (drawn in two passes): one line if their glyphs do not collide.
            let lGlyphs = l.chars.filter { !$0.isSpace && $0.size >= l.size * 0.85 }.map(\.rect)
            let collisions = r.chars.filter { c in
                !c.isSpace && c.size >= r.size * 0.85
                    && lGlyphs.contains { $0.minX < c.rect.maxX - c.rect.width * 0.4 && $0.maxX > c.rect.minX + c.rect.width * 0.4 }
            }.count
            guard collisions <= max(1, r.visibleCount / 10), r.minX < l.maxX, r.maxX > l.minX else { return nil }
        } else {
            guard rMain - lMain > -min(l.size, r.size) * 0.5, gap < max(l.size, r.size) * 1.0 else { return nil }
        }
        // Two lines that each fill a column are neighbouring columns, not pieces of one line.
        if l.inkRect.width > pageWidth * 0.3, r.inkRect.width > pageWidth * 0.3 { return nil }
        var space = l.chars.last!
        space.text = " "
        space.isSpace = true
        space.isMath = false
        space.glyphs = []
        space.run = nil
        space.link = nil
        space.rect = CGRect(x: l.maxX, y: space.rect.minY, width: max(gap, 0), height: space.rect.height)
        let wordGap = gap > min(l.size, r.size) * 0.15
        return makeLine(wordGap ? l.chars + [space] + r.chars : l.chars + r.chars)
    }

    // MARK: Reading order

    /// Lines in reading order. Columns are found from gutters: vertical strips no narrow line crosses, with
    /// narrow lines on both sides. Lines across a gutter (titles, abstracts, full-width captions) divide the
    /// page into bands, read top to bottom; each band column by column, each column top to bottom.
    static func readingOrder(_ lines: [LayoutLine]) -> [LayoutLine] {
        let flat = lines.indices.filter { !lines[$0].isRotated }
        let rotated = lines.indices.filter { lines[$0].isRotated }
        func topDown(_ a: Int, _ b: Int) -> Bool {
            let la = lines[a], lb = lines[b]
            if abs(la.baseline - lb.baseline) > min(la.size, lb.size) * 0.3 { return la.baseline > lb.baseline }
            return la.minX < lb.minX
        }
        guard flat.count > 3 else { return (flat.sorted(by: topDown) + rotated).map { lines[$0] } }
        let minX = flat.map { lines[$0].minX }.min()!, maxX = flat.map { lines[$0].maxX }.max()!
        let width = maxX - minX
        let gutters = Self.gutters(flat.map { lines[$0] }, minX: minX, width: width)
        guard !gutters.isEmpty else { return (flat.sorted(by: topDown) + rotated).map { lines[$0] } }

        var spanning: [Int] = []
        var column: [Int: Int] = [:]
        for k in flat {
            let line = lines[k]
            let crosses = gutters.contains { line.minX < $0.lowerBound - line.size && line.maxX > $0.upperBound + line.size }
            if crosses {
                spanning.append(k)
            } else {
                let center = (line.minX + line.maxX) / 2
                column[k] = gutters.filter { ($0.lowerBound + $0.upperBound) / 2 < center }.count
            }
        }
        spanning.sort(by: topDown)
        let separators = spanning.map { lines[$0].rect.midY }
        var cells: [[Int]: [Int]] = [:]
        for (k, c) in column {
            let band = separators.filter { $0 > lines[k].rect.midY }.count
            cells[[band, c], default: []].append(k)
        }
        var order: [Int] = []
        for band in 0...spanning.count {
            for c in 0...gutters.count { order += (cells[[band, c]] ?? []).sorted(by: topDown) }
            if band < spanning.count { order.append(spanning[band]) }
        }
        return (order + rotated).map { lines[$0] }
    }

    /// Column gutters: strips between 15% and 85% of the text width that no narrow line (under 55% of the width)
    /// crosses, 5 pt to 15% of the width wide, with at least three narrow lines on each side next to each other.
    static func gutters(_ lines: [LayoutLine], minX: Double, width: Double) -> [ClosedRange<Double>] {
        guard width > 100 else { return [] }
        let narrow = lines.filter { $0.inkRect.width < width * 0.55 }
        guard narrow.count >= 6 else { return [] }
        let bins = Int(width.rounded(.up)) + 1
        var coverage = [Int](repeating: 0, count: bins)
        for line in narrow {
            let a = max(0, Int((line.minX - minX).rounded(.down))), b = min(bins - 1, Int((line.maxX - minX).rounded(.up)))
            if a <= b { for x in a...b { coverage[x] += 1 } }
        }
        // A display formula a little wider than its column may cross.
        let tolerance = max(0, narrow.count / 60)
        var result: [ClosedRange<Double>] = []
        var x = Int(width * 0.15)
        while x < Int(width * 0.85) {
            guard coverage[x] <= tolerance else { x += 1; continue }
            var lo = x, hi = x
            while lo > 0, coverage[lo - 1] <= tolerance { lo -= 1 }
            while hi + 1 < bins, coverage[hi + 1] <= tolerance { hi += 1 }
            x = hi + 1
            let strip = (minX + Double(lo))...(minX + Double(hi + 1))
            guard strip.upperBound - strip.lowerBound >= 5, strip.upperBound - strip.lowerBound <= width * 0.15 else { continue }
            let left = narrow.filter { $0.maxX <= strip.lowerBound + 1 }, right = narrow.filter { $0.minX >= strip.upperBound - 1 }
            guard left.count >= 3, right.count >= 3 else { continue }
            let leftSpan = (left.map(\.rect.minY).min()!, left.map(\.rect.maxY).max()!)
            let rightSpan = (right.map(\.rect.minY).min()!, right.map(\.rect.maxY).max()!)
            let overlap = min(leftSpan.1, rightSpan.1) - max(leftSpan.0, rightSpan.0)
            guard overlap > min(leftSpan.1 - leftSpan.0, rightSpan.1 - rightSpan.0) * 0.3 else { continue }
            result.append(strip)
        }
        return result
    }

    /// Characters clearly smaller than the line's text are sub- or superscripts: part of a formula, together
    /// with the letter they are attached to ("f" in fₛ).
    static func markScripts(_ line: LayoutLine) -> LayoutLine {
        var line = line
        var chars = line.chars
        // Off the baseline: small capitals are smaller too, but sit on it.
        for i in chars.indices where !chars[i].isSpace && chars[i].size < line.size * 0.95
            && (chars[i].isScript || abs(chars[i].baseline - line.baseline) > line.size * 0.12) {
            chars[i].isMath = true
        }
        for i in chars.indices where !chars[i].isSpace && !chars[i].isMath && chars[i].text.first?.isLetter == true {
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            let previous = i > 0 ? chars[i - 1] : nil
            let wordStart = previous == nil || previous!.isSpace || previous!.isMath
            _ = wordStart
            if let next, next.isMath, next.size < line.size * 0.95, next.isScript || abs(next.baseline - line.baseline) > line.size * 0.12,
               next.rect.minX - chars[i].rect.maxX < line.size * 0.3 {
                // The symbol the script belongs to: the letters touching it ("f" in fₛ, "DEC" in DECₚᵢₓ), up to six.
                var start = i
                while start > 0, i - start < 5, !chars[start - 1].isSpace, !chars[start - 1].isMath,
                      chars[start - 1].text.first?.isLetter == true, chars[start].rect.minX - chars[start - 1].rect.maxX < line.size * 0.15 {
                    start -= 1
                }
                let isWord = start == 0 || chars[start - 1].isSpace || chars[start - 1].isMath || chars[start - 1].text.first?.isLetter != true
                if isWord { for k in start...i { chars[k].isMath = true } }
            }
        }
        // An accent belongs with the letter under it (F̂): both are the formula.
        for i in chars.indices where chars[i].text.unicodeScalars.contains(where: { (0x02C6...0x02DD).contains($0.value) || (0x0300...0x036F).contains($0.value) || $0.value == 0x00AF || $0.value == 0x00A8 }) {
            chars[i].isMath = true
            let accent = chars[i].rect
            for k in chars.indices where k != i && !chars[k].isSpace && chars[k].text.first?.isLetter == true {
                let overlap = min(chars[k].rect.maxX, accent.maxX) - max(chars[k].rect.minX, accent.minX)
                if overlap > min(accent.width, chars[k].rect.width) * 0.3 { chars[k].isMath = true }
            }
        }
        // A single letter touching the start of a formula ("D" of DEC set apart from E and C) is part of it.
        for i in chars.indices.dropLast() where !chars[i].isMath && !chars[i].isSpace && chars[i].text.first?.isLetter == true {
            let next = chars[i + 1]
            let before = i > 0 ? chars[i - 1] : nil
            let alone = before == nil || before!.isSpace || before!.text.first.map { !$0.isLetter && !$0.isNumber } == true
            if alone, next.isMath, next.text.first?.isLetter == true, abs(next.size - chars[i].size) < chars[i].size * 0.1,
               next.rect.minX - chars[i].rect.maxX < chars[i].size * 0.15 {
                chars[i].isMath = true
            }
        }
        // Operator names ("arg max", "exp") beside maths, read along the line (their limits are drawn apart).
        for _ in 0..<2 {
            var w = 0
            while w < chars.count {
                guard !chars[w].isSpace, !chars[w].isMath, chars[w].text.first?.isLetter == true else { w += 1; continue }
                var e = w
                while e + 1 < chars.count, !chars[e + 1].isSpace, !chars[e + 1].isMath, chars[e + 1].text.first?.isLetter == true { e += 1 }
                if MathDetector.operatorNames.contains(chars[w...e].map(\.text).joined()) {
                    let before = chars[..<w].last { !$0.isSpace }, after = chars[(e + 1)...].first { !$0.isSpace }
                    if before?.isMath == true || after?.isMath == true || after?.text == "(" || after?.text == "[" {
                        for k in w...e { chars[k].isMath = true }
                    }
                }
                w = e + 1
            }
        }
        // Pieces of one formula ("πₓ = h_θ(F̂(x))") separated only by spaces and operators are one formula.
        let operators: Set<Character> = Set("=+-−–×·*/<>≤≥≈∈()[]{}|,")
        var i = 0
        while i < chars.count {
            guard chars[i].isMath else { i += 1; continue }
            var j = i + 1
            while j < chars.count, !chars[j].isMath, chars[j].isSpace || (chars[j].text.count == 1 && operators.contains(chars[j].text.first!)) { j += 1 }
            if j < chars.count, j > i + 1, chars[j].isMath, chars[(i + 1)..<j].contains(where: { !$0.isSpace }) || j - i <= 2 {
                for k in (i + 1)..<j { chars[k].isMath = true }
            }
            i = j
        }
        // A formula with an open bracket goes on to the bracket that closes it ("F̂(" + "x))").
        i = 0
        while i < chars.count {
            guard chars[i].isMath else { i += 1; continue }
            var j = i
            var depth = 0
            while j < chars.count, chars[j].isMath {
                depth += chars[j].text == "(" ? 1 : chars[j].text == ")" ? -1 : 0
                j += 1
            }
            var extended = 0
            // F̂(x): an argument list right after the formula belongs to it too.
            if depth == 0, j < chars.count, chars[j].text == "(", chars[j].rect.minX - chars[j - 1].rect.maxX < chars[j].size * 0.2,
               chars[j...].prefix(8).contains(where: { $0.text == ")" }) {
                depth = 1
                chars[j].isMath = true
                j += 1
            }
            while depth > 0, j < chars.count, !chars[j].isSpace, extended < 8 {
                depth += chars[j].text == "(" ? 1 : chars[j].text == ")" ? -1 : 0
                chars[j].isMath = true
                j += 1
                extended += 1
            }
            i = j + 1
        }
        balanceBrackets(&chars)
        line.chars = chars
        return line
    }

    /// A bracket at the edge of a formula belongs to it only when its partner does too: "(Sₓ and S_y)" keeps its
    /// brackets as text, "F(x)" keeps them in the formula.
    static func balanceBrackets(_ chars: inout [PageChar]) {
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
        var i = 0
        while i < chars.count {
            guard chars[i].isMath, !chars[i].isSpace else { i += 1; continue }
            var j = i
            while j + 1 < chars.count, chars[j + 1].isMath { j += 1 }
            var changed = true
            while changed, i <= j {
                changed = false
                let span = chars[i...j].filter { !$0.isSpace }.map(\.text)
                for (open, close) in pairs {
                    let opens = span.filter { $0 == String(open) }.count, closes = span.filter { $0 == String(close) }.count
                    if closes > opens, chars[j].text == String(close) {
                        chars[j].isMath = false
                        j -= 1
                        changed = true
                    } else if opens > closes, chars[i].text == String(open) {
                        chars[i].isMath = false
                        i += 1
                        changed = true
                    }
                    while i <= j, chars[j].isSpace { chars[j].isMath = false; j -= 1 }
                    while i <= j, chars[i].isSpace { chars[i].isMath = false; i += 1 }
                    if changed { break }
                }
            }
            i = j + 2
        }
    }

    static func trimSpaces(_ chars: [PageChar]) -> [PageChar] {
        var result: [PageChar] = []
        for c in chars {
            if c.isSpace && (result.isEmpty || result.last!.isSpace) { continue }
            result.append(c)
        }
        while result.last?.isSpace == true { result.removeLast() }
        return result
    }

    /// Characters (left to right) with a space wherever one starts clear of everything before it by more than
    /// a word space: more than 0.15 em, plus the usual gap between letters in letter-spaced text.
    static func respaced(_ chars: [PageChar]) -> [PageChar] {
        guard chars.count > 1 else { return chars }
        var gaps: [Double] = []
        for (a, b) in zip(chars, chars.dropFirst()) where a.run == b.run && a.run != nil {
            let gap = (b.rect.minX - a.rect.maxX) / max(a.size, 1)
            if gap > -0.2 && gap < 0.5 { gaps.append(gap) }
        }
        gaps.sort()
        let tracking = gaps.count >= 4 && gaps[gaps.count / 2] > 0.04 ? gaps[gaps.count / 2] : 0
        var result: [PageChar] = [chars[0]]
        var reach = chars[0].rect.maxX
        for c in chars.dropFirst() {
            let previous = result.last!
            let gap = c.rect.minX - reach
            if gap > min(previous.size, c.size) * (0.15 + tracking) {
                var space = previous
                space.text = " "
                space.isSpace = true
                space.isMath = previous.isMath && c.isMath
                space.glyphs = []
                space.run = nil
                space.ink = nil
                space.link = nil
                space.rect = CGRect(x: reach, y: previous.rect.minY, width: gap, height: previous.rect.height)
                result.append(space)
            }
            result.append(c)
            reach = max(reach, c.rect.maxX)
        }
        return result
    }

    static func makeLine(_ unordered: [PageChar]) -> LayoutLine? {
        // Left to right: PDFKit sometimes lists scripts out of order.
        var chars = unordered
        if chars.filter(\.isRotated).count * 2 <= chars.count {
            chars = respaced(chars.filter { !$0.isSpace }.enumerated().sorted { a, b in
                a.element.rect.minX != b.element.rect.minX ? a.element.rect.minX < b.element.rect.minX : a.offset < b.offset
            }.map(\.element))
        }
        let visible = chars.filter { !$0.isSpace }
        guard let first = visible.first else { return nil }
        // Size and baseline come from the line's text, not its scripts: the largest size a quarter of the characters
        // have (PDFKit's own baseline offsets are unreliable around stacked scripts).
        let sizes = Set(visible.map { ($0.size * 4).rounded() / 4 }).sorted(by: >)
        let mainSize = sizes.first { s in visible.filter { abs($0.size - s) < s * 0.1 }.count * 4 >= visible.count } ?? sizes.last ?? first.size
        let reference = visible.filter { abs($0.size - mainSize) < mainSize * 0.1 }
        var ink = first.rect
        for c in visible.dropFirst() { ink = ink.union(c.rect) }
        var sizeCounts: [Double: Int] = [:]
        var fontCounts: [FontInfo: Int] = [:]
        for c in reference {
            sizeCounts[(c.size * 4).rounded() / 4, default: 0] += 1
            fontCounts[c.font, default: 0] += 1
        }
        let size = sizeCounts.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }!.key
        let main = reference.filter { abs($0.size - size) < size * 0.1 }
        let baselines = (main.isEmpty ? reference : main).map(\.baseline).sorted()
        let font = fontCounts.max { $0.value < $1.value }!.key
        // The colour of the words: links and citations are often coloured, the text around them is not.
        var colorCounts: [RGBColor: Int] = [:]
        for c in visible where c.text.first?.isLetter == true && c.link == nil { colorCounts[c.color, default: 0] += 1 }
        if colorCounts.isEmpty { for c in visible where c.text.first?.isLetter == true { colorCounts[c.color, default: 0] += 1 } }
        if colorCounts.isEmpty { for c in visible { colorCounts[c.color, default: 0] += 1 } }
        let color = colorCounts.max { $0.value < $1.value }!.key
        return LayoutLine(chars: chars, inkRect: ink, baseline: baselines[baselines.count / 2], size: max(size, 1),
                          font: font, color: color,
                          isRotated: visible.filter(\.isRotated).count * 2 > visible.count)
    }

    // MARK: Regions

    /// Tables from their rules: horizontal rules of (nearly) the same extent, two or more stacked.
    static func tableFrames(rules: [CGRect], lines: [LayoutLine]) -> [CGRect] {
        var groups: [[CGRect]] = []
        for rule in rules.sorted(by: { $0.maxY > $1.maxY }) {
            if let g = groups.firstIndex(where: { group in
                let r = group[0]
                return abs(r.minX - rule.minX) < 12 && abs(r.maxX - rule.maxX) < 12
            }) {
                groups[g].append(rule)
            } else {
                groups.append([rule])
            }
        }
        var frames: [CGRect] = []
        for group in groups where group.count >= 2 {
            // Split where consecutive rules are far apart (two tables of the same width on one page).
            // Split where a caption or running text sits between two rules (two tables of the same width).
            func separated(_ upper: CGRect, _ lower: CGRect) -> Bool {
                lines.contains { line in
                    let c = line.rect.center
                    return c.y < upper.minY && c.y > lower.maxY && c.x > upper.minX - 4 && c.x < upper.maxX + 4
                        && (isCaptionStart(line.text) || proseWords(line) >= 6)
                }
            }
            var start = 0
            for k in 1...group.count {
                if k == group.count || group[k - 1].minY - group[k].maxY > 400 || separated(group[k - 1], group[k]) {
                    if k - start >= 2 {
                        let top = group[start], bottom = group[k - 1]
                        let frame = CGRect(x: min(top.minX, bottom.minX), y: bottom.minY,
                                           width: max(top.maxX, bottom.maxX) - min(top.minX, bottom.minX), height: top.maxY - bottom.minY)
                        if frame.height > 8 { frames.append(frame) }
                    }
                    start = k
                }
            }
        }
        // Merge overlapping frames (partial rules inside a table).
        var merged: [CGRect] = []
        for frame in frames.sorted(by: { $0.area > $1.area }) {
            if let k = merged.firstIndex(where: { $0.insetBy(dx: -2, dy: -2).intersects(frame) }) {
                merged[k] = merged[k].union(frame)
            } else {
                merged.append(frame)
            }
        }
        return merged
    }

    /// A caption caught between a table's rules (a rule under the caption) is not part of the table.
    static func trimCaptions(_ frame: CGRect, lines: [LayoutLine]) -> CGRect {
        var frame = frame
        for line in lines where isCaptionStart(line.text) && !isAlgorithmStart(line.text) && frame.contains(line.rect.center) {
            if line.rect.midY < frame.midY {
                frame = CGRect(x: frame.minX, y: line.rect.maxY + 1, width: frame.width, height: max(frame.maxY - line.rect.maxY - 1, 0))
            } else {
                // The caption's further lines go with it.
                var last = line
                while let next = lines.first(where: { next in
                    let drop = last.baseline - next.baseline
                    return drop > last.size * 0.5 && drop < last.size * 1.7 && abs(next.size - last.size) < last.size * 0.1
                        && next.minX < last.maxX && next.maxX > last.minX && !isCaptionStart(next.text)
                }) { last = next }
                frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(last.rect.minY - 1 - frame.minY, 0))
            }
        }
        return frame
    }

    /// Rules around running text (a frame around an abstract) do not make a table: tables have several cells
    /// per row and short lines.
    func isTable(_ frame: CGRect, lines: [LayoutLine], marks: [GraphicMark] = []) -> Bool {
        let inside = lines.filter { frame.insetBy(dx: -1, dy: -2).contains($0.rect.center) }
        guard inside.count >= 2 else { return false }
        // Rules around a paper's title and authors.
        if inside.contains(where: { $0.size >= bodySize * 1.4 && Self.textWords($0) >= 2 }) { return false }
        // Grid lines of a bar chart: tall narrow bars stand between them.
        // (a table's own vertical rules are thin)
        let bars = marks.filter { $0.kind == .fill && !$0.isWhite && frame.insetBy(dx: -1, dy: -1).contains($0.rect.center) && $0.rect.height > bodySize * 2.2 && $0.rect.width > 3 && $0.rect.width < frame.width * 0.3 }
        if bars.count >= 3 { return false }
        let chars = inside.reduce(0) { $0 + $1.visibleCount }
        // Fraction bars of a big equation (numbers such as 7.6 × 10⁹ say nothing).
        let math = inside.reduce(0) { $0 + $1.chars.filter { $0.isMath && $0.text.first.map { !$0.isNumber && !".,×·-−".contains($0) } == true }.count }
        if Double(math) > Double(chars) * 0.4 { return false }
        let prose = inside.filter { Self.textWords($0) >= 6 }.reduce(0) { $0 + $1.visibleCount }
        if Double(prose) > Double(chars) * 0.5 { return false }
        // At least two rows with two or more cells: separate lines on one baseline, or wide gaps inside a line.
        var rows: [Double: Int] = [:]
        for line in inside { rows[(line.baseline / 3).rounded(), default: 0] += 1 + Self.columnGaps(line) }
        let wide = rows.values.filter { $0 >= 2 }.count
        return wide >= 2 || inside.count >= 6 && wide >= 1
    }

    /// Gaps between columns inside a line: horizontal space of more than 0.8 em between two characters.
    static func columnGaps(_ line: LayoutLine) -> Int {
        let visible = line.chars.filter { !$0.isSpace }
        return zip(visible, visible.dropFirst()).filter { $1.rect.minX - $0.rect.maxX > line.size * 0.8 }.count
    }

    /// Areas covered by drawings: images, curves, filled shapes and their axes, plus the short labels around them.
    func figureRegions(marks: [GraphicMark], lines: [LayoutLine], tables: [CGRect], page: CGRect) -> [CGRect] {
        var seeds: [CGRect] = []
        var minor: [CGRect] = []
        for mark in marks {
            let r = mark.rect
            // Shaded rows, check marks and rules belong to the table.
            if tables.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(r.center) }) { continue }
            let thin = r.width < 2.5 || r.height < 2.5
            let boxy = !mark.hasCurves && mark.segmentCount <= 5
            switch mark.kind {
            case .image:
                if r.width > 4, r.height > 4 { seeds.append(r) }
            case .shading:
                if !Self.isBackground(r, lines: lines, boxy: true) { seeds.append(r) }
            case .fill, .stroke:
                if thin {
                    // A rule across the page separates what is above and below it; it does not hold them together.
                    if r.width < page.width * 0.6 { minor.append(r) }
                } else if !Self.isBackground(r, lines: lines, boxy: boxy) {
                    seeds.append(r)
                } else if boxy, Self.textInside(r, lines: lines) < 40 {
                    // A box with a label: part of the drawing it touches, if any.
                    minor.append(r)
                }
            }
        }
        guard !seeds.isEmpty else { return [] }
        // Single-linkage clustering of seeds and nearby thin marks.
        let all = seeds + minor
        var parent = Array(all.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        let sorted = all.indices.sorted { all[$0].minX < all[$1].minX }
        for (n, a) in sorted.enumerated() {
            let ra = all[a].insetBy(dx: -4, dy: -4)
            for b in sorted[(n + 1)...] {
                if all[b].minX > ra.maxX { break }
                if ra.intersects(all[b]) { parent[find(a)] = find(b) }
            }
        }
        var clusters: [Int: (rect: CGRect, seeds: Int)] = [:]
        for i in all.indices {
            let root = find(i)
            let entry = clusters[root] ?? (all[i], 0)
            clusters[root] = (entry.rect.union(all[i]), entry.seeds + (i < seeds.count ? 1 : 0))
        }
        var regions = clusters.values.filter { $0.seeds > 0 && $0.rect.area > 150 }.map(\.rect)
        // Small marks next to a drawing (legend swatches, markers) belong to it.
        let small = clusters.values.filter { $0.seeds > 0 && $0.rect.area <= 150 }.map(\.rect)
        for mark in small {
            if let k = regions.firstIndex(where: { $0.area > 2000 && $0.insetBy(dx: -30, dy: -30).intersects(mark) }) {
                regions[k] = regions[k].union(mark)
            }
        }

        // Absorb labels: short lines inside or just around a region (axis titles, tick labels, legends).
        let reach = bodySize * 1.4
        for _ in 0..<3 {
            var changed = false
            for k in regions.indices {
                for line in lines {
                    let r = line.rect
                    if regions[k].contains(r) || Self.isCaptionStart(line.text) || Self.continuesText(line, in: lines) && !regions[k].contains(r.center) { continue }
                    let inside = regions[k].contains(r.center)
                    let near = regions[k].insetBy(dx: -reach, dy: -reach).intersects(r)
                    // A label in a box of the drawing.
                    let boxed = line.wordCount <= 4 && marks.contains { $0.kind != .image && !$0.isWhite && $0.rect.intersection(r).area > r.area * 0.25 && $0.rect.height > line.size }
                    // Labels are short; longer ones sit within the drawing's width. Lines of words beside it (a biography
                    // next to its photo) are text, however small.
                    let within = r.minX >= regions[k].minX - 2 && r.maxX <= regions[k].maxX + 2
                    let small = boxed || line.size < bodySize * 0.96 && (line.wordCount <= 4 || within && (line.wordCount <= 6 || line.size < bodySize * 0.9 && line.wordCount <= 8))
                    // A few words between two parts of one drawing belong to it.
                    let bridging = near && line.wordCount <= 4 && regions.indices.contains { j in
                        j != k && regions[j].insetBy(dx: -reach, dy: -reach).intersects(r) && min(regions[j].maxY, regions[k].maxY) > max(regions[j].minY, regions[k].minY)
                    }
                    // Axis titles in body type: a few words within the drawing's width, not the end of a paragraph.
                    let title = line.wordCount <= 4 && r.minX >= regions[k].minX - 2 && r.maxX <= regions[k].maxX + 2
                        && !Self.endsParagraph(line, in: lines)
                    if inside || bridging || (near && (small || title)) {
                        let grown = regions[k].union(r)
                        if grown != regions[k] {
                            regions[k] = grown
                            changed = true
                        }
                    }
                }
            }
            if !changed { break }
        }
        // A "figure" full of running text is a frame or background, not a drawing.
        regions.removeAll { region in
            let prose = lines.filter { region.contains($0.rect.center) && $0.wordCount >= 8 && abs($0.size - bodySize) < 0.6 }
            return prose.count >= 3
        }
        // Merge overlapping regions.
        var merged: [CGRect] = []
        for region in regions.sorted(by: { $0.area > $1.area }) {
            if let k = merged.firstIndex(where: { $0.intersects(region) }) { merged[k] = merged[k].union(region) } else { merged.append(region) }
        }
        return merged
    }

    /// Column gutters of a table: strips at least half an em wide that no glyph of the table touches, with text on
    /// both sides in at least two rows.
    static func columnGutters(in table: CGRect, lines: [LayoutLine]) -> [ClosedRange<Double>] {
        let inside = lines.filter { table.insetBy(dx: -1, dy: -2).contains($0.rect.center) }
        let glyphs = inside.flatMap { $0.chars.filter { !$0.isSpace } }
        guard glyphs.count > 10, table.width > 20 else { return [] }
        let size = glyphs.map(\.size).sorted()[glyphs.count / 2]
        let step = 0.5
        let bins = Int((table.width / step).rounded(.up)) + 1
        var covered = [Bool](repeating: false, count: bins)
        for c in glyphs {
            let a = max(0, Int(((c.rect.minX - table.minX) / step).rounded(.down)) + 1)
            let b = min(bins - 1, Int(((c.rect.maxX - table.minX) / step).rounded(.up)) - 1)
            if a <= b { for x in a...b { covered[x] = true } }
        }
        var result: [ClosedRange<Double>] = []
        var x = 0
        while x < bins {
            guard !covered[x] else { x += 1; continue }
            var e = x
            while e + 1 < bins, !covered[e + 1] { e += 1 }
            let strip = (table.minX + Double(x) * step)...(table.minX + Double(e + 1) * step)
            x = e + 1
            guard strip.upperBound - strip.lowerBound >= size * 0.5 else { continue }
            let rows = inside.filter { line in
                line.chars.contains { !$0.isSpace && $0.rect.maxX <= strip.lowerBound + 0.5 }
                    && line.chars.contains { !$0.isSpace && $0.rect.minX >= strip.upperBound - 0.5 }
            }
            if rows.count >= 2 { result.append(strip) }
        }
        return result
    }

    /// A line right under a line of running text (a caption's second line), in the same type.
    static func continuesText(_ line: LayoutLine, in lines: [LayoutLine]) -> Bool {
        lines.contains { other in
            let drop = other.baseline - line.baseline
            return drop > line.size * 0.5 && drop < line.size * 1.7 && abs(other.size - line.size) < line.size * 0.1
                && other.wordCount >= 6 && line.minX < other.maxX && line.maxX > other.minX && abs(other.minX - line.minX) < line.size * 2
        }
    }

    /// The short last line of a paragraph: right under a long line starting at the same place.
    static func endsParagraph(_ line: LayoutLine, in lines: [LayoutLine]) -> Bool {
        lines.contains { other in
            let drop = other.baseline - line.baseline
            return drop > 0 && drop < line.size * 1.7 && abs(other.minX - line.minX) < line.size * 1.5 && other.inkRect.width > line.size * 15
        }
    }

    /// A shape behind running text (a coloured box, a frame around an abstract) rather than part of a drawing.
    static func isBackground(_ rect: CGRect, lines: [LayoutLine], boxy: Bool) -> Bool {
        // A plain box (a shaded row, a highlight) with any text on it; a drawn shape only with a lot of text.
        textInside(rect, lines: lines) >= (boxy ? 3 : 40)
    }

    static func textInside(_ rect: CGRect, lines: [LayoutLine]) -> Int {
        var chars = 0
        for line in lines where rect.insetBy(dx: -1, dy: -1).contains(line.rect.center) { chars += line.visibleCount }
        return chars
    }

    // MARK: Line roles

    func isMarginal(_ line: LayoutLine, page: CGRect, lines: [LayoutLine] = []) -> Bool {
        let top = page.maxY - page.height * 0.065, bottom = page.minY + page.height * 0.06
        guard line.rect.minY > top || line.rect.maxY < bottom else { return false }
        // The last line of a full column may reach into the margin: it goes on from the line next to it.
        if line.wordCount >= 4, abs(line.size - bodySize) < bodySize * 0.12 {
            let continues = lines.contains { other in
                let distance = abs(other.baseline - line.baseline)
                return distance > line.size * 0.5 && distance < line.size * 1.6 && abs(other.size - line.size) < line.size * 0.1
                    && other.minX < line.maxX && other.maxX > line.minX && other.rect.minY <= top && other.rect.maxY >= bottom
            }
            if continues { return false }
        }
        let text = line.text.trimmingCharacters(in: .whitespaces)
        let numeric = text.range(of: #"^[\divxlcIVXLC\-–—/ ]+$"#, options: .regularExpression) != nil
        return numeric || line.size < bodySize * 0.95 || line.wordCount <= 12
    }

    func isDisplayMath(_ line: LayoutLine) -> Bool {
        let ratio = line.mathRatio
        let text = line.text
        // An equation number at the end: "… = … (11)".
        let numbered = text.range(of: #"\(\d+[a-z]?\)\s*$"#, options: .regularExpression) != nil
        if numbered, ratio >= 0.2 || text.contains("=") { return true }
        // "where" and a display: nothing to translate around it, and its limits and fractions stay with it.
        if ratio >= 0.7, Self.textWords(line) <= 1, text.range(of: #"^\s*(where|with|for|and|or|s\.t\.|subject to|if)\b"#, options: .regularExpression) != nil,
           let last = text.trimmingCharacters(in: .whitespaces).last, ",.;)".contains(last) || last.isNumber { return true }
        // A line starting with a word in lower case continues a sentence ("of queries as ŷ = …").
        if let first = line.chars.first(where: { !$0.isSpace }), !first.isMath, first.text.first?.isLowercase == true, Self.textWords(line) >= 1 {
            return false
        }
        // Words set in text type ("with … and …", "where …") make it running text with inline formulas.
        let words = Self.textWords(line)
        if words >= 2 && ratio < 0.85 { return false }
        return ratio >= 0.55 && line.wordCount <= 12
    }

    /// Words in lower case of three or more letters: a row of column names has few, a line of text many.
    static func proseWords(_ line: LayoutLine) -> Int {
        line.text.split(whereSeparator: \.isWhitespace).filter { word in
            let letters = word.trimmingCharacters(in: .punctuationCharacters)
            return letters.count >= 3 && letters.allSatisfy(\.isLowercase)
        }.count
    }

    /// Words of three or more letters outside formulas.
    static func textWords(_ line: LayoutLine) -> Int {
        var count = 0, run = 0
        for c in line.chars {
            if !c.isMath, !c.isSpace, c.text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                run += 1
            } else {
                if run >= 3 { count += 1 }
                run = 0
            }
        }
        return count + (run >= 3 ? 1 : 0)
    }

    // MARK: Blocks

    func canJoin(_ block: LayoutBlock, _ line: LayoutLine) -> Bool {
        guard let last = block.lines.last else { return false }
        let size = block.size
        if abs(line.size - size) > size * 0.16 { return false }
        let drop = last.baseline - line.baseline
        guard drop > size * 0.4 else { return false }
        let maxPitch = block.lines.count >= 2 ? min(block.pitch * 1.35 + 0.5, size * 2.0) : size * 1.9
        if drop > maxPitch { return false }
        let r = block.rect
        let overlap = min(r.maxX, line.maxX) - max(r.minX, line.minX)
        if overlap < min(r.width, line.inkRect.width) * 0.5 { return false }
        // A rule between two lines (the row of a table with its own rules, a line above a footnote) keeps them apart.
        if pageRules.contains(where: { rule in
            rule.midY < last.baseline - last.size * 0.2 && rule.midY > line.baseline + line.size * 0.6
                && min(rule.maxX, min(last.maxX, line.maxX)) - max(rule.minX, max(last.minX, line.minX)) > min(last.inkRect.width, line.inkRect.width) * 0.3
        }) { return false }
        // Text running on past a figure beside it, at full width: a block of its own, so each keeps its own width.
        if block.lines.count >= 2, line.minX < r.minX - size * 2 || line.maxX > r.maxX + size * 2 { return false }
        if Self.isCaptionStart(line.text) { return false }
        // "References" stands alone, whatever its type (IEEE sets it in small capitals like the entries).
        if Self.isReferencesHeading(last.text) || Self.isReferencesHeading(line.text) { return false }
        // A paragraph set in bold (IEEE abstracts): full lines of one style belong together.
        if last.font.isBold, line.font.isBold, abs(last.size - line.size) < size * 0.06, drop <= size * 1.45,
           last.inkRect.width > size * 18, !Self.isListItem(line.text) {
            return true
        }
        // Headings stand alone, except a heading (or bold paragraph) that continues in the same style.
        let lastHeading = isHeadingLike(last), lineHeading = isHeadingLike(line)
        if lastHeading || lineHeading {
            let sameStyle = lastHeading == lineHeading && last.font.isBold == line.font.isBold && abs(last.size - line.size) < last.size * 0.06
            let numbered = line.text.range(of: #"^\s*((\d{1,2}(\.\d+)*\.?)|([IVX]+\.)|([A-Z]\.))\s+\p{Lu}"#, options: .regularExpression) != nil
            if !sameStyle || numbered || drop > size * 1.45 { return false }
            return true
        }
        // A paragraph opening with bold words ("Problem Formulation. The entire …"), after a finished sentence.
        if !last.font.isBold, let opening = line.chars.first(where: { !$0.isSpace }), opening.font.isBold, !opening.isMath,
           line.chars.prefix(12).filter({ !$0.isSpace && $0.font.isBold }).count >= 6,
           let end = last.text.trimmingCharacters(in: .whitespaces).last, ".:?!。".contains(end) {
            return false
        }
        // A bullet always starts an item; "(2)" or "3." only after a line that stopped short.
        if Self.isListItem(line.text) {
            let bullet = line.text.trimmingCharacters(in: .whitespaces).first.map { "•▪◦●○■□‣∙·-–—*\u{FFFD}".contains($0) } ?? false
            if bullet || last.maxX < r.maxX - size * 2 { return false }
        }
        // A line in another colour is another element (a coloured heading or note), unless it is mostly citations.
        if abs(line.color.r - block.color.r) + abs(line.color.g - block.color.g) + abs(line.color.b - block.color.b) > 0.6,
           Self.textWords(line) >= 3 || isHeadingLike(line) { return false }
        // Short lines one under another, each starting anew: a list of names, addresses or keywords, not a paragraph.
        if let columnOf {
            let column = columnOf((line.minX + line.maxX) / 2)
            let width = min(column.hi - column.lo, typicalWidth)
            let opening = line.chars.first { !$0.isSpace }
            let startsAnew = opening.map { $0.isMath || $0.isScript || $0.text.first?.isUppercase == true || $0.text.first?.isNumber == true } ?? false
            let goesOn = last.text.range(of: #"(,|-|\b(and|or|of|the|for|to|with|in|on|by|a|an))\s*$"#, options: .regularExpression) != nil
            let ragged = abs(last.maxX - line.maxX) > size * 0.4
            // Lists like these are the front matter of a paper, or small print; a caption or narrow text runs on.
            let listLike = currentPage == 1 || size < bodySize * 0.96
            if listLike, !Self.isCaptionStart(block.lines[0].text), width > 0, last.inkRect.width < width * 0.6, line.inkRect.width < width * 0.6,
               ragged, startsAnew, !goesOn { return false }
        }
        // A new paragraph: the line is indented from the block's left edge …
        let left = block.lines.count > 1 ? block.lines.dropFirst().map(\.minX).min()! : last.minX
        let hanging = block.lines.count == 1 && Self.isListItem(last.text)
        // (lines centred under one another are not indented)
        let centred = abs((line.minX + line.maxX) / 2 - r.midX) < size * 0.6 && line.maxX < r.maxX - size * 0.8
        if !hanging, !centred, line.minX > left + size * 0.8, last.maxX > r.maxX - size * 2 { return false }
        // … or the previous line ended a sentence well short of the right edge.
        if block.lines.count >= 2, last.maxX < r.maxX - size * 4,
           let end = last.text.trimmingCharacters(in: .whitespaces).last, ".:?!。".contains(end) {
            return false
        }
        return true
    }

    func isHeadingLike(_ line: LayoutLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        guard line.wordCount <= 14, !text.isEmpty else { return false }
        if text.hasSuffix(",") || text.hasSuffix("-") { return false }
        // (a year starting a line of text, "2022. He is", is no section number)
        var numbered = text.range(of: #"^((\d{1,2}(\.\d+)*\.?)|([IVX]+\.)|([A-Z]\.))\s+\p{Lu}"#, options: .regularExpression) != nil
        // An initial and a name ("G. Sharma, “…”") is a line of a reference, not section "G".
        if numbered, text.range(of: #"^[A-Z]\.\s"#, options: .regularExpression) != nil, text.contains(",") || text.contains("“") { numbered = false }
        let bold = line.font.isBold
        let large = line.size >= bodySize * 1.12
        // Bold words that run on into plain ones start a paragraph: "Datasets. We use".
        if bold, !large, let end = line.chars.last(where: { !$0.isSpace }), !end.font.isBold, !end.isMath { return false }
        if numbered && (bold || large || line.wordCount <= 8) { return true }
        return (bold || large) && line.chars.filter { !$0.isSpace && $0.font.isBold == bold }.count * 10 >= line.visibleCount * 8
    }

    static func isCaptionStart(_ text: String) -> Bool {
        // Not a sentence that happens to start the line with a reference to one ("Fig. 3 and recount …", "Fig. 2 bottom)."):
        // punctuation, a capital, or nothing comes after the number.
        text.range(of: #"^\s*(Figure|Fig\.?|FIGURE|FIG\.?|Table|TABLE|Tab\.|Algorithm|Listing|Scheme|Chart|Supplementary (Figure|Table)|图|表)\s*(S?\d+|[IVXLC]+\b)(\s*$|\s*[.:：|—–\-]|\s+[\p{Lu}\p{Han}])"#,
                   options: .regularExpression) != nil
    }

    /// "• …", "– …", "1) …", "(ii) …", "[3] …" at the start of a line.
    static func isListItem(_ text: String) -> Bool {
        text.range(of: #"^\s*([•▪◦●○■□‣∙·\-–—*\x{FFFD}]|\(?[0-9]{1,2}[.)]|\([ivxIVX]{1,4}\)|\([a-z]\)|\[\d{1,3}\])\s"#, options: .regularExpression) != nil
    }

    static func isAlgorithmStart(_ text: String) -> Bool {
        text.range(of: #"^\s*(Algorithm|ALGORITHM|Procedure|Pseudocode|算法)\s*\d*"#, options: .regularExpression) != nil
    }

    /// Cell text worth translating: not an abbreviation ("AS", "mIoU", "CVPR22"), not mostly numbers.
    static func isCellText(_ raw: String) -> Bool {
        // Citations say nothing to translate: "SHADE (Zhao et al. 2022)" is a name.
        var text = raw.replacingOccurrences(of: #"\([^()]*(et al|\d{4})[^()]*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[[\d,\s–\-]+\]"#, with: " ", options: .regularExpression)
        let cited = text != raw
        text = text.trimmingCharacters(in: .whitespaces)
        let tokens = text.split(whereSeparator: \.isWhitespace)
        // A name with its citation: the method or dataset of that paper ("Rein [74]", "TENT (Wang et al. 2021)").
        if cited, tokens.count <= 3 { return false }
        if tokens.count == 1, text.range(of: #"^[A-Z0-9][A-Za-z0-9\-\.+/@%]{0,7}$"#, options: .regularExpression) != nil,
           text.filter(\.isUppercase).count >= 2 || text.contains(where: \.isNumber) {
            return false
        }
        let numeric = tokens.filter { $0.range(of: #"^[\d.,±%()\-–+*†‡]+$"#, options: .regularExpression) != nil }.count
        guard numeric * 2 < tokens.count else { return false }
        // Names of models, datasets and venues (ResNet, EVA02-L [18], DINOv2, CVPR22) stay: something must read as a word.
        return tokens.contains { token in
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            return word.count >= 3 && word.allSatisfy(\.isLetter) && word.dropFirst().allSatisfy(\.isLowercase)
        }
    }

    static func hasWords(_ text: String) -> Bool {
        text.range(of: #"\p{L}{2,}"#, options: .regularExpression) != nil
    }

    mutating func classify(_ blocks: inout [LayoutBlock], page: Int, crop: CGRect, boxes: [CGRect] = []) {
        // Title: the largest text near the top of the first page.
        var titleIndex: Int?
        if page == 1 {
            let candidates = blocks.indices.filter { i in
                let rect = blocks[i].rect
                return rect.minY > crop.midY - crop.height * 0.1 && blocks[i].size >= bodySize * 1.25 && Self.textWords(blocks[i].lines[0]) >= 2
                    && !boxes.contains { $0.insetBy(dx: -2, dy: -2).contains(rect) }
            }
            titleIndex = candidates.max { blocks[$0].size < blocks[$1].size }
        }
        // Names and addresses end where the abstract starts; without one, at the first real paragraph or section.
        var abstractTop: Double?
        if page == 1 {
            if let abstract = blocks.first(where: { Self.isAbstractStart($0.text) }) { abstractTop = abstract.rect.maxY }
            if abstractTop == nil, let titleIndex {
                let titleBottom = blocks[titleIndex].rect.minY
                for block in blocks where block.rect.maxY <= titleBottom + 1 {
                    let isBody = block.lines.count >= 4 && block.lines.dropLast().allSatisfy { $0.wordCount >= 6 }
                    let isFirstSection = block.text.range(of: #"^\s*(1\.?|I\.)\s+\p{Lu}"#, options: .regularExpression) != nil && block.lines.count <= 2
                    if isBody || isFirstSection { abstractTop = max(abstractTop ?? 0, block.rect.maxY) }
                }
            }
        }

        for i in blocks.indices {
            let text = blocks[i].text.trimmingCharacters(in: .whitespaces)
            let first = blocks[i].lines[0]
            if i == titleIndex {
                blocks[i].kind = .title
                continue
            }
            if Self.isCaptionStart(text) {
                blocks[i].kind = .caption
                continue
            }
            // An entry of a reference list with no heading to it: only that entry stays.
            if !inReferences, !options.translateReferences, Self.isReferenceEntry(blocks[i]) {
                blocks[i].kind = .reference
                blocks[i].translate = false
                continue
            }
            // The tail of an entry cut off from it ("Mach. Intell., vol. 47, no. 5, pp. 3673–3690, May 2025.").
            if !options.translateReferences, blocks[i].lines.count <= 2, text.range(of: #"\b(vol\.|pp\.)\s*\d"#, options: .regularExpression) != nil,
               text.range(of: #"(19|20)\d\d"#, options: .regularExpression) != nil {
                blocks[i].kind = .reference
                blocks[i].translate = false
                continue
            }
            // Running text in the middle of the references: the list has ended (an appendix, the next chapter).
            if inReferences, Self.isRunningProse(blocks[i]) { inReferences = false }
            if !inReferences, let titleIndex, let abstractTop, blocks[i].rect.minY > abstractTop, blocks[i].rect.maxY <= blocks[titleIndex].rect.minY + 1 {
                blocks[i].kind = .author
                blocks[i].translate = false
                continue
            }
            let heading = blocks[i].lines.count <= 2 && blocks[i].lines.allSatisfy { isHeadingLike($0) || $0.font.isBold && $0.wordCount <= 10 }
                || blocks[i].lines.count == 1 && Self.isReferencesHeading(text)
            if heading {
                blocks[i].kind = .heading
                if Self.isReferencesHeading(text) {
                    inReferences = !options.translateReferences
                    continue
                }
                if inReferences, Self.endsReferences(text) || Self.isNumberedSection(text) { inReferences = false }
                if inReferences { blocks[i].kind = .reference; blocks[i].translate = false }
                continue
            }
            if inReferences {
                blocks[i].kind = .reference
                blocks[i].translate = false
                continue
            }
            if blocks[i].font.isMonospace && first.font.isMonospace {
                blocks[i].kind = .code
                blocks[i].translate = false
                continue
            }
            if !Self.hasWords(text) {
                blocks[i].kind = .other
                blocks[i].translate = false
            }
        }
        // Nothing to translate in a block without real words ("V = sample(F, C)", a brace, "(a)").
        for i in blocks.indices where blocks[i].translate {
            let words = blocks[i].lines.reduce(0) { $0 + Self.textWords($1) }
            let mathHeavy = blocks[i].lines.reduce(0.0) { $0 + $1.mathRatio } / Double(blocks[i].lines.count) > 0.3
            let first = blocks[i].lines[0].chars.first { !$0.isSpace }
            let continues = first.map { !$0.isMath && $0.text.first?.isLowercase == true } ?? false
            let needed = blocks[i].kind == .paragraph && mathHeavy && !continues ? 2 : 1
            let text = blocks[i].text.trimmingCharacters(in: .whitespaces)
            let url = text.range(of: #"^(https?://|www\.|doi:|arXiv:)\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
                || text.range(of: #"^\S+@\S+\.\S+$"#, options: .regularExpression) != nil
            if url {
                blocks[i].kind = .other
                blocks[i].translate = false
            } else if words < needed, blocks[i].kind != .title {
                blocks[i].kind = blocks[i].kind == .paragraph ? .formula : .other
                blocks[i].translate = false
            }
        }
    }

    static func isAbstractStart(_ text: String) -> Bool {
        text.range(of: #"^\s*(a\s?b\s?s\s?t\s?r\s?a\s?c\s?t|summary|摘\s*要)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isReferencesHeading(_ text: String) -> Bool {
        text.range(of: #"^\s*((\d+|[IVX]+)\.?\s*)?(References|REFERENCES|Reference|Bibliography|BIBLIOGRAPHY|Literature Cited|Works Cited|参考文献)\s*$"#,
                   options: .regularExpression) != nil
    }

    /// "[12] A. Author, B. Author, “Title,” in Venue, 2019."
    static func isReferenceEntry(_ block: LayoutBlock) -> Bool {
        let text = block.text
        return block.lines.count <= 8 && text.range(of: #"^\s*\[\d{1,3}\]\s+\p{Lu}"#, options: .regularExpression) != nil
            && text.range(of: #"(19|20)\d\d"#, options: .regularExpression) != nil && text.filter { $0 == "," }.count >= 2
    }

    /// Five or more lines of sentences with nothing of a reference about them.
    static func isRunningProse(_ block: LayoutBlock) -> Bool {
        let text = block.text
        guard block.lines.count >= 5, text.split(separator: " ").count >= 50 else { return false }
        return text.range(of: #"(19|20)\d\d|et al|\bpp\.|\bvol\.|\bProc\b|\bConf\b|\bJ\.|doi|arXiv|^\s*\[\d"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// "3 Climbers", "3.2 Power" — no entry reads like this: entries have authors and commas.
    static func isNumberedSection(_ text: String) -> Bool {
        text.range(of: #"^\s*\d{1,2}(\.\d+)*\.?\s+\p{Lu}\p{Ll}"#, options: .regularExpression) != nil && !text.contains(",") && text.split(separator: " ").count <= 10
    }

    static func endsReferences(_ text: String) -> Bool {
        if text.range(of: #"^\s*(Appendix|APPENDIX|Appendices|Supplementary|SUPPLEMENTARY|Supplemental|附录)"#, options: .regularExpression) != nil {
            return true
        }
        // "A. Proofs", "B.2 Training details" — not an entry's author line ("G. Sharma, “Weakly-supervised …").
        return text.range(of: #"^\s*[A-H](\.\d+)*\.?\s+\p{Lu}\p{Ll}"#, options: .regularExpression) != nil
            && !text.contains(",") && !text.contains("“") && !text.contains("\"") && !text.hasSuffix("-")
            && text.split(separator: " ").count <= 10
    }
}

extension CGRect {
    var area: Double { isNull ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
