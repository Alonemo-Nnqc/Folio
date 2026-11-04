import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

@Suite struct PageFlowTests {
    private let words = "These words fill the whole of the line that they are set in today"

    private func analyze(_ page: [TestPDF.Element]) -> (CGPDFDocument, [PageLayout]) {
        let data = TestPDF.make([page])
        let cg = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        var analyzer = LayoutAnalyzer()
        return (cg, analyzer.analyze(document: PDFDocument(data: data)!, cgDocument: cg, pages: [1]))
    }

    /// Two paragraphs of `lines` lines each, the second starting one line under the first, indented.
    private func twoParagraphs(lines: Int, top: Double = 700) -> [TestPDF.Element] {
        var page: [TestPDF.Element] = []
        for block in 0..<2 {
            let start = top - Double(block * lines) * 12
            for k in 0..<lines {
                page.append(.text(words, x: k == 0 ? 84 : 72, y: start - Double(k) * 12, size: 10))
            }
        }
        return page
    }

    private func flowed(_ layout: PageLayout, text: (Int) -> String) -> (entries: [PageFlow.Entry], placements: [Int: PageFlow.Placement], results: [Typesetter.Result]) {
        let typesetter = Typesetter(language: "zh")
        let segments = SegmentBuilder.segments(for: layout)
        var entries = segments.enumerated().map { n, segment -> PageFlow.Entry in
            let frame = TranslationRenderer.frame(for: segment.block, in: layout)
            let t = text(n)
            return PageFlow.Entry(block: segment.block, frame: frame, text: t, formulas: segment.formulas,
                                  plan: typesetter.plan(t, block: layout.blocks[segment.block], formulas: segment.formulas, frame: frame))
        }
        let placements = PageFlow.layOut(&entries, layout: layout, typesetter: typesetter).placements
        let results = entries.indices.map { k in
            typesetter.finish(entries[k].plan, pitch: placements[k]!.pitch, firstBaseline: placements[k]!.firstBaseline, formulas: entries[k].formulas)
        }
        return (entries, placements, results)
    }

    @Test func paragraphsInAColumnFormOneStretch() {
        let (_, layouts) = analyze(twoParagraphs(lines: 4))
        let paragraphs = layouts[0].blocks.indices.filter { layouts[0].blocks[$0].kind == .paragraph }
        #expect(paragraphs.count == 2, "\(layouts[0].blocks.map(\.text))")
        #expect(PageFlow.runs(of: paragraphs, in: layouts[0]).count == 1)
    }

    @Test func aTranslationShorterThanItsOriginalGetsEvenLinesAcrossAParagraphBreak() {
        // Each paragraph takes fewer lines than its original: alone, each would stretch its lines, and the step from one
        // paragraph to the next would be the squeezed one.
        let (_, layouts) = analyze(twoParagraphs(lines: 4))
        let sentence = String(repeating: "这是一段被翻译成中文的文字，", count: 5)
        let (_, _, results) = flowed(layouts[0]) { _ in sentence }
        let baselines = results.flatMap { $0.lines.map { Double($0.origin.y) } }
        #expect(baselines.count >= 4)
        let gaps = zip(baselines, baselines.dropFirst()).map { $0 - $1 }
        let smallest = gaps.min()!, largest = gaps.max()!
        #expect(smallest > 0)
        // Even, and the paragraph break is never the tight one.
        #expect(smallest >= largest * 0.95 || gaps.dropLast().allSatisfy { abs($0 - gaps[0]) < 0.01 }, "\(gaps)")
        let breakIndex = results[0].lines.count - 1
        #expect(gaps[breakIndex] >= gaps[0] - 0.01, "\(gaps)")
    }

    @Test func aTranslationLongerThanOneParagraphBorrowsFromTheNext() {
        let (_, layouts) = analyze(twoParagraphs(lines: 4))
        let long = String(repeating: "这是一段被翻译成中文的文字，", count: 13)
        let short = String(repeating: "这是一段文字，", count: 3)
        let (entries, _, results) = flowed(layouts[0]) { $0 == 0 ? long : short }
        // No smaller type: the second paragraph moved down instead.
        #expect(entries.allSatisfy { abs($0.plan.scale - 1) < 0.001 }, "\(entries.map(\.plan.scale))")
        #expect(results[0].lines.count > 4)
        #expect(Double(results[1].lines[0].origin.y) < Double(layouts[0].blocks[entries[1].block].lines[0].baseline))
    }

