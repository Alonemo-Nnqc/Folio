import CoreGraphics
import CoreText
import Foundation

/// Line spacing of a page's running text.
///
/// Translations rarely take the lines of their originals, so paragraphs stretched to fill their own space end up with
/// lines further apart than the distance from one paragraph to the next, and every paragraph break reads as a line
/// squeezed in. So what follows one another in a column, with nothing fixed between (paragraphs, and the headings and
/// displayed formulas among them, which move along) is set as one stretch at one size and one spacing, from where the
/// first starts to where the last ends. Spacing stays close to a page-wide value; what that leaves over goes between
/// paragraphs and at the end, never into single lines.
enum PageFlow {
    struct Entry {
        var block: Int
        var frame: CGRect
        var text: String
        var formulas: [FormulaSpan]
        var plan: Typesetter.Plan
    }

    struct Placement {
        var firstBaseline: Double
        var pitch: Double
        /// The area the whole stretch may use.
        var frame: CGRect
    }

    /// A displayed formula going along with the text around it.
    struct FormulaMove {
        var blocks: [Int]
        var span: FormulaSpan
        var dy: Double
    }

    struct Outcome {
        /// By position in the entries.
        var placements: [Int: Placement] = [:]
        var moves: [FormulaMove] = []
    }

    enum Member: Hashable {
        /// A translated block.
        case text(Int)
        /// The blocks of a displayed formula: its rows, its number.
        case formula([Int])
    }

    /// The paragraphs and headings (block numbers, of those in `translated`) of each stretch, top to bottom.
    static func runs(of translated: [Int], in layout: PageLayout) -> [[Int]] {
        flows(of: translated, in: layout).map { flow in
            flow.compactMap { if case .text(let index) = $0 { index } else { nil } }
        }
    }

    static func flows(of translated: [Int], in layout: PageLayout) -> [[Member]] {
        let blocks = layout.blocks
        let measures = blocks.filter { $0.kind == .paragraph && $0.lines.count >= 2 }.map(\.rect.width).sorted()
        let measure = measures.isEmpty ? Double.infinity : measures[measures.count / 2]
        // Short single lines one under another are a list of names or keywords, not running text.
        func isShortLine(_ block: LayoutBlock) -> Bool { block.kind == .paragraph && block.lines.count == 1 && block.rect.width < measure * 0.6 }
        // A single line with something right beside it on its baseline is a row of a table the rules did not reveal.
        // (a full line of a column has the next column beside it)
        func isRow(_ index: Int) -> Bool {
            guard blocks[index].lines.count == 1, blocks[index].rect.width < measure * 0.6 else { return false }
            let line = blocks[index].lines[0]
            return blocks.enumerated().contains { k, other in
                k != index && other.lines.contains { o in
                    !o.isRotated && abs(o.baseline - line.baseline) < line.size * 0.3
                        && (o.minX >= line.maxX && o.minX - line.maxX < line.size * 8 || o.maxX <= line.minX && line.minX - o.maxX < line.size * 8)
                }
            }
        }
        var result: [[Member]] = []
        for index in translated where !isRow(index) {
            let block = blocks[index]
            guard block.kind == .heading || (block.kind == .paragraph && !block.isCentered) else { continue }
            var joined = false
            for k in result.indices.reversed() {
                guard let last = lastText(of: result[k]), !(isShortLine(block) && isShortLine(blocks[last])),
                      let formula = between(index, after: result[k], in: layout) else { continue }
                if !formula.isEmpty { result[k].append(.formula(formula)) }
                result[k].append(.text(index))
                joined = true
                break
            }
            if !joined { result.append([.text(index)]) }
        }
        // There has to be running text; and a single line on its own has no spacing to keep, and may run on sideways.
        return result.filter { flow in
            let texts = flow.compactMap { member -> Int? in if case .text(let index) = member { index } else { nil } }
            return texts.contains { blocks[$0].kind == .paragraph } && (texts.count > 1 || blocks[texts[0]].lines.count > 1)
        }
    }

    private static func lastText(of flow: [Member]) -> Int? {
        for member in flow.reversed() { if case .text(let index) = member { return index } }
        return nil
    }

