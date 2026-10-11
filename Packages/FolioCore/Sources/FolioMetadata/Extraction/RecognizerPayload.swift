import AppKit
import CoreText
import Foundation
import PDFKit

/// The request body of Zotero's PDF recognizer service, built with PDFKit.
///
/// Mirrors `getRecognizerData` in zotero/pdf-worker (`src/pdf/index.js`):
/// ```
/// { metadata: {<info dictionary strings>}, totalPages, fileName,
///   pages: [[width, height, [[[[0, 0, 0, 0, lines]]]]], …] }        // first 5 pages
/// line = [[word, …]]
/// word = [xMin, yMin, xMax, yMax, fontSize, spaceAfter, baseline, rotation, underlined,
///         bold, italic, colorIndex, fontIndex, text]
/// ```
/// Coordinates are relative to the crop box with the origin at the top-left (y grows
/// downwards) and rounded to 4 decimals; `fontIndex` points into a per-page list of fonts.
struct RecognizerPayload: Sendable, Equatable {
    static let maxPages = 5

    struct Word: Sendable, Equatable {
        var xMin: Double
        var yMin: Double
        var xMax: Double
        var yMax: Double
        var fontSize: Double
        var spaceAfter: Bool
        var baseline: Double
        var bold: Bool
        var italic: Bool
        var fontIndex: Int
        var text: String
    }

    struct Page: Sendable, Equatable {
        var width: Double
        var height: Double
        var lines: [[Word]]
        /// Font names referenced by `Word.fontIndex`.
        var fonts: [String]
    }

    var metadata: [String: String]
    var totalPages: Int
    var fileName: String
    var pages: [Page]

