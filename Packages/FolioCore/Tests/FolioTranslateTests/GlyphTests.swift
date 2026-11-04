import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

@Suite struct GlyphTests {
    /// A one-page PDF whose content stream is `content`, with a Type 1 font using `encoding` (a PDF object).
    static func pdf(content: String, encoding: String = "/WinAnsiEncoding", toUnicode: String? = nil) -> Data {
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 300] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>")
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        let unicode = toUnicode.map { _ in " /ToUnicode 6 0 R" } ?? ""
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding \(encoding)\(unicode) /FirstChar 32 /LastChar 126 /Widths [\(Array(repeating: "500", count: 95).joined(separator: " "))] >>")
        if let toUnicode { objects.append("<< /Length \(toUnicode.utf8.count) >>\nstream\n\(toUnicode)\nendstream") }
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

    static func interpret(_ data: Data) -> ContentInterpreter {
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let interpreter = ContentInterpreter()
        interpreter.run(page: document.page(at: 1)!)
        return interpreter
    }

    @Test func glyphsHaveExactPositionsFromWidthsAndKerning() {
        // 10 pt, widths 500: each glyph advances 5 pt; -1000 in TJ moves 10 pt right.
        let interpreter = Self.interpret(Self.pdf(content: "BT /F1 10 Tf 1 0 0 1 50 100 Tm [(ab) -1000 (c)] TJ ET"))
        let glyphs = interpreter.glyphs
        #expect(glyphs.map(\.text) == ["a", "b", "c"])
        let xs = glyphs.map { Double($0.origin.x) }
        #expect(xs == [50, 55, 70])
        #expect(glyphs.allSatisfy { abs($0.origin.y - 100) < 1e-9 && abs($0.size - 10) < 1e-9 })
        #expect(glyphs.map(\.element) == [0, 0, 2])
    }

    @Test func differencesNamesAndToUnicodeGiveTheText() {
        let differences = "<< /Type /Encoding /BaseEncoding /WinAnsiEncoding /Differences [65 /alpha /summationdisplay /f_f_i /uni2207] >>"
        var interpreter = Self.interpret(Self.pdf(content: "BT /F1 10 Tf 50 100 Td (ABCD) Tj ET", encoding: differences))
        #expect(interpreter.glyphs.map(\.text) == ["α", "∑", "ffi", "∇"])
        let reliable = interpreter.glyphs.allSatisfy { $0.reliable }
        #expect(reliable)
        let cmap = "begincmap 2 beginbfchar <41> <2192> <42> <00660069> endbfchar 1 beginbfrange <43> <45> <03B1> endbfrange endcmap"
        interpreter = Self.interpret(Self.pdf(content: "BT /F1 10 Tf 50 100 Td (ABCDE) Tj ET", toUnicode: cmap))
        #expect(interpreter.glyphs.map(\.text) == ["→", "fi", "α", "β", "γ"])
    }

    @Test func glyphNamesCoverTeXAndUnicodeForms() {
        #expect(GlyphNames.unicode("parenleftbig") == "(")
        #expect(GlyphNames.unicode("integraldisplay") == "∫")
        #expect(GlyphNames.unicode("uni03A9") == "Ω")
        #expect(GlyphNames.unicode("u1D49C") == "𝒜")
        #expect(GlyphNames.unicode("eacute") == "é")
        #expect(GlyphNames.unicode("a.sc") == "a")
        #expect(GlyphNames.unicode("g123") == nil)
    }

    @Test func type1ProgramsBuiltInEncodingIsRead() {
        let program = Data("%!PS-AdobeFont-1.0: CMMI10\n/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\ndup 11 /alpha put\ndup 80 /P put\nreadonly def\ncurrentfile eexec".utf8)
        let names = FontEncoding.type1Encoding(program)
        #expect(names?[11] == "alpha")
        #expect(names?[80] == "P")
    }

    @Test func takingGlyphsOutKeepsTheOthersExactlyInPlace() throws {
        let data = Self.pdf(content: "BT /F1 10 Tf 1 0 0 1 50 100 Tm [(Drop) -250 (Keep)] TJ ET")
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let interpreter = ContentInterpreter()
        interpreter.run(page: document.page(at: 1)!)
        let before = interpreter.glyphs
        let removing = Set(before.indices.filter { before[$0].element == 0 })
        let edits = TranslationRenderer.glyphEdits(interpreter: interpreter, removing: removing)
        #expect(edits.count == 1)
        let composer = PDFComposer(source: document)
        let form = composer.pageForm(1, interpreter: interpreter, edits: edits)!
        composer.addPage(mediaBox: CGRect(x: 0, y: 0, width: 400, height: 300), content: Data("q /P Do Q".utf8), xobjects: ["P": form])
        let after = Self.interpret(composer.finish()).glyphs.filter { $0.text != nil }
        #expect(after.map(\.text) == ["K", "e", "e", "p"])
        let kept = before.filter { $0.element == 2 }
        #expect(zip(after, kept).allSatisfy { abs($0.origin.x - $1.origin.x) < 1e-6 && abs($0.origin.y - $1.origin.y) < 1e-6 })
    }

