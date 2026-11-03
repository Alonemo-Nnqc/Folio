import CoreGraphics
import CoreText
import Foundation

/// Produces the translated PDFs from the analysed pages and the translations of their segments.
///
/// Each output page draws: the original page with the translated text removed (form XObject), the translations
/// set by Core Text (a page of a separate PDF, also a form), and each inline formula cut from the original and
/// moved to its place in the translation (a form keeping only that formula, clipped to it).
/// What to take out of a page: the operators that drew the translated blocks (known from their characters), and
/// their lines' area for operators no character was matched to.
struct PageRemoval {
    var runs: Set<Int> = []
    var rects: [CGRect] = []
    /// Operators that draw text staying in the original: never removed.
    var kept: Set<Int> = []

    mutating func add(_ block: LayoutBlock) {
        for line in block.lines {
            rects.append(line.rect.insetBy(dx: -0.5, dy: -line.size * 0.1))
            for c in line.chars { if let run = c.run { runs.insert(run) } }
        }
    }

    /// Whether run `index` (of the page's runs) goes.
    func removes(_ run: TextRun, index: Int) -> Bool {
        !kept.contains(index) && (runs.contains(index) || rects.contains { $0.contains(run.midpoint) })
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
    }
    private(set) var entries: [Entry] = []
    var conflicts = 0
    private let lock = NSLock()

    func record(page: Int, block: Int, frame: CGRect, result: Typesetter.Result, plan: Typesetter.Plan) {
        let boxes = result.lines.map { line, origin -> CGRect in
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil) - CTLineGetTrailingWhitespaceWidth(line)
            return CGRect(x: origin.x, y: origin.y - descent * 0.6, width: width, height: ascent * 0.9 + descent * 0.6)
        }
        lock.withLock {
            entries.append(Entry(page: page, block: block, frame: frame, boxes: boxes, scale: result.scale, fits: result.fits,
                                 lineCount: result.lines.count, pitch: result.pitch, fontSize: plan.fontSize))
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
    }

