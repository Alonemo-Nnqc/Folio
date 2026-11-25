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
    /// How far the line is turned on the image (radians, clockwise): its words' boxes are then given as they would be
    /// with the image turned back by that about its origin (a tilting scan, the title up the side of a chart).
    public var angle: Double

    public init(words: [OCRWord], angle: Double = 0) {
        self.words = words
        self.angle = angle
    }

    /// The boxes of the words together, on the image.
    public var box: CGRect {
        let rect = words.reduce(CGRect.null) { $0.union($1.rect) }
        return angle == 0 ? rect : rect.applying(CGAffineTransform(rotationAngle: angle))
    }

    public var text: String { OCRTextLayer.join(words.map(\.text)) }
}

/// What was recognised on one page: the lines, in the coordinates of an image of the page as it is shown
/// (crop box, page rotation applied) that is `imageSize` large.
public struct OCRPageResult: Sendable, Equatable {
    /// 1-based.
    public var page: Int
    public var imageSize: CGSize
    public var lines: [OCRLine]
    /// How far the image was turned (clockwise, degrees) past the page's own rotation to read it: a page scanned sideways.
    public var turn: Int
    /// The page had recognised text already: this takes its place.
    public var replaces = false

    public init(page: Int, imageSize: CGSize, lines: [OCRLine], turn: Int = 0) {
        self.page = page
        self.imageSize = imageSize
        self.lines = lines
        self.turn = turn
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
        let toUser = displayToUser(crop: crop, rotation: rotation + result.turn, imageSize: result.imageSize)
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
            let matrix = CGAffineTransform(a: height, b: 0, c: 0, d: -height, tx: start, ty: baseline)
                .concatenating(line.angle == 0 ? .identity : CGAffineTransform(rotationAngle: line.angle)).concatenating(toUser)
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

    /// A TrueType font of 65535 empty glyphs, 500 units wide, the glyph of each UTF-16 unit being the one of its number (a few
    /// hundred bytes compressed). One glyph for all characters, as Tesseract's font has, is smaller, but macOS before 27 writes
    /// the fonts of a document anew, by glyph, whenever PDFKit saves it (Preview, an annotation): every character was then the same.
    static let trueType: Data = {
        let glyphs = 65535
        func word(_ value: Int) -> Data { Data([UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        func long(_ value: Int) -> Data { word(value >> 16) + word(value) }
        let base = [UInt8](twoGlyphTrueType)
        func read(_ at: Int, _ count: Int) -> Int { base[at..<at + count].reduce(0) { $0 << 8 | Int($1) } }
        var tables: [(String, Data)] = (0..<read(4, 2)).map { k in
            let record = 12 + k * 16, offset = read(record + 8, 4)
            return (String(decoding: base[record..<record + 4], as: UTF8.self), Data(base[offset..<offset + read(record + 12, 4)]))
        }
        for k in tables.indices {
            switch tables[k].0 {
            case "maxp": tables[k].1.replaceSubrange(4..<6, with: word(glyphs))
            case "hhea": tables[k].1.replaceSubrange(34..<36, with: word(1))
            case "hmtx": tables[k].1 = word(500) + Data(count: 2 * glyphs)
            case "loca": tables[k].1 = Data(count: 2 * (glyphs + 1))
            case "head": tables[k].1.replaceSubrange(8..<12, with: Data(count: 4))
            case "cmap":
                // Format 4: the characters from the space on, each its own number.
                let header = [0, 2, 0, 3, 0, 20, 3, 1, 0, 20]
                let segments = [4, 32, 0, 4, 4, 1, 0, 0xFFFE, 0xFFFF, 0, 0x20, 0xFFFF, 0, 1, 0, 0]
                tables[k].1 = (header + segments).reduce(into: Data()) { $0.append(word($1)) }
            default: break
            }
        }
        func sum(_ data: Data) -> Int {
            var total: UInt32 = 0
            let bytes = [UInt8](data)
            for at in stride(from: 0, to: bytes.count, by: 4) {
                var value: UInt32 = 0
                for k in 0..<4 { value = value << 8 | (at + k < bytes.count ? UInt32(bytes[at + k]) : 0) }
                total &+= value
            }
            return Int(total)
        }
        var directory = Data(base[0..<12]), body = Data(), headAt = 0
        for (name, data) in tables {
            let at = 12 + tables.count * 16 + body.count
            if name == "head" { headAt = at }
            directory.append(Data(name.utf8))
            for value in [sum(data), at, data.count] { directory.append(long(value)) }
            body += data + Data(count: (4 - data.count % 4) % 4)
        }
        var font = directory + body
        font.replaceSubrange(headAt + 8..<headAt + 12, with: long((0xB1B0AFBA - sum(font)) & 0xFFFFFFFF))
        return font
    }()

    /// What it is made from: two empty glyphs (made with fontTools, 604 bytes).
    static let twoGlyphTrueType = Data(base64Encoded: """
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
        let file = writer.addStream(dict: ["Length1": .int(trueType.count)], data: trueType)
        let descriptor = writer.add(.dict([
            "Type": .name("FontDescriptor"), "FontName": .name(baseFont), "Flags": .int(5),
            "FontBBox": .array([.int(0), .int(-200), .int(500), .int(800)]), "ItalicAngle": .int(0),
            "Ascent": .int(800), "Descent": .int(-200), "CapHeight": .int(800), "StemV": .int(80), "FontFile2": .ref(file),
        ]))
        let cidFont = writer.add(.dict([
            "Type": .name("Font"), "Subtype": .name("CIDFontType2"), "BaseFont": .name(baseFont),
            "CIDSystemInfo": .dict(["Registry": .string(Data("Adobe".utf8)), "Ordering": .string(Data("Identity".utf8)), "Supplement": .int(0)]),
            "FontDescriptor": .ref(descriptor), "DW": .int(Int(glyphWidth)), "CIDToGIDMap": .name("Identity"),
        ]))
        let toUnicode = writer.addStream(dict: [:], data: toUnicodeCMap)
        return writer.add(.dict([
            "Type": .name("Font"), "Subtype": .name("Type0"), "BaseFont": .name(baseFont), "Encoding": .name("Identity-H"),
            "DescendantFonts": .array([.ref(cidFont)]), "ToUnicode": .ref(toUnicode),
        ]))
    }

    // MARK: Document

    /// The page's content without the hidden text of an earlier recognition nobody can read (its font does not say
    /// which characters it draws): left in, it would be selected and copied along with the new text. Nil: none.
    static func withoutUnreadableLayer(_ page: CGPDFPage, content: Data, all: Bool = false) -> Data? {
        let interpreter = ContentInterpreter()
        interpreter.run(page: page)
        guard let stream = interpreter.streams[[]], stream.source == content else { return nil }
        // Operators of the page's own content that only draw hidden, unreadable glyphs (with their spaces).
        var drop: [Range<Int>] = []
        for run in interpreter.runs where run.location.stream.isEmpty && run.renderMode == 3 && !run.glyphs.isEmpty {
            let glyphs = interpreter.glyphs[run.glyphs]
            guard all || glyphs.contains(where: { ScannedPDF.readableCharacters($0) == nil }),
                  stream.ops.indices.contains(run.location.index), ["Tj", "TJ"].contains(stream.ops[run.location.index].name) else { continue }
            drop.append(stream.ops[run.location.index].range)
        }
        guard !drop.isEmpty else { return nil }
        var result = content
        for range in drop.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            result.replaceSubrange(result.startIndex + range.lowerBound..<result.startIndex + range.upperBound, with: Data(" ".utf8))
        }
        return result
    }

    /// A copy of `source` with the text layers added to their pages (by page number). Everything else of the
    /// document is carried over: page boxes and rotation, resources (images as they are: JPEG and JPEG 2000 data is
    /// copied byte for byte, other images losslessly), annotations, outline, named destinations, forms and info.
    static func write(source: CGPDFDocument, layers: [Int: OCRPageResult]) -> Data {
        write(source: source, layers: layers, oneGlyphFonts: [])
    }

    /// The file with the fonts of its hidden text that PDFKit would ruin by saving it (before macOS 27) replaced by one of as
    /// many glyphs: recognised by an earlier Folio, by Tesseract or OCRmyPDF. Nil: there are none (or it cannot be written).
    public static func safeToSave(_ data: Data) -> Data? {
        guard let source = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init), !source.isEncrypted, source.numberOfPages > 0 else { return nil }
        let fonts = oneGlyphFonts(source)
        guard !fonts.isEmpty else { return nil }
        let result = write(source: source, layers: [:], oneGlyphFonts: fonts)
        guard let written = CGDataProvider(data: result as CFData).flatMap(CGPDFDocument.init), written.numberOfPages == source.numberOfPages else { return nil }
        return result
    }

    /// The descendants of composite fonts that draw every character with the same empty glyph, on pages and in the forms on them.
    private static func oneGlyphFonts(_ document: CGPDFDocument) -> [CGPDFDictionaryRef] {
        var found: [CGPDFDictionaryRef] = [], seen: Set<Int> = []
        func look(_ resources: CGPDFDictionaryRef, _ depth: Int) {
            guard seen.insert(PDFCopier.key(resources)).inserted else { return }
            for (_, object) in PDFDictionary.dict(resources, "Font").map(PDFDictionary.entries) ?? [] {
                var font: CGPDFDictionaryRef?, descendant: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &font), let font, seen.insert(PDFCopier.key(font)).inserted,
                      PDFDictionary.name(font, "BaseFont")?.hasSuffix(baseFont) == true, PDFDictionary.name(font, "Encoding") == "Identity-H",
                      let descendants = PDFDictionary.array(font, "DescendantFonts"), CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant,
                      PDFDictionary.stream(descendant, "CIDToGIDMap") != nil, seen.insert(PDFCopier.key(descendant)).inserted else { continue }
                found.append(descendant)
            }
            guard depth < 4 else { return }
            for (_, object) in PDFDictionary.dict(resources, "XObject").map(PDFDictionary.entries) ?? [] {
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream),
                      PDFDictionary.name(dict, "Subtype") == "Form", let inner = PDFDictionary.dict(dict, "Resources") else { continue }
                look(inner, depth + 1)
            }
        }
        for number in stride(from: 1, through: document.numberOfPages, by: 1) {
            if let page = document.page(at: number)?.dictionary, let resources = PDFDictionary.resources(of: page) { look(resources, 0) }
        }
        return found
    }

    private static func write(source: CGPDFDocument, layers: [Int: OCRPageResult], oneGlyphFonts: [CGPDFDictionaryRef]) -> Data {
        let writer = PDFWriter()
        let copier = PDFCopier(writer: writer)
        if !oneGlyphFonts.isEmpty {
            let file = writer.addStream(dict: ["Length1": .int(trueType.count)], data: trueType)
            for font in oneGlyphFonts {
                var descriptor = PDFDictionary.dict(font, "FontDescriptor").map { copier.entries(of: $0, skipping: ["FontFile", "FontFile2", "FontFile3"]) } ?? [:]
                descriptor["FontFile2"] = .ref(file)
                var entries = copier.entries(of: font, skipping: ["CIDToGIDMap", "FontDescriptor"])
                entries["CIDToGIDMap"] = .name("Identity")
                entries["FontDescriptor"] = .ref(writer.add(.dict(descriptor)))
                copier.pageMap[PDFCopier.key(font)] = writer.add(.dict(entries))
            }
        }
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
            if let layer = layers[number], let cleaned = withoutUnreadableLayer(page, content: content, all: layer.replaces) { content = cleaned }
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
