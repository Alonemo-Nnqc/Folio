import CoreGraphics
import CoreText
import Foundation

/// Produces the translated PDFs from the analysed pages and the translations of their segments.
///
/// Each output page draws: the original page with the translated text taken out glyph by glyph (form XObject),
/// the translations set by Core Text (a page of a separate PDF, also a form), and each inline formula drawn again
/// from its own glyphs and rules where the translation placed it.
/// What to take out of a page: the glyphs of the translated blocks, and glyphs no character stands for (spaces,
/// invisible text) inside their lines.
struct PageRemoval {
    var glyphs: Set<Int> = []
    var rects: [CGRect] = []
    /// Glyphs of text staying in the original: never removed.
    var kept: Set<Int> = []

    mutating func add(_ block: LayoutBlock) {
        for line in block.lines {
            rects.append(line.rect.insetBy(dx: -0.5, dy: -line.size * 0.1))
            for c in line.chars { glyphs.formUnion(c.glyphs) }
        }
    }

    /// Whether glyph `index` (of the page's glyphs) goes.
    func removes(_ glyph: Glyph, index: Int) -> Bool {
        guard !kept.contains(index) else { return false }
        if glyphs.contains(index) { return true }
        let box = glyph.box
        let center = CGPoint(x: box.midX, y: glyph.isHorizontal ? glyph.origin.y + glyph.size * 0.3 : box.midY)
        return rects.contains { $0.contains(center) }
    }
}

/// Measurements of a render, for checking layout quality (`folio-translate audit`).
final class RenderAudit: @unchecked Sendable {
    struct Entry {
        var page: Int, block: Int
        var frame: CGRect
        var boxes: [CGRect]
        var scale: Double
        var fits: Bool
        var lineCount: Int
        var pitch: Double
        var fontSize: Double
        /// Each line's baseline and where it runs.
        var lines: [(baseline: Double, minX: Double, maxX: Double)] = []
    }
    private(set) var entries: [Entry] = []
    var conflicts = 0
    /// Glyphs taken out of the original that neither the translation nor a formula stands for.
    var lostGlyphs = 0
    /// Glyphs drawn again in formulas.
    var formulaGlyphs = 0
    /// Blocks that kept their text but moved, by page and block: how far.
    var moved: [Int: [Int: Double]] = [:]
    private let lock = NSLock()

    /// Measures glyph ink (image bounds need a context; nothing is drawn into it).
    nonisolated(unsafe) private static let measuring = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)

    func record(page: Int, block: Int, frame: CGRect, result: Typesetter.Result, plan: Typesetter.Plan) {
        // What is drawn: the ink of each line's glyphs, and each formula's box where it goes.
        var boxes: [CGRect] = []
        lock.withLock {
            for (line, origin) in result.lines {
                guard let context = Self.measuring else { continue }
                context.textPosition = .zero
                let ink = CTLineGetImageBounds(line, context)
                if !ink.isNull, ink.width > 0 { boxes.append(ink.offsetBy(dx: origin.x, dy: origin.y)) }
            }
        }
        boxes += result.transplants.map { ($0.formula.ink.isNull ? $0.formula.rect : $0.formula.ink).applying($0.transform) }
        let lines = result.lines.map { entry -> (baseline: Double, minX: Double, maxX: Double) in
            let width = CTLineGetTypographicBounds(entry.line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(entry.line)
            return (Double(entry.origin.y), Double(entry.origin.x), Double(entry.origin.x) + width)
        }
        lock.withLock {
            entries.append(Entry(page: page, block: block, frame: frame, boxes: boxes, scale: result.scale, fits: result.fits,
                                 lineCount: result.lines.count, pitch: result.pitch, fontSize: plan.fontSize, lines: lines))
        }
    }
}

final class TranslationRenderer {
    let source: CGPDFDocument
    let language: String
    var audit: RenderAudit?
    /// Images and fonts of the source, compressed once for all the documents rendered from it.
    private let streamCache = StreamDataCache()

    init(source: CGPDFDocument, language: String) {
        self.source = source
        self.language = language
    }

    struct Output {
        var mono: Data?
        var dual: Data?
        /// For checking a render: what stays of the original, and what was set over it, each alone (`auditLayers`).
        var base: Data?
        var overlay: Data?
    }

    /// Also produce `Output.base` and `Output.overlay`.
    var auditLayers = false

    private enum Layers { case all, base, overlay }

