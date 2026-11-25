import CoreGraphics
import Foundation
import PDFKit

/// Tells scanned PDFs (pages that are pictures of text, with no text layer) from PDFs with text.
public enum ScannedPDF {
    /// Fewer characters than this on a page: no text layer to speak of (a page number, a stamp).
    static let minimumCharacters = 20
    /// The page is mostly a picture. A page without any text needs less of one (a scan set small on the page).
    static let minimumImageCoverage = 0.3
    static let minimumCoverageWithoutText = 0.12
    /// Drawn shapes on a page of text turned into outlines: each letter one or two filled curves.
    static let minimumOutlines = 120
    /// Pages looked at to decide about a whole document.
    static let samplePages = 8

    struct PageFacts: Equatable {
        /// Characters somebody can read (drawn or in a hidden layer), spaces aside, in the body of the page: not the
        /// line a download service prints along the edge of every page, not a watermark across it.
        var characters: Int
        /// All of them, the edges and watermarks too.
        var allCharacters: Int
        /// Glyphs no one can copy: their font does not say which characters they are.
        var unreadable: Int
        /// How much of the crop box images cover, 0…1.
        var imageCoverage: Double
        /// Small filled curves: letters drawn as shapes.
        var outlines: Int
        /// Text in a hidden layer (an earlier recognition) that cannot be read.
        var hiddenUnreadable: Int = 0

        var needsOCR: Bool {
            if characters >= ScannedPDF.minimumCharacters { return false }
            // Glyphs drawn on the page that only look like text (their font has no map back to characters).
            if unreadable >= ScannedPDF.minimumCharacters { return true }
            if outlines >= ScannedPDF.minimumOutlines { return true }
            let least = allCharacters < ScannedPDF.minimumCharacters ? ScannedPDF.minimumCoverageWithoutText : ScannedPDF.minimumImageCoverage
            return imageCoverage >= least
        }

        /// Nothing on the page that says what kind of document it is.
        var isBlank: Bool { allCharacters < ScannedPDF.minimumCharacters && !needsOCR }
    }

    static func facts(of page: CGPDFPage) -> PageFacts {
        let interpreter = ContentInterpreter()
        interpreter.run(page: page)
        return facts(interpreter, crop: effectiveCrop(page))
    }

    /// The part of the page that shows.
    static func effectiveCrop(_ page: CGPDFPage) -> CGRect {
        let media = page.getBoxRect(.mediaBox)
        let crop = page.getBoxRect(.cropBox).intersection(media)
        return crop.isNull || crop.width < 1 || crop.height < 1 ? media : crop
    }

    static func facts(_ interpreter: ContentInterpreter, crop: CGRect) -> PageFacts {
        // The edges as the page is stored: wide enough for a printed footer, narrow enough to leave the text.
        let body = crop.insetBy(dx: crop.width * 0.045, dy: crop.height * 0.06)
        var inBody = 0, all = 0, unreadable = 0, hiddenUnreadable = 0
        for glyph in interpreter.glyphs where !glyph.isClipped {
            guard let count = readableCharacters(glyph) else {
                unreadable += 1
                if glyph.renderMode == 3 { hiddenUnreadable += 1 }
                continue
            }
            guard count > 0 else { continue }
            all += count
            // A watermark runs across the page at a slant: neither along a line nor up the side.
            let quarter = abs(glyph.angle.truncatingRemainder(dividingBy: .pi / 2))
            let slanted = min(quarter, .pi / 2 - quarter) > 0.1
            if !slanted, body.contains(CGPoint(x: glyph.box.midX, y: glyph.box.midY)) { inBody += count }
        }
        let area = max(crop.width * crop.height, 1)
        let covered = interpreter.marks.filter { $0.kind == .image }.reduce(0.0) { sum, mark in
            let visible = mark.rect.intersection(crop)
            return visible.isNull ? sum : sum + visible.width * visible.height
        }
        let limit = max(crop.width, crop.height) * 0.06
        let outlines = interpreter.marks.filter { mark in
            mark.kind == .fill && !mark.isWhite && mark.hasCurves && mark.rect.width < limit && mark.rect.height < limit
        }.count
        return PageFacts(characters: inBody, allCharacters: all, unreadable: unreadable, imageCoverage: min(1, covered / area),
                         outlines: outlines, hiddenUnreadable: hiddenUnreadable)
    }

