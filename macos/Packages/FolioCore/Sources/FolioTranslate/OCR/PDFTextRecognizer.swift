import CoreGraphics
import Foundation
import Vision

public enum OCRError: LocalizedError, Equatable {
    case unreadable, encrypted
    /// Every page already has text.
    case nothingToRecognize
    /// The pages were read but no text was found on them (photos, blank pages).
    case noTextFound
    /// The new file would not look like the original: it is not used.
    case appearanceChanged

    public var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "无法读取这个 PDF 文件。", bundle: .module)
        case .encrypted: String(localized: "PDF 已加密或受密码保护，无法识别文字。", bundle: .module)
        case .nothingToRecognize: String(localized: "这个 PDF 已经有文字，不需要识别。", bundle: .module)
        case .noTextFound: String(localized: "没有在页面上识别到文字。", bundle: .module)
        case .appearanceChanged: String(localized: "识别后的文件与原文件外观不一致，已保留原文件。", bundle: .module)
        }
    }
}

/// Makes a scanned PDF searchable: renders each page without text, recognises it with Vision (Chinese and English)
/// and writes a copy with an invisible text layer over the unchanged page (`OCRTextLayer`).
public enum PDFTextRecognizer {
    public struct Summary: Sendable, Equatable {
        /// Pages recognised.
        public var pages: Int
        /// Characters found on them.
        public var characters: Int
    }

    public static let languages = ["zh-Hans", "en-US"]

