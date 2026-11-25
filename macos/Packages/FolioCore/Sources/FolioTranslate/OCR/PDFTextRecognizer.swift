import CoreGraphics
import CoreImage
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

    /// Chinese first (its model reads English words too), then English; the languages of the user's Mac that need a model
    /// of their own are tried after them.
    public static let languages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

    /// The languages asked for that this version of Vision reads.
    static let supportedLanguages: [String] = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let known = Set((try? request.supportedRecognitionLanguages()) ?? ["zh-Hans", "en-US"])
        let found = languages.filter(known.contains)
        return found.isEmpty ? ["en-US"] : found
    }()

    /// Writes `output`: `input` with text on the pages that had none. `progress` gets (pages done, pages to do).
    /// `force`: the user asked for it — when no page looks like a scan, every page with a picture on it is read too.
    /// `onlyPagesOfText`: only pages with sentences on them are taken (a drawing filling a page keeps its labels to itself).
    /// Throws `OCRError`, or `CancellationError` when the task is cancelled.
    @discardableResult
    public static func recognize(input: URL, output: URL, force: Bool = false, onlyPagesOfText: Bool = false,
                                 progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Summary {
        guard let document = CGPDFDocument(input as CFURL) else { throw OCRError.unreadable }
        guard ScannedPDF.canRead(document) else { throw OCRError.encrypted }
        var pages = ScannedPDF.pagesNeedingOCR(document, url: input)
        if pages.isEmpty, force { pages = pagesWithPictures(document) }
        guard !pages.isEmpty else { throw OCRError.nothingToRecognize }
        progress(0, pages.count)
        var results: [Int: OCRPageResult] = [:]
        var characters = 0
        var failure: Error?
        for (index, number) in pages.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: number) else { continue }
            do {
                // One page that cannot be read does not cost the rest of the document its text.
                if let result = try await read(page: page, number: number, anew: force), !result.lines.isEmpty,
                   !onlyPagesOfText || isPageOfText(result) {
                    results[number] = result
                    characters += result.lines.reduce(0) { $0 + $1.words.reduce(0) { $0 + $1.text.count } }
                }
            } catch { failure = error }
            progress(index + 1, pages.count)
        }
        try Task.checkCancellation()
        guard characters > 0 else { throw failure ?? OCRError.noTextFound }
        let data = OCRTextLayer.write(source: document, layers: results)
        guard let written = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init),
              looksTheSame(document, written) else { throw OCRError.appearanceChanged }
        try data.write(to: output, options: .atomic)
        return Summary(pages: results.count, characters: characters)
    }

    /// Reads a page away from the threads Swift's tasks share: reading one blocks for seconds, and Vision needs such threads
    /// itself (a few documents read at once on a Mac with few cores had them all, and waited for each other for ever).
    private static func read(page: CGPDFPage, number: Int, anew: Bool) async throws -> OCRPageResult? {
        nonisolated(unsafe) let page = page
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OCRPageResult?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try autoreleasepool { try recognize(page: page, number: number, anew: anew) } })
            }
        }
    }

    /// Several lines that are parts of sentences: a page of text, not a picture with labels.
    static func isPageOfText(_ result: OCRPageResult) -> Bool {
        var lines = 0, characters = 0
        for line in result.lines {
            let text = line.text
            let words = text.split(whereSeparator: \.isWhitespace).filter { $0.count >= 2 && $0.allSatisfy { $0.isLetter || $0.isPunctuation } }.count
            let han = text.unicodeScalars.filter { OCRTextLayer.isCJK($0) && $0.properties.isAlphabetic }.count
            guard words >= 6 || han >= 14 else { continue }
            lines += 1
            characters += text.count
        }
        return lines >= 5 && characters >= 120
    }

    private static func pagesWithPictures(_ document: CGPDFDocument) -> [Int] {
        guard document.numberOfPages > 0 else { return [] }
        return (1...document.numberOfPages).filter { number in
            guard let page = document.page(at: number) else { return false }
            return autoreleasepool { ScannedPDF.facts(of: page).imageCoverage >= 0.1 }
        }
    }

    // MARK: Recognition

    /// The long side of the picture read: about 300 dpi for letter-sized pages, whatever size the page says it is.
    static let longSide = 3300.0

    /// Recognises one page shown as it is (crop box, rotation); when little comes out, sharper and with more contrast
    /// (faint, small or low-resolution scans), and turned (pages scanned sideways or upside down). Text the page already
    /// has as text is not added again.
    static func recognize(page: CGPDFPage, number: Int, anew: Bool = false) throws -> OCRPageResult? {
        guard let image = render(page, longSide: longSide) else { return nil }
        var best = try read(image)
        var bestImage = image
        var turn = 0
        if best.isPoor, let sharper = enhanced(image) {
            let again = try read(sharper)
            if again.score > best.score { best = again }
        }
        if best.isPoor || best.isTurned {
            // Vision reads upside-down and sideways lines too, but their words then come out in the wrong places.
            for quarter in [90, 270, 180] {
                guard let turned = turned(image, by: quarter) else { continue }
                let reading = try read(turned)
                guard !reading.isTurned else { continue }
                if best.isTurned ? reading.score > best.score * 0.7 : reading.score > best.score * 1.3 + 4 {
                    best = reading
                    bestImage = turned
                    turn = quarter
                }
            }
        }
        let size = CGSize(width: bestImage.width, height: bestImage.height)
        let tilt = tilt(of: best.observations, size: size)
        var lines = best.observations.compactMap { line(from: $0, size: size, tilt: tilt) }
        // What is text on the page already (a footer, a stamp drawn as text) is not put there twice.
        let interpreter = ContentInterpreter()
        interpreter.run(page: page)
        let crop = ScannedPDF.effectiveCrop(page)
        let toUser = OCRTextLayer.displayToUser(crop: crop, rotation: Int(page.rotationAngle) + turn, imageSize: size)
        // Asked for again: what was read before gives way.
        let replaces = anew && interpreter.isRecognizedScan && interpreter.runs.allSatisfy { $0.renderMode != 3 || $0.glyphs.isEmpty || $0.location.stream.isEmpty }
        let text = interpreter.glyphs.filter { !$0.isClipped && !(replaces && $0.renderMode == 3) && (ScannedPDF.readableCharacters($0) ?? 0) > 0 }.map(\.box)
        if !text.isEmpty {
            lines.removeAll { line in
                let box = line.box.applying(toUser)
                return text.contains { box.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            }
        }
        var result = OCRPageResult(page: number, imageSize: size, lines: lines, turn: turn)
        result.replaces = replaces
        return result
    }

    /// What Vision read on one picture of a page.
    private struct Reading {
        var observations: [VNRecognizedTextObservation]
        /// Characters, each counting as much as Vision is sure of its line.
        var score: Double
        var characters: Int
        /// Most lines do not run from left to right: the page lies on its side or upside down.
        var isTurned: Bool
        var isPoor: Bool { characters < 40 || score < Double(characters) * 0.45 }
    }

    private static func read(_ image: CGImage) throws -> Reading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = supportedLanguages
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let found = (request.results ?? []).filter { ($0.topCandidates(1).first?.confidence ?? 0) >= 0.2 }
        var score = 0.0, characters = 0, astray = 0
        let width = Double(image.width), height = Double(image.height)
        for observation in found {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let count = candidate.string.count
            characters += count
            score += Double(count) * Double(candidate.confidence)
            let dx = (observation.topRight.x - observation.topLeft.x) * width, dy = (observation.topRight.y - observation.topLeft.y) * height
            if dx <= abs(dy) { astray += count }
        }
        return Reading(observations: found, score: score, characters: characters, isTurned: astray * 2 > characters && astray > 20)
    }

    /// The picture with its greys stretched to black and white and its edges sharpened, larger when it is small.
    private static func enhanced(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let factor = min(2, max(1, 4600 / Double(max(image.width, image.height))))
        let stretched = input
            .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.35, "inputSaturation": 0])
            .applyingFilter("CIUnsharpMask", parameters: ["inputRadius": 2.0, "inputIntensity": 0.8])
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        return CIContext(options: nil).createCGImage(stretched, from: stretched.extent.integral)
    }

    /// The picture turned clockwise by 90, 180 or 270 degrees.
    private static func turned(_ image: CGImage, by degrees: Int) -> CGImage? {
        let w = image.width, h = image.height
        let size = degrees % 180 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: -Double(degrees) * .pi / 180)
        context.draw(image, in: CGRect(x: -Double(w) / 2, y: -Double(h) / 2, width: Double(w), height: Double(h)))
        return context.makeImage()
    }

    /// Which way a line reads, on an image with rows going down: radians, clockwise.
    private static func direction(_ observation: VNRectangleObservation, size: CGSize) -> Double {
        let dx = (observation.bottomRight.x - observation.bottomLeft.x + observation.topRight.x - observation.topLeft.x) * size.width
        let dy = (observation.bottomRight.y - observation.bottomLeft.y + observation.topRight.y - observation.topLeft.y) * size.height
        return atan2(-dy, dx)
    }

    /// How far the page tilts: what its long lines agree on (0: straight enough).
    static func tilt(of observations: [VNRecognizedTextObservation], size: CGSize) -> Double {
        var angles: [Double] = []
        for observation in observations where observation.boundingBox.width * size.width > size.width * 0.2 {
            let angle = direction(observation, size: size)
            if abs(angle) < 0.2 { angles.append(angle) }
        }
        guard angles.count >= 3 else { return 0 }
        let middle = angles.sorted()[angles.count / 2]
        let agree = angles.filter { abs($0 - middle) < 0.006 }.count
        return abs(middle) >= 0.004 && agree * 2 > angles.count ? middle : 0
    }

    /// Vision's line as words with their own boxes. Vision boxes words of Latin text, and characters of CJK text:
    /// CJK characters are words of their own, so selecting them goes character by character. A line standing upright, or on a
    /// page that tilts (`tilt`), keeps its direction.
    static func line(from observation: VNRecognizedTextObservation, size: CGSize, tilt: Double = 0) -> OCRLine? {
        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.2 else { return nil }
        let string = candidate.string
        let direction = direction(observation, size: size)
        let quarter = (direction / (.pi / 2)).rounded()
        // One or two letters have no direction to speak of.
        let angle = (string.count >= 3 ? quarter * .pi / 2 : 0) + tilt
        let back = CGAffineTransform(rotationAngle: -angle)
        func rect(_ box: VNRectangleObservation) -> CGRect {
            if angle == 0 {
                let n = box.boundingBox
                return CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height, width: n.width * size.width, height: n.height * size.height)
            }
            let corners = [box.topLeft, box.topRight, box.bottomLeft, box.bottomRight].map { CGPoint(x: $0.x * size.width, y: (1 - $0.y) * size.height).applying(back) }
            let xs = corners.map(\.x).sorted(), ys = corners.map(\.y).sorted()
            return CGRect(x: xs[0], y: (ys[0] + ys[1]) / 2, width: xs[3] - xs[0], height: (ys[2] + ys[3] - ys[0] - ys[1]) / 2)
        }
        let lineRect = rect(observation)
        let units = units(of: string)
        guard !units.isEmpty else { return nil }
        // Where Vision gives no box for a unit, it gets a share of the line by its characters (CJK twice as wide).
        let weights = units.map { unit in string[unit].unicodeScalars.reduce(0.0) { $0 + (OCRTextLayer.isCJK($1) ? 1 : 0.55) } }
        let totalWeight = string.unicodeScalars.reduce(0.0) { $0 + (OCRTextLayer.isCJK($1) ? 1 : 0.55) }
        var words: [OCRWord] = []
        for (index, unit) in units.enumerated() {
            var box: CGRect?
            if let found = try? candidate.boundingBox(for: unit), found.boundingBox.width > 0, found.boundingBox.height > 0 {
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
        return OCRLine(words: words, angle: angle)
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

    /// The page as shown (crop box, `/Rotate`), white background, grey: its long side `longSide` pixels, however large the
    /// page says it is (a scanner may write one point per pixel), small pages at no more than about 430 dpi.
    static func render(_ page: CGPDFPage, longSide: Double, maxScale: Double = 6) -> CGImage? {
        let crop = ScannedPDF.effectiveCrop(page)
        let rotated = Int(page.rotationAngle) % 180 != 0
        let shown = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        guard shown.width >= 1, shown.height >= 1 else { return nil }
        return render(page, size: shown, scale: min(maxScale, longSide / max(shown.width, shown.height)))
    }

    static func render(_ page: CGPDFPage, size shown: CGSize, scale: Double) -> CGImage? {
        let width = max(1, Int((shown.width * scale).rounded())), height = max(1, Int((shown.height * scale).rounded()))
        guard width * height < 60_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: Double(width) / shown.width, y: Double(height) / shown.height)
        // The part of the page that shows, turned as the page says (a crop box reaching past the page is cut to it).
        let user = OCRTextLayer.displayToUser(crop: ScannedPDF.effectiveCrop(page), rotation: Int(page.rotationAngle), imageSize: shown)
        context.concatenate(user.inverted().concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: shown.height)))
        context.clip(to: ScannedPDF.effectiveCrop(page))
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
                return difference(a, b) < 3 && inkKept(a, b)
            }
            if !same { return false }
        }
        return true
    }

    /// Whether the new page still has the old one's ink: on a page with few words on it, a picture that went missing hardly
    /// changes the mean.
    static func inkKept(_ a: CGPDFPage, _ b: CGPDFPage) -> Bool {
        func ink(_ page: CGPDFPage) -> Double? {
            guard let image = render(page, longSide: 400), let pixels = image.dataProvider?.data as Data? else { return nil }
            var total = 0
            for y in 0..<image.height {
                for x in 0..<image.width { total += 255 - Int(pixels[y * image.bytesPerRow + x]) }
            }
            return Double(total) / Double(image.width * image.height)
        }
        guard let before = ink(a), let after = ink(b) else { return false }
        return abs(before - after) <= max(0.05, before * 0.1)
    }

    /// Mean difference of grey levels (0…255) between two pages rendered 160 pixels wide.
    static func difference(_ a: CGPDFPage, _ b: CGPDFPage) -> Double {
        let boxA = ScannedPDF.effectiveCrop(a), boxB = ScannedPDF.effectiveCrop(b)
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
