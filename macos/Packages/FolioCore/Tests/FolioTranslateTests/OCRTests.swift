import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import FolioTranslate

/// Scanned samples: text drawn into a grey bitmap (a "scan"), placed as the only content of a PDF page.
enum ScanSample {
    struct Line { var text: String; var font: String; var size: Double; var x: Double; var y: Double }

    static let english = [
        Line(text: "Scanned documents become searchable", font: "Times New Roman", size: 30, x: 70, y: 700),
        Line(text: "after optical character recognition.", font: "Times New Roman", size: 30, x: 70, y: 655),
        Line(text: "The quick brown fox jumps over the lazy dog 2024.", font: "Helvetica", size: 18, x: 70, y: 600),
    ]

    static let chinese = [
        Line(text: "扫描件识别文字后即可选中、搜索与翻译。", font: "PingFang SC", size: 26, x: 60, y: 700),
        Line(text: "深度学习方法在图像识别中的应用研究", font: "PingFang SC", size: 26, x: 60, y: 650),
        Line(text: "混合文本 Deep Learning 模型 2023 年", font: "PingFang SC", size: 22, x: 60, y: 600),
    ]

    /// The page as a 200 dpi grey image of `lines`, written as an image-only PDF. With `rotation` 90 the page is
    /// stored landscape, its picture turned the other way, and shown upright by `/Rotate 90`.
    static func pdf(_ pages: [[Line]], size: CGSize = CGSize(width: 612, height: 792), rotation: Int = 0, jpeg: Bool = true) -> Data {
        let data = NSMutableData()
        var box = rotation == 90 ? CGRect(x: 0, y: 0, width: size.height, height: size.width) : CGRect(origin: .zero, size: size)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for lines in pages {
            let image = bitmap(lines, size: size, jpeg: jpeg)
            context.beginPDFPage(nil)
            if rotation == 90 { context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)) }
            context.draw(image, in: CGRect(origin: .zero, size: size))
            context.endPDFPage()
        }
        context.closePDF()
        guard rotation != 0 else { return data as Data }
        let document = PDFDocument(data: data as Data)!
        for index in 0..<document.pageCount { document.page(at: index)!.rotation = rotation }
        return document.dataRepresentation()!
    }

    static func bitmap(_ lines: [Line], size: CGSize, jpeg: Bool) -> CGImage {
        let scale = 200.0 / 72
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0.97, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(gray: 0.08, alpha: 1)
        for line in lines {
            let font = CTFontCreateWithName(line.font as CFString, line.size, nil)
            let text = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]))
            context.textPosition = CGPoint(x: line.x, y: line.y)
            CTLineDraw(text, context)
        }
        let image = context.makeImage()!
        guard jpeg else { return image }
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(destination)
        let source = CGImageSourceCreateWithData(encoded, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }
}

@Suite struct OCRTextLayerTests {
    /// A result as an OCR engine would give it, in the coordinates of a 2x image of a letter page.
    static func result(page: Int = 1, rotation: Int = 0) -> OCRPageResult {
        let size = rotation % 180 == 0 ? CGSize(width: 1224, height: 1584) : CGSize(width: 1584, height: 1224)
        return OCRPageResult(page: page, imageSize: size, lines: [
            OCRLine(words: [OCRWord(text: "Hello", rect: CGRect(x: 144, y: 200, width: 150, height: 40)),
                            OCRWord(text: "world", rect: CGRect(x: 314, y: 204, width: 140, height: 36))]),
            OCRLine(words: "扫描件识别".map(String.init).enumerated().map { i, c in
                OCRWord(text: c, rect: CGRect(x: 144 + Double(i) * 44, y: 300, width: 42, height: 44))
            }),
        ])
    }

    static func blankPDF(rotation: Int = 0) -> CGPDFDocument {
        let data = TestPDF.make([[.rule(x: 10, y: 10, width: 5)]])
        let document = PDFDocument(data: data)!
        document.page(at: 0)!.rotation = rotation
        return CGPDFDocument(CGDataProvider(data: document.dataRepresentation()! as CFData)!)!
    }

