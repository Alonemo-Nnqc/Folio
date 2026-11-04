import CoreGraphics
import Foundation

/// Developer checks of the engine's building blocks, used by `folio-translate` and tests.
public enum EngineDiagnostics {
    /// Rewrites every page of `input` as a form XObject (optionally interpreted and re-emitted op by op) to `output`.
    public static func roundTrip(input: URL, output: URL, reemit: Bool) throws {
        guard let document = CGPDFDocument(input as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
        let composer = PDFComposer(source: document)
        for number in 1...document.numberOfPages {
            _ = composer.reserveOutputPage(forSourcePage: number)
        }
        for number in 1...document.numberOfPages {
            guard let geometry = composer.geometry(ofSourcePage: number) else { continue }
            var form: Int?
            if reemit {
                let interpreter = ContentInterpreter()
                interpreter.run(page: document.page(at: number)!)
                // Hiding nothing still exercises the editor: an unmatched location forces the rewrite path.
                form = composer.pageForm(number, interpreter: interpreter, edits: [OpLocation(stream: [-1], index: -1): .drop])
            } else {
                form = composer.pageForm(number)
            }
            guard let form else { continue }
            composer.addPage(object: composer.reserveOutputPage(forSourcePage: number), mediaBox: geometry.mediaBox,
                             cropBox: geometry.cropBox, rotation: geometry.rotation, content: Data("q /P Do Q".utf8),
                             xobjects: ["P": form], annotations: composer.links(ofSourcePage: number))
        }
        try composer.finish().write(to: output)
    }

    /// Renders both documents and returns, per page, the fraction of pixels that differ noticeably.
    public static func compare(_ a: URL, _ b: URL, scale: Double = 1.5) -> [Double] {
        guard let da = CGPDFDocument(a as CFURL), let db = CGPDFDocument(b as CFURL) else { return [] }
        return (1...min(da.numberOfPages, db.numberOfPages)).map { number in
            guard let pa = render(da.page(at: number)!, scale: scale), let pb = render(db.page(at: number)!, scale: scale),
                  pa.count == pb.count else { return 1 }
            var differing = 0
            for i in stride(from: 0, to: pa.count, by: 4) {
                let d = abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                if d > 48 { differing += 1 }
            }
            return Double(differing) / Double(pa.count / 4)
        }
    }

    static func render(_ page: CGPDFPage, scale: Double) -> [UInt8]? {
        let box = page.getBoxRect(.cropBox)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            return true
        }
        return ok ? pixels : nil
    }
}

import ImageIO
import PDFKit
import UniformTypeIdentifiers

extension EngineDiagnostics {
    /// Writes one PNG per page showing the layout: blocks coloured by kind (solid = translated), figures in blue,
    /// tables in orange, formula characters in purple. Returns a text summary.
    public static func layout(input: URL, outputDirectory: URL, pages: [Int]?) throws -> String {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
        let numbers = pages ?? Array(1...cg.numberOfPages)
        var analyzer = LayoutAnalyzer()
        let start = Date()
        let layouts = analyzer.analyze(document: document, cgDocument: cg, pages: numbers)
        var summary = String(format: "analysed %d pages in %.3f s, body size %.1f\n", layouts.count, Date().timeIntervalSince(start), analyzer.bodySize)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for layout in layouts {
            let page = cg.page(at: layout.number)!
            let box = layout.cropBox
            let scale = 2.0
            let width = Int(box.width * scale), height = Int(box.height * scale)
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            ctx.setLineWidth(0.8)
            for figure in layout.figures {
                ctx.setFillColor(CGColor(red: 0, green: 0.3, blue: 1, alpha: 0.12))
                ctx.fill(figure)
                ctx.setStrokeColor(CGColor(red: 0, green: 0.3, blue: 1, alpha: 0.8))
                ctx.stroke(figure)
            }
            for table in layout.tables {
                ctx.setStrokeColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 0.9))
                ctx.setLineWidth(1.5)
                ctx.stroke(table.insetBy(dx: -2, dy: -2))
            }
            ctx.setLineWidth(0.8)
            var counts: [BlockKind: Int] = [:]
            for block in layout.blocks {
                counts[block.kind, default: 0] += 1
                let color = Self.color(block.kind)
                ctx.setStrokeColor(color.copy(alpha: 0.9)!)
                if block.translate {
                    ctx.setFillColor(color.copy(alpha: 0.13)!)
                    ctx.fill(block.rect)
                    ctx.stroke(block.rect)
                } else {
                    ctx.setLineDash(phase: 0, lengths: [2, 2])
                    ctx.stroke(block.rect)
                    ctx.setLineDash(phase: 0, lengths: [])
                }
                for line in block.lines {
                    for c in line.chars where c.isMath {
                        ctx.setFillColor(CGColor(red: 0.6, green: 0, blue: 0.8, alpha: 0.3))
                        ctx.fill(c.rect)
                    }
                }
            }
            if ProcessInfo.processInfo.environment["DUMP"] != nil {
                for block in layout.blocks {
                    summary += "[\(block.kind.rawValue)\(block.translate ? "*" : "")] " + String(format: "(%.0f,%.0f %.0fx%.0f) ", block.rect.minX, block.rect.minY, block.rect.width, block.rect.height)
                        + block.lines.map { $0.text }.joined(separator: " | ") + "\n"
                }
            }
            summary += "page \(layout.number): " + BlockKind.allCases.compactMap { k in counts[k].map { "\(k.rawValue) \($0)" } }.joined(separator: ", ")
                + ", figures \(layout.figures.count), tables \(layout.tables.count)\n"
            guard let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(outputDirectory.appending(path: "page-\(layout.number).png") as CFURL,
                                                             UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        return summary
    }

