import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

/// Two pages: page 1 says "See the results in [12] for this method.", with a link over "12" to page 2 (by name).
enum LinkPDF {
    static func make(destination: String = "/A << /S /GoTo /D (cite.a) >>", content: String? = nil, rect: String = "[171.5 96 182.5 110]") -> Data {
        let body = content ?? "BT /F1 10 Tf 1 0 0 1 72 100 Tm (See the results in [12] for this method and for many other things as well.) Tj ET"
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R /Names << /Dests << /Names [(cite.a) [4 0 R /XYZ 72 200 null]] >> >> >>")
        objects.append("<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>")
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> /Annots [8 0 R] >>")
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>")
        objects.append("<< /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream")
        let second = "BT /F1 10 Tf 1 0 0 1 72 200 Tm (Reference entry.) Tj ET"
        objects.append("<< /Length \(second.utf8.count) >>\nstream\n\(second)\nendstream")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 /Widths [\(Array(repeating: "500", count: 95).joined(separator: " "))] >>")
        objects.append("<< /Type /Annot /Subtype /Link /Rect \(rect) /Border [0 0 0] \(destination) >>")
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

    static func layouts(_ data: Data) -> (CGPDFDocument, [PageLayout]) {
        let cg = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        var analyzer = LayoutAnalyzer()
        return (cg, analyzer.analyze(document: PDFDocument(data: data)!, cgDocument: cg, pages: [1, 2]))
    }
}

@Suite struct LinkTests {
    @Test func linkTextRoles() {
        #expect(LinkText.role(of: "12") == .whole)
        #expect(LinkText.role(of: "Vaswani et al. 2017") == .whole)
        #expect(LinkText.role(of: "He, Zhang, Ren and Sun") == .whole)
        #expect(LinkText.role(of: "https://github.com/foo/bar") == .whole)
        #expect(LinkText.role(of: "Figure 3") == .number(after: 7))
        #expect(LinkText.role(of: "Sec. 4.1") == .number(after: 5))
        #expect(LinkText.role(of: "see the supplementary material for more details") == .prose)
    }

    @Test func aCitationIsKeptWholeWithItsBrackets() throws {
        let (_, layouts) = LinkPDF.layouts(LinkPDF.make())
        let segment = try #require(SegmentBuilder.segments(for: layouts[0]).first)
        #expect(segment.source.contains("in {v1} for"), "\(segment.source)")
        let formula = try #require(segment.formulas.first)
        #expect(formula.links.map(\.link) == [0])
        let text = formula.glyphs.compactMap { layouts[0].glyphs[$0].text }.joined()
        #expect(text == "[12]")
    }