    @Test func displayCoordinatesMapToUserSpaceForEveryRotation() {
        let crop = CGRect(x: 10, y: 20, width: 600, height: 800)
        // The top-left corner of the shown page, and a point along its top edge.
        let cases: [(Int, CGPoint, CGPoint)] = [
            (0, CGPoint(x: 10, y: 820), CGPoint(x: 110, y: 820)),
            (90, CGPoint(x: 10, y: 20), CGPoint(x: 10, y: 120)),
            (180, CGPoint(x: 610, y: 20), CGPoint(x: 510, y: 20)),
            (270, CGPoint(x: 610, y: 820), CGPoint(x: 610, y: 720)),
        ]
        for (rotation, origin, along) in cases {
            let shown = rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
            let t = OCRTextLayer.displayToUser(crop: crop, rotation: rotation, imageSize: CGSize(width: shown.width * 2, height: shown.height * 2))
            let a = CGPoint.zero.applying(t), b = CGPoint(x: 200, y: 0).applying(t)
            #expect(abs(a.x - origin.x) < 0.01 && abs(a.y - origin.y) < 0.01, "rotation \(rotation): \(a)")
            #expect(abs(b.x - along.x) < 0.01 && abs(b.y - along.y) < 0.01, "rotation \(rotation): \(b)")
        }
    }

    @Test func contentIsInvisibleTextStretchedToEachWord() {
        let content = String(decoding: OCRTextLayer.content(for: Self.result(), crop: CGRect(x: 0, y: 0, width: 612, height: 792), rotation: 0), as: UTF8.self)
        #expect(content.hasPrefix("BT\n3 Tr\n/FolioOCR 1 Tf\n"))
        #expect(content.hasSuffix("ET\n"))
        #expect(content.contains("<00480065006C006C006F> Tj"))   // Hello
        #expect(content.contains("<0020> Tj"))                    // the space before "world"
        #expect(content.contains("<626B> Tj"))                    // 扫, without a space after it
        #expect(content.components(separatedBy: "<0020>").count == 2)
        // "Hello": 5 glyphs of half an em on a 40 px line (= 20 pt at 2x) are 50 pt; the word is 75 pt wide.
        #expect(content.contains("20 0 0 20 72 "))
        #expect(content.contains(" 150 Tz <00480065006C006C006F>"))
    }

