import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

/// A page as a scanner makes it, and the text layer a recognition would write over it: the words' boxes as rough as they come.
private struct ScannedPage {
    struct Text { var text: String; var font = "Times New Roman"; var size = 11.0; var x = 72.0; var y: Double }

    var texts: [Text] = []
    var rules: [CGRect] = []
    var shapes: [CGRect] = []
    var size = CGSize(width: 612, height: 792)
    /// Degrees the paper lies turned on the glass, counter-clockwise.
    var tilt = 0.0
    /// The boxes follow the tilt (an engine that knows of it) or lie level.
    var tellsTilt = true

    private func line(_ text: Text) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(text.font as CFString, text.size, nil),
        ]))
    }

    func document() -> CGPDFDocument {
        let scale = 200.0 / 72
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        bitmap.setFillColor(gray: 0.96, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.setShouldSmoothFonts(false)
        let turn = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2).concatenating(CGAffineTransform(rotationAngle: tilt * .pi / 180))
            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
        bitmap.concatenate(turn)
        bitmap.setFillColor(gray: 0.1, alpha: 1)
        for rect in rules + shapes { bitmap.fill(rect) }
        for text in texts {
            bitmap.textPosition = CGPoint(x: text.x, y: text.y)
            CTLineDraw(line(text), bitmap)
        }
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.draw(bitmap.makeImage()!, in: box)
        context.endPDFPage()
        context.closePDF()

        // The layer, on an image of one pixel per point with rows going down.
        var lines: [OCRLine] = []
        for text in texts {
            let set = line(text)
            var words: [OCRWord] = []
            var index = text.text.startIndex
            for word in text.text.split(separator: " ") {
                let range = text.text.range(of: word, range: index..<text.text.endIndex)!
                index = range.upperBound
                let x0 = text.x + CTLineGetOffsetForStringIndex(set, range.lowerBound.utf16Offset(in: text.text), nil)
                let x1 = text.x + CTLineGetOffsetForStringIndex(set, range.upperBound.utf16Offset(in: text.text), nil)
                // Higher than the type, and by a different bit on every line.
                let extra = text.size * (0.1 + 0.25 * abs(sin(text.y)))
                var rect = CGRect(x: x0, y: text.y - text.size * 0.25 - extra / 2, width: x1 - x0, height: text.size * 1.0 + extra)
                if !tellsTilt { rect = rect.applying(turn) }
                words.append(OCRWord(text: String(word), rect: CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)))
            }
            lines.append(OCRLine(words: words))
        }
        if tilt != 0, tellsTilt {
            // The same boxes on an image turned back about its corner.
            let angle = -tilt * .pi / 180
            let shown = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2).concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
            let back = shown.concatenating(CGAffineTransform(rotationAngle: -angle))
            lines = lines.map { line in
                OCRLine(words: line.words.map { word in
                    let corner = word.rect.origin.applying(back)
                    return OCRWord(text: word.text, rect: CGRect(origin: corner, size: word.rect.size))
                }, angle: angle)
            }
        }
        let source = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let written = OCRTextLayer.write(source: source, layers: [1: OCRPageResult(page: 1, imageSize: size, lines: lines)])
        return CGPDFDocument(CGDataProvider(data: written as CFData)!)!
    }

    func layout(rotation: Int = 0) -> PageLayout {
        let pdf = document()
        let data = pdf.page(at: 1).map { _ in PDFDocument(data: Self.data(of: pdf))! }!
        if rotation != 0 { data.page(at: 0)!.rotation = rotation }
        let bytes = data.dataRepresentation()!
        let cg = CGPDFDocument(CGDataProvider(data: bytes as CFData)!)!
        var analyzer = LayoutAnalyzer()
        return analyzer.analyze(document: PDFDocument(data: bytes)!, cgDocument: cg, pages: [1])[0]
    }

    static func data(of document: CGPDFDocument) -> Data { OCRTextLayer.write(source: document, layers: [:]) }

    static let paragraph = [
        "Tourism brings income to the town, and with it the need to share the",
        "burden of crowded streets and worn paths among those who visit them.",
        "We describe a model of both, and a plan that keeps them in balance",
        "over the years to come, whatever the weather and the season may be.",
    ]

    static func body(from y: Double, x: Double = 72) -> [Text] { paragraph.enumerated().map { Text(text: $1, x: x, y: y - Double($0) * 14) } }
}