    @Test func formulasAreDrawnAgainFromTheirGlyphs() {
        let data = Self.pdf(content: "BT /F1 10 Tf 1 0 0 1 50 100 Tm (x+y) Tj ET")
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let interpreter = ContentInterpreter()
        interpreter.run(page: document.page(at: 1)!)
        let composer = PDFComposer(source: document)
        var fonts: [String: PDFValue] = [:]
        // Moved 100 pt right and 50 pt up.
        let content = "q 1 0 0 1 100 50 cm\n" + TranslationRenderer.drawing(glyphs: Array(interpreter.glyphs.indices), rules: [], interpreter: interpreter) { font in
            fonts["G\(font)"] = composer.copier.copy(dictionary: interpreter.fonts[font].dict)
            return "G\(font)"
        } + "Q\n"
        composer.addPage(mediaBox: CGRect(x: 0, y: 0, width: 400, height: 300), content: Data(content.utf8), xobjects: [:], fonts: fonts)
        let drawn = Self.interpret(composer.finish()).glyphs
        #expect(drawn.map(\.text) == ["x", "+", "y"])
        #expect(zip(drawn, interpreter.glyphs).allSatisfy { abs($0.origin.x - $1.origin.x - 100) < 1e-6 && abs($0.origin.y - $1.origin.y - 50) < 1e-6 })
    }
}

@Suite struct TableColumnTests {
    @Test func narrowHeaderGapsOverColumnGuttersSplitCells() {
        var page: [TestPDF.Element] = [.rule(x: 72, y: 600, width: 260), .rule(x: 72, y: 584, width: 260), .rule(x: 72, y: 520, width: 260)]
        // Header words only 5 pt apart, over the columns of numbers below.
        page += [.text("Method", x: 76, y: 588, size: 9), .text("Citys", x: 200, y: 588, size: 9), .text("Map", x: 225, y: 588, size: 9),
                 .text("Mean", x: 246, y: 588, size: 9)]
        for (k, name) in ["Baseline", "Ours", "Other"].enumerated() {
            let y = 570 - Double(k) * 16
            page += [.text(name, x: 76, y: y, size: 9), .text("37.7", x: 200, y: y, size: 9), .text("34.1", x: 226, y: y, size: 9),
                     .text("36.8", x: 250, y: y, size: 9)]
        }
        let data = TestPDF.make([page])
        var analyzer = LayoutAnalyzer()
        let layout = analyzer.analyze(document: PDFDocument(data: data)!, cgDocument: CGPDFDocument(CGDataProvider(data: data as CFData)!)!, pages: [1])[0]
        let cells = layout.blocks.filter { $0.kind == .tableCell }.map(\.text)
        #expect(cells.contains("Citys") && cells.contains("Map") && cells.contains("Mean"), "\(cells)")
    }
}

@Suite struct ReadingOrderTests {
    @Test func twoColumnsAreReadColumnByColumn() {
        var page: [TestPDF.Element] = [.text("A Title Across Both Columns of the Page", x: 150, y: 740, size: 16, bold: true)]
        let left = (0..<6).map { "Left column line number \($0) with some words" }
        let right = (0..<6).map { "Right column line number \($0) and more words" }
        page += TestPDF.paragraph(left, x: 54, top: 700, size: 9, pitch: 11)
        page += TestPDF.paragraph(right, x: 318, top: 700, size: 9, pitch: 11)
        let data = TestPDF.make([page])
        var analyzer = LayoutAnalyzer()
        let layout = analyzer.analyze(document: PDFDocument(data: data)!, cgDocument: CGPDFDocument(CGDataProvider(data: data as CFData)!)!, pages: [1])[0]
        let paragraphs = layout.blocks.filter { $0.kind == .paragraph }
        let texts = paragraphs.map(\.text)
        #expect(paragraphs.count == 2, "\(texts)")
        #expect(paragraphs.first?.text.hasPrefix("Left column line number 0") == true)
        #expect(paragraphs.first?.lines.count == 6)
    }

    @Test func bracketsStayWithTheFormulaOnlyInPairs() {
        func chars(_ text: String, math: Set<Int>) -> [PageChar] {
            text.enumerated().map { i, ch in
                var c = PageChar(text: String(ch), rect: CGRect(x: Double(i) * 5, y: 0, width: 5, height: 12), isSpace: ch == " ", isNewline: false,
                                 size: 10, baseline: 2, font: .unknown, color: .black, run: 0, isRotated: false)
                c.isMath = math.contains(i)
                return c
            }
        }
        // "(a and b)": the formula "b)" gives its ")" back to the text.
        var line = chars("(a and b)", math: [1, 7, 8])
        LayoutAnalyzer.balanceBrackets(&line)
        #expect(line.map(\.isMath) == [false, true, false, false, false, false, false, true, false])
        // "F(x)" keeps both brackets.
        line = chars("F(x)", math: [0, 1, 2, 3])
        LayoutAnalyzer.balanceBrackets(&line)
        let allMath = line.allSatisfy { $0.isMath }
        #expect(allMath)
    }
}
