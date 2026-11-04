import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

@Suite struct PDFWriterTests {
    @Test func zlibStreamsDecodeWithAdler32() {
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        let compressed = Zlib.compress(data)!
        #expect(compressed[0] == 0x78 && compressed[1] == 0x9C)
        #expect(Zlib.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
    }

    @Test func numbersAndNamesAreWrittenAsPDFExpects() {
        #expect(PDFValue.format(1) == "1")
        #expect(PDFValue.format(0.5) == "0.5")
        #expect(PDFValue.format(-0.00001) == "0")
        var out = Data()
        PDFValue.name("A B#").serialize(into: &out)
        #expect(String(decoding: out, as: UTF8.self) == "/A#20B#23")
        out = Data()
        PDFValue.string(Data("a(b)\\".utf8)).serialize(into: &out)
        #expect(String(decoding: out, as: UTF8.self) == #"(a\(b\)\\)"#)
    }

    @Test func pagesRewrittenAsFormsRenderTheSame() throws {
        let folder = TemporaryDirectory()
        let input = folder.url.appending(path: "in.pdf"), output = folder.url.appending(path: "out.pdf")
        try TestPDF.make([TestPDF.paragraph(["The first line of text.", "A second line."], top: 700) + [.plot(CGRect(x: 72, y: 400, width: 200, height: 150))],
                          [.text("Page two", x: 72, y: 700, size: 14, bold: true)]]).write(to: input)
        try EngineDiagnostics.roundTrip(input: input, output: output, reemit: true)
        let differences = EngineDiagnostics.compare(input, output)
        #expect(differences.count == 2)
        #expect(differences.allSatisfy { $0 < 0.0005 }, "\(differences)")
        #expect(PDFDocument(url: output)?.string?.contains("A second line.") == true)
    }

    @Test func removedTextIsGoneAndTheRestStays() throws {
        let folder = TemporaryDirectory()
        let input = folder.url.appending(path: "in.pdf")
        try TestPDF.make([TestPDF.paragraph(["Remove this sentence.", "Keep this one."], top: 700)]).write(to: input)
        let document = CGPDFDocument(input as CFURL)!
        let interpreter = ContentInterpreter()
        interpreter.run(page: document.page(at: 1)!)
        #expect(interpreter.runs.count >= 2)
        let removing = Set(interpreter.glyphs.indices.filter { interpreter.glyphs[$0].origin.y > 695 })
        let edits = TranslationRenderer.glyphEdits(interpreter: interpreter, removing: removing)
        let composer = PDFComposer(source: document)
        let geometry = composer.geometry(ofSourcePage: 1)!
        let form = composer.pageForm(1, interpreter: interpreter, edits: edits)!
        composer.addPage(mediaBox: geometry.mediaBox, content: Data("q /P Do Q".utf8), xobjects: ["P": form])
        let text = PDFDocument(data: composer.finish())?.string ?? ""
        #expect(!text.contains("Remove"))
        #expect(text.contains("Keep this one."))
    }
}

@Suite struct LayoutTests {
    static func analyse(_ data: Data) -> [PageLayout] {
        let document = PDFDocument(data: data)!
        let cg = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        var analyzer = LayoutAnalyzer()
        return analyzer.analyze(document: document, cgDocument: cg, pages: Array(1...cg.numberOfPages))
    }

    @Test func paragraphsHeadingsAndFigureLabels() {
        var page: [TestPDF.Element] = [.text("A Paper About Layout Analysis", x: 120, y: 730, size: 18, bold: true)]
        page += [.text("1. Introduction", x: 72, y: 680, size: 12, bold: true)]
        page += TestPDF.paragraph(["Domain generalization aims to train models that work well on unseen",
                                   "target domains. This paper studies how layout analysis keeps figures",
                                   "intact while the running text around them is translated in place."], top: 660)
        page += [.plot(CGRect(x: 72, y: 380, width: 240, height: 180)), .text("Epoch", x: 180, y: 385, size: 7),
                 .text("Accuracy", x: 76, y: 540, size: 7)]
        page += [.text("Figure 1. Accuracy of the model during training.", x: 72, y: 360, size: 9)]
        let layout = Self.analyse(TestPDF.make([page]))[0]
        func block(_ prefix: String) -> LayoutBlock? { layout.blocks.first { $0.text.hasPrefix(prefix) } }
        #expect(block("A Paper")?.kind == .title)
        #expect(block("1. Introduction")?.kind == .heading)
        #expect(block("Domain generalization")?.kind == .paragraph)
        #expect(block("Domain generalization")?.lines.count == 3, "three lines, one paragraph")
        #expect(block("Figure 1.")?.kind == .caption && block("Figure 1.")?.translate == true)
        #expect(block("Epoch")?.translate == false, "labels inside a drawing stay as they are")
        #expect(block("Accuracy")?.kind == .figure)
        #expect(layout.figures.count == 1)
    }