    static func color(_ kind: BlockKind) -> CGColor {
        switch kind {
        case .title: CGColor(red: 0.8, green: 0, blue: 0.4, alpha: 1)
        case .heading: CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)
        case .paragraph: CGColor(red: 0, green: 0.6, blue: 0.2, alpha: 1)
        case .caption: CGColor(red: 0, green: 0.5, blue: 0.7, alpha: 1)
        case .tableCell: CGColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        case .formula: CGColor(red: 0.6, green: 0, blue: 0.8, alpha: 1)
        case .figure: CGColor(red: 0, green: 0.3, blue: 1, alpha: 1)
        default: CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        }
    }
}

extension EngineDiagnostics {
    public static func runs(input: URL, page number: Int) -> String {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL) else { return "" }
        let interpreter = ContentInterpreter()
        interpreter.run(page: cg.page(at: number)!)
        var chars = PageText.characters(of: document.page(at: number - 1)!, interpreter: interpreter)
        MathDetector.mark(&chars)
        let visible = chars.filter { !$0.isSpace && !$0.isNewline }
        var out = "runs \(interpreter.runs.count), chars \(visible.count), unmapped \(visible.filter { $0.run == nil }.count)\n"
        for c in visible[60..<min(72, visible.count)] {
            out += String(format: "char %@ rect (%.1f,%.1f %.1fx%.1f) size %.2f base %.1f run %d\n", c.text, c.rect.minX, c.rect.minY, c.rect.width, c.rect.height, c.size, c.baseline, c.run ?? -1)
        }
        for run in interpreter.runs.prefix(40) {
            out += String(format: "(%.1f,%.1f)->(%.1f,%.1f) size %.2f %@\n", run.origin.x, run.origin.y, run.end.x, run.end.y, run.fontSize, run.font.name)
        }
        for c in visible.prefix(300) where c.run == nil {
            out += "unmapped \(c.text) \(c.rect)\n"
        }
        var probeStart: Int?
        if let text = ProcessInfo.processInfo.environment["PROBE_TEXT"] {
            let joined = chars.map(\.text)
            probeStart = joined.indices.first { i in joined[i...].prefix(text.count).joined() == text }
        }
        if let start = probeStart {
            for c in chars[start..<min(start + Int(ProcessInfo.processInfo.environment["PROBE_COUNT"] ?? "30")!, chars.count)] {
                out += String(format: "%@ x %.1f-%.1f y %.1f-%.1f base %.1f size %.1f run %d %@ math %d\n", c.isSpace ? "␣" : c.text, c.rect.minX, c.rect.maxX, c.rect.minY, c.rect.maxY, c.baseline, c.size, c.run ?? -1, c.font.name, c.isMath ? 1 : 0)
            }
        }
        if let probe = ProcessInfo.processInfo.environment["PROBE"], let start = chars.firstIndex(where: { $0.text == String(probe.first!) && abs($0.rect.minY - (Double(probe.dropFirst()) ?? 0)) < 3 }) {
            for c in chars[start..<min(start + Int(ProcessInfo.processInfo.environment["PROBE_COUNT"] ?? "30")!, chars.count)] {
                out += String(format: "%@ x %.1f-%.1f y %.1f base %.1f size %.1f run %d\n", c.isSpace ? "␣" : c.text, c.rect.minX, c.rect.maxX, c.rect.minY, c.baseline, c.size, c.run ?? -1)
            }
        }
        return out
    }
}