    /// Whether block `index` can come next in `flow`, in its column with nothing fixed in the way: the blocks of the
    /// displayed formula between them (none is fine), or nil if it cannot.
    static func between(_ index: Int, after flow: [Member], in layout: PageLayout) -> [Int]? {
        let blocks = layout.blocks
        guard let lastIndex = lastText(of: flow) else { return nil }
        let a = blocks[lastIndex], b = blocks[index]
        let size = a.kind == .paragraph ? a.size : b.size
        // The body keeps one size; headings are their own.
        if b.kind == .paragraph, let body = flow.reversed().compactMap({ member -> LayoutBlock? in
            if case .text(let i) = member, blocks[i].kind == .paragraph { return blocks[i] }
            return nil
        }).first, abs(body.size - b.size) >= body.size * 0.06 { return nil }
        let bottom = a.lines.last!.baseline, top = b.lines[0].baseline
        let drop = bottom - top
        guard drop > 0 else { return nil }
        guard min(a.rect.maxX, b.rect.maxX) - max(a.rect.minX, b.rect.minX) > min(a.rect.width, b.rect.width) * 0.5 else { return nil }
        if a.kind == .paragraph, b.kind == .paragraph, abs(a.rect.minX - b.rect.minX) >= size * 2.5 { return nil }

        // A displayed formula in between: all of it goes along.
        let xLow = min(a.rect.minX, b.rect.minX) - 1, xHigh = max(a.rect.maxX, b.rect.maxX) + 1
        let formula = blocks.indices.filter { k in
            guard blocks[k].kind == .formula else { return false }
            let c = blocks[k].rect.center
            return c.y < bottom && c.y > top && c.x > xLow && c.x < xHigh
        }
        let formulaHeight: Double = {
            guard !formula.isEmpty else { return 0 }
            let baselines = formula.flatMap { blocks[$0].lines.map(\.baseline) }
            return baselines.max()! - baselines.min()!
        }()
        let bothText = a.kind == .paragraph && b.kind == .paragraph && formula.isEmpty
        guard drop - formulaHeight < size * (bothText ? 2.8 : 6) else { return nil }

        // Lines will move between the first baseline of the stretch and its last: nothing else may be there. (What only
        // reaches into its edges, like the bottom of a tall formula above it, stays clear: the first line does not move.)
        var members: [Int] = []
        for member in flow {
            switch member {
            case .text(let i): members.append(i)
            case .formula(let list): members += list
            }
        }
        members.append(index)
        members += formula
        let rects = members.map { blocks[$0].rect }
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        var flowTop = top
        for member in flow { if case .text(let i) = member { flowTop = blocks[i].lines[0].baseline; break } }
        let flowBottom = b.lines.last!.baseline
        let inner = CGRect(x: union.minX + 1, y: flowBottom, width: max(union.width - 2, 1), height: max(flowTop - flowBottom, 1))
        func inTheWay(_ rect: CGRect) -> Bool {
            let shared = rect.intersection(inner)
            return !shared.isNull && shared.width > 1 && shared.height > size * 0.2
        }
        for (k, other) in blocks.enumerated() where !members.contains(k) && inTheWay(other.rect) { return nil }
        for region in layout.tables + layout.figures where inTheWay(region) { return nil }
        let moving = members.filter { blocks[$0].kind == .formula }.map { blocks[$0].rect }
        let textRects = members.filter { blocks[$0].kind != .formula }.map { blocks[$0].rect }
        for graphic in layout.graphics where inTheWay(graphic) {
            // Marks on the text itself (fraction bars, underlines, chips) and a box behind all of it are no obstacle.
            if graphic.contains(union) { continue }
            if textRects.contains(where: { $0.insetBy(dx: -1, dy: -size * 0.3).contains(graphic) }) { continue }
            // A formula can take its rules along; anything drawn with more to it stays where it is, and so must the formula.
            if graphic.height < 4, moving.contains(where: { $0.insetBy(dx: -1, dy: -size * 0.8).contains(graphic) }) { continue }
            return nil
        }
        return formula
    }