    @Test func tableCellsAreSeparateAndNumbersStay() {
        var page: [TestPDF.Element] = [.rule(x: 72, y: 600, width: 300), .rule(x: 72, y: 582, width: 300), .rule(x: 72, y: 540, width: 300)]
        page += [.text("Method", x: 80, y: 586, size: 9), .text("Accuracy", x: 220, y: 586, size: 9), .text("Speed", x: 320, y: 586, size: 9)]
        page += [.text("Baseline model", x: 80, y: 568, size: 9), .text("71.2", x: 220, y: 568, size: 9), .text("12.5", x: 320, y: 568, size: 9)]
        page += [.text("Our method", x: 80, y: 548, size: 9), .text("75.9", x: 220, y: 548, size: 9), .text("11.8", x: 320, y: 548, size: 9)]
        page += TestPDF.paragraph(["Table 1. Results on the benchmark. Higher is better for accuracy."], top: 520, size: 9)
        let layout = Self.analyse(TestPDF.make([page]))[0]
        #expect(layout.tables.count == 1)
        let cells = layout.blocks.filter { $0.kind == .tableCell }
        #expect(cells.count == 9, "\(cells.map(\.text))")
        #expect(cells.first { $0.text == "Baseline model" }?.translate == true)
        #expect(cells.first { $0.text == "71.2" }?.translate == false)
        #expect(layout.blocks.first { $0.text.hasPrefix("Table 1.") }?.kind == .caption)
    }

    @Test func referencesStayInTheOriginal() {
        var page: [TestPDF.Element] = [.text("References", x: 72, y: 700, size: 12, bold: true)]
        page += TestPDF.paragraph(["[1] A. Author and B. Author. A study of things. In Proceedings of the Conference, 2020."], top: 680, size: 9)
        let layout = Self.analyse(TestPDF.make([page]))[0]
        #expect(layout.blocks.first { $0.text.hasPrefix("[1]") }?.kind == .reference)
        #expect(layout.blocks.allSatisfy { !$0.translate || $0.kind == .heading })
    }
}

@Suite struct TypesetterTests {
    @Test func translationStaysInsideItsFrame() {
        let data = TestPDF.make([TestPDF.paragraph(["Domain generalization aims to train models that work well on unseen",
                                                    "target domains and this is a fairly long line of text to fill space"], top: 700)])
        var analyzer = LayoutAnalyzer()
        let layout = analyzer.analyze(document: PDFDocument(data: data)!, cgDocument: CGPDFDocument(CGDataProvider(data: data as CFData)!)!, pages: [1])[0]
        let index = layout.blocks.firstIndex { $0.translate }!
        let frame = TranslationRenderer.frame(for: index, in: layout)
        let typesetter = Typesetter(language: "zh")
        // Far more text than fits: the type gets smaller, and lines never leave the frame.
        let long = String(repeating: "域泛化旨在训练在未见过的目标域上表现良好的模型。", count: 12)
        let result = typesetter.layout(long, block: layout.blocks[index], formulas: [], frame: frame)
        #expect(result.scale < 1)
        for (line, origin) in result.lines {
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            #expect(origin.x >= frame.minX - 0.5 && origin.x + width - CTLineGetTrailingWhitespaceWidth(line) <= frame.maxX + 1)
            #expect(origin.y >= frame.minY - 0.5)
        }
        let short = typesetter.layout("域泛化。", block: layout.blocks[index], formulas: [], frame: frame)
        #expect(short.scale == 1 && short.fits)
    }