    /// Paragraph, then `middle`, then paragraph.
    private func around(_ middle: [TestPDF.Element], gap: Double) -> [TestPDF.Element] {
        var page: [TestPDF.Element] = []
        for k in 0..<4 { page.append(.text(words, x: k == 0 ? 84 : 72, y: 700 - Double(k) * 12, size: 10)) }
        page += middle
        for k in 0..<4 { page.append(.text(words, x: k == 0 ? 84 : 72, y: 664 - gap - Double(k) * 12, size: 10)) }
        return page
    }

    @Test func aHeadingBetweenParagraphsMovesAlong() {
        let (_, layouts) = analyze(around([.text("3. A Section Heading", x: 72, y: 642, size: 12, bold: true)], gap: 36))
        let layout = layouts[0]
        let translated = layout.blocks.indices.filter { layout.blocks[$0].translate }
        let flows = PageFlow.flows(of: translated, in: layout)
        #expect(flows.count == 1, "\(layout.blocks.map(\.text))")
        #expect(PageFlow.runs(of: translated, in: layout)[0].contains { layout.blocks[$0].kind == .heading })
        // Each paragraph shorter than its original: the heading moves up with the text, spacing stays one.
        let sentence = String(repeating: "这是一段被翻译成中文的文字，", count: 5)
        let (entries, placements, results) = flowed(layout) { _ in sentence }
        let heading = entries.firstIndex { layout.blocks[$0.block].kind == .heading }!
        #expect(placements[heading]!.firstBaseline > layout.blocks[entries[heading].block].lines[0].baseline - 40)
        #expect(results.allSatisfy { !$0.lines.isEmpty })
        // No two lines of the stretch closer than the spacing.
        let baselines = results.flatMap { $0.lines.map { Double($0.origin.y) } }.sorted(by: >)
        let gaps = zip(baselines, baselines.dropFirst()).map { $0 - $1 }
        #expect(gaps.min()! >= placements[0]!.pitch - 0.01, "\(gaps)")
    }

    @Test func aDisplayedFormulaMovesAlongWithTheTextAroundIt() throws {
        let (cg, layouts) = analyze(around([.text("x = y + z (1)", x: 250, y: 642, size: 10)], gap: 36))
        let layout = layouts[0]
        let formula = try #require(layout.blocks.firstIndex { $0.kind == .formula })
        let translated = layout.blocks.indices.filter { layout.blocks[$0].translate }
        let flows = PageFlow.flows(of: translated, in: layout)
        #expect(flows.count == 1, "\(layout.blocks.map(\.text))")
        #expect(flows[0].contains(.formula([formula])))

        // Short translations: the formula comes up with them, and it is drawn where it went, once.
        let segments = layout.blocks.indices.flatMap { _ in [TextSegment]() } + SegmentBuilder.segments(for: layout)
        // The first paragraph much shorter than its original: what comes after it goes up.
        let translations = Dictionary(uniqueKeysWithValues: segments.enumerated().map { n, segment in
            (segment.id, n == 0 ? "这是一段被翻译成中文的文字。" : String(repeating: "这是一段被翻译成中文的文字，", count: 5))
        })
        let renderer = TranslationRenderer(source: cg, language: "zh")
        let audit = RenderAudit()
        renderer.audit = audit
        let output = renderer.render(layouts: layouts, segments: segments, translations: translations, mono: true, dual: false, dualLayout: .sideBySide, title: nil)
        let data = try #require(output.mono)
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let text = page.string ?? ""
        #expect(text.components(separatedBy: "x = y + z").count == 2, "\(text)")
        let dy = audit.moved[1]?[formula] ?? 0
        #expect(abs(dy) > 1, "\(audit.moved)")
        let found = try #require(PDFDocument(data: data)?.findString("x = y + z", withOptions: []).first)
        let bounds = found.bounds(for: found.pages[0])
        #expect(abs(Double(bounds.minY) - (642 + dy - 2)) < 6, "\(bounds) \(dy)")
    }

