import CoreGraphics
import Foundation

/// A word recognised on a page image, in the image's coordinates (origin top-left, y down).
public struct OCRWord: Sendable, Equatable {
    public var text: String
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

/// A line of words, left to right.
public struct OCRLine: Sendable, Equatable {
    public var words: [OCRWord]

    public init(words: [OCRWord]) { self.words = words }

    public var text: String { OCRTextLayer.join(words.map(\.text)) }
}

/// What was recognised on one page: the lines, in the coordinates of an image of the page as it is shown
/// (crop box, page rotation applied) that is `imageSize` large.
public struct OCRPageResult: Sendable, Equatable {
    /// 1-based.
    public var page: Int
    public var imageSize: CGSize
    public var lines: [OCRLine]

    public init(page: Int, imageSize: CGSize, lines: [OCRLine]) {
        self.page = page
        self.imageSize = imageSize
        self.lines = lines
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

/// The invisible text layer OCR adds to a scanned page, as OCRmyPDF and Tesseract write it: text rendering mode 3
/// (neither filled nor stroked) in a "glyphless" font — every glyph empty, half an em wide — so nothing changes
/// on the page. Each word is stretched (`Tz`) to the width of its box and set on its line's height, so selecting,
/// searching and copying find the words where they are on the image. The font is Type0 with Identity-H: the codes
/// are the text's UTF-16 units and the ToUnicode map gives them back as they are, so any script (CJK included)
/// copies correctly. The Windows version writes the same objects (Folio.Core/Ocr/OcrTextLayer.cs).
public enum OCRTextLayer {
    /// Font resource name on the page.
    static let fontResource = "FolioOCR"
    /// The name Tesseract and OCRmyPDF give the same font: tools that look for an existing OCR layer know it.
    static let baseFont = "GlyphLessFont"
    /// Glyph advance, in thousandths of an em.
    static let glyphWidth = 500.0
    /// The glyph box from the baseline: a fifth of an em below, four fifths above (like the line box of most fonts).
    static let ascent = 0.8, descent = 0.2

    // MARK: Content

    /// Maps the coordinates of a page image as shown (top-left origin, crop box with `/Rotate` applied) to the
    /// page's user space.
    static func displayToUser(crop: CGRect, rotation: Int, imageSize: CGSize) -> CGAffineTransform {
        let rotation = ((rotation % 360) + 360) % 360
        let shownWidth = rotation % 180 == 0 ? crop.width : crop.height
        let scale = shownWidth / max(imageSize.width, 1)
        let toUser: CGAffineTransform = switch rotation {
        case 90: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: crop.minX, ty: crop.minY)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: crop.maxX, ty: crop.minY)
        case 270: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: crop.maxX, ty: crop.maxY)
        default: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: crop.minX, ty: crop.maxY)
        }
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(toUser)
    }

    /// The page's text layer: one `BT … ET` drawing every word (and the spaces between words) invisibly.
    static func content(for result: OCRPageResult, crop: CGRect, rotation: Int, font: String = fontResource) -> Data {
        let toUser = displayToUser(crop: crop, rotation: rotation, imageSize: result.imageSize)
        var out = "BT\n3 Tr\n/\(font) 1 Tf\n"
        for line in result.lines {
            let words = line.words.filter { !$0.text.isEmpty && $0.rect.width > 0 }
            guard !words.isEmpty else { continue }
            // One height for the whole line: words without ascenders or descenders are shorter boxes.
            let top = words.map(\.rect.minY).min()!, bottom = words.map(\.rect.maxY).max()!
            let height = bottom - top
            guard height > 0 else { continue }
            let baseline = bottom - height * descent
            // One text matrix per line, the words placed along it with Td: text extraction (PDFKit, pdf.js) then reads
            // the line as one, on rotated pages too (a matrix per word made each word a line of its own there).
            let start = words[0].rect.minX
            let matrix = CGAffineTransform(a: height, b: 0, c: 0, d: -height, tx: start, ty: baseline).concatenating(toUser)
            out += [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].map(PDFValue.format).joined(separator: " ") + " Tm"
            var at = start
            func show(_ text: String, x: Double, width: Double) {
                if abs(x - at) > 1e-6 { out += " \(PDFValue.format((x - at) / height)) 0 Td" }
                at = x
                out += " " + Self.show(text, width: width, height: height) + "\n"
            }
            for (index, word) in words.enumerated() {
                show(word.text, x: word.rect.minX, width: word.rect.width)
                // The space between this word and the next, stretched over the gap: text extraction keeps the words apart.
                // It follows the word where its glyphs end (Td moves from the line's start, which stays the word's).
                if index + 1 < words.count, needsSpace(after: word.text, before: words[index + 1].text) {
                    let gap = max(words[index + 1].rect.minX - word.rect.maxX, height * 0.05)
                    out += " " + Self.show(" ", width: gap, height: height) + "\n"
                }
            }
        }
        out += "ET\n"
        return Data(out.utf8)
    }

    /// `text` stretched (Tz) to `width` on a line `height` high: "150 Tz <0048…> Tj".
    private static func show(_ text: String, width: Double, height: Double) -> String {
        let units = Array(text.utf16)
        let natural = Double(units.count) * glyphWidth / 1000 * height
        let stretch = max(0.1, min(100_000, width / max(natural, 1e-6) * 100))
        var hex = ""
        hex.reserveCapacity(units.count * 4)
        for unit in units { hex += String(format: "%04X", unit) }
        return "\(PDFValue.format(stretch)) Tz <\(hex)> Tj"
    }

    /// Words of scripts written without spaces (Chinese, Japanese) follow each other directly.
    static func needsSpace(after left: String, before right: String) -> Bool {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else { return false }
        return !(isCJK(last) || isCJK(first))
    }

    /// Words of a line joined as they are read: with spaces, except between CJK characters.
    static func join(_ words: [String]) -> String {
        var text = ""
        for word in words where !word.isEmpty {
            if !text.isEmpty, needsSpace(after: text, before: word) { text += " " }
            text += word
        }
        return text
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2E80...0x2FFF, 0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x3FFFF: true
        default: false
        }
    }

    // MARK: Font

    /// The glyphless TrueType font (two empty glyphs, 500 units wide; made with fontTools, 604 bytes).
    static let glyphlessTrueType = Data(base64Encoded: """
    AAEAAAAKAIAAAwAgT1MvMkUAQ7AAAAEoAAAAYGNtYXAADABzAAABkAAAADRnbHlmAAAAAAAAAcwAAAABaGVhZC9AyCYAAACsAAAANmhoZWEDIgEuAAAA5AAAACRobXR4AfQAAAAAAYgAAAAGbG9jYQAAAAAAAAHEAAAABm1heHAAAwACAAABCAAAACBuYW1lPah3zwAAAdAAAABjcG9zdAAHAAAAAAI0AAAAJgABAAAAAQAAN22Si18PPPUAAwPoAAAAAOcawncAAAAA5xrCdwAA/zgB9AMgAAAAAwACAAAAAAAAAAEAAAMg/zgAAAH0AAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAEAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAwH0AZAABQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAPz8/PwAAACAAIAMg/zgAAAMgAMgAAAAAAAAAAAAAAAAAAAAgAAAB9AAAAAAAAAAAAAIAAAADAAAAFAADAAEAAAAUAAQAIAAAAAQABAABAAAAIP//AAAAIP///+EAAQAAAAAAAAAAAAAAAAAAAAAAAAAEADYAAQAAAAAAAQAIAAAAAQAAAAAAAgAHAAgAAwABBAkAAQAQAA8AAwABBAkAAgAOAB9Gb2xpb09DUlJlZ3VsYXIARgBvAGwAaQBvAE8AQwBSAFIAZQBnAHUAbABhAHIAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAMAAA==
    """, options: .ignoreUnknownCharacters)!

    /// ToUnicode: every two-byte code stands for that UTF-16 unit (in ranges that keep the first byte, as the
    /// specification asks of `bfrange`).
    static var toUnicodeCMap: Data {
        var ranges: [String] = (0..<256).map { String(format: "<%02X00> <%02XFF> <%02X00>", $0, $0, $0) }
        var text = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange

        """
        while !ranges.isEmpty {
            let chunk = ranges.prefix(100)
            ranges.removeFirst(chunk.count)
            text += "\(chunk.count) beginbfrange\n" + chunk.joined(separator: "\n") + "\nendbfrange\n"
        }
        text += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n"
        return Data(text.utf8)
    }

    /// Adds the font's objects; returns the Type0 font's object number.
    static func addFont(to writer: PDFWriter) -> Int {
        let file = writer.addStream(dict: ["Length1": .int(glyphlessTrueType.count)], data: glyphlessTrueType)
        let descriptor = writer.add(.dict([
            "Type": .name("FontDescriptor"), "FontName": .name(baseFont), "Flags": .int(5),
            "FontBBox": .array([.int(0), .int(-200), .int(500), .int(800)]), "ItalicAngle": .int(0),
            "Ascent": .int(800), "Descent": .int(-200), "CapHeight": .int(800), "StemV": .int(80), "FontFile2": .ref(file),
        ]))
        // Every CID is glyph 1 (the font has only empty glyphs; the widths come from DW).
        var map = Data(count: 65536 * 2)
        for index in stride(from: 1, to: map.count, by: 2) { map[index] = 1 }
        let gidMap = writer.addStream(dict: [:], data: map)
        let cidFont = writer.add(.dict([
            "Type": .name("Font"), "Subtype": .name("CIDFontType2"), "BaseFont": .name(baseFont),
            "CIDSystemInfo": .dict(["Registry": .string(Data("Adobe".utf8)), "Ordering": .string(Data("Identity".utf8)), "Supplement": .int(0)]),
            "FontDescriptor": .ref(descriptor), "DW": .int(Int(glyphWidth)), "CIDToGIDMap": .ref(gidMap),
        ]))
        let toUnicode = writer.addStream(dict: [:], data: toUnicodeCMap)
        return writer.add(.dict([
            "Type": .name("Font"), "Subtype": .name("Type0"), "BaseFont": .name(baseFont), "Encoding": .name("Identity-H"),
            "DescendantFonts": .array([.ref(cidFont)]), "ToUnicode": .ref(toUnicode),
        ]))
    }

    // MARK: Document

    /// A copy of `source` with the text layers added to their pages (by page number). Everything else of the
    /// document is carried over: page boxes and rotation, resources (images as they are: JPEG and JPEG 2000 data is
    /// copied byte for byte, other images losslessly), annotations, outline, named destinations, forms and info.
    static func write(source: CGPDFDocument, layers: [Int: OCRPageResult]) -> Data {
        let writer = PDFWriter()
        let copier = PDFCopier(writer: writer)
        let pagesNode = writer.reserve()
        let count = source.numberOfPages
        // Page objects first: annotations, destinations and the outline point at them.
        var objects: [Int] = []
        for number in stride(from: 1, through: count, by: 1) {
            let object = writer.reserve()
            objects.append(object)
            if let dict = source.page(at: number)?.dictionary { copier.pageMap[PDFCopier.key(dict)] = object }
        }
        let font = layers.isEmpty ? nil : addFont(to: writer)
        for number in stride(from: 1, through: count, by: 1) {
            guard let page = source.page(at: number), let dict = page.dictionary else { continue }
            let inherited: Set<String> = ["Parent", "Contents", "Resources", "MediaBox", "CropBox", "Rotate"]
            var entries = copier.entries(of: dict, skipping: inherited)
            let media = page.getBoxRect(.mediaBox)
            var crop = page.getBoxRect(.cropBox).intersection(media)
            if crop.isNull || crop.width < 1 { crop = media }
            entries["Parent"] = .ref(pagesNode)
            entries["MediaBox"] = .rect(media)
            if crop != media { entries["CropBox"] = .rect(crop) }
            let rotation = Int(page.rotationAngle)
            if rotation % 360 != 0 { entries["Rotate"] = .int(rotation) }
            let sourceResources = PDFDictionary.resources(of: dict)
            var content = PDFDictionary.contents(of: dict)
            if let layer = layers[number], let font, !layer.lines.isEmpty {
                var resources = sourceResources.map { copier.entries(of: $0, skipping: ["Font"]) } ?? [:]
                var fonts = sourceResources.flatMap { PDFDictionary.dict($0, "Font") }.map { copier.entries(of: $0) } ?? [:]
                var name = fontResource
                var suffix = 1
                while fonts[name] != nil { name = fontResource + String(suffix); suffix += 1 }
                fonts[name] = .ref(font)
                resources["Font"] = .dict(fonts)
                entries["Resources"] = .dict(resources)
                // The original drawing in its own graphics state, then the text on the page's own coordinates.
                content.insert(contentsOf: Array("q\n".utf8), at: 0)
                content.append(contentsOf: Array("\nQ\n".utf8))
                content.append(Self.content(for: layer, crop: crop, rotation: rotation, font: name))
            } else {
                entries["Resources"] = .dict(sourceResources.map { copier.entries(of: $0) } ?? [:])
            }
            entries["Contents"] = .ref(writer.addStream(dict: [:], data: content))
            writer.set(objects[number - 1], .dict(entries))
        }
        writer.set(pagesNode, .dict(["Type": .name("Pages"), "Kids": .array(objects.map { .ref($0) }), "Count": .int(objects.count)]))
        var catalog: [String: PDFValue] = [:]
        if let root = source.catalog { catalog = copier.entries(of: root, skipping: ["Type", "Pages"]) }
        catalog["Type"] = .name("Catalog")
        catalog["Pages"] = .ref(pagesNode)
        let rootObject = writer.add(.dict(catalog))
        var info: [String: PDFValue] = [:]
        if let sourceInfo = source.info { info = copier.entries(of: sourceInfo) }
        if info["Producer"] == nil { info["Producer"] = .string(PDFComposer.pdfText("Folio")) }
        let infoObject = writer.add(.dict(info))
        return writer.finish(root: rootObject, info: infoObject)
    }
}