@Suite struct ScanLayoutTests {
    @Test func sizesAndWeightsAreMeasuredInThePicture() throws {
        var page = ScannedPage()
        page.texts = [.init(text: "A Model of Tourism in Small Towns", font: "Times New Roman Bold", size: 20, x: 140, y: 690),
                      .init(text: "1 Introduction", font: "Times New Roman Bold", size: 14, y: 640)]
            + ScannedPage.body(from: 610) + ScannedPage.body(from: 540)
        let layout = page.layout()
        #expect(layout.isScan)
        let title = try #require(layout.blocks.first { $0.kind == .title })
        #expect(abs(title.size - 20) < 1.6 && title.font.isBold)
        let heading = try #require(layout.blocks.first { $0.kind == .heading })
        #expect(heading.text == "1 Introduction" && abs(heading.size - 14) < 1.2)
        let paragraphs = layout.blocks.filter { $0.kind == .paragraph }
        #expect(paragraphs.map(\.lines.count) == [4, 4])
        for paragraph in paragraphs { #expect(abs(paragraph.size - 11) < 0.9 && !paragraph.font.isBold) }
    }

    @Test func aPageOnItsSideIsReadUpright() {
        var page = ScannedPage()
        page.texts = ScannedPage.body(from: 600)
        // The layer is written the way the paper lies; the page is shown turned by /Rotate.
        let layout = page.layout(rotation: 90)
        #expect(layout.blocks.contains { $0.kind == .paragraph && $0.translate && $0.lines.count == 4 })
        #expect(!layout.blocks.contains { $0.kind == .rotated })
    }

    @Test(arguments: [true, false]) func aTiltedPageIsStraightened(tells: Bool) {
        var page = ScannedPage()
        page.tilt = 1.6
        page.tellsTilt = tells
        page.texts = ScannedPage.body(from: 640) + ScannedPage.body(from: 560) + ScannedPage.body(from: 480)
        let layout = page.layout()
        let angle = atan2(layout.transform.b, layout.transform.a) * 180 / .pi
        #expect(abs(angle + 1.6) < 0.25)
        let paragraphs = layout.blocks.filter { $0.kind == .paragraph && $0.translate }
        #expect(paragraphs.map(\.lines.count) == [4, 4, 4])
        for paragraph in paragraphs { #expect(abs(paragraph.size - 11) < 1) }
    }

    @Test func drawingsKeepTheirWords() {
        var page = ScannedPage()
        page.texts = ScannedPage.body(from: 700) + [.init(text: "Visitors", size: 8, x: 200, y: 540), .init(text: "Income", size: 8, x: 330, y: 500),
                                                    .init(text: "Figure 1: Visitors and income by year", size: 10, x: 210, y: 420)] + ScannedPage.body(from: 390)
        page.shapes = [CGRect(x: 180, y: 440, width: 30, height: 80), CGRect(x: 250, y: 440, width: 30, height: 110), CGRect(x: 320, y: 440, width: 30, height: 50)]
        let layout = page.layout()
        for word in ["Visitors", "Income"] { #expect(layout.blocks.contains { $0.text == word && $0.kind == .figure && !$0.translate }) }
        #expect(layout.blocks.contains { $0.kind == .caption && $0.translate })
        #expect(layout.blocks.filter { $0.kind == .paragraph && $0.translate }.map(\.lines.count) == [4, 4])
    }

    @Test func rowsOfATableStayApartAndItsRulesStay() throws {
        var page = ScannedPage()
        let names = ["Number of tourists", "Catering revenue", "Transport costs", "Waste disposal costs"]
        page.texts = ScannedPage.body(from: 700) + [.init(text: "Symbol", font: "Times New Roman Bold", x: 160, y: 584), .init(text: "Description", font: "Times New Roman Bold", x: 300, y: 584)]
            + names.enumerated().flatMap { k, name in [ScannedPage.Text(text: String("ABCD".dropFirst(k).first!), x: 170, y: 564 - Double(k) * 15), ScannedPage.Text(text: name, x: 290, y: 564 - Double(k) * 15)] }
        page.rules = [CGRect(x: 140, y: 598, width: 300, height: 1.2), CGRect(x: 140, y: 578, width: 300, height: 0.8), CGRect(x: 140, y: 510, width: 300, height: 1.2)]
        let layout = page.layout()
        for name in names { #expect(layout.blocks.contains { $0.text == name && $0.translate && $0.lines.count == 1 }) }
        let row = try #require(layout.blocks.first { $0.text == "Description" })
        for area in TranslationRenderer.scanAreas(of: row.lines[0], in: layout) {
            for rule in page.rules { #expect(!area.intersects(rule)) }
        }
    }

    @Test func formulasSetApartStay() {
        var page = ScannedPage()
        page.texts = ScannedPage.body(from: 700) + [.init(text: "S = a + b × max(c)", x: 230, y: 620), .init(text: "(3)", x: 520, y: 620)] + ScannedPage.body(from: 590)
        let layout = page.layout()
        #expect(layout.blocks.contains { $0.text.hasPrefix("S =") && $0.kind == .formula && !$0.translate })
        #expect(layout.blocks.filter { $0.kind == .paragraph && $0.translate }.count == 2)
    }

    @Test func runningHeadsAreKnownByTheirText() {
        #expect(LayoutAnalyzer.runningKey("Team # 2505199") == LayoutAnalyzer.runningKey("Team #2505198"))
        #expect(LayoutAnalyzer.runningKey("Page 3 of 25") == LayoutAnalyzer.runningKey("page 12 of 25"))
        #expect(LayoutAnalyzer.distance("page#of#", "page#of#ąl") == 2)
        #expect(LayoutAnalyzer.sentenceWords("f（x）=3x+2") == 0)
        #expect(LayoutAnalyzer.sentenceWords("where the value of income is known") >= 5)
        #expect(LayoutAnalyzer.sentenceWords("本文提出一种方法") >= 3)
    }

    @Test func onlyPagesOfTextAreTakenFromAMixedDocument() {
        func result(_ lines: [String]) -> OCRPageResult {
            OCRPageResult(page: 1, imageSize: CGSize(width: 600, height: 800), lines: lines.enumerated().map { k, text in
                OCRLine(words: text.split(separator: " ").enumerated().map { OCRWord(text: String($1), rect: CGRect(x: Double($0) * 40, y: Double(k) * 20, width: 38, height: 12)) })
            })
        }
        #expect(PDFTextRecognizer.isPageOfText(result(ScannedPage.paragraph + ScannedPage.paragraph)))
        #expect(!PDFTextRecognizer.isPageOfText(result(["Visitors", "Income by year", "2019 2020 2021 2022", "Fig. 3", "North", "South east"])))
    }

    @Test func aTurnedLineIsWrittenTurned() {
        let line = OCRLine(words: [OCRWord(text: "Population", rect: CGRect(x: -300, y: 40, width: 120, height: 14))], angle: -.pi / 2)
        #expect(abs(line.box.minX - 40) < 0.01 && abs(line.box.width - 14) < 0.01 && abs(line.box.height - 120) < 0.01)
        let result = OCRPageResult(page: 1, imageSize: CGSize(width: 612, height: 792), lines: [line])
        let content = String(decoding: OCRTextLayer.content(for: result, crop: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0), as: UTF8.self)
        let numbers = content.split(separator: "\n").first { $0.contains(" Tm") }!.split(separator: " ").prefix(4).compactMap { Double($0) }
        // Upwards on the page.
        #expect(abs(numbers[0]) < 1e-6 && numbers[1] > 13 && numbers[2] < -13 && abs(numbers[3]) < 1e-6)
    }

    @Test func chineseLinesJoinWithoutSpaces() {
        var page = ScannedPage()
        page.texts = [.init(text: "视网膜血管的形态变化与糖尿病等疾病密切相关，准确分割对辅助诊", font: "Songti SC", size: 12, y: 600),
                      .init(text: "断具有重要意义。针对现有方法的问题，本文提出一种网络模型，并", font: "Songti SC", size: 12, y: 582),
                      .init(text: "在公开数据集上进行了实验。", font: "Songti SC", size: 12, y: 564)]
        let layout = page.layout()
        let segments = SegmentBuilder.segments(for: layout)
        #expect(segments.contains { $0.source.contains("辅助诊断具有") })
    }

    @Test func askedAgainTheLayerIsReplaced() async throws {
        let folder = FileManager.default.temporaryDirectory
        let input = folder.appending(path: "\(UUID()).pdf"), once = folder.appending(path: "\(UUID()).pdf"), twice = folder.appending(path: "\(UUID()).pdf")
        defer { for url in [input, once, twice] { try? FileManager.default.removeItem(at: url) } }
        try ScanSample.pdf([ScanSample.english]).write(to: input)
        let first = try await PDFTextRecognizer.recognize(input: input, output: once)
        let second = try await PDFTextRecognizer.recognize(input: once, output: twice, force: true)
        #expect(first.characters == second.characters)
        let text = try #require(PDFDocument(url: twice)?.string)
        #expect(text.components(separatedBy: "searchable").count == 2)
    }
}