    /// How many characters copying the glyph gives (0 for a space); nil when what it gives is nothing or nonsense: no
    /// text at all, control and private-use characters, replacement characters.
    static func readableCharacters(_ glyph: Glyph) -> Int? {
        guard let text = glyph.text else { return nil }
        var count = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            switch scalar.value {
            case 0..<0x20, 0x7F..<0xA0, 0xE000...0xF8FF, 0xFFF0...0xFFFF, 0xF0000...0x10FFFF: return nil
            default: count += 1
            }
        }
        return count
    }

    /// Whether the document is a scan to recognise: of the pages looked at (some across the whole document, blank ones
    /// aside), at least half have text only as a picture. A cover page with text in front of a scan does not hide it.
    public static func isScanned(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL) else { return false }
        return isScanned(document, url: url)
    }

    static func isScanned(_ document: CGPDFDocument, url: URL? = nil) -> Bool {
        guard canRead(document) else { return false }
        let reader = PageReader(url)
        var looked = 0, scanned = 0
        for number in sample(of: document.numberOfPages) {
            guard let page = document.page(at: number) else { continue }
            let facts = autoreleasepool { facts(of: page) }
            if facts.isBlank { continue }
            looked += 1
            if facts.needsOCR, !reader.reads(number, facts) { scanned += 1 }
        }
        return scanned > 0 && scanned * 2 >= looked
    }

    /// Pages spread over the document: the first three, then evenly to the last.
    static func sample(of count: Int) -> [Int] {
        guard count > samplePages else { return count > 0 ? Array(1...count) : [] }
        var pages = [1, 2, 3]
        let rest = samplePages - pages.count
        for k in 1...rest { pages.append(3 + Int((Double(count - 3) * Double(k) / Double(rest)).rounded())) }
        return pages
    }

    /// Open to us: not encrypted, or encrypted with no password to open it and copying allowed.
    static func canRead(_ document: CGPDFDocument) -> Bool {
        !document.isEncrypted || (document.isUnlocked && document.allowsCopying)
    }

    /// The facts of each page, for the developer tool.
    public static func describe(_ url: URL) -> String {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return "unreadable" }
        return (1...document.numberOfPages).compactMap { number in
            document.page(at: number).map { page in autoreleasepool { "page \(number): \(facts(of: page))" } }
        }.joined(separator: "\n")
    }

    /// Whether any page of the document has no text of its own.
    public static func hasPagesWithoutText(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL), canRead(document) else { return false }
        return !pagesNeedingOCR(document, url: url).isEmpty
    }

    /// The pages (1-based) that need text recognised.
    static func pagesNeedingOCR(_ document: CGPDFDocument, url: URL? = nil) -> [Int] {
        guard document.numberOfPages > 0 else { return [] }
        let reader = PageReader(url)
        return (1...document.numberOfPages).filter { number in
            guard let page = document.page(at: number) else { return false }
            return autoreleasepool {
                let facts = facts(of: page)
                return facts.needsOCR && !reader.reads(number, facts)
            }
        }
    }

    /// Asks PDFKit about pages whose fonts Folio cannot read: what can be selected and copied in the reader is text, and
    /// needs no recognising.
    private final class PageReader {
        private let url: URL?
        private lazy var document: PDFDocument? = url.flatMap { PDFDocument(url: $0) }

        init(_ url: URL?) { self.url = url }

        func reads(_ number: Int, _ facts: PageFacts) -> Bool {
            guard facts.unreadable >= ScannedPDF.minimumCharacters else { return false }
            var text = ""
            PDFKitAccess.serialize { text = document?.page(at: number - 1)?.string ?? "" }
            let letters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
            // As many as there are glyphs, more or less: a page number among unreadable text is not the page's text.
            return letters * 3 >= facts.unreadable
        }
    }
}
