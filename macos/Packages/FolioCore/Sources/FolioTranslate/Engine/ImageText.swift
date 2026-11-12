import CoreGraphics
import CoreText
import Foundation
import Vision

/// Text inside pictures (TRANS-40, optional): figures that are images keep their words in pixels, out of reach of the
/// layout analysis. Each picture of a page (pictures side by side read as one) is rendered and read with Vision,
/// across and, for labels set sideways (an axis title), up the page. Every run of words becomes a segment to
/// translate, and the translation is set back in the run's own place:
///
/// - only the words come out of the picture: the strokes found against the background around them, as far as they
///   touch the words' own box (an arrow or a line beside a label stays), filled from what is beside them;
/// - the translation keeps the words' colour, is never wider than they were, and keeps how the labels stood: lines
///   set one under the other keep their left edges, right edges or centres in line and share one size; a label on its
///   own keeps its centre, so what was centred under a picture stays centred.
///
/// Numbers, lone abbreviations and text the page draws as real text are left alone. The Windows engine does the same
/// (Folio.Core Translate/Engine/ImageText.cs).
enum ImageText {
    enum Alignment: Sendable { case left, center, right }

    struct Line: @unchecked Sendable {
        var page: Int
        /// Where the words are (page space).
        var rect: CGRect
        var text: String
        var color: RGBColor
        /// The picture under the words with the words taken out, and where it goes (page space): drawn first.
        var patch: CGImage?
        var patchRect: CGRect
        /// Set sideways, reading up the page (or, `readsDown`, down it).
        var vertical = false
        var readsDown = false
        var alignment: Alignment = .center
        /// Lines set together (one under the other): one size for all of them.
        var group = 0
        /// Words the page draws as text (a figure drawn in vectors): their glyphs, taken out of the page, and their size.
        var glyphs: [Int] = []
        var size: Double?
    }

    /// A rendered picture: RGB bytes (4 per pixel), rows from the top.
    struct Raster {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        func pixel(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let cx = min(max(x, 0), width - 1), cy = min(max(y, 0), height - 1)
            let p = (cy * width + cx) * 4
            return (Double(bytes[p]) / 255, Double(bytes[p + 1]) / 255, Double(bytes[p + 2]) / 255)
        }

        /// Turned a quarter clockwise: text that read up the page reads across.
        func turnedClockwise() -> Raster {
            var out = [UInt8](repeating: 255, count: bytes.count)
            for y in 0..<height {
                for x in 0..<width {
                    let source = (y * width + x) * 4
                    let target = (x * height + (height - 1 - y)) * 4
                    out[target] = bytes[source]; out[target + 1] = bytes[source + 1]; out[target + 2] = bytes[source + 2]
                }
            }
            return Raster(width: height, height: width, bytes: out)
        }