    @Test func theLinkFollowsItsCitationAndStillLeadsToItsTarget() throws {
        let data = LinkPDF.make()
        let (cg, layouts) = LinkPDF.layouts(data)
        let segments = layouts.flatMap { SegmentBuilder.segments(for: $0) }
        let translation = "这是一段被翻译成中文的文字,而引用出现在这句话的最后面 {v1}。"
        let renderer = TranslationRenderer(source: cg, language: "zh")
        let translations = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.page == 1 ? translation : "参考文献条目。") })
        let output = renderer.render(layouts: layouts, segments: segments, translations: translations, mono: true, dual: true, dualLayout: .sideBySide, title: nil)

        let monoData = try #require(output.mono)
        let mono = try #require(PDFDocument(data: monoData))
        let link = try #require(mono.page(at: 0)?.annotations.first { $0.type == "Link" })
        // Where the citation went now, not where it was (x 167…187).
        #expect(link.bounds.minX > 200, "\(link.bounds)")
        #expect(abs(link.bounds.width - 20) < 3, "\(link.bounds)")
        let destination = try #require(link.destination ?? (link.action as? PDFActionGoTo)?.destination)
        #expect(destination.page.map { mono.index(for: $0) } == 1)
        // The citation itself is drawn inside it.
        #expect(mono.page(at: 0)?.selection(for: link.bounds)?.string?.contains("12") == true)

        // Beside the original: the original's link stays, the translation's follows its citation.
        let dualData = try #require(output.dual)
        let dual = try #require(PDFDocument(data: dualData))
        let links = try #require(dual.page(at: 0)?.annotations.filter { $0.type == "Link" })
        #expect(links.count == 2)
        #expect(links.contains { abs($0.bounds.minX - 171.5) < 1 })
        #expect(links.contains { abs($0.bounds.minX - link.bounds.minX - 612) < 1 })
    }

    @Test func aCitationBrokenOverALineIsOnePlaceholder() throws {
        let content = "BT /F1 10 Tf 1 0 0 1 72 100 Tm (Many words of the sentence that come before the name of Wang et) Tj ET "
            + "BT /F1 10 Tf 1 0 0 1 72 88 Tm (al. which ends the sentence and goes on for some more words in this line.) Tj ET"
        // Two annotations with one target.
        let before = "Many words of the sentence that come before the name of ".count
        let data = LinkPDF.make(content: content, rect: "[\(72 + before * 5 - 1) 96 \(72 + (before + 7) * 5 + 1) 110]").replacingOccurrences(
            of: "/Annots [8 0 R]", with: "/Annots [8 0 R << /Type /Annot /Subtype /Link /Rect [72 84 87 98] /Border [0 0 0] /A << /S /GoTo /D (cite.a) >> >>]")
        let (cg, layouts) = LinkPDF.layouts(data)
        let segment = try #require(SegmentBuilder.segments(for: layouts[0]).first)
        #expect(segment.formulas.count == 1, "\(segment.source)")
        #expect(segment.formulas[0].continuation.count == 1)
        #expect(Set(segment.formulas[0].allLinks.map(\.link)) == [0, 1])
        let renderer = TranslationRenderer(source: cg, language: "zh")
        let output = renderer.render(layouts: layouts, segments: [segment], translations: [segment.id: "译文开始 {v1} 译文结束。"], mono: true, dual: false, dualLayout: .sideBySide, title: nil)
        let monoData = try #require(output.mono)
        let mono = try #require(PDFDocument(data: monoData))
        #expect(mono.page(at: 0)?.annotations.filter { $0.type == "Link" }.count == 2)
    }

    @Test func aLongCitationMayBreakBetweenItsWords() throws {
        let citation = "Rabeneck, El-Serag, Davila, and Sandler, 2003"
        let content = "BT /F1 10 Tf 1 0 0 1 72 100 Tm (Words before it \(citation) and more words after it to fill this line.) Tj ET"
        let start = 72 + "Words before it ".count * 5, end = start + citation.count * 5
        let (cg, layouts) = LinkPDF.layouts(LinkPDF.make(content: content, rect: "[\(start - 1) 96 \(end + 1) 110]"))
        let segment = try #require(SegmentBuilder.segments(for: layouts[0]).first)
        #expect(segment.formulas.count == 1, "\(segment.source)")
        #expect(segment.formulas[0].continuation.count == 5)
        // A narrow frame: the citation runs over the lines, every word keeps the link.
        let typesetter = Typesetter(language: "zh")
        let block = layouts[0].blocks[segment.block]
        let frame = CGRect(x: 72, y: 20, width: 90, height: block.rect.maxY - 20)
        let result = typesetter.layout("引用 {v1} 之后。", block: block, formulas: segment.formulas, frame: frame)
        #expect(result.lines.count >= 3)
        #expect(result.transplants.count == 6)
        #expect(result.transplants.allSatisfy { !$0.formula.links.isEmpty })
        _ = cg
    }

    @Test func aLinkToAPageLeftOutIsDropped() throws {
        let data = LinkPDF.make()
        let (cg, layouts) = LinkPDF.layouts(data)
        let first = Array(layouts.prefix(1))
        let segments = SegmentBuilder.segments(for: first[0])
        let renderer = TranslationRenderer(source: cg, language: "zh")
        let translations = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, "译文 {v1}。") })
        let output = renderer.render(layouts: first, segments: segments, translations: translations, mono: true, dual: false, dualLayout: .sideBySide, title: nil)
        let monoData = try #require(output.mono)
        let mono = try #require(PDFDocument(data: monoData))
        #expect(mono.page(at: 0)?.annotations.filter { $0.type == "Link" }.isEmpty == true)
    }

    @Test func aLinkOverRunningWordsCoversTheSameStretchOfTheTranslation() throws {
        // The whole line is the link.
        let content = "BT /F1 10 Tf 1 0 0 1 72 100 Tm (see the supplementary material for more details on this) Tj ET"
        let data = LinkPDF.make(content: content, rect: "[70 96 350 110]")
        let (cg, layouts) = LinkPDF.layouts(data)
        let segment = try #require(SegmentBuilder.segments(for: layouts[0]).first)
        #expect(segment.formulas.isEmpty)
        let renderer = TranslationRenderer(source: cg, language: "zh")
        let output = renderer.render(layouts: layouts, segments: [segment], translations: [segment.id: "更多细节请参见补充材料。"], mono: true, dual: false, dualLayout: .sideBySide, title: nil)
        let monoData = try #require(output.mono)
        let mono = try #require(PDFDocument(data: monoData))
        let link = try #require(mono.page(at: 0)?.annotations.first { $0.type == "Link" })
        #expect(mono.page(at: 0)?.selection(for: link.bounds)?.string?.contains("补充材料") == true)
    }
}