extension EngineDiagnostics {
    /// Runs layout, typesetting and composition with made-up Chinese text (about as long as a real translation),
    /// writing `<name>.mono.pdf` and `<name>.dual.pdf`.
    public static func fakeTranslate(input: URL, outputDirectory: URL, pages: [Int]?) throws -> String {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
        let numbers = pages ?? Array(1...cg.numberOfPages)
        var analyzer = LayoutAnalyzer()
        var t = Date()
        let layouts = analyzer.analyze(document: document, cgDocument: cg, pages: numbers)
        var report = String(format: "layout %.2f s\n", Date().timeIntervalSince(t))
        let segments = SegmentBuilder.segments(for: layouts, target: "zh")
        let sample = Array("本文提出了一种简单而有效的方法，用于在未知目标域上提升语义分割模型的泛化能力。我们在多个基准数据集上进行了大量实验，结果表明该方法优于现有技术。")
        var translations: [String: String] = [:]
        for segment in segments {
            let letters = segment.source.filter(\.isLetter).count
            let length = max(2, Int(Double(letters) * 0.42))
            var text = ""
            let pieces = segment.formulas.count + 1
            for k in 0..<pieces {
                let n = length / pieces
                for i in 0..<n { text.append(sample[(k * 7 + i) % sample.count]) }
                if k < segment.formulas.count { text += "{v\(k + 1)}" }
            }
            translations[segment.id] = text
        }
        t = Date()
        let renderer = TranslationRenderer(source: cg, language: "zh")
        let output = renderer.render(layouts: layouts, segments: segments, translations: translations, mono: true, dual: true,
                                     dualLayout: .sideBySide, title: nil)
        report += String(format: "render %.2f s, %d segments, %d formulas\n", Date().timeIntervalSince(t), segments.count,
                         segments.reduce(0) { $0 + $1.formulas.count })
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let name = input.deletingPathExtension().lastPathComponent
        try output.mono?.write(to: outputDirectory.appending(path: "\(name).mono.pdf"))
        try output.dual?.write(to: outputDirectory.appending(path: "\(name).dual.pdf"))
        report += "mono \(output.mono?.count ?? 0) bytes, dual \(output.dual?.count ?? 0) bytes\n"
        return report
    }