        var image: CGImage? {
            CGDataProvider(data: Data(bytes) as CFData).flatMap {
                CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: $0, decode: nil, shouldInterpolate: true,
                        intent: .defaultIntent)
            }
        }
    }

    /// A run of words found: pixel box (from the top left of the picture), text.
    struct Run {
        var text: String
        var box: CGRect
        var vertical: Bool
    }

    /// The runs of words in the pictures of page `number`.
    static func recognize(document: CGPDFDocument, number: Int, languages: [String], layout: PageLayout? = nil) -> [Line] {
        guard let page = document.page(at: number) else { return [] }
        let interpreter = ContentInterpreter()
        interpreter.run(page: page)
        let vector = layout.map { vectorLabels($0, interpreter: interpreter) } ?? []
        let media = page.getBoxRect(.mediaBox)
        // Words the page draws as text: not read again from the picture under them.
        let textBoxes = interpreter.glyphs.filter { $0.isVisible && ($0.text?.contains { $0.isLetter || $0.isNumber } ?? false) }.map(\.box)
        var pictures: [CGRect] = []
        for (_, image) in interpreter.images {
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(image.matrix).standardized.intersection(media)
            guard rect.width >= 24, rect.height >= 12, rect.width * rect.height < media.width * media.height * 0.8 else { continue }
            pictures.append(rect)
        }
        pictures = mergedPictures(pictures, within: media)
        var lines: [Line] = []
        var group = 0
        for rect in pictures {
            // The picture as it shows on the page, sharp enough to read small labels.
            let scale = max(2.5, min(4, 2400 / max(rect.width, rect.height)))
            guard let raster = render(page: page, rect: rect, scale: scale), let image = raster.image else { continue }
            var runs = read(image, languages: languages).map { Run(text: $0.0, box: $0.1, vertical: false) }
            // Sideways labels: read on the picture turned a quarter, where they lie across.
            if let turned = raster.turnedClockwise().image {
                for (text, box) in read(turned, languages: languages) {
                    // Back to the picture: x' = h - 1 - y, y' = x.
                    let original = CGRect(x: box.minY, y: Double(raster.height) - box.maxX, width: box.height, height: box.width)
                    guard original.height > original.width * 1.5 else { continue }
                    if runs.contains(where: { area($0.box.intersection(original)) > area(original) * 0.2 }) { continue }
                    runs.append(Run(text: text, box: original, vertical: true))
                }
            }
            func pageRect(_ r: CGRect) -> CGRect {
                CGRect(x: rect.minX + r.minX / scale, y: rect.maxY - r.maxY / scale, width: r.width / scale, height: r.height / scale)
            }
            var found: [(run: Run, line: Line)] = []
            for run in runs where isWords(run.text) {
                let box = pageRect(run.box)
                // Real text over the picture is translated with the page's own text, or kept.
                if textBoxes.contains(where: { area($0.intersection(box)) > area(box) * 0.3 }) { continue }
                guard let erased = erase(run, raster: raster) else { continue }
                found.append((run, Line(page: number, rect: box, text: run.text, color: erased.color, patch: erased.patch,
                                        patchRect: pageRect(erased.area), vertical: run.vertical)))
            }
            // How the lines stand together.
            let arranged = arrange(found.map(\.run))
            for (k, entry) in found.enumerated() {
                var line = entry.line
                line.alignment = arranged[k].alignment
                line.group = group + arranged[k].group
                lines.append(line)
            }
            group += found.count + 1
        }
        // Words read from a picture under a label drawn as text: the label's.
        lines.removeAll { line in vector.contains { area($0.rect.intersection(line.rect)) > area(line.rect) * 0.3 } }
        return lines + vector
    }

    /// The labels of figures drawn in vectors: the figure's own text (the layout analysis leaves it to the figure), cut
    /// where words stand far apart, set over the figure the same way as words read from pictures. Text set sideways in a
    /// figure is gathered character by character into columns (the layout analysis cuts it up), reading up or down the
    /// page as its glyphs are turned.
    static func vectorLabels(_ layout: PageLayout, interpreter: ContentInterpreter) -> [Line] {
        var runs: [Run] = []
        var lines: [Line] = []
        let figures = layout.figures.map { $0.insetBy(dx: -12, dy: -12) }
        let inFigure = layout.blocks.filter { block in
            !block.translate && (block.kind == .figure || figures.contains { $0.intersects(block.rect) } && block.kind != .paragraph)
        }
        // Sideways characters, by the way their glyphs are turned.
        var sideways: [(char: PageChar, down: Bool)] = []
        for block in inFigure {
            for line in block.lines {
                for c in line.chars where !c.isSpace && (c.isRotated || line.isRotated) {
                    guard let g = c.glyphs.first, g < interpreter.glyphs.count else { continue }
                    let m = interpreter.glyphs[g].matrix
                    let angle = atan2(m.b, m.a)
                    guard abs(abs(angle) - .pi / 2) < 0.2 else { continue }
                    sideways.append((c, angle < 0))
                }
            }
        }
        // Columns: about one x, one after the other along the reading direction.
        var columns: [[(char: PageChar, down: Bool)]] = []
        for item in sideways.sorted(by: { ($0.down ? -$0.char.rect.midY : $0.char.rect.midY) < ($1.down ? -$1.char.rect.midY : $1.char.rect.midY) }) {
            if let k = columns.lastIndex(where: { column in
                let last = column.last!
                let gap = item.down ? last.char.rect.minY - item.char.rect.maxY : item.char.rect.minY - last.char.rect.maxY
                return last.down == item.down && abs(last.char.rect.midX - item.char.rect.midX) < item.char.size * 0.6 && gap < item.char.size * 1.1 && gap > -item.char.size
            }) {
                columns[k].append(item)
            } else {
                columns.append([item])
            }
        }
        for column in columns {
            var text = ""
            for (k, item) in column.enumerated() {
                if k > 0 {
                    let last = column[k - 1].char
                    let gap = item.down ? last.rect.minY - item.char.rect.maxY : item.char.rect.minY - last.rect.maxY
                    if gap > item.char.size * 0.18 { text += " " }
                }
                text += item.char.text
            }
            guard isWords(text) else { continue }
            let ink = column.dropFirst().reduce(column[0].char.rect) { $0.union($1.char.rect) }
            let size = column.map(\.char.size).max() ?? ink.width
            let rect = CGRect(x: ink.midX - size * 0.51, y: ink.minY, width: size * 1.02, height: ink.height)
            runs.append(Run(text: text, box: rect, vertical: true))
            lines.append(Line(page: layout.number, rect: rect, text: text, color: column[0].char.color, patch: nil, patchRect: .null,
                              vertical: true, readsDown: column[0].down, glyphs: column.flatMap(\.char.glyphs), size: size))
        }
        // Labels across.
        for block in inFigure {
            for line in block.lines where !line.isRotated {
                var current: [PageChar] = []
                func flush() {
                    let chars = current.filter { !$0.isSpace }
                    current = []
                    guard !chars.isEmpty else { return }
                    var spaced = ""
                    for (k, c) in chars.enumerated() {
                        if k > 0, c.rect.minX - chars[k - 1].rect.maxX > line.size * 0.18 { spaced += " " }
                        spaced += c.text
                    }
                    guard isWords(spaced) else { return }
                    let ink = chars.dropFirst().reduce(chars[0].rect) { $0.union($1.rect) }
                    let rect = CGRect(x: ink.minX, y: line.baseline - line.size * 0.24, width: ink.width, height: line.size * 1.02)
                    runs.append(Run(text: spaced, box: rect, vertical: false))
                    lines.append(Line(page: layout.number, rect: rect, text: spaced, color: line.color, patch: nil, patchRect: .null,
                                      glyphs: chars.flatMap(\.glyphs), size: line.size))
                }
                for c in line.chars where !c.isRotated {
                    if let last = current.last(where: { !$0.isSpace }), !c.isSpace, c.rect.minX - last.rect.maxX > line.size * 1.1 { flush() }
                    current.append(c)
                }
                flush()
            }
        }
        let arranged = arrange(runs)
        for k in lines.indices {
            lines[k].alignment = arranged[k].alignment
            lines[k].group = 1_000_000 + layout.number * 10_000 + arranged[k].group
        }
        return lines
    }

    /// Pictures side by side (a figure made of many) as one, with a little room around: words at their edges are read whole.
    static func mergedPictures(_ rects: [CGRect], within media: CGRect) -> [CGRect] {
        var pictures = rects
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
        return pictures.filter { $0.width >= 48 && $0.height >= 24 }.map { $0.insetBy(dx: -18, dy: -6).intersection(media) }
    }

    private static func render(page: CGPDFPage, rect: CGRect, scale: Double) -> Raster? {
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.drawPDFPage(page)
        guard let data = context.data else { return nil }
        // The context's memory runs from the top row.
        let bytes = [UInt8](UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height * 4), count: width * height * 4))
        return Raster(width: width, height: height, bytes: bytes)
    }

    /// Runs of words read from `image`: text and pixel box from the top left. Words far apart on one line (labels
    /// side by side) are runs of their own.
    private static func read(_ image: CGImage, languages: [String]) -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }
        let w = Double(image.width), h = Double(image.height)
        func box(_ n: CGRect) -> CGRect { CGRect(x: n.minX * w, y: (1 - n.maxY) * h, width: n.width * w, height: n.height * h) }
        var result: [(String, CGRect)] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { continue }
            let string = candidate.string
            var words: [(String, CGRect)] = []
            var index = string.startIndex
            for word in string.split(separator: " ", omittingEmptySubsequences: true) {
                guard let range = string.range(of: word, range: index..<string.endIndex) else { continue }
                index = range.upperBound
                guard let n = (try? candidate.boundingBox(for: range))?.boundingBox else { continue }
                words.append((String(word), box(n)))
            }
            let line = box(observation.boundingBox)
            var runs: [(String, CGRect)] = []
            for (word, b) in words {
                if let last = runs.last, b.minX - last.1.maxX < max(last.1.height, b.height) * 1.1 {
                    runs[runs.count - 1] = (last.0 + " " + word, last.1.union(b))
                } else {
                    runs.append((word, b))
                }
            }
            if runs.isEmpty { runs = [(string, line)] }
            // Vision places single words roughly: a run's outer ends are the line's own, its height the line's.
            runs[0].1 = runs[0].1.union(CGRect(x: line.minX, y: runs[0].1.minY, width: 0, height: 0))
            runs[runs.count - 1].1 = runs[runs.count - 1].1.union(CGRect(x: line.maxX, y: runs[runs.count - 1].1.minY, width: 0, height: 0))
            for k in runs.indices { runs[k].1 = CGRect(x: runs[k].1.minX, y: line.minY, width: runs[k].1.width, height: line.height) }
            result += runs.map { ($0.0.trimmingCharacters(in: .whitespaces), $0.1) }
        }
        return result
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Words worth translating: two letters at least, more letters than digits, not an abbreviation alone.
    static func isWords(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count, digits = text.filter(\.isNumber).count
        guard letters >= 2, letters > digits else { return false }
        if !text.contains(" "), letters <= 4, text.filter(\.isLetter).allSatisfy(\.isUppercase) { return false }
        return true
    }

    // MARK: Taking the words out

    /// The words' strokes: pixels unlike the background around them and like the words' ink, as far as they belong to
    /// shapes touching the words' own box (an arrowhead beside a label is a shape of its own and stays). They are filled
    /// across from what is beside them (across rows for words across, columns for words up the page).
    static func erase(_ run: Run, raster: Raster) -> (patch: CGImage?, area: CGRect, color: RGBColor)? {
        let box = run.box
        let thickness = run.vertical ? box.width : box.height
        let along = thickness * 0.3, across = thickness * 0.12
        let area = box.insetBy(dx: -(run.vertical ? across : along), dy: -(run.vertical ? along : across))
            .intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        let px = Int(area.minX.rounded(.down)), py = Int(area.minY.rounded(.down))
        let pw = Int(area.maxX.rounded(.up)) - px, ph = Int(area.maxY.rounded(.up)) - py
        guard pw > 2, ph > 2, pw * ph < 4_000_000 else { return nil }
        func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) }
        // The background: the ring just outside.
        var ring: [(Double, Double, Double)] = []
        let step = max(1, (pw + ph) / 160)
        for x in stride(from: px, through: px + pw, by: step) { ring.append(raster.pixel(x, py - 2)); ring.append(raster.pixel(x, py + ph + 1)) }
        for y in stride(from: py, through: py + ph, by: step) { ring.append(raster.pixel(px - 2, y)); ring.append(raster.pixel(px + pw + 1, y)) }
        let background = median(ring)
        var colors = [(Double, Double, Double)](repeating: (1, 1, 1), count: pw * ph)
        for y in 0..<ph { for x in 0..<pw { colors[y * pw + x] = raster.pixel(px + x, py + y) } }
        // The ink: the pixels inside the words' box most unlike the background.
        var inside: [(Double, Double, Double)] = []
        let bx0 = Int(box.minX) - px, by0 = Int(box.minY) - py, bx1 = Int(box.maxX) - px, by1 = Int(box.maxY) - py
        for y in max(0, by0)..<min(ph, max(by1, by0 + 1)) { for x in max(0, bx0)..<min(pw, max(bx1, bx0 + 1)) { inside.append(colors[y * pw + x]) } }
        inside.sort { distance($0, background) > distance($1, background) }
        let darkest = inside.prefix(max(1, inside.count / 10))
        guard !darkest.isEmpty else { return nil }
        let ink = (darkest.map(\.0).reduce(0, +) / Double(darkest.count), darkest.map(\.1).reduce(0, +) / Double(darkest.count),
                   darkest.map(\.2).reduce(0, +) / Double(darkest.count))
        let contrast = distance(ink, background)
        guard contrast > 0.12 else { return nil }
        // Stroke pixels: nearer the ink than the background, by a margin (anti-aliased edges included).
        var mask = [Bool](repeating: false, count: pw * ph)
        for i in mask.indices {
            let c = colors[i]
            mask[i] = distance(c, background) > contrast * 0.28 && distance(c, ink) < distance(c, background) * 1.6
        }
        // Only the shapes that reach into the words' box.
        var label = [Int](repeating: 0, count: pw * ph)
        var keep: Set<Int> = [0]
        var next = 1
        for start in mask.indices where mask[start] && label[start] == 0 {
            var stack = [start]
            label[start] = next
            var touches = false
            while let i = stack.popLast() {
                let x = i % pw, y = i / pw
                if x >= bx0, x < bx1, y >= by0, y < by1 { touches = true }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < pw, ny >= 0, ny < ph else { continue }
                    let j = ny * pw + nx
                    if mask[j], label[j] == 0 { label[j] = next; stack.append(j) }
                }
            }
            if touches { keep.insert(next) }
            next += 1
        }
        for i in mask.indices where mask[i] && !keep.contains(label[i]) { mask[i] = false }
        // Grown a little: the soft edges of the strokes.
        let grow = max(1, Int(thickness / 18))
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
        // Filled across from what is beside them.
        var filled = colors
        let lines = run.vertical ? pw : ph, length = run.vertical ? ph : pw
        func index(_ line: Int, _ k: Int) -> Int { run.vertical ? k * pw + line : line * pw + k }
        for line in 0..<lines {
            var k = 0
            while k < length {
                guard grown[index(line, k)] else { k += 1; continue }
                var end = k
                while end < length, grown[index(line, end)] { end += 1 }
                let a = k > 0 ? colors[index(line, k - 1)] : background
                let b = end < length ? colors[index(line, end)] : background
                for m in k..<end {
                    let t = Double(m - k + 1) / Double(end - k + 1)
                    filled[index(line, m)] = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
                }
                k = end
            }
        }
        var bytes = [UInt8](repeating: 255, count: pw * ph * 4)
        for i in filled.indices {
            bytes[i * 4] = UInt8(max(0, min(255, filled[i].0 * 255)))
            bytes[i * 4 + 1] = UInt8(max(0, min(255, filled[i].1 * 255)))
            bytes[i * 4 + 2] = UInt8(max(0, min(255, filled[i].2 * 255)))
        }
        let patch = Raster(width: pw, height: ph, bytes: bytes).image
        return (patch, CGRect(x: px, y: py, width: pw, height: ph), RGBColor(r: ink.0, g: ink.1, b: ink.2))
    }

    private static func median(_ colors: [(Double, Double, Double)]) -> (Double, Double, Double) {
        guard !colors.isEmpty else { return (1, 1, 1) }
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return (mid(colors.map(\.0)), mid(colors.map(\.1)), mid(colors.map(\.2)))
    }

    // MARK: How the labels stand

    /// For each run: its group (runs set one under the other, of about one size, overlapping across) and how the group is
    /// aligned — left edges, right edges or centres in line, whichever lines up best. A run alone keeps its centre.
    static func arrange(_ runs: [Run]) -> [(group: Int, alignment: Alignment)] {
        var parent = Array(runs.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
        for i in runs.indices {
            for j in runs.indices where j > i && !runs[i].vertical && !runs[j].vertical {
                let a = runs[i].box, b = runs[j].box
                let gap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                let size = max(a.height, b.height)
                guard gap < size * 0.8, max(a.height, b.height) < min(a.height, b.height) * 1.4,
                      min(a.maxX, b.maxX) - max(a.minX, b.minX) > -size * 0.2 else { continue }
                parent[root(j)] = root(i)
            }
        }
        var result = [(group: Int, alignment: Alignment)](repeating: (0, .center), count: runs.count)
        for (key, members) in Dictionary(grouping: runs.indices, by: root) {
            var alignment: Alignment = .center
            if members.count >= 2 {
                let boxes: [CGRect] = members.map { runs[$0].box }
                func spread(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }
                let left = spread(boxes.map { $0.minX }), center = spread(boxes.map { $0.midX }), right = spread(boxes.map { $0.maxX })
                alignment = left <= center && left <= right ? .left : (center <= right ? .center : .right)
            }
            for m in members { result[m] = (key, alignment) }
        }
        return result
    }

    // MARK: Drawing

    /// Vision's names for the source language's script (Latin text is read too: labels mix them).
    static func recognitionLanguages(for language: String) -> [String] {
        switch language.lowercased() {
        case "zh", "zh-cn", "zh-hans": ["zh-Hans", "en-US"]
        case "zh-tw", "zh-hant": ["zh-Hant", "en-US"]
        case "ja": ["ja-JP", "en-US"]
        case "ko": ["ko-KR", "en-US"]
        case "fr": ["fr-FR", "en-US"]
        case "de": ["de-DE", "en-US"]
        case "es": ["es-ES", "en-US"]
        case "it": ["it-IT", "en-US"]
        case "pt": ["pt-BR", "en-US"]
        case "ru": ["ru-RU", "en-US"]
        default: ["en-US"]
        }
    }

    /// A translation set in a run's place: its font size and how much it is narrowed so that it never runs past the words.
    private struct Fit {
        var size: Double
        var squeeze: Double
        var width: Double
    }

    private static func font(_ size: Double, language: String) -> CTFont {
        let cjk = ["zh", "ja", "ko"].contains { language.lowercased().hasPrefix($0) }
        return CTFontCreateWithName((cjk ? "PingFang SC" : "Helvetica") as CFString, max(size, 1), nil)
    }

    private static func measure(_ text: String, size: Double, language: String) -> Double {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font(size, language: language)]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    private static func fit(_ text: String, length: Double, thickness: Double, language: String, size given: Double? = nil, natural: Double? = nil) -> Fit {
        var size = given ?? natural ?? thickness * 0.82
        var width = measure(text, size: size, language: language)
        if given == nil, width > length {
            size = max(thickness * 0.5, size * length / max(width, 0.01))
            width = measure(text, size: size, language: language)
        }
        var squeeze = width > length ? max(0.75, length / width) : 1
        if width * squeeze > length {
            // Still too long: smaller, never past the words.
            size *= length / (width * squeeze)
            width = measure(text, size: size, language: language)
            squeeze = width > length ? length / width : 1
        }
        return Fit(size: size, squeeze: squeeze, width: width * squeeze)
    }

    /// The translations of a page's pictures: first every patch (the words taken out), then the translations, a
    /// group's lines at one size, each aligned as the words were.
    static func draw(_ entries: [(line: Line, translation: String)], language: String, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        for entry in entries { if let patch = entry.line.patch { context.draw(patch, in: entry.line.patchRect) } }
        context.restoreGState()
        func length(_ line: Line) -> Double { line.vertical ? line.rect.height : line.rect.width }
        func thickness(_ line: Line) -> Double { line.vertical ? line.rect.width : line.rect.height }
        var fits = entries.map { fit($0.translation, length: length($0.line), thickness: thickness($0.line), language: language, natural: $0.line.size) }
        // One size for a group: the smallest any of its lines needs.
        for (_, members) in Dictionary(grouping: entries.indices, by: { entries[$0].line.group }) where members.count > 1 {
            let size = members.map { fits[$0].size }.min()!
            for m in members {
                fits[m] = fit(entries[m].translation, length: length(entries[m].line), thickness: thickness(entries[m].line), language: language, size: size)
            }
        }
        for (k, entry) in entries.enumerated() {
            let line = entry.line, f = fits[k]
            let color = CGColor(red: line.color.r, green: line.color.g, blue: line.color.b, alpha: 1)
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: entry.translation, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font(f.size, language: language), kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            ]))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil)
            let room = length(line) - f.width
            let offset = switch line.alignment {
            case .left: 0.0
            case .center: room / 2
            case .right: room
            }
            let rise = (thickness(line) - (ascent + descent)) / 2 + descent
            context.saveGState()
            if line.vertical && line.readsDown {
                // Reading down the page: turned a quarter clockwise, the tops of the letters to the right.
                context.translateBy(x: line.rect.minX + rise, y: line.rect.maxY - offset)
                context.rotate(by: -.pi / 2)
            } else if line.vertical {
                // Reading up the page: turned a quarter anticlockwise, the tops of the letters to the left.
                context.translateBy(x: line.rect.maxX - rise, y: line.rect.minY + offset)
                context.rotate(by: .pi / 2)
            } else {
                context.translateBy(x: line.rect.minX + offset, y: line.rect.minY + rise)
            }
            context.textMatrix = CGAffineTransform(scaleX: f.squeeze, y: 1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
    }
}