private extension Data {
    func replacingOccurrences(of target: String, with replacement: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: target, with: replacement).utf8)
    }
}

@Suite struct AnalysisTests {
    private func analyze(_ page: [TestPDF.Element]) -> PageLayout {
        let data = TestPDF.make([page])
        var analyzer = LayoutAnalyzer()
        return analyzer.analyze(document: PDFDocument(data: data)!, cgDocument: CGPDFDocument(CGDataProvider(data: data as CFData)!)!, pages: [1])[0]
    }

    @Test func aCaptionStartsWithItsLabelNotWithAReferenceToIt() {
        #expect(LayoutAnalyzer.isCaptionStart("Fig. 2. Illustration of the overall process"))
        #expect(LayoutAnalyzer.isCaptionStart("Figure 3: The difference"))
        #expect(LayoutAnalyzer.isCaptionStart("TABLE 8"))
        #expect(LayoutAnalyzer.isCaptionStart("TABLE IV ABLATION STUDY"))
        #expect(LayoutAnalyzer.isCaptionStart("Table 1 An overview"))
        #expect(!LayoutAnalyzer.isCaptionStart("Fig. 3 and recount the architectures as follows."))
        #expect(!LayoutAnalyzer.isCaptionStart("Fig. 2 bottom)."))
    }

    @Test func aYearStartingALineIsNoSectionNumber() {
        let lines = ["from a university in a city of the country where she studied until the year of",
                     "2022. He is currently pursuing the degree at another university in the",
                     "same country, where his research interests include many of these subjects."]
        let layout = analyze(TestPDF.paragraph(lines, x: 72, top: 600, size: 10, pitch: 12))
        #expect(layout.blocks.filter(\.translate).count == 1, "\(layout.blocks.map(\.text))")
    }

    @Test func aRuleBetweenLinesKeepsThemApart() {
        var page: [TestPDF.Element] = []
        let line = "These words fill the whole of the line that they are set in today"
        page.append(.text(line, x: 72, y: 700, size: 10))
        page.append(.rule(x: 72, y: 693, width: 300))
        page.append(.text(line, x: 72, y: 686, size: 10))
        page.append(.text(line, x: 72, y: 674, size: 10))
        let layout = analyze(page)
        #expect(layout.blocks.filter(\.translate).map(\.lines.count).sorted() == [1, 2], "\(layout.blocks.map(\.text))")
    }

    @Test func aHyphenAtALinesEndJoinsOrStays() {
        func joined(_ first: String, _ second: String) -> String {
            let layout = analyze(TestPDF.paragraph([first, second, "and this goes on with some further words to fill out the block here."], x: 72, top: 600, size: 10, pitch: 12))
            return layout.blocks.first { $0.translate }.map { SegmentBuilder.text(of: $0).0 } ?? ""
        }
        #expect(joined("This is the part where the seg-", "mentation of the image is done by the model.").contains("segmentation"))
        #expect(joined("This model is one of the most state-of-the-", "art models that is used by people.").contains("state-of-the-art"))
        #expect(joined("This model is a kind of feature Contrast-", "Driven model that is used by people.").contains("Contrast-Driven"))
        #expect(joined("Our code is at https://github.com/Mengqi-", "Lei/ConDSeg and it is free for everyone.").contains("https://github.com/Mengqi-Lei/ConDSeg"))
    }

    @Test func symbolFontsAreMath() {
        #expect(MathDetector.isMathFont("LASY10"))
        #expect(MathDetector.isMathFont("CMSY10"))
        #expect(!MathDetector.isMathFont("NimbusRomNo9L-Regu"))
    }