    var wordCount: Int {
        pages.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.count } }
    }

    // MARK: - Extraction

    /// Reads the first pages of the PDF at `url`; nil when it is unreadable or has no text layer.
    static func extract(from url: URL) -> RecognizerPayload? {
        autoreleasepool {
            guard let document = PDFDocument(url: url) else { return nil }
            if document.isLocked, !document.unlock(withPassword: "") { return nil }
            var payload = RecognizerPayload(metadata: infoStrings(of: document), totalPages: document.pageCount,
                                            fileName: url.lastPathComponent, pages: [])
            for index in 0..<min(maxPages, document.pageCount) {
                guard let page = document.page(at: index) else { continue }
                payload.pages.append(autoreleasepool { Self.page(page) })
            }
            return payload.wordCount > 0 ? payload : nil
        }
    }

    /// Words and lines of one page, from PDFKit's attributed text and per-character bounds.
    static func page(_ page: PDFPage) -> Page {
        let box = page.bounds(for: .cropBox)
        var result = Page(width: round4(box.width), height: round4(box.height), lines: [], fonts: [])
        guard let attributed = page.attributedString, attributed.length > 0 else { return result }
        let string = attributed.string as NSString

        var line: [Word] = []
        var wordText = ""
        var wordRect = CGRect.null
        var wordFont: NSFont?

        func flushWord(spaceAfter: Bool) {
            defer { wordText = ""; wordRect = .null; wordFont = nil }
            guard !wordText.isEmpty, !wordRect.isNull, let font = wordFont else { return }
            line.append(makeWord(text: wordText, rect: wordRect, font: font, spaceAfter: spaceAfter,
                                 box: box, fonts: &result.fonts))
        }
        func flushLine() {
            flushWord(spaceAfter: false)
            if !line.isEmpty { result.lines.append(line) }
            line = []
        }

        var location = 0
        while location < string.length {
            let range = string.rangeOfComposedCharacterSequence(at: location)
            location = range.location + range.length
            guard let character = Self.character(in: string, range: range) else { continue }
            if character.unicodeScalars.contains(where: CharacterSet.newlines.contains) {
                flushLine()
                continue
            }
            if character.unicodeScalars.allSatisfy({ CharacterSet.whitespaces.contains($0) || $0.properties.generalCategory == .control }) {
                flushWord(spaceAfter: true)
                continue
            }
            let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            // A change of font or size inside a run (superscript affiliation marks, emphasis)
            // starts a new word, as in pdf.js' structured text.
            if let current = wordFont, let font,
               current.fontName != font.fontName || abs(current.pointSize - font.pointSize) > 0.01 {
                flushWord(spaceAfter: false)
            }
            let bounds = page.characterBounds(at: range.location)
            if !bounds.isNull, !bounds.isInfinite, bounds.width > 0 || bounds.height > 0 {
                wordRect = wordRect.union(bounds)
            }
            if wordFont == nil { wordFont = font ?? NSFont.systemFont(ofSize: max(bounds.height, 1)) }
            wordText += character
        }
        flushLine()
        return result
    }

    /// The character at `range` as valid Unicode; nil for glyphs PDFKit could not map to text
    /// (lone UTF-16 surrogates, U+FFFD), which would also make the JSON body unencodable.
    static func character(in string: NSString, range: NSRange) -> String? {
        var units = [unichar](repeating: 0, count: range.length)
        string.getCharacters(&units, range: range)
        let repaired = String(decoding: units, as: UTF16.self)
        return repaired.unicodeScalars.contains("\u{FFFD}") ? nil : repaired
    }

    private static func makeWord(text: String, rect: CGRect, font: NSFont, spaceAfter: Bool, box: CGRect,
                                 fonts: inout [String]) -> Word {
        let name = PDFFacts.baseFontName(font.fontName)
        let fontIndex: Int
        if let existing = fonts.firstIndex(of: name) {
            fontIndex = existing
        } else {
            fontIndex = fonts.count
            fonts.append(name)
        }
        // PDFKit character boxes span the font's ascent and descent, so the baseline sits
        // `descender` above the bottom edge.
        let baselineY = min(rect.maxY, max(rect.minY, rect.minY - font.descender))
        let traits = CTFontGetSymbolicTraits(font as CTFont)
        let lowered = name.lowercased()
        let bold = traits.contains(.traitBold) || ["bold", "black", "heavy"].contains { lowered.contains($0) }
        let italic = traits.contains(.traitItalic) || ["italic", "oblique"].contains { lowered.contains($0) }
        let height = box.height
        return Word(xMin: round4(rect.minX - box.minX), yMin: round4(height - (rect.maxY - box.minY)),
                    xMax: round4(rect.maxX - box.minX), yMax: round4(height - (rect.minY - box.minY)),
                    fontSize: round4(font.pointSize), spaceAfter: spaceAfter,
                    baseline: round4(height - (baselineY - box.minY)),
                    bold: bold, italic: italic, fontIndex: fontIndex, text: text)
    }

    /// String entries of the document information dictionary (Title, Author, Creator, dates …).
    static func infoStrings(of document: PDFDocument) -> [String: String] {
        guard let info = document.documentRef?.info else { return [:] }
        var strings: [String: String] = [:]
        CGPDFDictionaryApplyBlock(info, { key, object, _ in
            var value: CGPDFStringRef?
            if CGPDFObjectGetValue(object, .string, &value), let value,
               let text = CGPDFStringCopyTextString(value) as String? {
                strings[String(cString: key)] = text
            }
            return true
        }, nil)
        return strings
    }

    static func round4(_ value: CGFloat) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }

    // MARK: - Encoding

    /// The JSON body to POST.
    func jsonData() -> Data? {
        let encodedPages: [Any] = pages.map { page in
            let lines: [Any] = page.lines.map { words in
                [words.map { word -> [Any] in
                    [word.xMin, word.yMin, word.xMax, word.yMax, word.fontSize, word.spaceAfter ? 1 : 0,
                     word.baseline, 0, 0, word.bold ? 1 : 0, word.italic ? 1 : 0, 0, word.fontIndex, word.text]
                }]
            }
            return [page.width, page.height, [[[[0, 0, 0, 0, lines]]]]] as [Any]
        }
        let object: [String: Any] = [
            "metadata": metadata,
            "totalPages": totalPages,
            "fileName": fileName,
            "pages": encodedPages,
        ]
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