    /// Writes `output`: `input` with text on the pages that had none. `progress` gets (pages done, pages to do).
    /// Throws `OCRError`, or `CancellationError` when the task is cancelled.
    @discardableResult
    public static func recognize(input: URL, output: URL, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Summary {
        guard let document = CGPDFDocument(input as CFURL) else { throw OCRError.unreadable }
        if document.isEncrypted { throw OCRError.encrypted }
        let pages = ScannedPDF.pagesNeedingOCR(document)
        guard !pages.isEmpty else { throw OCRError.nothingToRecognize }
        progress(0, pages.count)
        var results: [Int: OCRPageResult] = [:]
        var characters = 0
        for (index, number) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { continue }
            let result = try autoreleasepool { try recognize(page: page, number: number) }
            if let result, !result.lines.isEmpty {
                results[number] = result
                characters += result.lines.reduce(0) { $0 + $1.words.reduce(0) { $0 + $1.text.count } }
            }
            progress(index + 1, pages.count)
        }
        try Task.checkCancellation()
        guard characters > 0 else { throw OCRError.noTextFound }
        let data = OCRTextLayer.write(source: document, layers: results)
        guard let written = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init),
              looksTheSame(document, written) else { throw OCRError.appearanceChanged }
        try data.write(to: output, options: .atomic)
        return Summary(pages: results.count, characters: characters)
    }

    // MARK: Recognition

    /// Recognises one page shown as it is (crop box, rotation) at about 300 dpi for letter-sized pages.
    static func recognize(page: CGPDFPage, number: Int) throws -> OCRPageResult? {
        guard let image = render(page, longSide: 3300, minScale: 2, maxScale: 4.2) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        if #available(macOS 13, *) { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        let lines = (request.results ?? []).compactMap { line(from: $0, size: size) }
        return OCRPageResult(page: number, imageSize: size, lines: lines)
    }

    /// Vision's line as words with their own boxes. Vision boxes words of Latin text, and characters of CJK text:
    /// CJK characters are words of their own, so selecting them goes character by character.
    static func line(from observation: VNRecognizedTextObservation, size: CGSize) -> OCRLine? {
        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { return nil }
        let string = candidate.string
        func rect(_ normalized: CGRect) -> CGRect {
            CGRect(x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
                   width: normalized.width * size.width, height: normalized.height * size.height)
        }
        let lineRect = rect(observation.boundingBox)
        let units = units(of: string)
        guard !units.isEmpty else { return nil }
        // Where Vision gives no box for a unit, it gets a share of the line by its characters (CJK twice as wide).
        let weights = units.map { unit in string[unit].unicodeScalars.reduce(0.0) { $0 + (OCRTextLayer.isCJK($1) ? 1 : 0.55) } }
        let totalWeight = string.unicodeScalars.reduce(0.0) { $0 + (OCRTextLayer.isCJK($1) ? 1 : 0.55) }
        var words: [OCRWord] = []
        for (index, unit) in units.enumerated() {
            var box: CGRect?
            if let found = try? candidate.boundingBox(for: unit)?.boundingBox, found.width > 0, found.height > 0 {
                box = rect(found).intersection(lineRect.insetBy(dx: -2, dy: -lineRect.height))
            }
            if box == nil || box!.isNull || box!.width <= 0 {
                let before = string[string.startIndex..<unit.lowerBound].unicodeScalars.reduce(0.0) { $0 + (OCRTextLayer.isCJK($1) ? 1 : 0.55) }
                box = CGRect(x: lineRect.minX + lineRect.width * before / max(totalWeight, 1), y: lineRect.minY,
                             width: lineRect.width * weights[index] / max(totalWeight, 1), height: lineRect.height)
            }
            words.append(OCRWord(text: String(string[unit]), rect: box!))
        }
        // Boxes in reading order and not overlapping the next: a word's box ends where the next begins.
        for index in words.indices.dropLast() where words[index].rect.maxX > words[index + 1].rect.minX {
            let end = max(words[index].rect.minX + 0.5, words[index + 1].rect.minX)
            words[index].rect.size.width = end - words[index].rect.minX
        }
        return OCRLine(words: words)
    }

    /// Words split at spaces; within a word, each CJK character is a unit of its own.
    static func units(of string: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var start: String.Index?
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            let character = string[index]
            if character.isWhitespace {
                if let s = start { result.append(s..<index) }
                start = nil
            } else if character.unicodeScalars.contains(where: OCRTextLayer.isCJK) {
                if let s = start { result.append(s..<index) }
                start = nil
                result.append(index..<next)
            } else if start == nil {
                start = index
            }
            index = next
        }
        if let s = start { result.append(s..<string.endIndex) }
        return result
    }

    // MARK: Rendering

    /// The page as shown (crop box, `/Rotate`), white background, grey: the long side `longSide` pixels, the scale
    /// kept between `minScale` and `maxScale` of the page's points.
    static func render(_ page: CGPDFPage, longSide: Double, minScale: Double, maxScale: Double) -> CGImage? {
        let media = page.getBoxRect(.mediaBox)
        var crop = page.getBoxRect(.cropBox).intersection(media)
        if crop.isNull || crop.width < 1 { crop = media }
        let rotated = Int(page.rotationAngle) % 180 != 0
        let shown = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        guard shown.width >= 1, shown.height >= 1 else { return nil }
        let scale = min(maxScale, max(minScale, longSide / max(shown.width, shown.height)))
        return render(page, size: shown, scale: scale)
    }

    static func render(_ page: CGPDFPage, size shown: CGSize, scale: Double) -> CGImage? {
        let width = Int((shown.width * scale).rounded()), height = Int((shown.height * scale).rounded())
        guard width > 0, height > 0, width * height < 60_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: Double(width) / shown.width, y: Double(height) / shown.height)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: shown), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: Checking

    /// Whether every page of `written` looks like the same page of `original` (small renders compared pixel by
    /// pixel): an image that could not be carried over would show here.
    static func looksTheSame(_ original: CGPDFDocument, _ written: CGPDFDocument) -> Bool {
        guard original.numberOfPages == written.numberOfPages else { return false }
        for number in stride(from: 1, through: original.numberOfPages, by: 1) {
            let same: Bool = autoreleasepool {
                guard let a = original.page(at: number), let b = written.page(at: number) else { return false }
                return difference(a, b) < 3
            }
            if !same { return false }
        }
        return true
    }

    /// Mean difference of grey levels (0…255) between two pages rendered 160 pixels wide.
    static func difference(_ a: CGPDFPage, _ b: CGPDFPage) -> Double {
        let boxA = a.getBoxRect(.cropBox), boxB = b.getBoxRect(.cropBox)
        guard abs(boxA.width - boxB.width) < 0.5, abs(boxA.height - boxB.height) < 0.5, a.rotationAngle == b.rotationAngle else { return 255 }
        let rotated = Int(a.rotationAngle) % 180 != 0
        let shown = rotated ? CGSize(width: boxA.height, height: boxA.width) : boxA.size
        let scale = 160 / max(shown.width, 1)
        guard let imageA = render(a, size: shown, scale: scale), let imageB = render(b, size: shown, scale: scale),
              let pixelsA = imageA.dataProvider?.data as Data?, let pixelsB = imageB.dataProvider?.data as Data?,
              pixelsA.count == pixelsB.count, !pixelsA.isEmpty else { return 255 }
        guard imageA.bytesPerRow == imageB.bytesPerRow, imageA.width == imageB.width, imageA.height == imageB.height else { return 255 }
        let width = imageA.width, height = imageA.height, row = imageA.bytesPerRow
        var total = 0
        pixelsA.withUnsafeBytes { ra in
            pixelsB.withUnsafeBytes { rb in
                let pa = ra.bindMemory(to: UInt8.self), pb = rb.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width { total += abs(Int(pa[y * row + x]) - Int(pb[y * row + x])) }
                }
            }
        }
        return Double(total) / Double(max(width * height, 1))
    }
}