    @Test func aCellRunningOverTwoLinesIsOneCell() {
        var page: [TestPDF.Element] = [.rule(x: 72, y: 700, width: 400), .rule(x: 72, y: 600, width: 400)]
        page.append(.text("Method", x: 80, y: 685, size: 9))
        page.append(.text("Score", x: 300, y: 685, size: 9))
        page.append(.text("A long description of the", x: 80, y: 665, size: 9))
        page.append(.text("0.91", x: 300, y: 665, size: 9))
        page.append(.text("method that runs over lines", x: 80, y: 654, size: 9))
        page.append(.text("Another method", x: 80, y: 635, size: 9))
        page.append(.text("0.87", x: 300, y: 635, size: 9))
        let layout = analyze(page)
        let cell = layout.blocks.first { $0.text.hasPrefix("A long") }
        #expect(cell?.kind == .tableCell)
        #expect(cell?.lines.count == 2)
        #expect(!layout.blocks.contains { $0.text.hasPrefix("method that") })
        #expect(cell?.cellAlignment == .left)
    }

    @Test func numberedPseudocodeIsLeftAlone() {
        var lines = ["for each epoch do", "sample a batch of images", "x ← model(batch)", "if converged then", "return x"]
        lines = lines.enumerated().map { "\($0.offset + 1): \($0.element)" }
        let layout = analyze(TestPDF.paragraph(lines, x: 72, top: 600, size: 10, pitch: 12))
        #expect(layout.blocks.filter(\.translate).isEmpty, "\(layout.blocks.map(\.text))")
    }

    @Test func aBoldHeadingRunIntoItsParagraphComesApart() throws {
        let body = "This paragraph goes on in plain type for a long time and has many words in it."
        let page: [TestPDF.Element] = [
            .text("Datasets.", x: 72, y: 700, size: 10, bold: true),
            .text("We use two of them here, which are the ones most people know quite well.", x: 118, y: 700, size: 10),
            .text(body, x: 72, y: 688, size: 10),
        ]
        let layout = analyze(page)
        let segments = SegmentBuilder.segments(for: layout)
        let lead = try #require(segments.first { $0.isLead })
        #expect(lead.source == "Datasets.")
        #expect(segments.contains { !$0.isLead && $0.source.hasPrefix("We use two") })
    }

    @Test func theReferenceListEndsAtRunningProseNotAtAFloat() {
        let entry = "[12] A. Author, B. Author, and C. Author, “A title of a paper,” in Proc. Conf., 2019, pp. 1–9."
        var page: [TestPDF.Element] = [.text("References", x: 72, y: 720, size: 12, bold: true)]
        page += TestPDF.paragraph([entry], x: 72, top: 700, size: 9, pitch: 11)
        page += TestPDF.paragraph(["Table 3: Results of the experiments on all of the data sets."], x: 72, top: 670, size: 9, pitch: 11)
        page += TestPDF.paragraph([entry], x: 72, top: 650, size: 9, pitch: 11)
        let prose = (0..<6).map { _ in "this appendix goes on in plain sentences about the method and what it does here" }
        page += TestPDF.paragraph(prose, x: 72, top: 600, size: 9, pitch: 11)
        let layout = analyze(page)
        let entries = layout.blocks.filter { $0.text.hasPrefix("[12]") }
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.kind == .reference && !$0.translate })
        #expect(layout.blocks.first { $0.text.hasPrefix("Table 3") }?.translate == true)
        #expect(layout.blocks.first { $0.text.hasPrefix("this appendix") }?.translate == true)
    }

    @Test func aDocumentAlreadyInTheTargetLanguageNeedsNoTranslation() {
        #expect(SegmentBuilder.isInScript(of: "zh", "这是一段中文文字，其中有 CNN 这样的词。"))
        #expect(!SegmentBuilder.isInScript(of: "zh", "This is English with one 中 character."))
        #expect(!SegmentBuilder.isInScript(of: "fr", "这是一段中文文字"))
    }

    @Test func linesWhoseInkWouldTouchGoFurtherApart() {
        let offsets = Typesetter.offsets(pitch: 12, clearances: [10, 15, 11])
        #expect(offsets == [0, 12, 27, 39])
        // Within a given height the spacing gives way to the clearance the tall line needs.
        let pitch = Typesetter.pitch(fitting: 37, clearances: [10, 15, 11], from: 11, to: 20)
        #expect(abs(pitch - 11) < 0.01)
        #expect(Typesetter.pitch(fitting: 100, clearances: [10, 15, 11], from: 11, to: 20) == 20)
    }
}