    @Test func aFigureBesideTheTextKeepsTheParagraphsApart() {
        // Narrow text beside a drawing, then wide text under it: moving the wide lines up would run into the drawing.
        var page: [TestPDF.Element] = [.plot(CGRect(x: 320, y: 640, width: 150, height: 70))]
        let narrow = "Narrow words that are set beside it"
        for k in 0..<4 { page.append(.text(narrow, x: 72, y: 700 - Double(k) * 12, size: 10)) }
        for k in 0..<3 { page.append(.text(words + words, x: 72, y: 628 - Double(k) * 12, size: 10)) }
        let (_, layouts) = analyze(page)
        let paragraphs = layouts[0].blocks.indices.filter { layouts[0].blocks[$0].translate && layouts[0].blocks[$0].kind == .paragraph }
        #expect(paragraphs.count == 2, "\(layouts[0].blocks.map(\.text))")
        #expect(PageFlow.runs(of: paragraphs, in: layouts[0]).count == 2)
    }

    @Test func aFormulaReachingIntoTheFirstLineDoesNotKeepParagraphsApart() {
        var page = twoParagraphs(lines: 4)
        // A tall symbol above the first line whose box reaches just past it.
        page.append(.text("Σ", x: 200, y: 712, size: 24))
        let (_, layouts) = analyze(page)
        let paragraphs = layouts[0].blocks.indices.filter { layouts[0].blocks[$0].kind == .paragraph && layouts[0].blocks[$0].lines.count > 1 }
        #expect(PageFlow.runs(of: paragraphs, in: layouts[0]).count == 1, "\(layouts[0].blocks.map(\.text))")
    }

    @Test func aFullLineBesideTheNextColumnIsNoTableRow() {
        // Two columns, whose single lines have the other column right beside them on the same baseline.
        var page: [TestPDF.Element] = []
        let column = "These words fill a whole column line today"
        for k in 0..<3 { page.append(.text(column, x: 54, y: 700 - Double(k) * 12, size: 9)) }
        page.append(.text(column, x: 54, y: 650, size: 9))
        for k in 0..<3 { page.append(.text(column, x: 54, y: 638 - Double(k) * 12, size: 9)) }
        for k in 0..<8 { page.append(.text(column, x: 318, y: 700 - Double(k) * 12 - 2, size: 9)) }
        for k in 0..<8 { page.append(.text(column, x: 318, y: 650 - Double(k) * 12, size: 9)) }
        let (_, layouts) = analyze(page)
        let layout = layouts[0]
        let single = layout.blocks.indices.filter { layout.blocks[$0].translate && layout.blocks[$0].lines.count == 1 && layout.blocks[$0].rect.minX < 100 }
        let translated = layout.blocks.indices.filter { layout.blocks[$0].translate }
        let inRuns = Set(PageFlow.runs(of: translated, in: layout).flatMap { $0 })
        #expect(single.allSatisfy { inRuns.contains($0) }, "\(layout.blocks.map(\.text))")
    }

    @Test func shortLinesOneUnderAnotherAreLeftAlone() {
        var page = twoParagraphs(lines: 4)
        for (k, name) in ["Retinal vessels", "Deep learning", "Segmentation"].enumerated() {
            page.append(.text(name, x: 72, y: 500 - Double(k) * 12, size: 10))
        }
        let (_, layouts) = analyze(page)
        let translated = layouts[0].blocks.indices.filter { layouts[0].blocks[$0].translate }
        let runs = PageFlow.runs(of: translated, in: layouts[0])
        let names = translated.filter { layouts[0].blocks[$0].text.hasPrefix("Retinal") || layouts[0].blocks[$0].text.hasPrefix("Deep") }
        #expect(!names.isEmpty, "\(layouts[0].blocks.map(\.text))")
        // Not stretched with the paragraphs above, nor with each other.
        #expect(!runs.contains { run in run.contains { names.contains($0) } && run.count > 1 }, "\(runs)")
    }

