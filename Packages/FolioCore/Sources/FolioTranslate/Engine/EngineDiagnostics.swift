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
        var chars = PageText.characters(of: document.page(at: number - 1)!, runs: interpreter.runs)
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
        let segments = layouts.flatMap(SegmentBuilder.segments(for:))
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
        for segment in layouts.flatMap(SegmentBuilder.segments(for:)) where needle.isEmpty || segment.source.contains(needle) {
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
        var chars = PageText.characters(of: document.page(at: number - 1)!, runs: interpreter.runs)
        MathDetector.mark(&chars)
        let analyzer = LayoutAnalyzer()
        let lines = analyzer.buildLines(chars, tables: [], pageWidth: 600)
        var out = ""
        for line in lines where line.baseline >= minY && line.baseline <= maxY {
            out += String(format: "base %.1f size %.1f x %.1f-%.1f: ", line.baseline, line.size, line.minX, line.maxX) + line.text + "\n"
            out += "   " + line.chars.filter { !$0.isSpace }.prefix(8).map { String(format: "%@[%.1f %.1f %@]", $0.text, $0.baseline, $0.size, $0.isScript ? "s" : "") }.joined(separator: " ") + "\n"
        }
        return out
    }
}
