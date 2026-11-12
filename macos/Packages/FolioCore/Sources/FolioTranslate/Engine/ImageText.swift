import CoreGraphics
import CoreText
import Foundation
import Vision

/// Text inside pictures (TRANS-40, optional): figures that are images keep their words in pixels, out of reach of the
/// layout analysis. Each picture of a page is rendered and read with Vision; every line of words found becomes a
/// segment to translate, and the translation is set back over the picture in the line's own box — the words taken out
/// of the picture (filled from what is beside them), the translation in their colour, as large as fits — so the
/// picture's layout stays as it was.
/// Numbers, single letters and text the page draws as real text (labels laid over a picture) are left alone. The
/// Windows engine does the same (Folio.Core Translate/Engine/ImageText.cs).
enum ImageText {
    struct Line: @unchecked Sendable {
        var page: Int
        /// Where the words are (page space).
        var rect: CGRect
        var text: String
        var color: RGBColor
        /// The picture under the words with the words taken out (their pixels filled from the background beside
        /// them), and where it goes (page space): drawn first, so lines and shapes behind the words stay.
        var patch: CGImage?
        var patchRect: CGRect
    }

    /// The lines of words in the pictures of page `number`.
    static func recognize(document: CGPDFDocument, number: Int, languages: [String]) -> [Line] {
        guard let page = document.page(at: number) else { return [] }
        let interpreter = ContentInterpreter()
        interpreter.run(page: page)
        let media = page.getBoxRect(.mediaBox)
        // Words the page draws as text: not read again from the picture under them.
        let textBoxes = interpreter.glyphs.filter { $0.isVisible && ($0.text?.contains { $0.isLetter || $0.isNumber } ?? false) }.map(\.box)
        // Pictures side by side (a figure made of many) are read as one.
        var pictures: [CGRect] = []
        for (_, image) in interpreter.images {
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(image.matrix).standardized.intersection(media)
            guard rect.width >= 24, rect.height >= 12, rect.width * rect.height < media.width * media.height * 0.8 else { continue }
            pictures.append(rect)
        }
        var merged = true
        while merged {
            merged = false
            outer: for i in pictures.indices {
                for j in pictures.indices where j > i && pictures[i].insetBy(dx: -14, dy: -14).intersects(pictures[j]) {
                    pictures[i] = pictures[i].union(pictures[j])
                    pictures.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        // A little beyond the pictures: words at their edges (cut where the picture is cut in two) are read whole.
        pictures = pictures.filter { $0.width >= 48 && $0.height >= 24 }.map { $0.insetBy(dx: -18, dy: -6).intersection(media) }
        var lines: [Line] = []
        for rect in pictures {
            lines += read(page: page, rect: rect, number: number, languages: languages, textBoxes: textBoxes)
        }
        return lines
    }

    private static func read(page: CGPDFPage, rect: CGRect, number: Int, languages: [String], textBoxes: [CGRect]) -> [Line] {
        // The picture as it shows on the page, sharp enough to read small labels.
        let scale = max(2, min(3.5, 2000 / max(rect.width, rect.height)))
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage(), let data = context.data else { return [] }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func pixel(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            // Bitmap rows run from the top.
            let cx = min(max(x, 0), width - 1), cy = min(max(height - 1 - y, 0), height - 1)
            let p = (cy * width + cx) * 4
            return (Double(pixels[p]) / 255, Double(pixels[p + 1]) / 255, Double(pixels[p + 2]) / 255)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }

        var lines: [Line] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.4 else { continue }
            // Words far apart on one line (labels side by side) are set apart.
            for (text, box) in groups(candidate, in: rect) {
                guard isWords(text) else { continue }
                // Real text over the picture is translated with the page's own text, or kept.
                if textBoxes.contains(where: { area($0.intersection(box)) > area(box) * 0.3 }) { continue }
                if let line = erase(text: text, box: box, picture: rect, scale: scale, size: (width, height), pixel: pixel, number: number) {
                    lines.append(line)
                }
            }
        }
        return lines
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// The words of a recognised line in runs: a gap wider than the line is tall starts a new run.
    private static func groups(_ candidate: VNRecognizedText, in picture: CGRect) -> [(String, CGRect)] {
        let string = candidate.string
        var words: [(String, CGRect)] = []
        var index = string.startIndex
        for word in string.split(separator: " ", omittingEmptySubsequences: true) {
            guard let range = string.range(of: word, range: index..<string.endIndex) else { continue }
            index = range.upperBound
            guard let n = (try? candidate.boundingBox(for: range))?.boundingBox else { continue }
            words.append((String(word), CGRect(x: picture.minX + n.minX * picture.width, y: picture.minY + n.minY * picture.height,
                                              width: n.width * picture.width, height: n.height * picture.height)))
        }
        // Vision places single words roughly: the run's outer ends are the line's own.
        let n = (try? candidate.boundingBox(for: string.startIndex..<string.endIndex))?.boundingBox ?? .null
        let line = n.isNull ? CGRect.null : CGRect(x: picture.minX + n.minX * picture.width, y: picture.minY + n.minY * picture.height,
                                                   width: n.width * picture.width, height: n.height * picture.height)
        var result: [(String, CGRect)] = []
        for (word, box) in words {
            if let last = result.last, box.minX - last.1.maxX < max(last.1.height, box.height) * 1.1 {
                result[result.count - 1] = (last.0 + " " + word, last.1.union(box))
            } else {
                result.append((word, box))
            }
        }
        if !line.isNull, !result.isEmpty {
            result[0].1 = result[0].1.union(CGRect(x: line.minX, y: result[0].1.minY, width: 0, height: result[0].1.height))
            result[result.count - 1].1 = result[result.count - 1].1.union(CGRect(x: line.maxX, y: result[result.count - 1].1.minY, width: 0, height: result[result.count - 1].1.height))
            // Words placed within the line's height.
            for k in result.indices { result[k].1 = CGRect(x: result[k].1.minX, y: line.minY, width: result[k].1.width, height: line.height) }
        }
        return result
    }

    /// The words' pixels found against the background around them, and filled from the background beside them in
    /// the same row; their colour taken from the darkest (most unlike the background) pixels.
    private static func erase(text: String, box: CGRect, picture: CGRect, scale: Double, size: (Int, Int),
                              pixel: (Int, Int) -> (Double, Double, Double), number: Int) -> Line? {
        let pad = box.height * 0.18
        let area = box.insetBy(dx: -box.height * 0.4, dy: -pad * 0.6).intersection(picture)
        let px = Int(((area.minX - picture.minX) * scale).rounded(.down)), py = Int(((area.minY - picture.minY) * scale).rounded(.down))
        let pw = Int((area.width * scale).rounded(.up)), ph = Int((area.height * scale).rounded(.up))
        guard pw > 2, ph > 2, pw * ph < 4_000_000 else { return nil }
        // The background: the ring just outside.
        var ring: [(Double, Double, Double)] = []
        let step = max(1, (pw + ph) / 160)
        for x in stride(from: px, through: px + pw, by: step) { ring.append(pixel(x, py - 2)); ring.append(pixel(x, py + ph + 1)) }
        for y in stride(from: py, through: py + ph, by: step) { ring.append(pixel(px - 2, y)); ring.append(pixel(px + pw + 1, y)) }
        let background = median(ring)
        func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) }
        var colors = [(Double, Double, Double)](repeating: (1, 1, 1), count: pw * ph)
        var far: [(Double, Double, Double, Double)] = []
        for y in 0..<ph {
            for x in 0..<pw {
                let c = pixel(px + x, py + y)
                colors[y * pw + x] = c
                far.append((c.0, c.1, c.2, distance(c, background)))
            }
        }
        far.sort { $0.3 > $1.3 }
        let darkest = far.prefix(max(1, far.count / 12))
        let ink = (darkest.map(\.0).reduce(0, +) / Double(darkest.count), darkest.map(\.1).reduce(0, +) / Double(darkest.count),
                   darkest.map(\.2).reduce(0, +) / Double(darkest.count))
        let threshold = max(0.15, distance(ink, background) * 0.3)
        // The words' pixels, grown a little (their soft edges).
        var mask = [Bool](repeating: false, count: pw * ph)
        for i in mask.indices where distance(colors[i], background) > threshold { mask[i] = true }
        let grow = max(1, Int(Double(ph) / 14))
        var grown = mask
        for y in 0..<ph {
            for x in 0..<pw where mask[y * pw + x] {
                for dy in -grow...grow {
                    for dx in -grow...grow {
                        let nx = x + dx, ny = y + dy
                        if nx >= 0, nx < pw, ny >= 0, ny < ph { grown[ny * pw + nx] = true }
                    }
                }
            }
        }
        // Filled across each row from what is beside the words (the background where nothing is).
        var bytes = [UInt8](repeating: 255, count: pw * ph * 4)
        for y in 0..<ph {
            var x = 0
            while x < pw {
                if !grown[y * pw + x] {
                    let c = colors[y * pw + x]
                    put(&bytes, (ph - 1 - y) * pw + x, c)
                    x += 1
                    continue
                }
                var end = x
                while end < pw, grown[y * pw + end] { end += 1 }
                let left = x > 0 ? colors[y * pw + x - 1] : background
                let right = end < pw ? colors[y * pw + end] : background
                for k in x..<end {
                    let t = Double(k - x + 1) / Double(end - x + 1)
                    put(&bytes, (ph - 1 - y) * pw + k, (left.0 + (right.0 - left.0) * t, left.1 + (right.1 - left.1) * t, left.2 + (right.2 - left.2) * t))
                }
                x = end
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        let patch = provider.flatMap {
            CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: $0, decode: nil, shouldInterpolate: true,
                    intent: .defaultIntent)
        }
        let patchRect = CGRect(x: picture.minX + Double(px) / scale, y: picture.minY + Double(py) / scale, width: Double(pw) / scale, height: Double(ph) / scale)
        return Line(page: number, rect: box, text: text, color: RGBColor(r: ink.0, g: ink.1, b: ink.2), patch: patch, patchRect: patchRect)
    }

    private static func put(_ bytes: inout [UInt8], _ index: Int, _ c: (Double, Double, Double)) {
        bytes[index * 4] = UInt8(max(0, min(255, c.0 * 255)))
        bytes[index * 4 + 1] = UInt8(max(0, min(255, c.1 * 255)))
        bytes[index * 4 + 2] = UInt8(max(0, min(255, c.2 * 255)))
    }

    /// Words worth translating: two letters at least, more letters than digits.
    static func isWords(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count, digits = text.filter(\.isNumber).count
        guard letters >= 2, letters > digits else { return false }
        // An abbreviation alone ("GT", "ROI", "CNN") stays as it is.
        if !text.contains(" "), letters <= 4, text.filter(\.isLetter).allSatisfy(\.isUppercase) { return false }
        return true
    }

    private static func median(_ colors: [(Double, Double, Double)]) -> (Double, Double, Double) {
        guard !colors.isEmpty else { return (1, 1, 1) }
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return (mid(colors.map(\.0)), mid(colors.map(\.1)), mid(colors.map(\.2)))
    }

    /// Vision's names for the source language's script (Latin text is read too: labels mix them).
    static func recognitionLanguages(for language: String) -> [String] {
        switch language.lowercased() {
        case "zh", "zh-cn", "zh-hans": ["zh-Hans", "en-US"]
        case "zh-tw", "zh-hant": ["zh-Hant", "en-US"]
        case "ja": ["ja-JP", "en-US"]
        case "ko": ["ko-KR", "en-US"]
        case "fr": ["fr-FR"]
        case "de": ["de-DE"]
        case "es": ["es-ES"]
        case "it": ["it-IT"]
        case "pt": ["pt-BR"]
        case "ru": ["ru-RU"]
        default: ["en-US"]
        }
    }

    /// The translation of `line` drawn over the picture: the words covered by their background, the translation in
    /// their colour, as large as the box allows (narrowed a little rather than made tiny), from the box's left edge.
    static func draw(_ line: Line, translation: String, language: String, in context: CGContext) {
        let box = line.rect
        context.saveGState()
        if let patch = line.patch {
            context.interpolationQuality = .high
            context.draw(patch, in: line.patchRect)
        }
        let cjk = ["zh", "ja", "ko"].contains { language.lowercased().hasPrefix($0) }
        func font(_ size: CGFloat) -> CTFont { CTFontCreateWithName((cjk ? "PingFang SC" : "Helvetica") as CFString, size, nil) }
        let color = CGColor(red: line.color.r, green: line.color.g, blue: line.color.b, alpha: 1)
        func make(_ size: CGFloat) -> (CTLine, Double, Double, Double) {
            let attributed = NSAttributedString(string: translation, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font(size), kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
            return (ctLine, width, ascent, descent)
        }
        let full = box.height * 0.82
        var size = full
        var (ctLine, width, ascent, descent) = make(size)
        if width > box.width {
            size = max(full * 0.62, size * box.width / width)
            (ctLine, width, ascent, descent) = make(size)
        }
        let squeeze = width > box.width ? max(0.7, box.width / width) : 1
        let baseline = box.minY + (box.height - (ascent + descent)) / 2 + descent
        context.textMatrix = CGAffineTransform(scaleX: squeeze, y: 1)
        context.textPosition = CGPoint(x: box.minX, y: baseline)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}