    @Test func layerTextIsExtractedSearchableAndCopiedForEveryRotation() throws {
        for rotation in [0, 90, 180, 270] {
            let source = Self.blankPDF(rotation: rotation)
            let data = OCRTextLayer.write(source: source, layers: [1: Self.result(rotation: rotation)])
            let document = try #require(PDFDocument(data: data))
            let page = try #require(document.page(at: 0))
            #expect(page.rotation == rotation)
            let text = page.string ?? ""
            // PDFKit reads text that runs upwards (pages turned 90°) word by word on lines of their own, however it is
            // written; the words and their order are what matter.
            let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(words.contains("Hello world"), "rotation \(rotation): \(text)")
            if rotation != 90 { #expect(text.contains("Hello world"), "rotation \(rotation): \(text)") }
            #expect(text.contains("扫描件识别"), "rotation \(rotation): \(text)")
            let hits = document.findString("描件", withOptions: [])
            #expect(hits.count == 1)
            // The hit is where the characters are on the shown page: the second and third of five 22 pt boxes.
            if rotation == 0, let hit = hits.first {
                let bounds = hit.bounds(for: page)
                #expect(abs(bounds.minX - 94) < 3 && abs(bounds.width - 43) < 4, "\(bounds)")
                #expect(abs(bounds.minY - (792 - 172)) < 1 && abs(bounds.height - 22) < 1, "\(bounds)")
            }
        }
    }

    /// The glyphs have a box (selections get their height from it) but no ink, even drawn visibly.
    @Test func glyphsDrawNothingInAnyRenderingMode() throws {
        let source = Self.blankPDF()
        let data = OCRTextLayer.write(source: source, layers: [1: Self.result()])
        let document = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let plain = Self.blankPDF()
        #expect(PDFTextRecognizer.difference(plain.page(at: 1)!, document.page(at: 1)!) == 0)
        // Filled instead of invisible (software that drops the rendering mode).
        let page = try #require(PDFDocument(data: data)?.page(at: 0))
        let content = OCRTextLayer.content(for: Self.result(), crop: page.bounds(for: .cropBox), rotation: 0)
        let filled = String(decoding: content, as: UTF8.self).replacingOccurrences(of: "3 Tr", with: "0 Tr")
        let drawn = TestPDFContent.replacingContent(of: data, with: Data(filled.utf8))
        let redrawn = CGPDFDocument(CGDataProvider(data: drawn as CFData)!)!
        let empty = CGPDFDocument(CGDataProvider(data: TestPDF.make([[]]) as CFData)!)!
        let difference = PDFTextRecognizer.difference(empty.page(at: 1)!, redrawn.page(at: 1)!)
        let inkless = PDFTextRecognizer.difference(empty.page(at: 1)!, CGPDFDocument(CGDataProvider(data: TestPDFContent.replacingContent(of: data, with: Data()) as CFData)!)!.page(at: 1)!)
        #expect(difference == 0, "\(difference) \(inkless)")
    }

    @Test func layerKeepsPagesThatHaveNoResultAndTheDrawing() throws {
        let data = TestPDF.make([[.text("Born digital page", x: 72, y: 700, size: 12)], [.rule(x: 10, y: 10, width: 300)]])
        let source = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let written = OCRTextLayer.write(source: source, layers: [2: Self.result(page: 2)])
        let document = try #require(PDFDocument(data: written))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("Born digital page") == true)
        #expect(document.page(at: 1)?.string?.contains("Hello world") == true)
        let output = CGPDFDocument(CGDataProvider(data: written as CFData)!)!
        #expect(PDFTextRecognizer.looksTheSame(source, output))
    }

    @Test func toUnicodeRangesStayWithinTheirFirstByte() {
        let cmap = String(decoding: OCRTextLayer.toUnicodeCMap, as: UTF8.self)
        #expect(cmap.contains("<4E00> <4EFF> <4E00>"))
        #expect(cmap.components(separatedBy: "beginbfrange").count == 4)   // 100 + 100 + 56
    }

    @Test func unitsSplitWordsAndCJKCharacters() {
        let string = "混合文本 Deep Learning (深度) 2023年"
        let units = PDFTextRecognizer.units(of: string).map { String(string[$0]) }
        #expect(units == ["混", "合", "文", "本", "Deep", "Learning", "(", "深", "度", ")", "2023", "年"])
        #expect(OCRTextLayer.join(units) == "混合文本Deep Learning (深度) 2023年")
    }
}

@Suite(.serialized) struct ScanRecognitionTests {
    @Test func detectsScansButNotTextPDFs() throws {
        let scan = ScanSample.pdf([ScanSample.english])
        #expect(ScannedPDF.isScanned(CGPDFDocument(CGDataProvider(data: scan as CFData)!)!))
        let text = TestPDF.make([TestPDF.paragraph(["A born-digital paper has a text layer on every page."], top: 700)])
        #expect(!ScannedPDF.isScanned(CGPDFDocument(CGDataProvider(data: text as CFData)!)!))
        let empty = TestPDF.make([[.rule(x: 10, y: 10, width: 5)]])
        #expect(!ScannedPDF.isScanned(CGPDFDocument(CGDataProvider(data: empty as CFData)!)!))
    }

    static func recognize(_ data: Data) async throws -> (PDFDocument, Data, URL) {
        let folder = TemporaryDirectory("FolioOCR")
        let input = folder.url.appending(path: "scan.pdf"), output = folder.url.appending(path: "out.pdf")
        try data.write(to: input)
        let summary = try await PDFTextRecognizer.recognize(input: input, output: output)
        #expect(summary.pages >= 1)
        let written = try Data(contentsOf: output)
        // Keep the folder until the document is read.
        let document = try #require(PDFDocument(data: written))
        _ = folder
        return (document, written, input)
    }

    /// Words of `expected` found in `text` (case and punctuation aside).
    static func accuracy(_ text: String, _ expected: [String]) -> Double {
        let normalized = text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        let words = expected.flatMap { line in
            line.split(separator: " ").flatMap { word -> [String] in
                word.unicodeScalars.contains(where: OCRTextLayer.isCJK) ? word.map(String.init) : [String(word)]
            }
        }.map { $0.lowercased().filter { !$0.isPunctuation } }.filter { !$0.isEmpty }
        return Double(words.filter { normalized.contains($0) }.count) / Double(max(words.count, 1))
    }