    @Test func formulasBecomeTransplantsAtTheirPlaceholders() {
        let data = TestPDF.make([TestPDF.paragraph(["We minimise the loss over the training set."], top: 700)])
        var analyzer = LayoutAnalyzer()
        let layout = analyzer.analyze(document: PDFDocument(data: data)!, cgDocument: CGPDFDocument(CGDataProvider(data: data as CFData)!)!, pages: [1])[0]
        let index = layout.blocks.firstIndex { $0.translate }!
        let formula = FormulaSpan(rect: CGRect(x: 100, y: 697, width: 20, height: 12), baseline: 700)
        let result = Typesetter(language: "zh").layout("我们最小化{v1}，并且{v2}", block: layout.blocks[index], formulas: [formula],
                                                    frame: TranslationRenderer.frame(for: index, in: layout))
        #expect(result.transplants.count == 1, "unknown placeholders are ignored")
        #expect(abs(result.transplants[0].origin.y - 700) < 0.5, "on the first line's baseline")
    }
}

@Suite(.serialized) struct JobTests {
    @Test func translatesWithACommandAndFilesBothOutputs() async throws {
        let folder = TemporaryDirectory()
        TranslationJob.supportDirectory = folder.url.appending(path: "support")
        let input = folder.url.appending(path: "paper.pdf")
        var page: [TestPDF.Element] = [.text("A Paper About Layout Analysis", x: 120, y: 730, size: 18, bold: true)]
        page += TestPDF.paragraph(["Domain generalization aims to train models that work well on unseen",
                                   "target domains. This paper studies how layout analysis keeps figures."], top: 680)
        try TestPDF.make([page, page]).write(to: input)
        // The "translator" upper-cases its input.
        let command = try folder.script("upper.sh", "tr '[:lower:]' '[:upper:]'")
        let request = TranslationRequest(input: input, outputDirectory: folder.url.appending(path: "out"), serviceID: "clitranslator",
                                         fieldValues: ["--clitranslator-command": command.path], options: TranslationOptions(outputs: .both))
        let events = await collect(TranslationJob(request: request).start())
        guard case .finished(let mono?, let dual?) = events.last else {
            Issue.record("did not finish: \(events)")
            return
        }
        let text = PDFDocument(url: mono)?.string ?? ""
        #expect(text.contains("DOMAIN GENERALIZATION AIMS"))
        #expect(!text.contains("Domain generalization aims"), "the original text is removed")
        let dualDocument = PDFDocument(url: dual)!
        #expect(dualDocument.pageCount == 2)
        #expect(dualDocument.page(at: 0)!.bounds(for: .mediaBox).width == 1224, "original and translation side by side")
        #expect(events.contains { if case .progress = $0 { true } else { false } })

        // A second run comes from the cache: no command needed.
        let cached = TranslationRequest(input: input, outputDirectory: folder.url.appending(path: "out2"), serviceID: "clitranslator",
                                        fieldValues: ["--clitranslator-command": "/usr/bin/false"], options: TranslationOptions(outputs: .mono))
        let again = await collect(TranslationJob(request: cached).start())
        if case .finished(let mono?, nil) = again.last {
            #expect(PDFDocument(url: mono)?.string?.contains("DOMAIN GENERALIZATION AIMS") == true)
        } else {
            Issue.record("cached run did not finish: \(again)")
        }
    }

    @Test func failuresAreExplained() async throws {
        let folder = TemporaryDirectory()
        TranslationJob.supportDirectory = folder.url.appending(path: "support")
        let input = folder.url.appending(path: "paper.pdf")
        try TestPDF.make([TestPDF.paragraph(["Some text to translate here and there."], top: 700)]).write(to: input)
        let request = TranslationRequest(input: input, outputDirectory: folder.url.appending(path: "out"), serviceID: "openai",
                                         options: TranslationOptions(ignoreCache: true))
        let events = await collect(TranslationJob(request: request).start())
        guard case .failed(let message, _) = events.last else {
            Issue.record("expected a failure: \(events)")
            return
        }
        #expect(message.contains("API Key"))
    }
}