    @Test func aFullWidthBracketStartingALineHangsIntoTheMargin() {
        let (_, layouts) = analyze(twoParagraphs(lines: 4))
        let typesetter = Typesetter(language: "zh")
        let block = layouts[0].blocks.first { $0.kind == .paragraph }!
        let frame = CGRect(x: block.rect.minX, y: 100, width: 100, height: block.rect.maxY - 100)
        // Brackets often enough for some line to start with one, however many characters a line holds.
        // A bracket every so many characters, so that some line starts with one whatever a line holds.
        let text = (1...60).map { "\(String(repeating: "字", count: 3 + $0 % 11))（括号）" }.joined()
        let plan = typesetter.plan(text, block: block, formulas: [], frame: frame, indent: 0)
        // Some lines start further out than the others, by half a character: those that open with the bracket.
        let hanging = plan.lines.filter { $0.x < frame.minX - 1 }
        #expect(!hanging.isEmpty)
        #expect(hanging.count < plan.lines.count)
        #expect(hanging.allSatisfy { abs($0.x - (frame.minX - plan.fontSize / 2)) < 0.01 })
    }
}

@Suite struct TableAndIconTests {
    private func line(_ text: String, x: Double, baseline: Double, size: Double = 9) -> LayoutLine {
        let chars = text.enumerated().map { k, c in
            PageChar(text: String(c), rect: CGRect(x: x + Double(k) * 5, y: baseline - 2, width: 5, height: 11), isSpace: c == " ", isNewline: false,
                     size: size, baseline: baseline, font: .unknown, color: .black, run: nil, isRotated: false)
        }
        return LayoutAnalyzer.makeLine(chars)!
    }

    private func mark(_ rect: CGRect) -> GraphicMark {
        GraphicMark(kind: .fill, rect: rect, isWhite: false, location: OpLocation(stream: [], index: 0), hasCurves: false, segmentCount: 4, opRange: 0...0)
    }

    private var rows: [LayoutLine] {
        [680.0, 660, 640, 620].enumerated().flatMap { k, y in
            [line("Method \(k)", x: 100, baseline: y), line("0.\(k)1", x: 220, baseline: y)]
        }
    }

    @Test func aTableWithVerticalRulesIsATable() {
        let frame = CGRect(x: 90, y: 610, width: 200, height: 90)
        let verticals = [90.0, 210, 290].map { mark(CGRect(x: $0, y: 610, width: 1.5, height: 90)) }
        #expect(LayoutAnalyzer().isTable(frame, lines: rows, marks: verticals))
    }

    @Test func gridLinesAroundBarsAreAChart() {
        let frame = CGRect(x: 90, y: 610, width: 200, height: 90)
        let bars = [100.0, 140, 180].map { mark(CGRect(x: $0, y: 610, width: 20, height: 60)) }
        #expect(!LayoutAnalyzer().isTable(frame, lines: rows, marks: bars))
    }

