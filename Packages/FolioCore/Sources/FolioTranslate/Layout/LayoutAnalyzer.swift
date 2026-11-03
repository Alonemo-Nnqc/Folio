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

    init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Document

    /// Analyses `pages` (1-based numbers) of the document.
    mutating func analyze(document: PDFDocument, cgDocument: CGPDFDocument, pages: [Int]) -> [PageLayout] {
        var prepared: [(Int, ContentInterpreter, [PageChar])] = []
        var sizeCounts: [Double: Int] = [:]
        for number in pages {
            guard let cgPage = cgDocument.page(at: number), let page = document.page(at: number - 1) else { continue }
            let interpreter = ContentInterpreter()
            interpreter.run(page: cgPage)
            let chars = PageText.characters(of: page, runs: interpreter.runs)
            for c in chars where !c.isSpace && !c.isNewline && !c.isRotated {
                sizeCounts[(c.size * 2).rounded() / 2, default: 0] += 1
            }
            prepared.append((number, interpreter, chars))
        }
        bodySize = sizeCounts.max { $0.value < $1.value }?.key ?? 10
        inReferences = false
        return prepared.map { number, interpreter, chars in
            analyzePage(number: number, cgPage: cgDocument.page(at: number)!, interpreter: interpreter, chars: chars)
        }
    }

    // MARK: Page

    mutating func analyzePage(number: Int, cgPage: CGPDFPage, interpreter: ContentInterpreter, chars rawChars: [PageChar]) -> PageLayout {
        let media = cgPage.getBoxRect(.mediaBox)
        var crop = cgPage.getBoxRect(.cropBox).intersection(media)
        if crop.isNull || crop.width < 1 { crop = media }
        var chars = rawChars
        MathDetector.mark(&chars)

        let marks = interpreter.marks.filter { !$0.isWhite && $0.rect.width * $0.rect.height < crop.width * crop.height * 0.6 }
        let rules = marks.filter { ($0.kind == .fill || $0.kind == .stroke) && $0.rect.height < 2.5 && $0.rect.width > 30 }.map(\.rect)
        // Regions first, from lines not yet split into cells; then the final lines.
        var lines = buildLines(chars, tables: [], pageWidth: crop.width)
        var tables = Self.tableFrames(rules: rules, lines: lines).map { Self.trimCaptions($0, lines: lines) }.filter { isTable($0, lines: lines) }
        let figures = figureRegions(marks: marks, lines: lines, tables: tables, page: crop)
        tables.removeAll { table in figures.contains { $0.intersection(table).area > table.area * 0.4 } }
        lines = buildLines(chars, tables: tables, pageWidth: crop.width).map(Self.markScripts)
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
        for number in numbers {
            for (k, line) in lines.enumerated() where line.maxX < number.minX && abs(line.baseline - number.baseline) < number.size * 0.6 {
                if Self.textWords(line) <= 3 { equations.insert(k) }
            }
        }

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
            } else if figures.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(center) }) && !Self.isCaptionStart(line.text) {
                blocks.append(LayoutBlock(kind: .figure, lines: [line], translate: false))
            } else if tables.contains(where: { $0.insetBy(dx: -1, dy: -2).contains(center) }) {
                let translate = options.translateTables && Self.hasWords(line.text) && !line.font.isMonospace && Self.isCellText(line.text)
                blocks.append(LayoutBlock(kind: .tableCell, lines: [line], translate: translate))
            } else if isMarginal(line, page: crop) {
                blocks.append(LayoutBlock(kind: .header, lines: [line], translate: false))
            } else if isDisplayMath(line) || equations.contains(k) || numbers.contains(where: { $0.inkRect == line.inkRect }) {
                blocks.append(LayoutBlock(kind: .formula, lines: [line], translate: false))
            } else {
                flowing.append(line)
            }
        }

        // Running text → paragraphs, headings, captions.
        var current: LayoutBlock?
        var textBlocks: [LayoutBlock] = []
        for line in flowing {
            if var block = current, canJoin(block, line) {
                block.lines.append(line)
                current = block
            } else {
                if let block = current { textBlocks.append(block) }
                current = LayoutBlock(kind: .paragraph, lines: [line], translate: true)
            }
        }
        if let block = current { textBlocks.append(block) }
        // Shaded boxes (a journal's banner) do not hold the paper's title.
        let boxes = marks.filter { $0.kind == .fill && $0.rect.width * $0.rect.height > 3000 }.map(\.rect)
        classify(&textBlocks, page: number, crop: crop, boxes: boxes)
        blocks.append(contentsOf: textBlocks)

        Self.mergeInterleaved(&blocks)
        Self.absorbStrays(&blocks)
        let graphics = marks.map(\.rect) + figures
        return PageLayout(number: number, mediaBox: media, cropBox: crop, blocks: blocks, figures: figures, tables: tables,
                          graphics: graphics, runs: interpreter.runs)
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
                            && line.minX < host.maxX + host.size * 1.5 && line.maxX > host.minX - host.size * 1.5
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
    func buildLines(_ chars: [PageChar], tables: [CGRect], pageWidth: Double) -> [LayoutLine] {
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
                let inTable = tables.contains { $0.insetBy(dx: -1, dy: -2).contains(c.center) }
                let limit = (inTable ? 0.75 : 2.2) * max(mainSize, c.size)
                if !sameLine || gap > limit || gap < -max(mainSize, 4) * 1.5 || c.isRotated != last.isRotated {
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
            outer: for a in lines.indices {
                for b in lines.indices where b != a {
                    let l = lines[a], r = lines[b]
                    // A short piece of formula may sit off the baseline (PDFKit placed only its scripts).
                    func formulaPiece(_ line: LayoutLine) -> Bool {
                        line.visibleCount <= 8 && (line.mathRatio >= 0.5 || line.chars.contains { $0.isScript || $0.size < line.size * 0.85 })
                    }
                    let piece = formulaPiece(l) || formulaPiece(r)
                    // A piece of formula sits up to about half an em off its host line's baseline.
                    let host = l.visibleCount >= r.visibleCount ? l : r
                    let baselineTolerance = piece ? host.size * 0.7 : min(l.size, r.size) * 0.3
                    guard !l.isRotated, !r.isRotated, r.minX >= l.minX,
                          abs(l.baseline - r.baseline) < baselineTolerance,
                          piece || abs(l.size - r.size) < max(l.size, r.size) * 0.2 else { continue }
                    let gap = r.minX - l.maxX
                    guard !inTable(l.rect), !inTable(r.rect) else { continue }
                    if gap < -min(l.size, r.size) * 0.5 {
                        guard abs(l.baseline - r.baseline) < min(l.size, r.size) * 0.3, abs(l.size - r.size) < max(l.size, r.size) * 0.2 else { continue }
                        // Interleaved pieces (accents and scripts PDFKit split off): one line if their glyphs do not collide.
                        let lGlyphs = l.chars.filter { !$0.isSpace && $0.size >= l.size * 0.85 }.map(\.rect)
                        let collisions = r.chars.filter { c in
                            !c.isSpace && c.size >= r.size * 0.85
                                && lGlyphs.contains { $0.minX < c.rect.maxX - c.rect.width * 0.4 && $0.maxX > c.rect.minX + c.rect.width * 0.4 }
                        }.count
                        guard collisions <= max(1, r.visibleCount / 10), r.minX < l.maxX, r.maxX > l.minX else { continue }
                    } else {
                        // Scripts may overlap (a subscript under a superscript); full-size text may not.
                        let lMain = l.chars.filter { !$0.isSpace && $0.size >= l.size * 0.85 }.map { Double($0.rect.maxX) }.max() ?? l.maxX
                        let rMain = r.chars.filter { !$0.isSpace && $0.size >= r.size * 0.85 }.map { Double($0.rect.minX) }.min() ?? r.minX
                        guard rMain - lMain > -min(l.size, r.size) * 0.5, gap < max(l.size, r.size) * 1.0 else { continue }
                    }
                    // Two lines that each fill a column are neighbouring columns, not pieces of one line.
                    if l.inkRect.width > pageWidth * 0.3, r.inkRect.width > pageWidth * 0.3 { continue }
                    var space = l.chars.last!
                    space.text = " "
                    space.isSpace = true
                    space.isMath = false
                    space.rect = CGRect(x: l.maxX, y: space.rect.minY, width: max(gap, 0), height: space.rect.height)
                    let chars = gap > 0 ? l.chars + [space] + r.chars : l.chars + r.chars
                    guard let line = makeLine(chars) else { continue }
                    let first = min(a, b)
                    lines[first] = line
                    lines.remove(at: max(a, b))
                    merged = true
                    break outer
                }
            }
        }
        return lines
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
        line.chars = chars
        return line
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

    static func makeLine(_ unordered: [PageChar]) -> LayoutLine? {
        // Left to right: PDFKit sometimes lists scripts out of order.
        var chars = unordered
        if chars.filter(\.isRotated).count * 2 <= chars.count {
            chars = chars.enumerated().sorted { a, b in
                a.element.rect.minX != b.element.rect.minX ? a.element.rect.minX < b.element.rect.minX : a.offset < b.offset
            }.map(\.element)
            chars = trimSpaces(chars)
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
        for c in visible where c.text.first?.isLetter == true { colorCounts[c.color, default: 0] += 1 }
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
                        && (isCaptionStart(line.text) || textWords(line) >= 8)
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
                frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(line.rect.minY - 1 - frame.minY, 0))
            }
        }
        return frame
    }

    /// Rules around running text (a frame around an abstract) do not make a table: tables have several cells
    /// per row and short lines.
    func isTable(_ frame: CGRect, lines: [LayoutLine]) -> Bool {
        let inside = lines.filter { frame.insetBy(dx: -1, dy: -2).contains($0.rect.center) }
        guard inside.count >= 2 else { return false }
        let chars = inside.reduce(0) { $0 + $1.visibleCount }
        // Fraction bars of a big equation.
        let math = inside.reduce(0) { $0 + $1.chars.filter(\.isMath).count }
        if Double(math) > Double(chars) * 0.4 { return false }
        let prose = inside.filter { Self.textWords($0) >= 6 }.reduce(0) { $0 + $1.visibleCount }
        if Double(prose) > Double(chars) * 0.5 { return false }
        // At least two rows with two or more cells: separate lines on one baseline, or wide gaps inside a line.
        var rows: [Double: Int] = [:]
        for line in inside { rows[(line.baseline / 3).rounded(), default: 0] += 1 + Self.columnGaps(line) }
        return rows.values.filter { $0 >= 2 }.count >= 2 || inside.count >= 6
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
                    minor.append(r)
                } else if !Self.isBackground(r, lines: lines, boxy: boxy) {
                    seeds.append(r)
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
                    if regions[k].contains(r) || Self.isCaptionStart(line.text) { continue }
                    let inside = regions[k].contains(r.center)
                    let near = regions[k].insetBy(dx: -reach, dy: -reach).intersects(r)
                    let small = line.size < bodySize * 0.96 && (line.wordCount <= 6 || line.size < bodySize * 0.9)
                    // Axis titles in body type: a few words within the drawing's width, not the end of a paragraph.
                    let title = line.wordCount <= 4 && r.minX >= regions[k].minX - 2 && r.maxX <= regions[k].maxX + 2
                        && !Self.endsParagraph(line, in: lines)
                    if inside || (near && (small || title)) {
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

    /// The short last line of a paragraph: right under a long line starting at the same place.
    static func endsParagraph(_ line: LayoutLine, in lines: [LayoutLine]) -> Bool {
        lines.contains { other in
            let drop = other.baseline - line.baseline
            return drop > 0 && drop < line.size * 1.7 && abs(other.minX - line.minX) < line.size * 1.5 && other.inkRect.width > line.size * 15
        }
    }

    /// A shape behind running text (a coloured box, a frame around an abstract) rather than part of a drawing.
    static func isBackground(_ rect: CGRect, lines: [LayoutLine], boxy: Bool) -> Bool {
        var chars = 0
        for line in lines where rect.insetBy(dx: -1, dy: -1).contains(line.rect.center) { chars += line.visibleCount }
        // A plain box (a shaded row, a highlight) with any text on it; a drawn shape only with a lot of text.
        return chars >= (boxy ? 3 : 40)
    }

    // MARK: Line roles

    func isMarginal(_ line: LayoutLine, page: CGRect) -> Bool {
        let top = page.maxY - page.height * 0.065, bottom = page.minY + page.height * 0.06
        guard line.rect.minY > top || line.rect.maxY < bottom else { return false }
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
        // Words set in text type ("with … and …", "where …") make it running text with inline formulas.
        let words = Self.textWords(line)
        if words >= 2 && ratio < 0.85 { return false }
        return ratio >= 0.55 && line.wordCount <= 12
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
        if Self.isCaptionStart(line.text) { return false }
        // A paragraph set in bold (IEEE abstracts): full lines of one style belong together.
        if last.font.isBold, line.font.isBold, abs(last.size - line.size) < size * 0.06, drop <= size * 1.45,
           last.inkRect.width > size * 18, !Self.isListItem(line.text) {
            return true
        }
        // Headings stand alone, except a heading (or bold paragraph) that continues in the same style.
        let lastHeading = isHeadingLike(last), lineHeading = isHeadingLike(line)
        if lastHeading || lineHeading {
            let sameStyle = lastHeading == lineHeading && last.font.isBold == line.font.isBold && abs(last.size - line.size) < last.size * 0.06
            let numbered = line.text.range(of: #"^\s*((\d+(\.\d+)*\.?)|([IVX]+\.)|([A-Z]\.))\s+\p{Lu}"#, options: .regularExpression) != nil
            if !sameStyle || numbered || drop > size * 1.45 { return false }
            return true
        }
        // A bullet always starts an item; "(2)" or "3." only after a line that stopped short.
        if Self.isListItem(line.text) {
            let bullet = line.text.trimmingCharacters(in: .whitespaces).first.map { "•▪◦●○■□‣∙·-–—*".contains($0) } ?? false
            if bullet || last.maxX < r.maxX - size * 2 { return false }
        }
        // A line in another colour is another element (a coloured heading or note), unless it is mostly citations.
        if abs(line.color.r - block.color.r) + abs(line.color.g - block.color.g) + abs(line.color.b - block.color.b) > 0.6,
           Self.textWords(line) >= 3 || isHeadingLike(line) { return false }
        // A new paragraph: the line is indented from the block's left edge …
        let left = block.lines.count > 1 ? block.lines.dropFirst().map(\.minX).min()! : last.minX
        let hanging = block.lines.count == 1 && Self.isListItem(last.text)
        if !hanging, line.minX > left + size * 0.8, last.maxX > r.maxX - size * 2 { return false }
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
        if text.hasSuffix(",") { return false }
        let numbered = text.range(of: #"^((\d+(\.\d+)*\.?)|([IVX]+\.)|([A-Z]\.))\s+\p{Lu}"#, options: .regularExpression) != nil
        let bold = line.font.isBold
        let large = line.size >= bodySize * 1.12
        if numbered && (bold || large || line.wordCount <= 8) { return true }
        return (bold || large) && line.chars.filter { !$0.isSpace && $0.font.isBold == bold }.count * 10 >= line.visibleCount * 8
    }

    static func isCaptionStart(_ text: String) -> Bool {
        text.range(of: #"^\s*(Figure|Fig\.?|FIGURE|FIG\.?|Table|TABLE|Tab\.|Algorithm|Listing|Scheme|Chart|Supplementary (Figure|Table)|图|表)\s*[S]?\d+"#,
                   options: .regularExpression) != nil
    }

    /// "• …", "– …", "1) …", "(ii) …", "[3] …" at the start of a line.
    static func isListItem(_ text: String) -> Bool {
        text.range(of: #"^\s*([•▪◦●○■□‣∙·\-–—*]|\(?[0-9]{1,2}[.)]|\([ivxIVX]{1,4}\)|\([a-z]\)|\[\d{1,3}\])\s"#, options: .regularExpression) != nil
    }

    static func isAlgorithmStart(_ text: String) -> Bool {
        text.range(of: #"^\s*(Algorithm|ALGORITHM|Procedure|Pseudocode|算法)\s*\d*"#, options: .regularExpression) != nil
    }

    /// Cell text worth translating: not an abbreviation ("AS", "mIoU", "CVPR22"), not mostly numbers.
    static func isCellText(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: \.isWhitespace)
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
        let abstractTop = page == 1 ? blocks.first(where: { Self.isAbstractStart($0.text) })?.rect.maxY : nil

        for i in blocks.indices {
            let text = blocks[i].text.trimmingCharacters(in: .whitespaces)
            let first = blocks[i].lines[0]
            if i == titleIndex {
                blocks[i].kind = .title
                continue
            }
            if Self.isCaptionStart(text) {
                blocks[i].kind = .caption
                if inReferences { inReferences = false }
                continue
            }
            if !inReferences, let titleIndex, let abstractTop, blocks[i].rect.minY > abstractTop, blocks[i].rect.maxY <= blocks[titleIndex].rect.minY + 1 {
                blocks[i].kind = .author
                blocks[i].translate = false
                continue
            }
            let heading = blocks[i].lines.count <= 2 && blocks[i].lines.allSatisfy { isHeadingLike($0) || $0.font.isBold && $0.wordCount <= 10 }
            if heading {
                blocks[i].kind = .heading
                if Self.isReferencesHeading(text) {
                    inReferences = !options.translateReferences
                    continue
                }
                if inReferences, Self.endsReferences(text) { inReferences = false }
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
            let needed = blocks[i].kind == .paragraph && mathHeavy ? 2 : 1
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
        text.range(of: #"^\s*(Abstract|ABSTRACT|A B S T R A C T|Summary|摘\s*要)\b"#, options: .regularExpression) != nil
    }

    static func isReferencesHeading(_ text: String) -> Bool {
        text.range(of: #"^\s*((\d+|[IVX]+)\.?\s*)?(References|REFERENCES|Reference|Bibliography|BIBLIOGRAPHY|Literature Cited|Works Cited|参考文献)\s*$"#,
                   options: .regularExpression) != nil
    }

    static func endsReferences(_ text: String) -> Bool {
        text.range(of: #"^\s*(Appendix|APPENDIX|Appendices|Supplementary|SUPPLEMENTARY|Supplemental|[A-H](\.\d+)*\.?\s+\p{Lu}\p{Ll}|附录)"#,
                   options: .regularExpression) != nil
    }
}

extension CGRect {
    var area: Double { isNull ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