    /// One stretch, set at one size: what its spacing has to work with.
    private struct Stretch {
        var members: [Member]
        var fontSize: Double
        var firstBaseline: Double
        /// Between neighbouring lines, top to bottom: the least distance for their ink to stay clear.
        var clearances: [Double]
        /// Which of those gaps come at a break, with what they take beyond the spacing: the original's own space there,
        /// and the height of a formula's rows.
        var breaks: [Int: Double]
        var minPitch: Double
        var maxPitch: Double
        /// Distance from the first baseline to the last one of the original, and to the lowest one allowed.
        var fullHeight: Double
        var roomHeight: Double
        var frame: CGRect
        /// Lines of each text member; a formula counts as one.
        var counts: [Int]

        var extra: Double { breaks.values.reduce(0, +) }
        var fillPitch: Double { Typesetter.pitch(fitting: fullHeight - extra, clearances: clearances, from: minPitch, to: maxPitch) }
        var roomPitch: Double { Typesetter.pitch(fitting: roomHeight - extra, clearances: clearances, from: minPitch, to: maxPitch) }
        var fits: Bool { clearances.reduce(0) { $0 + max(minPitch, $1) } + extra <= roomHeight + 0.5 }
    }

    /// Sets the running text of a page. `entries` get their plans for the size each stretch ends up at; the result says
    /// where each of them goes, and which formulas move.
    static func layOut(_ entries: inout [Entry], layout: PageLayout, typesetter: Typesetter) -> Outcome {
        let positions = Dictionary(entries.enumerated().map { ($0.element.block, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let flows = flows(of: entries.map(\.block), in: layout)
        var stretches = flows.map { stretch(for: $0, entries: &entries, positions: positions, layout: layout, typesetter: typesetter) }

        // The page's spacing, relative to the type: what most of its lines would get on their own. A stretch hemmed in
        // by a figure may not be able to reach it; the others come down part of the way, for an even page.
        let ratios = stretches.filter { !$0.clearances.isEmpty }.flatMap { s in
            Array(repeating: s.fillPitch / s.fontSize, count: s.clearances.count)
        }.sorted()
        var common: Double?
        if let median = ratios.isEmpty ? nil : ratios[ratios.count / 2] {
            let tightest = stretches.filter { !$0.clearances.isEmpty }.map { $0.roomPitch / $0.fontSize }.min() ?? median
            common = max(median * 0.85, min(median, tightest * 1.12))
        }
        // What comes next starts where it starts: the last line stops a line above it, not closer.
        if let common {
            for k in stretches.indices {
                guard let below = nextBaseline(under: stretches[k], in: layout) else { continue }
                let s = stretches[k]
                let lowest = below + common * s.fontSize
                var limited = s
                limited.fullHeight = min(s.fullHeight, s.firstBaseline - lowest)
                limited.roomHeight = min(s.roomHeight, s.firstBaseline - lowest)
                let needed = s.clearances.reduce(0) { $0 + max(common * s.fontSize * 0.9, $1) } + s.extra
                if limited.roomHeight >= needed { stretches[k] = limited }
            }
        }

        var outcome = Outcome()
        for s in stretches {
            var pitch = s.fillPitch
            if let common {
                pitch = min(max(pitch, common * s.fontSize * 0.96), common * s.fontSize * 1.04)
            }
            pitch = max(min(pitch, s.roomPitch), s.minPitch)
            // Left over from filling the original's height: between paragraphs, as far as that still looks like one.
            let used = s.clearances.reduce(0) { $0 + max(pitch, $1) } + s.extra
            let share = s.breaks.isEmpty ? 0 : max(0, min((s.fullHeight - used) / Double(s.breaks.count), pitch * 0.7))
            var baseline = s.firstBaseline
            var gap = 0
            for (n, member) in s.members.enumerated() {
                switch member {
                case .text(let block):
                    outcome.placements[positions[block]!] = Placement(firstBaseline: baseline, pitch: pitch, frame: s.frame)
                case .formula(let list):
                    outcome.moves.append(move(of: list, toFirstBaseline: baseline, in: layout))
                }
                for _ in 0..<max(s.counts[n] - 1, 0) {
                    baseline -= max(pitch, s.clearances[gap])
                    gap += 1
                }
                if gap < s.clearances.count {
                    baseline -= max(pitch, s.clearances[gap]) + (s.breaks[gap].map { $0 + share } ?? 0)
                    gap += 1
                }
            }
        }
        return outcome
    }

    /// The rows of a formula, and where its ink reaches.
    private static func extent(of list: [Int], in layout: PageLayout) -> (top: Double, bottom: Double, above: Double, below: Double) {
        let lines = list.flatMap { layout.blocks[$0].lines }
        let top = lines.map(\.baseline).max()!, bottom = lines.map(\.baseline).min()!
        let chars = lines.flatMap(\.chars).filter { !$0.isSpace }
        let inkTop = chars.map { Double($0.inkBox.maxY) }.max() ?? top, inkBottom = chars.map { Double($0.inkBox.minY) }.min() ?? bottom
        return (top, bottom, max(inkTop - top, 0), max(bottom - inkBottom, 0))
    }

    private static func move(of list: [Int], toFirstBaseline baseline: Double, in layout: PageLayout) -> FormulaMove {
        let lines = list.flatMap { layout.blocks[$0].lines }
        let chars = lines.flatMap(\.chars).filter { !$0.isSpace }
        let extent = extent(of: list, in: layout)
        var rect = chars[0].glyphBox, ink = chars[0].inkBox
        for c in chars.dropFirst() {
            rect = rect.union(c.glyphBox)
            ink = ink.union(c.inkBox)
        }
        // Rules of a fraction or a root lie within: the area taken along reaches over all its rows.
        let span = FormulaSpan(rect: rect, baseline: extent.top, runs: Set(chars.compactMap(\.run)), size: lines[0].size,
                               glyphs: chars.flatMap(\.glyphs).sorted(), ink: ink)
        return FormulaMove(blocks: list, span: span, dy: baseline - extent.top)
    }

    /// The first baseline of the text right under a stretch in its column, if text comes next.
    private static func nextBaseline(under s: Stretch, in layout: PageLayout) -> Double? {
        guard let lastIndex = lastText(of: s.members) else { return nil }
        let last = layout.blocks[lastIndex]
        var own: Set<Int> = []
        for member in s.members {
            switch member {
            case .text(let i): own.insert(i)
            case .formula(let list): own.formUnion(list)
            }
        }
        let bottom = last.lines.last!.baseline
        let nearest = layout.blocks.enumerated().filter { k, block in
            guard !own.contains(k), !block.lines.isEmpty, !block.lines[0].isRotated, block.lines[0].baseline < bottom else { return false }
            return min(block.rect.maxX, last.rect.maxX) - max(block.rect.minX, last.rect.minX) > min(block.rect.width, last.rect.width) * 0.5
        }.max { $0.element.lines[0].baseline < $1.element.lines[0].baseline }?.element
        guard let nearest, [.paragraph, .heading, .caption, .reference].contains(nearest.kind) else { return nil }
        return nearest.lines[0].baseline
    }

    /// Plans the text of a stretch at the largest size at which everything fits together.
    private static func stretch(for members: [Member], entries: inout [Entry], positions: [Int: Int], layout: PageLayout, typesetter: Typesetter) -> Stretch {
        let texts = members.compactMap { member -> Int? in if case .text(let index) = member { index } else { nil } }
        let blocks = texts.map { layout.blocks[$0] }
        let frames = texts.map { entries[positions[$0]!].frame }
        let bottom = frames.last!.minY
        let body = blocks.filter { $0.kind == .paragraph }
        let left = body.map(\.rect.minX).min()!, right = body.map(\.rect.maxX).max()!
        // Each keeps its own measure; a single line of text has none of its own, so it gets the column's.
        var planFrames: [CGRect] = []
        for (n, block) in blocks.enumerated() {
            let wide = block.kind == .paragraph && block.lines.count == 1
            let x = wide ? left : frames[n].minX
            let width = wide ? right - left : block.kind == .heading ? frames[n].width : block.rect.width
            let top = n == 0 ? frames[0].maxY : block.rect.maxY + block.size
            planFrames.append(CGRect(x: x, y: bottom, width: width, height: max(top - bottom, 1)))
        }
        var area = planFrames.dropFirst().reduce(planFrames[0]) { $0.union($1) }
        area.size.height = max(frames[0].maxY - bottom, 1)
        var scale = 1.0
        while true {
            var plans: [Typesetter.Plan] = []
            for (n, index) in texts.enumerated() {
                let entry = entries[positions[index]!]
                let indent: Double? = blocks[n].kind == .paragraph && blocks[n].lines.count == 1 ? Double(max(0, blocks[n].rect.minX - left)) : nil
                plans.append(typesetter.plan(entry.text, block: blocks[n], formulas: entry.formulas, frame: planFrames[n], maxScale: scale, indent: indent))
            }
            let smallest = plans.map(\.scale).min()!
            // A formula too wide for its line at this size: the whole stretch goes to that size.
            if smallest < scale - 0.001 {
                scale = smallest
                continue
            }
            let bodyPlans = plans.indices.filter { blocks[$0].kind == .paragraph }.map { plans[$0] }
            let fontSize = bodyPlans[0].fontSize
            let pitches = body.filter { $0.lines.count > 1 }.map(\.pitch).sorted()
            let linePitch = pitches.isEmpty ? body[0].size * 1.2 : pitches[pitches.count / 2]

            var clearances: [Double] = []
            var breaks: [Int: Double] = [:]
            var counts: [Int] = []
            // What the previous member reaches down to, and where in the original it ends.
            var previous: (below: Double, sourceBottom: Double, height: Double)?
            var textIndex = 0
            for member in members {
                var above: Double, below: Double, sourceTop: Double, sourceBottom: Double, height: Double
                var plan: Typesetter.Plan?
                var formulas: [FormulaSpan] = []
                switch member {
                case .text:
                    let p = plans[textIndex]
                    let entry = entries[positions[texts[textIndex]]!]
                    plan = p
                    formulas = entry.formulas
                    above = p.lines.first.map { typesetter.reach(of: $0.line, formulas: formulas, scale: p.scale).above } ?? 0
                    below = p.lines.last.map { typesetter.reach(of: $0.line, formulas: formulas, scale: p.scale).below } ?? 0
                    sourceTop = blocks[textIndex].lines[0].baseline
                    sourceBottom = blocks[textIndex].lines.last!.baseline
                    height = 0
                    counts.append(p.lines.count)
                    textIndex += 1
                case .formula(let list):
                    let e = extent(of: list, in: layout)
                    above = e.above
                    below = e.below
                    sourceTop = e.top
                    sourceBottom = e.bottom
                    height = e.top - e.bottom
                    counts.append(1)
                }
                if let previous {
                    clearances.append(previous.below + above + fontSize * 0.04)
                    // The original's own space here, beyond its line spacing.
                    let extra = min(max(0, previous.sourceBottom - sourceTop - previous.height * 0 - linePitch), body[0].size * 3)
                    breaks[clearances.count - 1] = (extra < body[0].size * 0.1 ? 0 : extra) + previous.height
                }
                if let plan { clearances += plan.clearances }
                previous = (below, sourceBottom, height)
            }
            let first = plans[0]
            let deepest = plans.last.map { typesetter.depth(of: $0) } ?? 0
            let s = Stretch(members: members, fontSize: fontSize, firstBaseline: first.firstBaseline, clearances: clearances, breaks: breaks,
                            minPitch: bodyPlans.map(\.minPitch).max()!, maxPitch: fontSize * 1.85,
                            fullHeight: first.firstBaseline - blocks.last!.lines.last!.baseline,
                            roomHeight: first.firstBaseline - bottom - max(fontSize * 0.22, deepest), frame: area, counts: counts)
            if s.fits || scale < 0.45 {
                for (n, index) in texts.enumerated() {
                    entries[positions[index]!].plan = plans[n]
                    entries[positions[index]!].plan.fits = s.fits
                    entries[positions[index]!].frame = planFrames[n]
                }
                return s
            }
            scale -= scale > 0.7 ? 0.04 : 0.05
        }
    }
}