    /// Renders pages of a PDF to PNGs (for looking at results).
    public static func snapshot(input: URL, outputDirectory: URL, pages: [Int], scale: Double = 2) throws {
        guard let cg = CGPDFDocument(input as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for number in pages where number <= cg.numberOfPages {
            let page = cg.page(at: number)!
            let box = page.getBoxRect(.cropBox)
            guard let ctx = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(page)
            guard let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(outputDirectory.appending(path: "\(input.deletingPathExtension().lastPathComponent)-\(number).png") as CFURL,
                                                             UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

extension EngineDiagnostics {
    public static func segments(input: URL, page: Int, containing needle: String) -> String {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL) else { return "" }
        var analyzer = LayoutAnalyzer()
        let layouts = analyzer.analyze(document: document, cgDocument: cg, pages: [page])
        var out = ""
        for segment in layouts.flatMap({ SegmentBuilder.segments(for: $0) }) where needle.isEmpty || segment.source.contains(needle) {
            out += "[\(segment.kind.rawValue)] \(segment.source)\n"
            for (i, f) in segment.formulas.enumerated() {
                out += String(format: "  v%d x %.1f-%.1f y %.1f-%.1f base %.1f\n", i + 1, f.rect.minX, f.rect.maxX, f.rect.minY, f.rect.maxY, f.baseline)
            }
        }
        return out
    }
}

extension EngineDiagnostics {
    public static func lines(input: URL, page number: Int, minY: Double, maxY: Double) -> String {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL) else { return "" }
        let interpreter = ContentInterpreter()
        interpreter.run(page: cg.page(at: number)!)
        var chars = PageText.characters(of: document.page(at: number - 1)!, interpreter: interpreter)
        MathDetector.mark(&chars)
        let analyzer = LayoutAnalyzer()
        let lines = analyzer.buildLines(chars, tables: [], pageWidth: 600)
        var out = ""
        for line in lines where line.baseline >= minY && line.baseline <= maxY {
            out += String(format: "base %.1f size %.1f x %.1f-%.1f: ", line.baseline, line.size, line.minX, line.maxX) + line.text + "\n"
            out += "   " + line.chars.filter { !$0.isSpace }.map { String(format: "%@[%.1f r%d m%d]", $0.text, $0.baseline, $0.run ?? -1, $0.isMath ? 1 : 0) }.joined(separator: " ") + "\n"
        }
        return out
    }
}

extension EngineDiagnostics {
    public static func bing(_ text: String) async -> String {
        do {
            let session = try await BingWebProvider.fetchSession()
            let result = try await BingWebProvider().translateOne(text, context: TranslationContext(sourceLanguage: "en", targetLanguage: "zh", glossary: []))
            return "\(session)\n\(result)"
        } catch { return "\(error)" }
    }
}

extension EngineDiagnostics {
    /// Renders with cached translations of `serviceID` (made-up text where there are none) and checks the result:
    /// translated lines over other content, outside their frame, shrunk type, how full paragraphs are, and
    /// original text left behind. Writes the mono PDF to `output` when given.
    public static func audit(input: URL, serviceID: String, model: String = "", output: URL? = nil, verbose: Bool = false) throws -> String {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL) else { throw CocoaError(.fileReadCorruptFile) }
        var analyzer = LayoutAnalyzer()
        let layouts = analyzer.analyze(document: document, cgDocument: cg, pages: Array(1...cg.numberOfPages))
        let segments = SegmentBuilder.segments(for: layouts, target: "zh")
        let cache = TranslationCache(directory: TranslationJob.supportDirectory.appending(path: "cache", directoryHint: .isDirectory),
                                     document: input, signature: "\(serviceID)|\(model)|en|zh|v1", ignore: false)
        let sample = Array("本文提出了一种简单而有效的方法，用于在未知目标域上提升语义分割模型的泛化能力。我们在多个基准数据集上进行了大量实验，结果表明该方法优于现有技术。")
        var translations: [String: String] = [:]
        var cached = 0
        for segment in segments {
            if segment.kind == .heading, let heading = StandardHeadings.translate(segment.source, to: "zh") {
                translations[segment.id] = heading
                continue
            }
            if let hit = cache.lookup(segment.source) {
                translations[segment.id] = hit
                cached += 1
                continue
            }
            let length = max(2, Int(Double(segment.source.filter(\.isLetter).count) * 0.42))
            var text = ""
            for k in 0...segment.formulas.count {
                for i in 0..<(length / (segment.formulas.count + 1)) { text.append(sample[(k * 7 + i) % sample.count]) }
                if k < segment.formulas.count { text += "{v\(k + 1)}" }
            }
            translations[segment.id] = text
        }
        // Paragraphs continued in the next column or page: translated as one, then cut where each part ends.
        let continuations = Continuations.find(segments, layouts: layouts)
        var joinedNotes: [String] = []
        for c in continuations where c.parts.allSatisfy({ cache.lookup($0.source) == nil }) {
            var offset = 0
            var whole = ""
            for (k, part) in c.parts.enumerated() {
                let shift = offset
                let text = Placeholders.replace(in: translations[part.id] ?? "") { TextSegment.placeholder($0 + shift) }
                whole += (k == 0 ? "" : Continuations.marker) + text
                offset += part.formulas.count
            }
            guard let pieces = Continuations.split(whole, c) else { joinedNotes.append("joined, not splittable: p\(c.parts[0].page)"); continue }
            for (part, piece) in zip(c.parts, pieces) { translations[part.id] = piece }
            let a = c.parts[0].source.suffix(30), b = c.parts[1].source.prefix(30)
            joinedNotes.append("joined: p\(c.parts[0].page)→p\(c.parts[1].page) \"…\(a)\" + \"\(b)…\"")
        }
        let renderer = TranslationRenderer(source: cg, language: "zh")
        let audit = RenderAudit()
        renderer.audit = audit
        renderer.auditLayers = true
        let rendered = renderer.render(layouts: layouts, segments: segments, translations: translations, mono: true, dual: false,
                                       dualLayout: .sideBySide, title: nil)
        if let output, let mono = rendered.mono { try mono.write(to: output) }

        var issues: [String] = []
        var overlaps = 0, outside = 0, shrunk = 0, unfit = 0, stray = 0, misplaced = 0
        var fills: [Double] = []
        let byPage = Dictionary(grouping: audit.entries, by: \.page)
        for layout in layouts {
            let entries = byPage[layout.number] ?? []
            let translated = Set(entries.map(\.block))
            var obstacles: [(String, CGRect)] = []
            for (i, block) in layout.blocks.enumerated() where !translated.contains(i) {
                let rect = block.rect.offsetBy(dx: 0, dy: audit.moved[layout.number]?[i] ?? 0)
                obstacles.append(("\(block.kind.rawValue) \"\(block.text.prefix(24))\"", rect.insetBy(dx: 0.5, dy: block.size * 0.15)))
            }
            for figure in layout.figures { obstacles.append(("figure", figure)) }
            // A piece of a formula set with another line: the glyphs drawn just before and after it are elsewhere.
            do {
                var lineOfRun: [Int: Int] = [:]
                var charsAndLines: [(c: PageChar, line: Int, translated: Bool)] = []
                var n = 0
                for block in layout.blocks {
                    for line in block.lines {
                        for c in line.chars where !c.isSpace {
                            if let run = c.run { lineOfRun[run] = n }
                            charsAndLines.append((c, n, block.translate && block.kind != .formula))
                        }
                        n += 1
                    }
                }
                let translatedLines = Set(charsAndLines.filter(\.translated).map(\.line))
                for (c, own, _) in charsAndLines where c.isMath {
                    guard let run = c.run, let before = lineOfRun[run - 1], let after = lineOfRun[run + 1], before == after, before != own,
                          translatedLines.contains(before) || translatedLines.contains(own) else { continue }
                    misplaced += 1
                    issues.append("misplaced: p\(layout.number) \"\(c.text)\" @\(Int(c.rect.midX)),\(Int(c.rect.midY))")
                }
            }
            // Stays on the page in the middle of a paragraph that is set again: it would sit on top of the translation.
            for (i, block) in layout.blocks.enumerated() where !translated.contains(i) && block.lines.reduce(0, { $0 + $1.visibleCount }) <= 8 {
                let inside = entries.contains { entry in
                    let host = layout.blocks[entry.block]
                    return host.kind == .paragraph && host.rect.insetBy(dx: 0, dy: host.size * 0.3).contains(block.rect.center)
                }
                if inside { stray += 1; issues.append("stray: p\(layout.number) \"\(block.text.prefix(24))\" @\(Int(block.rect.minX)),\(Int(block.rect.minY))") }
            }
            for entry in entries {
                let block = layout.blocks[entry.block]
                let label = "p\(layout.number) \(block.kind.rawValue) \"\(block.text.prefix(30))\""
                if entry.scale < 0.85 { shrunk += 1; if verbose { issues.append(String(format: "shrunk %.2f: ", entry.scale) + label) } }
                if !entry.fits { unfit += 1; issues.append("does not fit: " + label) }
                func at(_ r: CGRect) -> String { String(format: " @%d,%.0f,%.0f,%.0f,%.0f", layout.number, r.minX, r.minY, r.width, r.height) }
                for box in entry.boxes {
                    // The first line's ascent may reach above the original's line box; bottom and sides may not grow.
                    let allowed = CGRect(x: entry.frame.minX - 1.5, y: entry.frame.minY - 1.5, width: entry.frame.width + 3,
                                         height: entry.frame.height + 1.5 + entry.fontSize * 0.35)
                    if !allowed.contains(box) {
                        outside += 1
                        issues.append("outside frame: " + label + at(box))
                        break
                    }
                }
                var hit = false
                for box in entry.boxes where !hit {
                    for (name, rect) in obstacles where rect.intersection(box).area > max(2, box.area * 0.03) {
                        // A drawing the block sits on (a shaded box) is a background, not an obstacle.
                        if rect.contains(block.rect.insetBy(dx: 2, dy: 2)) { continue }
                        overlaps += 1
                        issues.append("overlaps \(name): " + label + at(box))
                        hit = true
                        break
                    }
                    for other in entries where other.block != entry.block && !hit {
                        if other.boxes.contains(where: { $0.intersection(box).area > max(2, box.area * 0.05) }) {
                            overlaps += 1
                            issues.append("overlaps translated block \(other.block): " + label + at(box))
                            hit = true
                        }
                    }
                }
                if block.kind == .paragraph, block.lines.count >= 3, entry.lineCount >= 2 {
                    let original = block.lines[0].baseline - block.lines.last!.baseline
                    let drawn = entry.pitch * Double(entry.lineCount - 1)
                    fills.append(drawn / original)
                }
            }
        }
        // Real collisions: places where what was set over the page and what stays of the page both put ink.
        var collisions = 0
        if let base = rendered.base.flatMap({ CGPDFDocument(CGDataProvider(data: $0 as CFData)!) }),
           let over = rendered.overlay.flatMap({ CGPDFDocument(CGDataProvider(data: $0 as CFData)!) }) {
            for layout in layouts where byPage[layout.number] != nil {
                guard let a = base.page(at: layout.number), let b = over.page(at: layout.number) else { continue }
                for spot in inkCollisions(a, b) {
                    collisions += 1
                    issues.append(String(format: "collision %d px: p%d @%d,%.0f,%.0f,%.0f,%.0f", spot.pixels, layout.number, layout.number, spot.rect.minX, spot.rect.minY, spot.rect.width, spot.rect.height))
                }
            }
        }
        // Even spacing: neighbouring lines of running text much closer together than is usual on their page.
        var tightGaps = 0, lineGaps = 0
        for layout in layouts {
            // Lists of short lines (keywords, names) and table rows set their own distances; running text is what counts.
            let measures = layout.blocks.filter { $0.kind == .paragraph && $0.lines.count >= 2 }.map(\.rect.width).sorted()
            let measure = measures.isEmpty ? Double.infinity : measures[measures.count / 2]
            let entries = (byPage[layout.number] ?? []).filter { entry in
                let block = layout.blocks[entry.block]
                return block.kind == .paragraph && (block.lines.count >= 2 || block.rect.width >= measure * 0.6)
            }
            var lines = entries.flatMap { entry in entry.lines.map { (line: $0, size: entry.fontSize) } }
            lines.sort { $0.line.baseline > $1.line.baseline }
            let kept = layout.blocks.enumerated().filter { k, _ in !entries.contains { $0.block == k } }.map { k, block in
                block.rect.offsetBy(dx: 0, dy: audit.moved[layout.number]?[k] ?? 0)
            }
            var gaps: [(distance: Double, ratio: Double, upper: Int)] = []
            for (i, upper) in lines.enumerated() {
                guard let j = lines[(i + 1)...].firstIndex(where: { lower in
                    min(lower.line.maxX, upper.line.maxX) - max(lower.line.minX, upper.line.minX) > min(lower.line.maxX - lower.line.minX, upper.line.maxX - upper.line.minX) * 0.5
                        && upper.line.baseline - lower.line.baseline > upper.size * 0.5
                }) else { continue }
                let lower = lines[j]
                let distance = upper.line.baseline - lower.line.baseline
                guard distance < upper.size * 3, abs(upper.size - lower.size) < upper.size * 0.1 else { continue }
                // Something kept between them (a formula) sets its own distance.
                let band = CGRect(x: max(lower.line.minX, upper.line.minX), y: lower.line.baseline + upper.size * 0.2,
                                  width: min(lower.line.maxX, upper.line.maxX) - max(lower.line.minX, upper.line.minX), height: max(distance - upper.size * 0.4, 0.1))
                if kept.contains(where: { $0.intersects(band) }) { continue }
                gaps.append((distance, distance / upper.size, i))
            }
            let sorted = gaps.map(\.ratio).sorted()
            guard sorted.count >= 4 else { continue }
            let median = sorted[sorted.count / 2]
            lineGaps += gaps.count
            for gap in gaps where gap.ratio < median * 0.85 {
                tightGaps += 1
                let upper = lines[gap.upper].line
                issues.append(String(format: "tight gap %.2f of %.2f: p%d @%d,%.0f,%.0f,%.0f,%.0f", gap.ratio, median, layout.number, layout.number,
                                     upper.minX, upper.baseline - gap.distance, upper.maxX - upper.minX, gap.distance))
            }
        }
        // Original text left on translated pages.
        var residual = 0
        if let mono = rendered.mono, let out = PDFDocument(data: mono) {
            for segment in segments where translations[segment.id] != nil {
                let words = segment.source.split(separator: " ").filter { $0.count > 3 && !$0.contains("{") }.prefix(5)
                guard words.count == 5 else { continue }
                let phrase = words.joined(separator: " ")
                if out.page(at: segment.page - 1)?.string?.replacingOccurrences(of: "\n", with: " ").contains(phrase) == true,
                   segment.source.contains(phrase) {
                    residual += 1
                    issues.append("original text left: p\(segment.page) \"\(phrase)\"")
                }
            }
        }
        // Links under translated words: which of them followed their words.
        var linksFollowed = 0, linksLost = 0
        for layout in layouts {
            let byBlock = Dictionary(grouping: segments.filter { $0.page == layout.number }, by: \.block)
            for (block, parts) in byBlock {
                var texts: [Int: String] = [:]
                for line in layout.blocks[block].lines {
                    for c in line.chars { if let link = c.link { texts[link, default: ""] += c.text } }
                }
                let followed = Set(parts.flatMap(\.formulas).flatMap(\.allLinks).map(\.link))
                for (link, text) in texts {
                    if followed.contains(link) {
                        linksFollowed += 1
                    } else {
                        linksLost += 1
                        issues.append("link lost: p\(layout.number) \"\(text.prefix(50))\"")
                    }
                }
            }
        }
        fills.sort()
        let fill = fills.isEmpty ? 0 : fills[fills.count / 2]
        let low = fills.filter { $0 < 0.75 }.count
        var report = String(format: "%@: %d segments (%d cached), overlaps %d, outside %d, unfit %d, shrunk<0.85 %d, rewritten ops %d, residual %d, lost glyphs %d, formula glyphs %d, links followed %d lost %d, tight gaps %d of %d, collisions %d, fill median %.2f (%d of %d under 0.75)\n",
                            input.lastPathComponent, segments.count, cached, overlaps, outside, unfit, shrunk, audit.conflicts, residual,
                            audit.lostGlyphs, audit.formulaGlyphs, linksFollowed, linksLost, tightGaps, lineGaps, collisions, fill, low, fills.count)
        report += "left behind \(audit.leftBehind.count), misplaced \(misplaced), stray \(stray), continued \(continuations.count)\n"
        for note in joinedNotes.prefix(verbose ? 200 : 10) { report += "  " + note + "\n" }
        for glyph in audit.leftBehind.prefix(verbose ? 200 : 20) { report += "  left: " + glyph + "\n" }
        for issue in issues.prefix(verbose ? 400 : 60) { report += "  " + issue + "\n" }
        return report
    }
}

extension EngineDiagnostics {
    /// The fonts a page uses: name, type, vertical metrics, and glyphs drawn with each (text, reliability).
    public static func fonts(input: URL, page number: Int) -> String {
        guard let cg = CGPDFDocument(input as CFURL), let page = cg.page(at: number) else { return "" }
        let interpreter = ContentInterpreter()
        interpreter.run(page: page)
        var out = ""
        for (k, font) in interpreter.fonts.enumerated() {
            let descriptor = PDFDictionary.dict(font.dict, "FontDescriptor")
            let ascent = descriptor.flatMap { PDFDictionary.number($0, "Ascent") } ?? .nan
            let descent = descriptor.flatMap { PDFDictionary.number($0, "Descent") } ?? .nan
            let bbox = descriptor.flatMap { PDFDictionary.rect($0, "FontBBox") } ?? .zero
            let glyphs = interpreter.glyphs.filter { $0.font == k }
            let unknown = glyphs.filter { $0.text == nil }.count, guessed = glyphs.filter { $0.text != nil && !$0.reliable }.count
            out += String(format: "%d %@ %@ asc %.0f desc %.0f bbox %.0f %.0f %.0f %.0f glyphs %d unknown %d guessed %d em %.2f\n", k, font.info.name,
                          PDFDictionary.name(font.dict, "Subtype") ?? "?", ascent, descent, bbox.minX, bbox.minY, bbox.maxX, bbox.maxY,
                          glyphs.count, unknown, guessed, font.emScale)
            out += "   " + glyphs.prefix(40).map { $0.text ?? "<\(String($0.code, radix: 16))>" }.joined(separator: " ") + "\n"
        }
        return out
    }
}

extension EngineDiagnostics {
    /// Every block of a page with its kind, whether it is translated, and where it is.
    public static func blocks(input: URL, page: Int, containing needle: String = "") -> String {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL) else { return "" }
        var analyzer = LayoutAnalyzer()
        guard let layout = analyzer.analyze(document: document, cgDocument: cg, pages: [page]).first else { return "" }
        var out = ""
        // Which stretch of even lines each paragraph is set in.
        let runs = PageFlow.runs(of: layout.blocks.indices.filter { layout.blocks[$0].translate }, in: layout)
        var stretch: [Int: Int] = [:]
        for (k, run) in runs.enumerated() { for member in run { stretch[member] = k } }
        for (i, block) in layout.blocks.enumerated() where needle.isEmpty || block.text.contains(needle) {
            let r = block.rect
            out += String(format: "%3d %@%@%@ (%.0f,%.0f %.0fx%.0f) ", i, block.kind.rawValue, block.translate ? "*" : "", stretch[i].map { " s\($0)" } ?? "", r.minX, r.minY, r.width, r.height)
                + String(block.text.prefix(90)) + "\n"
        }
        return out
    }
}

extension EngineDiagnostics {
    /// The links of a PDF: where each is, the text under it, and where it leads.
    public static func links(input: URL, pages: [Int]? = nil) -> String {
        guard let document = PDFDocument(url: input) else { return "" }
        var out = ""
        var total = 0, internalLinks = 0, external = 0, dead = 0
        for number in pages ?? Array(1...max(document.pageCount, 1)) {
            guard let page = document.page(at: number - 1) else { continue }
            for annotation in page.annotations where annotation.type == "Link" {
                total += 1
                let r = annotation.bounds
                let text = page.selection(for: r)?.string?.replacingOccurrences(of: "\n", with: " ") ?? ""
                var target = "?"
                if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination {
                    if let to = destination.page {
                        target = "p\(document.index(for: to) + 1) y\(Int(destination.point.y))"
                        internalLinks += 1
                    } else {
                        dead += 1
                    }
                } else if let url = (annotation.action as? PDFActionURL)?.url {
                    target = url.absoluteString
                    external += 1
                } else {
                    dead += 1
                }
                out += String(format: "p%d (%.0f,%.0f %.0fx%.0f) \"%@\" → %@\n", number, r.minX, r.minY, r.width, r.height, String(text.prefix(40)), target)
            }
        }
        return "links \(total): internal \(internalLinks), web \(external), no target \(dead)\n" + out
    }
}

extension EngineDiagnostics {
    /// Blocks that look wrongly understood, for checking the analysis on many documents: formulas sent for
    /// translation, text left in the original, paragraphs cut into pieces.
    public static func suspects(input: URL) -> String {
        guard let document = PDFDocument(url: input), let cg = CGPDFDocument(input as CFURL), cg.numberOfPages > 0 else { return "" }
        var analyzer = LayoutAnalyzer()
        let layouts = analyzer.analyze(document: document, cgDocument: cg, pages: Array(1...cg.numberOfPages))
        var out = ""
        func report(_ kind: String, _ layout: PageLayout, _ rect: CGRect, _ text: String) {
            out += String(format: "%@ p%d \"%@\" @%d,%.0f,%.0f,%.0f,%.0f\n", kind, layout.number, String(text.prefix(60)).replacingOccurrences(of: "\n", with: " "),
                          layout.number, rect.minX, rect.minY, rect.width, rect.height)
        }
        for layout in layouts {
            let blocks = layout.blocks
            for (i, block) in blocks.enumerated() {
                let visible = block.lines.reduce(0) { $0 + $1.visibleCount }
                if block.translate {
                    // A line set far apart from its neighbours: a display inside the paragraph.
                    if block.lines.count >= 3 {
                        let gaps = zip(block.lines, block.lines.dropFirst()).map { $0.baseline - $1.baseline }
                        if let g = gaps.max(), g > block.pitch * 1.7 { report("gap", layout, block.rect, block.text) }
                    }
                    let math = block.lines.reduce(0) { $0 + $1.chars.filter { $0.isMath && !$0.isSpace }.count }
                    if visible >= 3, Double(math) >= Double(visible) * 0.5 { report("mathy", layout, block.rect, block.text) }
                    let words = block.lines.reduce(0) { $0 + LayoutAnalyzer.textWords($1) }
                    if words <= 1, block.kind != .tableCell { report("fewwords", layout, block.rect, block.text) }
                    if layout.figures.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(block.rect.center) }) { report("infigure", layout, block.rect, block.text) }
                    // Something else on the same baseline, right next to it: a piece of a line.
                    if block.lines.count == 1, block.kind == .heading || block.kind == .paragraph {
                        let line = block.lines[0]
                        let beside = blocks.enumerated().contains { k, other in
                            k != i && other.lines.contains { o in
                                abs(o.baseline - line.baseline) < line.size * 0.3 && (o.minX - line.maxX < line.size * 0.8 && o.minX >= line.minX || line.minX - o.maxX < line.size * 0.8 && o.maxX <= line.maxX)
                            }
                        }
                        if beside { report("piece", layout, block.rect, block.text) }

                    }
                    for (k, other) in blocks.enumerated() where k > i && other.translate {
                        let shared = block.rect.insetBy(dx: 1, dy: block.size * 0.25).intersection(other.rect.insetBy(dx: 1, dy: other.size * 0.25))
                        if !shared.isNull, shared.width > 2, shared.height > 1 { report("cross", layout, shared, block.text + " × " + other.text) }
                    }
                } else if block.kind != .reference && block.kind != .figure && block.kind != .tableCell && block.kind != .header && block.kind != .rotated {
                    let prose = block.lines.reduce(0) { $0 + $1.text.split(separator: " ").filter { $0.count >= 3 && $0.allSatisfy { $0.isLowercase } }.count }
                    if prose >= 5 { report("kept-\(block.kind.rawValue)", layout, block.rect, block.text) }
                }
                // A paragraph in pieces: one-line blocks stacked like lines.
                if block.translate, block.kind == .paragraph, block.lines.count == 1, i + 1 < blocks.count {
                    let next = blocks[i + 1]
                    if next.translate, next.kind == .paragraph, next.lines.count == 1, abs(next.lines[0].minX - block.lines[0].minX) < 1,
                       block.lines[0].baseline - next.lines[0].baseline < block.size * 1.5, block.lines[0].baseline > next.lines[0].baseline {
                        report("stack", layout, block.rect.union(next.rect), block.text)
                    }
                }
            }
        }
        return out
    }
}