    @Test func englishScanBecomesSearchableAndCopyable() async throws {
        let scan = ScanSample.pdf([ScanSample.english])
        let (document, written, _) = try await Self.recognize(scan)
        let text = document.page(at: 0)?.string ?? ""
        let score = Self.accuracy(text, ScanSample.english.map(\.text))
        print("OCR en accuracy \(score): \(text)")
        #expect(score >= 0.9)
        #expect(!document.findString("searchable", withOptions: .caseInsensitive).isEmpty)
        let hit = try #require(document.findString("brown fox", withOptions: .caseInsensitive).first)
        #expect(hit.string?.lowercased() == "brown fox")
        // Where "brown fox" is on the page: on the third line, a quarter of the way in.
        let bounds = hit.bounds(for: document.page(at: 0)!)
        #expect(bounds.minY > 590 && bounds.maxY < 630 && bounds.minX > 130 && bounds.minX < 220, "\(bounds)")
        // The page looks the same, and the scan was carried over byte for byte (JPEG).
        let source = CGPDFDocument(CGDataProvider(data: scan as CFData)!)!
        let output = CGPDFDocument(CGDataProvider(data: written as CFData)!)!
        #expect(PDFTextRecognizer.difference(source.page(at: 1)!, output.page(at: 1)!) < 0.5)
        #expect(written.range(of: Data([0xFF, 0xD8, 0xFF])) != nil)
        #expect(!ScannedPDF.isScanned(output))
    }

    @Test func chineseScanBecomesSearchableAndCopyable() async throws {
        let scan = ScanSample.pdf([ScanSample.chinese])
        let (document, _, _) = try await Self.recognize(scan)
        let text = document.page(at: 0)?.string ?? ""
        let score = Self.accuracy(text, ScanSample.chinese.map(\.text))
        print("OCR zh accuracy \(score): \(text)")
        #expect(score >= 0.9)
        #expect(text.contains("深度学习方法"))
        let hit = try #require(document.findString("图像识别", withOptions: []).first)
        #expect(hit.string == "图像识别")
    }

    @Test func rotatedScanIsRecognisedAsShown() async throws {
        let scan = ScanSample.pdf([ScanSample.english], rotation: 90)
        let (document, _, _) = try await Self.recognize(scan)
        let page = try #require(document.page(at: 0))
        #expect(page.rotation == 90)
        let text = page.string ?? ""
        #expect(Self.accuracy(text, ScanSample.english.map(\.text)) >= 0.9, "\(text)")
        // The words are where they show: "brown fox" on the third line from the top, a quarter of the way in.
        let hit = try #require(document.findString("brown fox", withOptions: .caseInsensitive).first)
        let bounds = hit.bounds(for: page)
        // Stored turned: the line 600 pt up the shown page is 792 - 600 pt across the stored one, reading upwards.
        #expect(bounds.minX > 160 && bounds.maxX < 210 && bounds.minY > 130 && bounds.minY < 220, "\(bounds)")
    }

    @Test func textPDFHasNothingToRecognize() async throws {
        let folder = TemporaryDirectory("FolioOCR")
        let input = folder.url.appending(path: "text.pdf")
        try TestPDF.make([TestPDF.paragraph(["A born-digital paper has a text layer on every page."], top: 700)]).write(to: input)
        await #expect(throws: OCRError.nothingToRecognize) {
            try await PDFTextRecognizer.recognize(input: input, output: folder.url.appending(path: "out.pdf"))
        }
    }
}

/// Rewrites the content of the first page (for drawing a text layer visibly).
enum TestPDFContent {
    static func replacingContent(of data: Data, with content: Data) -> Data {
        let source = CGPDFDocument(CGDataProvider(data: data as CFData)!)!
        let writer = PDFWriter()
        let copier = PDFCopier(writer: writer)
        let pages = writer.reserve()
        let pageObject = writer.reserve()
        let dict = source.page(at: 1)!.dictionary!
        copier.pageMap[PDFCopier.key(dict)] = pageObject
        var entries = copier.entries(of: dict, skipping: ["Parent", "Contents"])
        entries["Parent"] = .ref(pages)
        entries["Contents"] = .ref(writer.addStream(dict: [:], data: content))
        writer.set(pageObject, .dict(entries))
        writer.set(pages, .dict(["Type": .name("Pages"), "Kids": .array([.ref(pageObject)]), "Count": .int(1)]))
        let root = writer.add(.dict(["Type": .name("Catalog"), "Pages": .ref(pages)]))
        return writer.finish(root: root, info: nil)
    }
}