    /// Renders `pages` (layouts in page order). `translations` maps segment ids to translated text; segments
    /// without a translation keep their original text (partial previews).
    func render(layouts: [PageLayout], segments: [TextSegment], translations: [String: String],
                mono wantMono: Bool, dual wantDual: Bool, dualLayout: TranslationOptions.DualLayout, title: String?) -> Output {
        let bySegment = Dictionary(grouping: segments, by: \.page)
        // 1. Translations, one overlay page per output page.
        let overlayData = NSMutableData()
        var transplants: [Int: [Transplant]] = [:]
        var removals: [Int: PageRemoval] = [:]
        // Where the links of translated text went, by page and link.
        var linkPlaces: [Int: [Int: [CGRect]]] = [:]
        if let consumer = CGDataConsumer(data: overlayData as CFMutableData),
           let context = CGContext(consumer: consumer, mediaBox: nil, nil) {
            let typesetter = Typesetter(language: language)
            for layout in layouts {
                var box = layout.mediaBox
                let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                context.beginPDFPage(info)
                // Operators that also draw text staying in the original must stay.
                let onPage = bySegment[layout.number] ?? []
                let leads = Dictionary(onPage.filter(\.isLead).map { ($0.block, $0) }, uniquingKeysWith: { a, _ in a })
                let pageSegments = onPage.filter { !$0.isLead && translations[$0.id]?.isEmpty == false }
                let translatedBlocks = Set(pageSegments.map(\.block))
                var kept: Set<Int> = []
                for (index, block) in layout.blocks.enumerated() where !translatedBlocks.contains(index) {
                    for line in block.lines { for c in line.chars { kept.formUnion(c.glyphs) } }
                }
                var planned: [(segment: TextSegment, frame: CGRect, plan: Typesetter.Plan, text: String)] = []
                for var segment in pageSegments {
                    guard var text = translations[segment.id] else { continue }
                    // A heading run into the paragraph goes before it, its formulas first.
                    if let lead = leads[segment.block] {
                        let shift = lead.formulas.count
                        let body = Placeholders.replace(in: text) { TextSegment.placeholder($0 + shift) }
                        text = Typesetter.leadStart + (translations[lead.id] ?? lead.source) + Typesetter.leadEnd + " " + body
                        segment.formulas = lead.formulas + segment.formulas
                    }
                    let frame = Self.frame(for: segment.block, in: layout)
                    planned.append((segment, frame, typesetter.plan(text, block: layout.blocks[segment.block], formulas: segment.formulas, frame: frame), text))
                }
                // The cells of a table share one size: the size most of them fit at.
                for table in layout.tables {
                    let cells = planned.indices.filter { k in
                        let block = layout.blocks[planned[k].segment.block]
                        return block.kind == .tableCell && table.insetBy(dx: -1, dy: -2).contains(block.rect.center)
                    }
                    guard cells.count >= 3 else { continue }
                    let scales = cells.map { planned[$0].plan.scale }.sorted()
                    let common = scales[scales.count / 2]
                    for k in cells where planned[k].plan.scale > common + 0.001 {
                        let entry = planned[k]
                        planned[k].plan = typesetter.plan(entry.text, block: layout.blocks[entry.segment.block],
                                                          formulas: entry.segment.formulas, frame: entry.frame, maxScale: common)
                    }
                }
                // Running text is set in stretches of even lines; the rest fills its own space.
                var flowing = planned.map { PageFlow.Entry(block: $0.segment.block, frame: $0.frame, text: $0.text, formulas: $0.segment.formulas, plan: $0.plan) }
                let outcome = PageFlow.layOut(&flowing, layout: layout, typesetter: typesetter)
                let placements = outcome.placements
                for k in planned.indices {
                    planned[k].plan = flowing[k].plan
                    planned[k].frame = flowing[k].frame
                }
                let pitches = Self.harmonizedPitches(planned.map { ($0.plan, layout.blocks[$0.segment.block]) })
                // Displayed formulas going along with the text around them are drawn again, like the formulas in lines.
                let moves = outcome.moves.filter { abs($0.dy) >= 0.3 }
                for move in moves {
                    for index in move.blocks {
                        for line in layout.blocks[index].lines { for c in line.chars { kept.subtract(c.glyphs) } }
                    }
                }
                var removal = PageRemoval(kept: kept)
                for move in moves {
                    for index in move.blocks { removal.add(layout.blocks[index]) }
                    // Its rules too: the whole area, rows and all.
                    let area = move.span.rect.insetBy(dx: -0.5, dy: -move.span.size * 0.15)
                    removal.rects.append(area)
                    var span = move.span
                    span.links = []
                    for index in move.blocks {
                        for line in layout.blocks[index].lines {
                            for c in line.chars {
                                if let link = c.link, let page = layout.links.first(where: { $0.index == link }) {
                                    linkPlaces[layout.number, default: [:]][link] = page.rects.map { $0.offsetBy(dx: 0, dy: move.dy) }
                                }
                            }
                        }
                        audit?.moved[layout.number, default: [:]][index] = move.dy
                    }
                    transplants[layout.number, default: []].append(Transplant(formula: span, origin: CGPoint(x: span.rect.minX, y: span.baseline + move.dy), scale: 1))
                }
                for (k, entry) in planned.enumerated() {
                    let block = layout.blocks[entry.segment.block]
                    let placement = placements[k]
                    let result = typesetter.finish(entry.plan, pitch: placement?.pitch ?? pitches[k], firstBaseline: placement?.firstBaseline, formulas: entry.segment.formulas)
                    typesetter.draw(result, in: context)
                    transplants[layout.number, default: []] += result.transplants
                    removal.add(block)
                    for line in block.lines {
                        for c in line.chars {
                            if let link = c.link, linkPlaces[layout.number]?[link] == nil { linkPlaces[layout.number, default: [:]][link] = [] }
                        }
                    }
                    for transplant in result.transplants {
                        for span in transplant.formula.links {
                            linkPlaces[layout.number, default: [:]][span.link, default: []].append(span.rect.applying(transplant.transform).insetBy(dx: -0.5, dy: 0))
                        }
                    }
                    // Links over running words go with the same stretch of the translation.
                    let held = Set(entry.segment.formulas.flatMap(\.allLinks).map(\.link))
                    for link in Set(block.lines.flatMap { $0.chars.compactMap(\.link) }).subtracting(held) {
                        linkPlaces[layout.number, default: [:]][link] = LinkText.places(of: link, in: block, lines: result.lines, fontSize: entry.plan.fontSize)
                    }
                    audit?.record(page: layout.number, block: entry.segment.block, frame: placement?.frame ?? entry.frame, result: result, plan: entry.plan)
                }
                removals[layout.number] = removal
                context.endPDFPage()
            }
            context.closePDF()
        }
        guard let overlay = CGPDFDocument(CGDataProvider(data: overlayData as CFData)!) else { return Output() }

        func compose(dual: Bool, layers: Layers = .all) -> Data {
            let composer = PDFComposer(source: source, streamCache: streamCache)
            for layout in layouts { _ = composer.reserveOutputPage(forSourcePage: layout.number) }
            for (index, layout) in layouts.enumerated() {
                guard let geometry = composer.geometry(ofSourcePage: layout.number),
                      let page = source.page(at: layout.number) else { continue }
                let interpreter = ContentInterpreter()
                interpreter.run(page: page)
                var xobjects: [String: Int] = [:]
                var fonts: [String: PDFValue] = [:]
                var content = ""
                let removal = removals[layout.number] ?? PageRemoval()
                let rects = removal.rects
                let removed = Set(interpreter.glyphs.indices.filter { removal.removes(interpreter.glyphs[$0], index: $0) })
                var edits = Self.glyphEdits(interpreter: interpreter, removing: removed)
                audit?.conflicts += edits.values.filter { if case .replace = $0 { return true } else { return false } }.count
                // Rules that are part of formulas (fraction bars, radicals) move with the formula.
                var droppedRules: [Int] = []
                // The formulas' own areas too: a fraction's bar may lie outside the line's box.
                let pageFormulas = transplants[layout.number] ?? []
                let formulaAreas = pageFormulas.map { $0.formula.rect.insetBy(dx: -0.5, dy: -$0.formula.size * 0.15) }
                for (m, mark) in interpreter.marks.enumerated() where mark.kind != .image && !mark.isWhite
                    && (mark.rect.height < 4 && rects.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(mark.rect) })
                        || Self.isRule(mark.rect, ofFormulaIn: formulaAreas)) {
                    for index in mark.opRange { edits[OpLocation(stream: mark.location.stream, index: index)] = .drop }
                    droppedRules.append(m)
                }
                // Pictures set among the words go with them.
                for transplant in pageFormulas {
                    for m in transplant.formula.icons where m < interpreter.marks.count {
                        let mark = interpreter.marks[m]
                        for index in mark.opRange { edits[OpLocation(stream: mark.location.stream, index: index)] = .drop }
                    }
                }
                // A coloured chip tight around a formula moves with it.
                var chips: [Int: Int] = [:]
                for transplant in transplants[layout.number] ?? [] {
                    let formula = transplant.formula
                    for (m, mark) in interpreter.marks.enumerated() where mark.kind == .fill && !mark.isWhite && !mark.hasCurves && chips[m] == nil
                        && mark.rect.height >= 4 && mark.rect.contains(CGPoint(x: formula.rect.midX, y: formula.baseline + formula.size * 0.25))
                        && mark.rect.width < formula.rect.width + formula.size * 2 && mark.rect.height < formula.size * 2 {
                        chips[m] = transplant.formula.glyphs.first ?? -1
                        for index in mark.opRange { edits[OpLocation(stream: mark.location.stream, index: index)] = .drop }
                    }
                }
                if layers != .overlay, let edited = composer.pageForm(layout.number, interpreter: interpreter, edits: edits) {
                    xobjects["E"] = edited
                    content += "q /E Do Q\n"
                }
                let debugEdited = layers == .base || ProcessInfo.processInfo.environment["FOLIO_DEBUG_EDITED_ONLY"] != nil
                if !debugEdited, let text = composer.foreignPageForm(overlay, page: index + 1) {
                    xobjects["T"] = text
                    content += "q /T Do Q\n"
                }
                // Glyphs taken out that no character stands for, inside a formula's box, go with that formula.
                let pageTransplants = debugEdited ? [] : transplants[layout.number] ?? []
                let claimed = removal.glyphs.union(pageTransplants.flatMap(\.formula.glyphs))
                let orphans = removed.subtracting(claimed).filter { interpreter.glyphs[$0].isVisible }
                var fontNames: [Int: String] = [:]
                var drawnOrphans = Set<Int>()
                defer {
                    if !debugEdited {
                        audit?.lostGlyphs += orphans.subtracting(drawnOrphans).filter { interpreter.glyphs[$0].text.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? true }.count
                    }
                }
                for transplant in pageTransplants {
                    let formula = transplant.formula
                    let area = formula.rect.insetBy(dx: -0.5, dy: -formula.size * 0.15)
                    var glyphs = formula.glyphs
                    glyphs += orphans.filter { g in
                        let box = interpreter.glyphs[g].box
                        return area.contains(CGPoint(x: box.midX, y: box.midY))
                    }
                    drawnOrphans.formUnion(glyphs[formula.glyphs.count...])
                    audit?.formulaGlyphs += glyphs.count
                    let rules = droppedRules.filter { Self.isRule(interpreter.marks[$0].rect, ofFormulaIn: [area]) }
                        + chips.filter { $0.value == (formula.glyphs.first ?? -1) }.map(\.key)
                    let t = transplant.transform
                    content += "q \(PDFValue.format(t.a)) 0 0 \(PDFValue.format(t.d)) \(PDFValue.format(t.tx)) \(PDFValue.format(t.ty)) cm\n"
                    func matrix(_ m: CGAffineTransform) -> String {
                        [m.a, m.b, m.c, m.d, m.tx, m.ty].map { PDFValue.format(Double($0)) }.joined(separator: " ")
                    }
                    for m in formula.icons {
                        if let image = interpreter.images[m], case .ref(let number) = composer.copier.copy(stream: image.stream) {
                            let name = "FolioI\(xobjects.count)"
                            xobjects[name] = number
                            content += "q " + matrix(image.matrix) + " cm /\(name) Do Q\n"
                        } else if let ctm = interpreter.paths[m], let stream = interpreter.streams[interpreter.marks[m].location.stream] {
                            // A shape: its own path, in its own colour.
                            let mark = interpreter.marks[m]
                            let ops = mark.opRange.map { String(decoding: stream.source[stream.ops[$0].range], as: UTF8.self) }.joined(separator: "\n")
                            content += "q " + matrix(ctm) + " cm \(PDFValue.format(mark.color.r)) \(PDFValue.format(mark.color.g)) \(PDFValue.format(mark.color.b)) rg\n" + ops + "\nQ\n"
                        }
                    }
                    content += Self.drawing(glyphs: glyphs.sorted(), rules: rules, interpreter: interpreter) { font in
                        if let name = fontNames[font] { return name }
                        let name = "FolioG\(fontNames.count)"
                        fontNames[font] = name
                        fonts[name] = composer.copier.copy(dictionary: interpreter.fonts[font].dict)
                        return name
                    }
                    content += "Q\n"
                }
                let outputPage = composer.reserveOutputPage(forSourcePage: layout.number)
                let places = linkPlaces[layout.number] ?? [:]
                if !dual {
                    composer.addPage(object: outputPage, mediaBox: geometry.mediaBox, cropBox: geometry.cropBox, rotation: geometry.rotation,
                                     content: Data(content.utf8), xobjects: xobjects, fonts: fonts,
                                     annotations: composer.links(ofSourcePage: layout.number, placement: places))
                    continue
                }
                guard let original = composer.pageForm(layout.number) else { continue }
                // The translated page as one form, so it can be placed beside or after the original.
                var resources: [String: PDFValue] = ["XObject": .dict(xobjects.mapValues { .ref($0) })]
                if !fonts.isEmpty { resources["Font"] = .dict(fonts) }
                let translatedForm = composer.writer.addStream(dict: [
                    "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(geometry.mediaBox), "Resources": .dict(resources),
                ], data: Data(content.utf8))
                switch dualLayout {
                case .sideBySide:
                    let width = geometry.cropBox.width
                    let media = CGRect(x: geometry.cropBox.minX, y: geometry.cropBox.minY, width: width * 2, height: geometry.cropBox.height)
                    let both = "q /O Do Q\nq 1 0 0 1 \(PDFValue.format(width)) 0 cm /M Do Q\n"
                    composer.addPage(object: outputPage, mediaBox: media, rotation: geometry.rotation, content: Data(both.utf8),
                                     xobjects: ["O": original, "M": translatedForm],
                                     annotations: composer.links(ofSourcePage: layout.number)
                                        + composer.links(ofSourcePage: layout.number, offset: CGPoint(x: width, y: 0), placement: places))
                case .alternatingPages:
                    composer.addPage(object: outputPage, mediaBox: geometry.mediaBox, cropBox: geometry.cropBox, rotation: geometry.rotation,
                                     content: Data("q /O Do Q\n".utf8), xobjects: ["O": original],
                                     annotations: composer.links(ofSourcePage: layout.number))
                    composer.addPage(mediaBox: geometry.mediaBox, cropBox: geometry.cropBox, rotation: geometry.rotation,
                                     content: Data("q /M Do Q\n".utf8), xobjects: ["M": translatedForm],
                                     annotations: composer.links(ofSourcePage: layout.number, placement: places))
                }
            }
            return composer.finish(title: title)
        }
        return Output(mono: wantMono ? compose(dual: false) : nil, dual: wantDual ? compose(dual: true) : nil,
                      base: auditLayers ? compose(dual: false, layers: .base) : nil,
                      overlay: auditLayers ? compose(dual: false, layers: .overlay) : nil)
    }

    /// Whether a thin mark belongs to a formula in one of `areas`: a fraction's bar (a little wider than what is over and
    /// under it), a root's line, the sides of a big bracket. Its middle is inside, and it hardly reaches out.
    static func isRule(_ rect: CGRect, ofFormulaIn areas: [CGRect]) -> Bool {
        guard min(rect.width, rect.height) < 2.5 else { return false }
        return areas.contains { area in
            area.insetBy(dx: -2.5, dy: -0.5).contains(rect) && area.contains(CGPoint(x: rect.midX, y: rect.midY))
        }
    }

    // MARK: Spacing

    /// Line spacing for each planned block. Each paragraph fills the height of its original, but paragraphs of
    /// one page stay within about ±12% of a common spacing, so the page looks even rather than patchy.
    static func harmonizedPitches(_ plans: [(plan: Typesetter.Plan, block: LayoutBlock)]) -> [Double] {
        let ratios = plans.filter { $0.block.kind == .paragraph && $0.plan.lines.count >= 2 && $0.plan.fits }
            .map { $0.plan.fillPitch / $0.plan.fontSize }.sorted()
        guard !ratios.isEmpty else { return plans.map(\.plan.fillPitch) }
        let common = ratios[ratios.count / 2]
        return plans.map { entry in
            let plan = entry.plan
            guard entry.block.kind == .paragraph || entry.block.kind == .caption, plan.lines.count >= 2 else { return plan.fillPitch }
            let lower = common * plan.fontSize * 0.88, upper = common * plan.fontSize * 1.12
            return min(max(plan.fillPitch, lower), upper)
        }
    }

    // MARK: Space

    /// The area a translated block may use: its own lines, plus free space below it (and, for one-line blocks, to
    /// its right) up to the next thing on the page.
    static func frame(for index: Int, in layout: PageLayout) -> CGRect {
        let block = layout.blocks[index]
        let rect = block.rect
        let size = block.size
        let gap = size * 0.25
        var obstacles: [CGRect] = []
        for (k, other) in layout.blocks.enumerated() where k != index {
            // PDFKit's selections are taller than the type: below a block, the next one starts at its cap height.
            var r = other.rect
            // A formula reaches as high as its scripts and accents do.
            let top = other.kind == .formula ? other.lines.flatMap(\.chars).filter { !$0.isSpace }.map { Double($0.inkBox.maxY) }.max() ?? Double(r.maxY)
                : other.lines[0].baseline + other.lines[0].size * 0.8
            if top < r.maxY, top > r.minY { r = CGRect(x: r.minX, y: r.minY, width: r.width, height: top - r.minY) }
            obstacles.append(r)
        }
        let inTable = layout.tables.contains { $0.insetBy(dx: -1, dy: -2).contains(rect.center) }
        for g in layout.graphics where g.width * g.height > 1 || g.width > 20 || g.height > 20 {
            // Rules a cell sits between count; the frame of the table it sits in does not.
            if g.contains(rect) && g.width * g.height > rect.width * rect.height * 4 { continue }
            obstacles.append(g)
        }
        if !inTable { obstacles += layout.tables }
        let page = layout.cropBox.insetBy(dx: layout.cropBox.width * 0.03, dy: layout.cropBox.height * 0.03)

        // Downwards: to the nearest obstacle below that overlaps horizontally. "Below" is judged from the last
        // baseline: a tall formula's ink may reach into the next block.
        let horizontal = rect.insetBy(dx: 1, dy: 0)
        let lastBaseline = block.lines.last!.baseline
        let belowTop = obstacles.filter { $0.maxY <= lastBaseline + size * 0.2 && $0.maxX > horizontal.minX && $0.minX < horizontal.maxX }
            .map(\.maxY).max() ?? page.minY
        let maxExtension = block.kind == .tableCell ? size * 0.2 : max(block.pitch * 2, rect.height * 0.5)
        var bottom = max(min(rect.minY, belowTop + gap), rect.minY - maxExtension)
        if belowTop + gap > rect.minY { bottom = min(belowTop + gap, lastBaseline - size * 0.25) }
        // Whatever the original's last line got away with, the lines of a translation stay above a rule right under them.
        if block.lines.count > 1 {
            let rules = layout.graphics.filter { $0.height < 2.5 && $0.maxX > horizontal.minX && $0.minX < horizontal.maxX && $0.maxY <= lastBaseline - size * 0.1 }
            if let rule = rules.map(\.maxY).max() { bottom = max(bottom, rule + 0.2) }
        }
        // Upwards: not into the descenders of the line above (rows of a table set an em apart).
        var top = rect.maxY
        let firstBaseline = block.lines[0].baseline
        for (k, other) in layout.blocks.enumerated() where k != index && block.lines.count == 1 {
            guard let low = other.lines.min(by: { $0.baseline < $1.baseline }), low.baseline > firstBaseline + size * 0.5,
                  low.baseline < firstBaseline + size * 1.8,
                  other.rect.maxX > horizontal.minX, other.rect.minX < horizontal.maxX else { continue }
            top = min(top, max(low.baseline - low.size * 0.14 - size * 0.04, firstBaseline + size * 0.6))
        }
        // Nor into a rule right above it (the rule over a table's header).
        if block.lines.count == 1 {
            for g in layout.graphics where g.height < 2.5 && g.minX < horizontal.maxX && g.maxX > horizontal.minX
                && g.minY > firstBaseline + size * 0.4 && g.minY < firstBaseline + size * 1.8 {
                top = min(top, max(g.minY - size * 0.02, firstBaseline + size * 0.6))
            }
        }
        var frame = CGRect(x: rect.minX, y: bottom, width: rect.width, height: top - bottom)

        // Sideways for single lines (headings, short captions, cells): to the next obstacle on the right.
        if block.lines.count == 1 {
            let band = CGRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: max(rect.height - 2, 0.5))
            let right = obstacles.filter { $0.minX >= rect.maxX - 0.5 && $0.minY < band.maxY && $0.maxY > band.minY }.map(\.minX).min()
                ?? (inTable ? rect.maxX + size * 2 : page.maxX)
            let limit = inTable ? size * 3 : max(rect.width, size * 30)
            let maxX = min(right - gap, rect.maxX + limit)
            if maxX > frame.maxX { frame.size.width = maxX - frame.minX }
            if block.isCentered, block.kind != .tableCell {
                // Growing on both sides keeps it centred.
                let left = obstacles.filter { $0.maxX <= rect.minX + 0.5 && $0.minY < band.maxY && $0.maxY > band.minY }.map(\.maxX).max() ?? page.minX
                let grow = max(0, min(right - gap - rect.maxX, rect.minX - left - gap, limit))
                frame = CGRect(x: rect.minX - grow, y: frame.minY, width: rect.width + 2 * grow, height: frame.height)
            }
            if block.kind == .tableCell {
                // Cells grow on both sides, so centred text stays centred, into at most half the space between them
                // and their neighbours (which may grow too).
                let right = obstacles.filter { $0.minX >= rect.maxX - 0.5 && $0.minY < band.maxY && $0.maxY > band.minY }.map(\.minX).min()
                    ?? rect.maxX + size * 2
                let left = obstacles.filter { $0.maxX <= rect.minX + 0.5 && $0.minY < band.maxY && $0.maxY > band.minY }.map(\.maxX).max()
                    ?? rect.minX - size * 2
                switch block.cellAlignment {
                case .left?:
                    // Its column's left edge stays; it grows to the right.
                    frame = CGRect(x: rect.minX, y: frame.minY, width: rect.width + max(0, min(right - rect.maxX - size * 0.4, size * 4)), height: frame.height)
                case .right?:
                    let grow = max(0, min(rect.minX - left - size * 0.4, size * 4))
                    frame = CGRect(x: rect.minX - grow, y: frame.minY, width: rect.width + grow, height: frame.height)
                default:
                    let grow = max(0, min((right - rect.maxX) / 2, (rect.minX - left) / 2, size * 3) - 0.5)
                    frame = CGRect(x: rect.minX - grow, y: frame.minY, width: rect.width + 2 * grow, height: frame.height)
                }
            }
        }
        return frame
    }

    // MARK: Edits

    /// Takes the `removing` glyphs out of the page. A show operator losing all its glyphs is dropped, unless text
    /// drawn after it in the same chain (positioned relative to it) stays; then, as when only some of its glyphs go,
    /// it is written again with the removed glyphs replaced by their advance, so every kept glyph stays exactly
    /// where it was.
    static func glyphEdits(interpreter: ContentInterpreter, removing: Set<Int>) -> [OpLocation: EditAction] {
        let runs = interpreter.runs, glyphs = interpreter.glyphs
        var affected: [(run: Int, all: Bool)] = []
        var lastKept: [Int: Int] = [:]
        for (r, run) in runs.enumerated() {
            let gone = run.glyphs.filter { removing.contains($0) }.count
            // Clipping text (modes 4–7) shapes other content; leave it alone.
            if run.renderMode >= 4 || gone == 0 {
                lastKept[run.chain] = max(lastKept[run.chain] ?? -1, run.location.index)
                continue
            }
            if gone < run.glyphs.count { lastKept[run.chain] = max(lastKept[run.chain] ?? -1, run.location.index) }
            affected.append((r, gone == run.glyphs.count))
        }
        var edits: [OpLocation: EditAction] = [:]
        for (r, all) in affected {
            let run = runs[r]
            if all, (lastKept[run.chain] ?? -1) <= run.location.index {
                edits[run.location] = .drop
            } else if let op = interpreter.streams[run.location.stream]?.ops[run.location.index],
                      let data = rewrittenShow(op, glyphs: glyphs[run.glyphs], removing: removing, first: run.glyphs.lowerBound) {
                edits[run.location] = .replace(data)
            } else {
                edits[run.location] = .hide(restore: run.renderMode)
            }
        }
        return edits
    }

    /// The show operator `op` as a `TJ` without the `removing` glyphs: each is replaced by an adjustment of its
    /// own advance. `'` and `"` keep their move to the next line (and `"` its spacing).
    static func rewrittenShow(_ op: ContentOp, glyphs: ArraySlice<Glyph>, removing: Set<Int>, first: Int) -> Data? {
        let elements: [ContentOperand]
        switch op.name {
        case "TJ":
            guard case .array(let items)? = op.operands.first else { return nil }
            elements = items
        case "Tj":
            guard let s = op.operands.first else { return nil }
            elements = [s]
        case "'", "\"":
            guard let s = op.operands.last else { return nil }
            elements = [s]
        default:
            return nil
        }
        var out = ""
        if op.name == "'" { out = "T*\n" }
        if op.name == "\"", op.operands.count == 3 {
            out = "\(PDFValue.format(op.operands[0].number ?? 0)) Tw \(PDFValue.format(op.operands[1].number ?? 0)) Tc T*\n"
        }
        var items: [String] = []
        var pending = 0.0
        var hex = ""
        func flushString() {
            if !hex.isEmpty { items.append("<\(hex)>"); hex = "" }
        }
        func flushNumber() {
            if pending != 0 { items.append(PDFValue.format(pending)); pending = 0 }
        }
        var byElement: [Int: [(Int, Glyph)]] = [:]
        for (offset, g) in glyphs.enumerated() { byElement[g.element, default: []].append((first + offset, g)) }
        for (e, element) in elements.enumerated() {
            switch element {
            case .number(let n):
                flushString()
                pending += n
            case .string(let data):
                let bytes = [UInt8](data)
                for (index, g) in byElement[e] ?? [] {
                    if removing.contains(index) {
                        guard let adjustment = g.adjustment else { return nil }
                        flushString()
                        pending += adjustment
                    } else {
                        flushNumber()
                        guard g.offset + g.length <= bytes.count else { return nil }
                        for b in bytes[g.offset..<(g.offset + g.length)] { hex += String(format: "%02X", b) }
                    }
                }
            default:
                break
            }
        }
        flushString()
        flushNumber()
        out += "[" + items.joined(separator: " ") + "] TJ"
        return Data(out.utf8)
    }

    /// Content drawing `glyphs` (of the page) exactly as they were drawn, and `rules` (fraction bars, radicals) as
    /// filled rectangles. `fontName` names the resource for a font index.
    static func drawing(glyphs: [Int], rules: [Int], interpreter: ContentInterpreter, fontName: (Int) -> String) -> String {
        var out = ""
        // Chips go under the glyphs; bars and radicals are drawn after them.
        func box(_ r: Int) -> String {
            let mark = interpreter.marks[r]
            var rect = mark.rect
            if mark.kind == .stroke {
                let w = max(mark.lineWidth, 0.3)
                rect = rect.insetBy(dx: rect.height < rect.width ? 0 : -w / 2, dy: rect.height < rect.width ? -w / 2 : 0)
            }
            return "\(PDFValue.format(mark.color.r)) \(PDFValue.format(mark.color.g)) \(PDFValue.format(mark.color.b)) rg "
                + "\(PDFValue.format(rect.minX)) \(PDFValue.format(rect.minY)) \(PDFValue.format(rect.width)) \(PDFValue.format(rect.height)) re f\n"
        }
        for r in rules where interpreter.marks[r].rect.height >= 4 { out += box(r) }
        var font = -1
        var color: RGBColor?
        var mode = -1
        let drawable = glyphs.map { interpreter.glyphs[$0] }.filter { $0.isVisible && $0.font >= 0 }
        if !drawable.isEmpty {
            out += "BT 0 Tc 0 Tw 100 Tz 0 Ts\n"
            for g in drawable {
                if g.font != font {
                    font = g.font
                    out += "/\(fontName(font)) 1 Tf\n"
                }
                if g.color != color {
                    color = g.color
                    let c = "\(PDFValue.format(g.color.r)) \(PDFValue.format(g.color.g)) \(PDFValue.format(g.color.b))"
                    out += "\(c) rg \(c) RG\n"
                }
                let render = min(g.renderMode, 2)
                if render != mode {
                    mode = render
                    out += "\(render) Tr\n"
                }
                let m = g.matrix
                var code = ""
                for k in stride(from: g.length - 1, through: 0, by: -1) { code += String(format: "%02X", (g.code >> (8 * k)) & 0xFF) }
                out += [m.a, m.b, m.c, m.d, m.tx, m.ty].map { PDFValue.format(Double($0)) }.joined(separator: " ") + " Tm <\(code)> Tj\n"
            }
            out += "ET\n"
        }
        for r in rules where interpreter.marks[r].rect.height < 4 { out += box(r) }
        return out
    }
}