extension EngineDiagnostics {
    /// The agents found on this Mac; with `probe`, each is asked to translate one sentence.
    public static func agents(probe: Bool, only: String? = nil) async -> String {
        var out = ""
        for agent in LocalAgent.allCases where only == nil || agent.serviceID == only || agent.command == only {
            guard let url = agent.locate() else {
                out += "○ \(agent.serviceID)\t\(agent.commands.joined(separator: "/"))\tnot found\n"
                continue
            }
            out += "● \(agent.serviceID)\t\(url.path)\t\(agent.version(at: url) ?? "?")\n"
            guard probe else { continue }
            let started = Date()
            let outcome = await TranslationServiceTest.run(serviceID: agent.serviceID, fields: [:], secrets: [:])
            out += String(format: "    %@ %.0f s: %@\n", outcome.succeeded ? "ok" : "FAILED", Date().timeIntervalSince(started), outcome.message)
        }
        return out
    }
}

extension EngineDiagnostics {
    /// Where two pages (rendered at twice their size) both have dark ink, grouped into spots: page coordinates, and how
    /// many pixels. Anything light (a shaded row behind a table) is not ink.
    static func inkCollisions(_ a: CGPDFPage, _ b: CGPDFPage) -> [(rect: CGRect, pixels: Int)] {
        let scale = 2.0
        guard let pa = render(a, scale: scale), let pb = render(b, scale: scale), pa.count == pb.count else { return [] }
        let box = a.getBoxRect(.cropBox)
        let width = Int(box.width * scale), height = Int(box.height * scale)
        let cell = 12
        var cells: [Int: Int] = [:]
        let columns = width / cell + 1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                func dark(_ p: [UInt8]) -> Bool { Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) < 320 }
                if dark(pa), dark(pb) { cells[(y / cell) * columns + x / cell, default: 0] += 1 }
            }
        }
        // Neighbouring cells are one spot.
        var seen: Set<Int> = []
        var spots: [(rect: CGRect, pixels: Int)] = []
        for start in cells.keys where !seen.contains(start) {
            var stack = [start], pixels = 0
            var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0
            seen.insert(start)
            while let c = stack.popLast() {
                pixels += cells[c] ?? 0
                let row = c / columns, column = c % columns
                minX = min(minX, column); maxX = max(maxX, column); minY = min(minY, row); maxY = max(maxY, row)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let n = (row + dy) * columns + column + dx
                        if cells[n] != nil, seen.insert(n).inserted { stack.append(n) }
                    }
                }
            }
            guard pixels >= 6 else { continue }
            // The bitmap's rows run down from the top of the page.
            let size = Double(cell) / scale
            spots.append((CGRect(x: box.minX + Double(minX) * size, y: box.maxY - Double(maxY + 1) * size, width: Double(maxX - minX + 1) * size, height: Double(maxY - minY + 1) * size), pixels))
        }
        return spots.sorted { $0.pixels > $1.pixels }
    }
}

extension EngineDiagnostics {
    /// What a page draws other than text, largest first.
    public static func marks(input: URL, page number: Int) -> String {
        guard let cg = CGPDFDocument(input as CFURL), let page = cg.page(at: number) else { return "" }
        let interpreter = ContentInterpreter()
        interpreter.run(page: page)
        return interpreter.marks.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }.map { m in
            String(format: "%@ (%.1f,%.1f %.1fx%.1f) curves %d segs %d white %d", "\(m.kind)", m.rect.minX, m.rect.minY, m.rect.width, m.rect.height, m.hasCurves ? 1 : 0, m.segmentCount, m.isWhite ? 1 : 0)
        }.joined(separator: "\n")
    }
}