    /// One page: words, a small picture among them, more words.
    private func pdfWithIcon() -> Data {
        let before = "These are the words that come before", after = "and the words that come after it on the line"
        let iconX = 72 + before.count * 5 + 3
        let content = "BT /F1 10 Tf 1 0 0 1 72 100 Tm (\(before)) Tj ET q 8 0 0 8 \(iconX) 99 cm /Im0 Do Q BT /F1 10 Tf 1 0 0 1 \(iconX + 11) 100 Tm (\(after)) Tj ET"
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im0 6 0 R >> >> >>")
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 /Widths [\(Array(repeating: "500", count: 95).joined(separator: " "))] >>")
        objects.append("<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\nstream\n0\nendstream")
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    @Test func aPictureAmongTheWordsMovesWithThem() throws {
        let data = pdfWithIcon()
        let cg = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        var analyzer = LayoutAnalyzer()
        let layouts = analyzer.analyze(document: PDFDocument(data: data)!, cgDocument: cg, pages: [1])
        let segment = try #require(SegmentBuilder.segments(for: layouts[0]).first)
        #expect(segment.source.contains("{v1}"), "\(segment.source)")
        let formula = try #require(segment.formulas.first)
        #expect(formula.icons.count == 1)
        let renderer = TranslationRenderer(source: cg, language: "zh")
        // The picture first in the translation: far left of where it was.
        let output = renderer.render(layouts: layouts, segments: [segment], translations: [segment.id: "{v1} 这是翻译以后的文字。"], mono: true, dual: false, dualLayout: .sideBySide, title: nil)
        let mono = try #require(output.mono)
        let interpreter = ContentInterpreter()
        interpreter.run(page: CGPDFDocument(CGDataProvider(data: mono as CFData)!)!.page(at: 1)!)
        let images = interpreter.marks.filter { $0.kind == .image }
        #expect(images.count == 1, "\(images.map(\.rect))")
        #expect(abs(Double(images[0].rect.minX) - 72) < 2, "\(images[0].rect)")
        #expect(abs(Double(images[0].rect.width) - 8) < 0.5)
    }

    @Test func scriptsStackedUnderOthersStayOnTheirLine() {
        // "… f" + superscript "conv" drawn first, then subscript "1x1" under it and the rest of the line.
        var first = line("split operation f", x: 100, baseline: 600, size: 10).chars
        first += line("conv", x: 185, baseline: 603.6, size: 7).chars.map { c in var c = c; c.isScript = true; return c }
        let head = LayoutAnalyzer.makeLine(first)!
        let scripts = line("1x1", x: 185, baseline: 597, size: 7)
        let merged = LayoutAnalyzer.mergePieces(head, scripts, tables: [], pageWidth: 612)
        #expect(merged != nil)
        #expect(merged?.baseline == head.baseline)
    }

    @Test func aFractionsBarGoesWithItsFormula() {
        let area = CGRect(x: 100, y: 96, width: 7.5, height: 18)
        #expect(TranslationRenderer.isRule(CGRect(x: 99.5, y: 105, width: 8.6, height: 0), ofFormulaIn: [area]))
        #expect(TranslationRenderer.isRule(CGRect(x: 103, y: 98, width: 0.5, height: 14), ofFormulaIn: [area]))
        // A rule across the column, or something drawn with some body to it, is not the formula's.
        #expect(!TranslationRenderer.isRule(CGRect(x: 60, y: 105, width: 200, height: 0.5), ofFormulaIn: [area]))
        #expect(!TranslationRenderer.isRule(CGRect(x: 100, y: 100, width: 7, height: 7), ofFormulaIn: [area]))
    }

    @Test func aRowOfColumnNamesIsNoLineOfText() {
        #expect(LayoutAnalyzer.proseWords(line("Architecture mIoU F1 score Acc AUC Sen MCC Rank Avg", x: 100, baseline: 600)) < 5)
        #expect(LayoutAnalyzer.proseWords(line("these are the words of a line that goes on in the text", x: 100, baseline: 600)) >= 6)
    }

    @Test func textStaysAboveARuleTheOriginalAlmostTouched() {
        // The last line of a caption just over a table's rule.
        let block = LayoutBlock(kind: .caption, lines: [line("Table 3. A caption that is set right over the", x: 100, baseline: 610),
                                                        line("rule of the table that comes under it", x: 100, baseline: 600)], translate: true)
        let layout = PageLayout(number: 1, mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792), cropBox: CGRect(x: 0, y: 0, width: 612, height: 792),
                                blocks: [block], figures: [], tables: [], graphics: [CGRect(x: 80, y: 598, width: 300, height: 0.5)], runs: [])
        #expect(TranslationRenderer.frame(for: 0, in: layout).minY >= 598.5)
    }

    @Test func aRuleAboveACellKeepsItsTextUnder() {
        let block = LayoutBlock(kind: .tableCell, lines: [line("Setting", x: 100, baseline: 600, size: 10)], translate: true)
        let layout = PageLayout(number: 1, mediaBox: CGRect(x: 0, y: 0, width: 612, height: 792), cropBox: CGRect(x: 0, y: 0, width: 612, height: 792),
                                blocks: [block], figures: [], tables: [], graphics: [CGRect(x: 80, y: 608, width: 200, height: 0.5)], runs: [])
        #expect(TranslationRenderer.frame(for: 0, in: layout).maxY <= 608)
    }
}
