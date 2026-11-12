import CoreGraphics
import Foundation

/// Tells scanned PDFs (pages that are pictures of text, with no text layer) from PDFs with text.
public enum ScannedPDF {
    /// Fewer characters than this on a page: no text layer to speak of (a page number, a stamp).
    static let minimumCharacters = 20
    /// The page is mostly a picture.
    static let minimumImageCoverage = 0.3
    /// Pages looked at to decide about a whole document.
    static let samplePages = 3

    struct PageFacts: Equatable {
        /// Characters drawn (visible or not), spaces aside.
        var characters: Int
        /// How much of the crop box images cover, 0…1.
        var imageCoverage: Double

        var needsOCR: Bool { characters < ScannedPDF.minimumCharacters && imageCoverage >= ScannedPDF.minimumImageCoverage }
    }

    static func facts(of page: CGPDFPage) -> PageFacts {
        let interpreter = ContentInterpreter()
        interpreter.run(page: page)
        let characters = interpreter.glyphs.reduce(0) { count, glyph in
            guard let text = glyph.text else { return count + 1 }
            return count + text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        }
        let media = page.getBoxRect(.mediaBox)
        var crop = page.getBoxRect(.cropBox).intersection(media)
        if crop.isNull || crop.width < 1 { crop = media }
        let area = max(crop.width * crop.height, 1)
        let covered = interpreter.marks.filter { $0.kind == .image }.reduce(0.0) { sum, mark in
            let visible = mark.rect.intersection(crop)
            return visible.isNull ? sum : sum + visible.width * visible.height
        }
        return PageFacts(characters: characters, imageCoverage: min(1, covered / area))
    }

    /// Whether the first pages (up to three) are mostly scanned pictures without text: at least half of them.
    public static func isScanned(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL) else { return false }
        return isScanned(document)
    }

    static func isScanned(_ document: CGPDFDocument) -> Bool {
        guard !document.isEncrypted || document.isUnlocked else { return false }
        let sample = min(samplePages, document.numberOfPages)
        guard sample > 0 else { return false }
        var scanned = 0
        for number in 1...sample {
            guard let page = document.page(at: number) else { continue }
            if autoreleasepool(invoking: { facts(of: page).needsOCR }) { scanned += 1 }
        }
        return scanned * 2 >= sample && scanned > 0
    }

    /// The pages (1-based) that need text recognised.
    static func pagesNeedingOCR(_ document: CGPDFDocument) -> [Int] {
        guard document.numberOfPages > 0 else { return [] }
        return (1...document.numberOfPages).filter { number in
            guard let page = document.page(at: number) else { return false }
            return autoreleasepool { facts(of: page).needsOCR }
        }
    }
}
