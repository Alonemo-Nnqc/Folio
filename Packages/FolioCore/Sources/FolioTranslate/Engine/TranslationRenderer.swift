import CoreGraphics
import CoreText
import Foundation

/// Produces the translated PDFs from the analysed pages and the translations of their segments.
///
/// Each output page draws: the original page with the translated text removed (form XObject), the translations
/// set by Core Text (a page of a separate PDF, also a form), and each inline formula cut from the original and
/// moved to its place in the translation (a form keeping only that formula, clipped to it).
final class TranslationRenderer {
    let source: CGPDFDocument
    let language: String
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
        var removals: [Int: [CGRect]] = [:]
        if let consumer = CGDataConsumer(data: overlayData as CFMutableData),
           let context = CGContext(consumer: consumer, mediaBox: nil, nil) {
            let typesetter = Typesetter(language: language)
            for layout in layouts {
                var box = layout.mediaBox
                let info = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary
                context.beginPDFPage(info)
                for segment in bySegment[layout.number] ?? [] {
                    guard let text = translations[segment.id], !text.isEmpty else { continue }
                    let block = layout.blocks[segment.block]
                    let frame = Self.frame(for: segment.block, in: layout)
                    let result = typesetter.layout(text, block: block, formulas: segment.formulas, frame: frame)
                    typesetter.draw(result, in: context)
                    transplants[layout.number, default: []] += result.transplants
                    removals[layout.number, default: []] += block.lines.map { $0.rect.insetBy(dx: -0.5, dy: -$0.size * 0.1) }
                }
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
                let rects = removals[layout.number] ?? []
                var edits = Self.removalEdits(runs: interpreter.runs, removing: { r in rects.contains { $0.contains(r.midpoint) } })
                // Rules that are part of formulas (fraction bars, radicals) move with the formula.
                for mark in interpreter.marks where mark.kind != .image && !mark.isWhite
                    && mark.rect.height < 4 && rects.contains(where: { $0.insetBy(dx: -0.5, dy: -0.5).contains(mark.rect) }) {
                    for index in mark.opRange { edits[OpLocation(stream: mark.location.stream, index: index)] = .drop }
                }
                if let edited = composer.pageForm(layout.number, interpreter: interpreter, edits: edits) {
                    xobjects["E"] = edited
                    content += "q /E Do Q\n"
                }
                if let text = composer.foreignPageForm(overlay, page: index + 1) {
                    xobjects["T"] = text
                    content += "q /T Do Q\n"
                }
                for (k, transplant) in (transplants[layout.number] ?? []).enumerated() {
                    let clip = transplant.formula.rect.insetBy(dx: -0.6, dy: -0.4)
                    let formulaEdits = Self.isolationEdits(interpreter: interpreter, keeping: clip)
                    guard let form = composer.pageForm(layout.number, interpreter: interpreter, edits: formulaEdits, namePrefix: "FolioF") else { continue }
                    xobjects["F\(k)"] = form
                    let t = transplant.transform
                    content += "q \(PDFValue.format(t.a)) 0 0 \(PDFValue.format(t.d)) \(PDFValue.format(t.tx)) \(PDFValue.format(t.ty)) cm "
                        + "\(PDFValue.format(clip.minX)) \(PDFValue.format(clip.minY)) \(PDFValue.format(clip.width)) \(PDFValue.format(clip.height)) re W n /F\(k) Do Q\n"
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
            obstacles.append(other.rect)
        }
        let inTable = layout.tables.contains { $0.insetBy(dx: -1, dy: -2).contains(rect.center) }
        for g in layout.graphics where g.width * g.height > 1 || g.width > 20 || g.height > 20 {
            // Rules a cell sits between count; the frame of the table it sits in does not.
            if g.contains(rect) && g.width * g.height > rect.width * rect.height * 4 { continue }
            obstacles.append(g)
        }
        if !inTable { obstacles += layout.tables }
        let page = layout.cropBox.insetBy(dx: layout.cropBox.width * 0.03, dy: layout.cropBox.height * 0.03)

        // Downwards: to the nearest obstacle below that overlaps horizontally.
        let horizontal = rect.insetBy(dx: 1, dy: 0)
        let belowTop = obstacles.filter { $0.maxY <= rect.minY + size * 0.2 && $0.maxX > horizontal.minX && $0.minX < horizontal.maxX }
            .map(\.maxY).max() ?? page.minY
        let maxExtension = block.kind == .tableCell ? size * 0.2 : max(block.pitch * 2, rect.height * 0.5)
        let bottom = max(min(rect.minY, belowTop + gap), rect.minY - maxExtension)
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
                // Cells grow on both sides, so centred text stays centred.
                let left = obstacles.filter { $0.maxX <= rect.minX + 0.5 && $0.minY < band.maxY && $0.maxY > band.minY }.map(\.maxX).max()
                    ?? rect.minX - size * 2
                let grow = min(frame.maxX - rect.maxX, rect.minX - max(left + gap, rect.minX - size * 3))
                frame = CGRect(x: rect.minX - max(grow, 0), y: frame.minY, width: rect.width + 2 * max(grow, 0), height: frame.height)
            }
        }
        return frame
    }

    // MARK: Edits

    /// Removes the runs `removing` selects. A removed run followed by a kept one in the same chain (positioned
    /// relative to it) is drawn invisibly instead, so the kept text stays where it was.
    static func removalEdits(runs: [TextRun], removing: (TextRun) -> Bool) -> [OpLocation: EditAction] {
        var removed: [Int] = []
        var lastKept: [Int: Int] = [:]
        for (i, run) in runs.enumerated() {
            // Clipping text (modes 4–7) shapes other content; leave it alone.
            if run.renderMode < 4, removing(run) {
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
    static func isolationEdits(interpreter: ContentInterpreter, keeping rect: CGRect) -> [OpLocation: EditAction] {
        var edits = removalEdits(runs: interpreter.runs) { run in
            !rect.contains(run.midpoint) && !rect.contains(CGPoint(x: (run.origin.x + run.end.x) / 2, y: run.origin.y))
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