    /// Renders `pages` (layouts in page order). `translations` maps segment ids to translated text; segments
    /// without a translation keep their original text (partial previews).
    func render(layouts: [PageLayout], segments: [TextSegment], translations: [String: String],
                mono wantMono: Bool, dual wantDual: Bool, dualLayout: TranslationOptions.DualLayout, title: String?) -> Output {
        let bySegment = Dictionary(grouping: segments, by: \.page)
        // 1. Translations, one overlay page per output page.
        let overlayData = NSMutableData()
        var transplants: [Int: [Transplant]] = [:]
        var removals: [Int: PageRemoval] = [:]
        var restores: [Int: [FormulaSpan]] = [:]
        if let consumer = CGDataConsumer(data: overlayData as CFMutableData),
           let context = CGContext(consumer: consumer, mediaBox: nil, nil) {
            let typesetter = Typesetter(language: language)
            for layout in layouts {
                var box = layout.mediaBox
                let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                context.beginPDFPage(info)
                // Operators that also draw text staying in the original must stay.
                let pageSegments = (bySegment[layout.number] ?? []).filter { translations[$0.id]?.isEmpty == false }
                let translatedBlocks = Set(pageSegments.map(\.block))
                var kept: Set<Int> = []
                for (index, block) in layout.blocks.enumerated() where !translatedBlocks.contains(index) {
                    for line in block.lines { for c in line.chars { if let run = c.run { kept.insert(run) } } }
                }
                var planned: [(segment: TextSegment, frame: CGRect, plan: Typesetter.Plan)] = []
                for segment in pageSegments {
                    guard let text = translations[segment.id] else { continue }

                    let frame = Self.frame(for: segment.block, in: layout)
                    planned.append((segment, frame, typesetter.plan(text, block: layout.blocks[segment.block], formulas: segment.formulas, frame: frame)))
                }
                let pitches = Self.harmonizedPitches(planned.map { ($0.plan, layout.blocks[$0.segment.block]) })
                var removal = PageRemoval(kept: kept)
                for (k, entry) in planned.enumerated() {
                    let block = layout.blocks[entry.segment.block]
                    let result = typesetter.finish(entry.plan, pitch: pitches[k], formulas: entry.segment.formulas)
                    typesetter.draw(result, in: context)
                    transplants[layout.number, default: []] += result.transplants
                    removal.add(block)
                    audit?.record(page: layout.number, block: entry.segment.block, frame: entry.frame, result: result, plan: entry.plan)
                }
                // Text that stays but was drawn by the same operators as translated text (pdfTeX sets a whole table
                // row with one operator) is drawn again from the original, in place.
                for (index, block) in layout.blocks.enumerated() where !translatedBlocks.contains(index) {
                    let runs = Set(block.lines.flatMap { $0.chars.compactMap(\.run) })
                    guard !runs.isDisjoint(with: removal.runs) else { continue }
                    audit?.conflicts += 1
                    for line in block.lines {
                        let lineRuns = Set(line.chars.compactMap(\.run))
                        restores[layout.number, default: []].append(FormulaSpan(rect: line.inkRect, baseline: line.baseline, runs: lineRuns, size: line.size))
                    }
                }
                removal.kept = []
                removals[layout.number] = removal
                context.endPDFPage()
            }
            context.closePDF()
        }
        guard let overlay = CGPDFDocument(CGDataProvider(data: overlayData as CFData)!) else { return Output() }

        func compose(dual: Bool) -> Data {
            let composer = PDFComposer(source: source, streamCache: streamCache)
            for layout in layouts { _ = composer.reserveOutputPage(forSourcePage: layout.number) }
            for (index, layout) in layouts.enumerated() {
                guard let geometry = composer.geometry(ofSourcePage: layout.number),
                      let page = source.page(at: layout.number) else { continue }
                let interpreter = ContentInterpreter()
                interpreter.run(page: page)
                var xobjects: [String: Int] = [:]
                var content = ""
                let removal = removals[layout.number] ?? PageRemoval()
                let rects = removal.rects
                var edits = Self.removalEdits(runs: interpreter.runs, removing: removal.removes)
                // Rules that are part of formulas (fraction bars, radicals) move with the formula.
                for mark in interpreter.marks where mark.kind != .image && !mark.isWhite
                    && mark.rect.height < 4 && rects.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(mark.rect) }) {
                    for index in mark.opRange { edits[OpLocation(stream: mark.location.stream, index: index)] = .drop }
                }
                if let edited = composer.pageForm(layout.number, interpreter: interpreter, edits: edits) {
                    xobjects["E"] = edited
                    content += "q /E Do Q\n"
                }
                let debugEdited = ProcessInfo.processInfo.environment["FOLIO_DEBUG_EDITED_ONLY"] != nil
                if !debugEdited, let text = composer.foreignPageForm(overlay, page: index + 1) {
                    xobjects["T"] = text
                    content += "q /T Do Q\n"
                }
                for (k, transplant) in (debugEdited ? [] : transplants[layout.number] ?? []).enumerated() {
                    // Only the formula's own operators are kept.
                    let formula = transplant.formula
                    // The formula's box already covers its scripts and accents; a little more, not into the lines around.
                    let clip = CGRect(x: formula.rect.minX - 0.8, y: formula.rect.minY - formula.size * 0.1,
                                      width: formula.rect.width + 1.6, height: formula.rect.height + formula.size * 0.2)
                    // Operators found by position must sit on the formula's own line.
                    let band = CGRect(x: formula.rect.minX - 0.6, y: formula.baseline - formula.size * 0.35,
                                      width: formula.rect.width + 1.2, height: formula.size * 1.35).intersection(formula.rect.insetBy(dx: -0.6, dy: -0.4))
                    let formulaEdits = Self.isolationEdits(interpreter: interpreter, keeping: band, runs: formula.runs)
                    guard let form = composer.pageForm(layout.number, interpreter: interpreter, edits: formulaEdits, namePrefix: "FolioF") else { continue }
                    xobjects["F\(k)"] = form
                    let t = transplant.transform
                    content += "q \(PDFValue.format(t.a)) 0 0 \(PDFValue.format(t.d)) \(PDFValue.format(t.tx)) \(PDFValue.format(t.ty)) cm "
                        + "\(PDFValue.format(clip.minX)) \(PDFValue.format(clip.minY)) \(PDFValue.format(clip.width)) \(PDFValue.format(clip.height)) re W n /F\(k) Do Q\n"
                }
                for (k, keep) in (restores[layout.number] ?? []).enumerated() {
                    let clip = CGRect(x: keep.rect.minX - 0.8, y: keep.baseline - keep.size * 0.32, width: keep.rect.width + 1.6, height: keep.size * 1.3)
                    let keepEdits = Self.isolationEdits(interpreter: interpreter, keeping: clip, runs: keep.runs)
                    guard let form = composer.pageForm(layout.number, interpreter: interpreter, edits: keepEdits, namePrefix: "FolioK") else { continue }
                    xobjects["K\(k)"] = form
                    content += "q \(PDFValue.format(clip.minX)) \(PDFValue.format(clip.minY)) \(PDFValue.format(clip.width)) \(PDFValue.format(clip.height)) re W n /K\(k) Do Q\n"
                }
                let outputPage = composer.reserveOutputPage(forSourcePage: layout.number)
                if !dual {
                    composer.addPage(object: outputPage, mediaBox: geometry.mediaBox, cropBox: geometry.cropBox, rotation: geometry.rotation,
                                     content: Data(content.utf8), xobjects: xobjects, annotations: composer.links(ofSourcePage: layout.number))
                    continue
                }
                guard let original = composer.pageForm(layout.number) else { continue }
                // The translated page as one form, so it can be placed beside or after the original.
                let translatedForm = composer.writer.addStream(dict: [
                    "Type": .name("XObject"), "Subtype": .name("Form"), "BBox": .rect(geometry.mediaBox),
                    "Resources": .dict(["XObject": .dict(xobjects.mapValues { .ref($0) })]),
                ], data: Data(content.utf8))
                switch dualLayout {
                case .sideBySide:
                    let width = geometry.cropBox.width
                    let media = CGRect(x: geometry.cropBox.minX, y: geometry.cropBox.minY, width: width * 2, height: geometry.cropBox.height)
                    let both = "q /O Do Q\nq 1 0 0 1 \(PDFValue.format(width)) 0 cm /M Do Q\n"
                    composer.addPage(object: outputPage, mediaBox: media, rotation: geometry.rotation, content: Data(both.utf8),
                                     xobjects: ["O": original, "M": translatedForm],
                                     annotations: composer.links(ofSourcePage: layout.number)
                                        + composer.links(ofSourcePage: layout.number, offset: CGPoint(x: width, y: 0)))
                case .alternatingPages:
                    composer.addPage(object: outputPage, mediaBox: geometry.mediaBox, cropBox: geometry.cropBox, rotation: geometry.rotation,
                                     content: Data("q /O Do Q\n".utf8), xobjects: ["O": original],
                                     annotations: composer.links(ofSourcePage: layout.number))
                    composer.addPage(mediaBox: geometry.mediaBox, cropBox: geometry.cropBox, rotation: geometry.rotation,
                                     content: Data("q /M Do Q\n".utf8), xobjects: ["M": translatedForm],
                                     annotations: composer.links(ofSourcePage: layout.number))
                }
            }
            return composer.finish(title: title)
        }
        return Output(mono: wantMono ? compose(dual: false) : nil, dual: wantDual ? compose(dual: true) : nil)
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
            let top = other.lines[0].baseline + other.lines[0].size * 0.8
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
        var frame = CGRect(x: rect.minX, y: bottom, width: rect.width, height: rect.maxY - bottom)

        // Sideways for single lines (headings, short captions, cells): to the next obstacle on the right.
        if block.lines.count == 1 {
            let band = CGRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: max(rect.height - 2, 0.5))
            let right = obstacles.filter { $0.minX >= rect.maxX - 0.5 && $0.minY < band.maxY && $0.maxY > band.minY }.map(\.minX).min()
                ?? (inTable ? rect.maxX + size * 2 : page.maxX)
            let limit = inTable ? size * 3 : max(rect.width, size * 30)
            let maxX = min(right - gap, rect.maxX + limit)
            if maxX > frame.maxX { frame.size.width = maxX - frame.minX }
            if block.kind == .tableCell {
                // Cells grow on both sides, so centred text stays centred, into at most half the space between them
                // and their neighbours (which may grow too).
                let right = obstacles.filter { $0.minX >= rect.maxX - 0.5 && $0.minY < band.maxY && $0.maxY > band.minY }.map(\.minX).min()
                    ?? rect.maxX + size * 2
                let left = obstacles.filter { $0.maxX <= rect.minX + 0.5 && $0.minY < band.maxY && $0.maxY > band.minY }.map(\.maxX).max()
                    ?? rect.minX - size * 2
                let grow = max(0, min((right - rect.maxX) / 2, (rect.minX - left) / 2, size * 3) - 0.5)
                frame = CGRect(x: rect.minX - grow, y: frame.minY, width: rect.width + 2 * grow, height: frame.height)
            }
        }
        return frame
    }

    // MARK: Edits

    /// Removes the runs `removing` selects. A removed run followed by a kept one in the same chain (positioned
    /// relative to it) is drawn invisibly instead, so the kept text stays where it was.
    static func removalEdits(runs: [TextRun], removing: (TextRun) -> Bool) -> [OpLocation: EditAction] {
        removalEdits(runs: runs) { run, _ in removing(run) }
    }

    static func removalEdits(runs: [TextRun], removing: (TextRun, Int) -> Bool) -> [OpLocation: EditAction] {
        var removed: [Int] = []
        var lastKept: [Int: Int] = [:]
        for (i, run) in runs.enumerated() {
            // Clipping text (modes 4–7) shapes other content; leave it alone.
            if run.renderMode < 4, removing(run, i) {
                removed.append(i)
            } else {
                lastKept[run.chain] = max(lastKept[run.chain] ?? -1, run.location.index)
            }
        }
        var edits: [OpLocation: EditAction] = [:]
        for i in removed {
            let run = runs[i]
            if let kept = lastKept[run.chain], kept > run.location.index {
                edits[run.location] = .hide(restore: run.renderMode)
            } else {
                edits[run.location] = .drop
            }
        }
        return edits
    }

    /// Everything but what lies in `rect`: text outside it, drawings that do not touch it, and forms with nothing
    /// left in them.
    static func isolationEdits(interpreter: ContentInterpreter, keeping rect: CGRect, runs keep: Set<Int> = []) -> [OpLocation: EditAction] {
        let indexOf = Dictionary(interpreter.runs.enumerated().map { ($0.element.location, $0.offset) }, uniquingKeysWith: { a, _ in a })
        var edits = removalEdits(runs: interpreter.runs) { run in
            // The formula's operators, and whatever else lies in its rectangle (glyphs no character was matched to).
            if let index = indexOf[run.location], keep.contains(index) { return false }
            return !rect.contains(run.midpoint) && !rect.contains(CGPoint(x: (run.origin.x + run.end.x) / 2, y: run.origin.y))
        }
        var kept: Set<StreamPath> = []
        for run in interpreter.runs where edits[run.location] == nil {
            var path = run.location.stream
            kept.insert(path)
            while !path.isEmpty { path.removeLast(); kept.insert(path) }
        }
        for mark in interpreter.marks {
            if mark.rect.insetBy(dx: -0.5, dy: -0.5).intersects(rect) {
                var path = mark.location.stream
                kept.insert(path)
                while !path.isEmpty { path.removeLast(); kept.insert(path) }
            } else {
                for index in mark.opRange { edits[OpLocation(stream: mark.location.stream, index: index)] = .drop }
            }
        }
        for path in interpreter.streams.keys where !path.isEmpty && !kept.contains(path) {
            edits[OpLocation(stream: Array(path.dropLast()), index: path.last!)] = .drop
        }
        return edits
    }
}
