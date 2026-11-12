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
        /// The words' font size, as measured from their ink (pictures) or as the page sets them (vectors).
        var size: Double?
        /// Where the words stand on the page (lines across): their baseline.
        var baseline: Double?
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

        /// Turned a quarter anticlockwise: text that read down the page reads across.
        func turnedCounterClockwise() -> Raster {
            var out = [UInt8](repeating: 255, count: bytes.count)
            for y in 0..<height {
                for x in 0..<width {
                    let source = (y * width + x) * 4
                    let target = ((width - 1 - x) * height + y) * 4
                    out[target] = bytes[source]; out[target + 1] = bytes[source + 1]; out[target + 2] = bytes[source + 2]
                }
            }
            return Raster(width: height, height: width, bytes: out)
        }

        /// The part of the picture in `rect` (pixels).
        func cropped(_ rect: CGRect) -> Raster {
            let x0 = max(0, Int(rect.minX)), y0 = max(0, Int(rect.minY))
            let x1 = min(width, Int(rect.maxX)), y1 = min(height, Int(rect.maxY))
            var out = [UInt8](repeating: 255, count: max(0, x1 - x0) * max(0, y1 - y0) * 4)
            for y in y0..<max(y1, y0) {
                let from = (y * width + x0) * 4, to = ((y - y0) * (x1 - x0)) * 4
                out.replaceSubrange(to..<(to + (x1 - x0) * 4), with: bytes[from..<(from + (x1 - x0) * 4)])
            }
            return Raster(width: x1 - x0, height: y1 - y0, bytes: out)
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
        /// The edge it keeps when it stands alone: the side an icon was read at (a check mark before the words).
        var anchor: Alignment?
        /// Set sideways reading down the page (the tops of the letters to the right).
        var readsDown = false
        var confidence: Float = 1
        /// Which way the line reads, as text recognition saw it (pixels, rows down).
        var direction = CGVector(dx: 1, dy: 0)
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
            // The picture as it shows on the page, sharp enough to read small labels (3 pt labels: 24 pixels high).
            let scale = max(2.5, min(8, 4000 / max(rect.width, rect.height)))
            guard let raster = render(page: page, rect: rect, scale: scale) else { continue }
            // Lines across (text set sideways comes out of an upright reading as a tall box: read below, turned).
            let upright = read(raster, languages: languages)
            var runs = upright.filter { $0.box.height < $0.box.width * 1.2 || $0.text.count <= 1 }
            // Sideways text read upright: which way its baseline runs tells which way it reads.
            let turnedLines = upright.filter { $0.box.height >= $0.box.width * 1.2 && abs($0.direction.dy) > abs($0.direction.dx) }
            // Sideways labels: read on the picture turned a quarter each way, where they lie across. Words read both
            // ways (upside down too) are taken the way they read best.
            var sideways: [Run] = []
            for var run in read(raster.turnedClockwise(), languages: languages) {
                // Back to the picture: x' = h - 1 - y, y' = x.
                let box = run.box
                run.box = CGRect(x: box.minY, y: Double(raster.height) - box.maxX, width: box.height, height: box.width)
                run.vertical = true
                sideways.append(run)
            }
            for var run in read(raster.turnedCounterClockwise(), languages: languages) {
                // Back: x' = y, y' = w - 1 - x.
                let box = run.box
                run.box = CGRect(x: Double(raster.width) - box.maxY, y: box.minX, width: box.height, height: box.width)
                run.vertical = true
                run.readsDown = true
                sideways.append(run)
            }
            // Which way each reads: as text recognition saw it upright, else by its letters; labels neither can tell
            // (short ones, few tall letters) read as most of the picture's do.
            let decided: [Bool?] = sideways.map { run in
                if let seen = turnedLines.first(where: { area($0.box.intersection(run.box)) > area(run.box) * 0.3 }) { return seen.direction.dy > 0 }
                return readsDown(run, raster: raster)
            }
            let down = decided.filter { $0 == true }.count, up = decided.filter { $0 == false }.count
            let usual: Bool? = down > up ? true : (up > down ? false : nil)
            for k in sideways.indices {
                guard let way = decided[k] ?? usual else { continue }
                if sideways[k].readsDown == way { sideways[k].confidence += 0.5 }
                sideways[k].readsDown = way
            }
            sideways.sort { ($0.confidence, $0.text.count) > ($1.confidence, $1.text.count) }
            for run in sideways where run.box.height > run.box.width * 1.5 {
                if runs.contains(where: { area($0.box.intersection(run.box)) > area(run.box) * 0.2 }) { continue }
                runs.append(run)
            }
            // Words of one label read apart (or cut at a space a little wide) are one run again.
            runs = joinedAcross(runs, raster: raster)
            // In reading order: row by row, each row from the left.
            runs.sort { a, b in
                abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5 ? a.box.minX < b.box.minX : a.box.midY < b.box.midY
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
                // Text too small to read in print (the buttons of a screenshot): left as it is.
                if let size = erased.size, size / scale < 1.7 { continue }
                var line = Line(page: number, rect: box, text: run.text, color: erased.color, patch: erased.patch,
                                patchRect: pageRect(erased.area), vertical: run.vertical, readsDown: run.readsDown)
                if let size = erased.size { line.size = size / scale }
                if let baseline = erased.baseline { line.baseline = rect.maxY - baseline / scale }
                found.append((run, line))
            }
            // One size for words set at one size (measured sizes differ a little from label to label).
            for vertical in [false, true] {
                let sizes = harmonized(found.map { $0.line.vertical == vertical ? $0.line.size : nil })
                for k in found.indices where sizes[k] != nil { found[k].line.size = sizes[k] }
            }
            // How the lines stand together.
            let placed = found.map(\.run)
            let arranged = arrange(placed, separated: { separated(placed[$0].box, placed[$1].box, raster: raster) })
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
            runs.append(Run(text: text, box: rect, vertical: true, readsDown: column[0].down))
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
                                      glyphs: chars.flatMap(\.glyphs), size: line.size, baseline: line.baseline))
                }
                for c in line.chars where !c.isRotated {
                    if let last = current.last(where: { !$0.isSpace }), !c.isSpace, c.rect.minX - last.rect.maxX > line.size * 1.1 { flush() }
                    current.append(c)
                }
                flush()
            }
        }
        let arranged = arrange(runs, yUp: true)
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

    /// A line as Vision read it: its words (text and rough pixel box from the top left) and the line's box.
    struct Reading {
        var words: [(String, CGRect)]
        var line: CGRect
        var confidence: Float
        /// Along the baseline, from the first letter on (pixels, rows down): which way the words read.
        var direction: CGVector
    }

    private static func observe(_ image: CGImage, languages: [String]) -> [Reading] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.minimumTextHeight = 0
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // Text recognition has been seen to wait forever on rare occasions: a minute, then this picture goes unread
        // rather than the translation never finishing.
        final class Outcome: @unchecked Sendable { var ok = false }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.ok = (try? handler.perform([request])) != nil
            done.signal()
        }
        if done.wait(timeout: .now() + 60) == .timedOut {
            request.cancel()
            return []
        }
        guard outcome.ok, let observations = request.results else { return [] }
        let w = Double(image.width), h = Double(image.height)
        func box(_ n: CGRect) -> CGRect { CGRect(x: n.minX * w, y: (1 - n.maxY) * h, width: n.width * w, height: n.height * h) }
        var result: [Reading] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { continue }
            let string = candidate.string
            let line = box(observation.boundingBox)
            var words: [(String, CGRect)] = []
            var index = string.startIndex
            for word in string.split(separator: " ", omittingEmptySubsequences: true) {
                guard let range = string.range(of: word, range: index..<string.endIndex) else { continue }
                index = range.upperBound
                let b = ((try? candidate.boundingBox(for: range)) ?? nil).map { box($0.boundingBox) } ?? line
                words.append((String(word), b))
            }
            if words.isEmpty { words = [(string, line)] }
            let direction = CGVector(dx: (observation.bottomRight.x - observation.bottomLeft.x) * w, dy: -(observation.bottomRight.y - observation.bottomLeft.y) * h)
            result.append(Reading(words: words, line: line, confidence: candidate.confidence, direction: direction))
        }
        return result
    }

    /// Runs of words read from `raster`, pixel boxes from the top left.
    /// Large pictures are read in tiles as well (overlapping, so that a label cut at a tile's edge is whole in the
    /// next): text recognition works on a picture made smaller, where small labels are lost. A line read in a tile
    /// wins; the whole picture's reading adds what the tiles missed (labels longer than the overlap).
    static func read(_ raster: Raster, languages: [String]) -> [Run] {
        guard let image = raster.image else { return [] }
        let latin = languages.allSatisfy { !["zh", "ja", "ko", "ru", "uk", "el", "ar", "he", "th"].contains(String($0.prefix(2))) }
        func runs(_ readings: [Reading]) -> [Run] {
            readings.flatMap { reading in
                Self.runs(in: reading, raster: raster, latinScript: latin).map { var r = $0; r.confidence = reading.confidence; r.direction = reading.direction; return r }
            }
        }
        let whole = runs(observe(image, languages: languages))
        let tile = 1400.0, overlap = 280.0
        guard Double(max(raster.width, raster.height)) > tile * 1.15 else { return whole }
        var tiled: [Reading] = []
        for y in stride(from: 0.0, to: Double(raster.height), by: tile - overlap) {
            for x in stride(from: 0.0, to: Double(raster.width), by: tile - overlap) {
                let frame = CGRect(x: x, y: y, width: tile, height: tile).intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
                guard frame.width > overlap, frame.height > overlap || y == 0, let part = raster.cropped(frame).image else { continue }
                for var reading in observe(part, languages: languages) {
                    reading.line = reading.line.offsetBy(dx: frame.minX, dy: frame.minY)
                    reading.words = reading.words.map { ($0.0, $0.1.offsetBy(dx: frame.minX, dy: frame.minY)) }
                    // Cut by the tile's edge (not the picture's): read whole elsewhere.
                    // (A word cut in half at the edge is left out of the line: a margin of more than a word's height.)
                    let line = reading.line, margin = max(3, line.height * 1.5)
                    if (line.minX < frame.minX + margin && frame.minX > 0) || (line.maxX > frame.maxX - margin && frame.maxX < Double(raster.width))
                        || (line.minY < frame.minY + 3 && frame.minY > 0) || (line.maxY > frame.maxY - 3 && frame.maxY < Double(raster.height)) { continue }
                    tiled.append(reading)
                }
                if frame.maxX >= Double(raster.width) { break }
            }
            if y + tile >= Double(raster.height) { break }
        }
        var accepted: [Run] = []
        func overlapping(_ run: Run) -> Bool {
            accepted.contains { area($0.box.intersection(run.box)) > min(area($0.box), area(run.box)) * 0.3 }
        }
        for var run in runs(tiled).sorted(by: { ($0.confidence, $0.text.count) > ($1.confidence, $1.text.count) }) where !overlapping(run) {
            // An icon the whole picture's reading saw beside these words.
            if run.anchor == nil, let seen = whole.first(where: { $0.anchor != nil && area($0.box.intersection(run.box)) > area(run.box) * 0.5 }) { run.anchor = seen.anchor }
            // A character at an end the tile's reading left out ("(d)" read as "d)").
            if let fuller = whole.first(where: { $0.text.count > run.text.count && ($0.text.hasSuffix(run.text) || $0.text.hasPrefix(run.text))
                && $0.text.count - run.text.count <= 2 && area($0.box.intersection(run.box)) > area(run.box) * 0.7 }) {
                run.text = fuller.text
                run.box = run.box.union(fuller.box)
            }
            accepted.append(run)
        }
        for run in whole where !overlapping(run) { accepted.append(run) }
        return accepted
    }

    /// A line read cut into runs where its ink leaves a wide gap (labels side by side read as one line), without the
    /// icons read as characters at its ends (a check mark read as "/", a red cross as "X"), and kept only when it reads
    /// as words. Each run's box is its own ink, across.
    static func runs(in reading: Reading, raster: Raster, latinScript: Bool = true) -> [Run] {
        let line = reading.line
        let h = max(line.height, 1)
        let background = ringColor(raster, line)
        let top = max(0, Int(line.minY.rounded(.down))), bottom = min(raster.height, Int(line.maxY.rounded(.up)))
        guard bottom > top else { return [] }
        func blank(_ x: Int) -> Bool {
            guard x >= 0, x < raster.width else { return true }
            for y in top..<bottom where distance(raster.pixel(x, y), background) > 0.3 { return false }
            return true
        }
        /// The widest stretch of blank columns between two x.
        func widestGap(_ from: Double, _ to: Double) -> Range<Int>? {
            let a = Int(from.rounded()), b = Int(to.rounded())
            guard b > a else { return nil }
            var best: Range<Int>?
            var start: Int?
            for x in a...b {
                if x < b, blank(x) {
                    if start == nil { start = x }
                } else if let s = start {
                    if x - s > (best?.count ?? 0) { best = s..<x }
                    start = nil
                }
            }
            return best
        }
        // Markers read stuck to a word ("→Multi-scale", "figure)→"): words of their own.
        var words: [(String, CGRect)] = []
        for (token, box) in reading.words {
            let chars = Array(token)
            var lead = 0, trail = chars.count
            while lead < chars.count - 1, isMarker(chars[lead]) { lead += 1 }
            while trail > lead + 1, isMarker(chars[trail - 1]) { trail -= 1 }
            let n = Double(max(chars.count, 1))
            func part(_ a: Int, _ b: Int) -> CGRect { CGRect(x: box.minX + box.width * Double(a) / n, y: box.minY, width: box.width * Double(b - a) / n, height: box.height) }
            if lead > 0 { words.append((String(chars[0..<lead]), part(0, lead))) }
            words.append((String(chars[lead..<trail]), part(lead, trail)))
            if trail < chars.count { words.append((String(chars[trail...]), part(trail, chars.count))) }
        }
        var left = line.minX, right = line.maxX
        /// An icon read as a character: no letter or digit in it, or a lone letter inked in another colour than the words.
        func isIcon(_ k: Int, beside other: Int) -> Bool {
            let token = words[k].0
            // Brackets and quotes are the text's own ("(d)" read as "( d)").
            if !token.contains(where: { $0.isLetter || $0.isNumber }) { return !token.allSatisfy { "()[]{}\"'“”‘’.,:;!?…".contains($0) } }
            guard token.count == 1, token.first!.isLetter, !["a", "A", "I"].contains(token) else { return false }
            let a = inkColor(raster, words[k].1, background: background), b = inkColor(raster, words[other].1, background: background)
            return distance(a, b) > 0.45
        }
        /// Past an icon's ink, from `x` on, `step` ±1: where the words' ink starts. An icon in a colour of its own ends
        /// where that colour does (an italic letter may lean into it); one in the words' colour at the blank after it.
        func past(_ x: Int, step: Int, icon: CGRect, words other: CGRect) -> Int? {
            let iconInk = inkColor(raster, icon, background: background), wordInk = inkColor(raster, other, background: background)
            let coloured = distance(iconInk, wordInk) > 0.45
            func hasIcon(_ x: Int) -> Bool {
                let near = distance(iconInk, background) * 0.35
                for y in top..<bottom where distance(raster.pixel(x, y), iconInk) < near { return true }
                return false
            }
            var x = x, sawIcon = false, sawBlank = false
            while x >= 0, x < raster.width {
                let empty = blank(x)
                if coloured {
                    let icon = !empty && hasIcon(x)
                    if icon { sawIcon = true } else if sawIcon, !empty { return x }
                } else {
                    if !empty, sawBlank { return x }
                    if !empty { sawIcon = true } else if sawIcon { sawBlank = true }
                }
                x += step
            }
            return nil
        }
        var anchor: Alignment?
        while words.count > 1, isIcon(0, beside: 1) {
            left = past(Int(min(line.minX, words[0].1.minX)), step: 1, icon: words[0].1, words: words[1].1).map(Double.init) ?? words[1].1.minX
            words.removeFirst()
            anchor = .left
        }
        while words.count > 1, isIcon(words.count - 1, beside: words.count - 2) {
            right = past(Int(max(line.maxX, words[words.count - 1].1.maxX)) - 1, step: -1, icon: words[words.count - 1].1,
                         words: words[words.count - 2].1).map { Double($0 + 1) } ?? words[words.count - 2].1.maxX
            words.removeLast()
            anchor = anchor ?? .right
        }
        // Cut where the gap between two words is far wider than a space: than about a quarter of the em, or than the
        // line's other spaces.
        let size = em(CGRect(x: left, y: line.minY, width: max(right - left, 1), height: line.height), raster: raster)
        let gaps: [Range<Int>?] = words.indices.dropFirst().map { widestGap(words[$0 - 1].1.midX, words[$0].1.midX) }
        // An icon between words (an arrow in a legend) ends one label and starts another, which keeps its left edge.
        func between(_ k: Int) -> Bool {
            let token = words[k].0
            return k > 0 && k < words.count - 1 && !token.contains { $0.isLetter || $0.isNumber } && !token.allSatisfy { "()[]{}\"'“”‘’.,:;!?…&+=-–—/".contains($0) }
        }
        var pieces: [(words: [String], minX: Double, maxX: Double, afterIcon: Bool, beforeIcon: Bool)] = [([words[0].0], left, right, anchor == .left, anchor == .right)]
        var k = 1
        while k < words.count {
            if between(k) {
                pieces[pieces.count - 1].maxX = widestGap(words[k - 1].1.midX, words[k].1.midX).map { Double($0.lowerBound) } ?? words[k].1.minX
                pieces[pieces.count - 1].beforeIcon = true
                let start = past(Int(words[k].1.minX), step: 1, icon: words[k].1, words: words[k + 1].1).map(Double.init) ?? words[k + 1].1.minX
                pieces.append(([words[k + 1].0], start, right, true, anchor == .right))
                k += 2
                continue
            }
            let width = Double(gaps[k - 1]?.count ?? 0)
            let others = gaps.enumerated().filter { $0.offset != k - 1 }.map { Double($0.element?.count ?? 0) }.sorted()
            let usual = others.isEmpty ? nil : others[others.count / 2]
            if let gap = gaps[k - 1], width > size * 0.9 || (usual.map { width > max($0, 1) * 2.5 } ?? false && width > size * 0.45) {
                pieces[pieces.count - 1].maxX = Double(gap.lowerBound)
                pieces[pieces.count - 1].beforeIcon = false
                pieces.append(([words[k].0], Double(gap.upperBound), right, false, anchor == .right))
            } else {
                pieces[pieces.count - 1].words.append(words[k].0)
            }
            k += 1
        }
        var result: [Run] = []
        for piece in pieces {
            // Just the ink across (Vision's boxes run wide).
            var minX = Int(piece.minX.rounded(.down)), maxX = Int(piece.maxX.rounded(.up))
            while minX < maxX, blank(minX) { minX += 1 }
            while maxX > minX, blank(maxX - 1) { maxX -= 1 }
            guard maxX > minX else { continue }
            // An icon at either end that was not read as a character: a small shape in a colour of its own, apart.
            var edge: Alignment?
            func icon(at start: Int, step: Int) -> Int? {
                var x = start
                while x != (step > 0 ? maxX : minX - 1), !blank(x) { x += step }
                let shape = abs(x - start)
                var y = x
                while y != (step > 0 ? maxX : minX - 1), blank(y) { y += step }
                guard shape > 0, Double(shape) < size * 1.3, Double(abs(y - x)) >= size * 0.15, y != (step > 0 ? maxX : minX - 1) else { return nil }
                // The shape may begin outside the box (only its edge read with the words): all of it.
                var outer = start
                while outer - step >= 0, outer - step < raster.width, abs(outer - step - start) < Int(size * 1.3), !blank(outer - step) { outer -= step }
                let shapeBox = CGRect(x: Double(min(outer, x - step)), y: line.minY, width: Double(abs(x - outer)), height: line.height)
                let rest = step > 0 ? CGRect(x: Double(y), y: line.minY, width: Double(maxX - y), height: line.height)
                                    : CGRect(x: Double(minX), y: line.minY, width: Double(y + 1 - minX), height: line.height)
                return coloured(inkColor(raster, shapeBox, background: background), apartFrom: inkColor(raster, rest, background: background)) ? y : nil
            }
            if let start = icon(at: minX, step: 1) { minX = start; edge = .left }
            if let end = icon(at: maxX - 1, step: -1) { maxX = end + 1; edge = edge ?? .right }
            // Or just outside it (read apart): the words keep that edge.
            func iconBeside(_ from: Int, step: Int) -> Bool {
                var x = from
                while abs(x - from) < Int(size * 1.2), x >= 0, x < raster.width, blank(x) { x += step }
                guard abs(x - from) < Int(size * 1.2), x >= 0, x < raster.width else { return false }
                let start = x
                while abs(x - start) <= Int(size * 1.3), x >= 0, x < raster.width, !blank(x) { x += step }
                guard abs(x - start) <= Int(size * 1.3), x >= 0, x < raster.width else { return false }
                let shape = CGRect(x: Double(min(start, x)), y: line.minY, width: Double(abs(x - start)), height: line.height)
                // An icon is about a letter wide (not a thin line).
                guard shape.width >= size * 0.3 else { return false }
                // Part of something larger (a box's edge, a line running past the words): not an icon.
                for row in [Int(line.minY - size * 0.45), Int(line.maxY + size * 0.45)] {
                    for column in Int(shape.minX)..<Int(shape.maxX) where distance(raster.pixel(column, row), background) > 0.3 { return false }
                }
                let words = CGRect(x: Double(minX), y: line.minY, width: Double(maxX - minX), height: line.height)
                return coloured(inkColor(raster, shape, background: background), apartFrom: inkColor(raster, words, background: background))
            }
            if piece.afterIcon { edge = .left }
            if edge == nil, anchor == nil, iconBeside(minX - 1, step: -1) { edge = .left }
            // A long line set just after a shape (a legend's entry after its marker) keeps its start there.
            if edge == nil, anchor == nil, Double(maxX - minX) > size * 5 {
                let rows = Int(line.minY + line.height * 0.2)..<Int(line.maxY - line.height * 0.2)
                let near = (max(0, minX - Int(size * 0.6))..<minX).contains { x in rows.contains { distance(raster.pixel(x, $0), background) > 0.3 } }
                if near { edge = .left }
            }
            if edge == nil, anchor == nil, iconBeside(maxX, step: 1) { edge = .right }
            var text = piece.words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            while let last = text.last, ",;".contains(last) { text.removeLast() }
            guard isWords(text), isReadable(text, latinScript: latinScript) else { continue }
            let first = result.isEmpty && piece.minX == left, last = piece.maxX == right
            result.append(Run(text: text, box: CGRect(x: Double(minX), y: line.minY, width: Double(maxX - minX), height: line.height), vertical: false,
                              anchor: edge ?? (anchor == .left && first ? .left : (anchor == .right && last ? .right : nil))))
        }
        return result
    }

    static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) }

    /// A character that marks rather than spells: arrows, bullets, check marks and other symbols (not + = × % °).
    static func isMarker(_ c: Character) -> Bool {
        if "→←↑↓⇒⇐➔➜►▶▸•▪■●○◆◇★☆✓✔✗✘><*".contains(c) { return true }
        if "+=×±÷~%°".contains(c) { return false }
        return c.unicodeScalars.allSatisfy { [.mathSymbol, .otherSymbol].contains($0.properties.generalCategory) }
    }

    /// A shape inked in a colour of its own (a red cross, a green check mark), not the words' colour a little lighter
    /// (a thin bracket's ink is greyer than the letters').
    static func coloured(_ shape: (Double, Double, Double), apartFrom words: (Double, Double, Double)) -> Bool {
        func chroma(_ c: (Double, Double, Double)) -> Double { max(c.0, c.1, c.2) - min(c.0, c.1, c.2) }
        return distance(shape, words) > 0.45 && chroma(shape) > 0.3 && abs(chroma(shape) - chroma(words)) > 0.2
    }

    /// The colour just around `box`: what the words stand on.
    static func ringColor(_ raster: Raster, _ box: CGRect) -> (Double, Double, Double) {
        var ring: [(Double, Double, Double)] = []
        let x0 = Int(box.minX) - 2, x1 = Int(box.maxX) + 2, y0 = Int(box.minY) - 2, y1 = Int(box.maxY) + 2
        let step = max(1, (x1 - x0 + y1 - y0) / 160)
        for x in stride(from: x0, through: x1, by: step) { ring.append(raster.pixel(x, y0)); ring.append(raster.pixel(x, y1)) }
        for y in stride(from: y0, through: y1, by: step) { ring.append(raster.pixel(x0, y)); ring.append(raster.pixel(x1, y)) }
        return median(ring)
    }

    /// The colour of the ink in `box`: its pixels most unlike the background.
    static func inkColor(_ raster: Raster, _ box: CGRect, background: (Double, Double, Double)) -> (Double, Double, Double) {
        var pixels: [(Double, Double, Double)] = []
        for y in Int(box.minY)..<max(Int(box.maxY), Int(box.minY) + 1) { for x in Int(box.minX)..<max(Int(box.maxX), Int(box.minX) + 1) { pixels.append(raster.pixel(x, y)) } }
        pixels.sort { distance($0, background) > distance($1, background) }
        let top = pixels.prefix(max(1, pixels.count / 10))
        let n = Double(top.count)
        return (top.map(\.0).reduce(0, +) / n, top.map(\.1).reduce(0, +) / n, top.map(\.2).reduce(0, +) / n)
    }

    /// Whether two runs, one above the other, have a line drawn between them (a box's edge: not one label).
    static func separated(_ a: CGRect, _ b: CGRect, raster: Raster) -> Bool {
        let upper = a.minY < b.minY ? a : b, lower = a.minY < b.minY ? b : a
        let x0 = Int(max(a.minX, b.minX)), x1 = Int(min(a.maxX, b.maxX))
        guard x1 - x0 >= 4 else { return false }
        let background = ringColor(raster, upper)
        let from = Int(upper.maxY.rounded(.down)), to = Int(lower.minY.rounded(.up))
        guard to > from else { return false }
        for y in from...to {
            var ink = 0
            for x in x0..<x1 where distance(raster.pixel(x, y), background) > 0.3 { ink += 1 }
            if Double(ink) > Double(x1 - x0) * 0.6 { return true }
        }
        return false
    }

    /// The words' em from their ink: the band the small letters fill is about half of it.
    static func em(_ box: CGRect, raster: Raster, vertical: Bool = false) -> Double {
        let background = ringColor(raster, box)
        let across = vertical ? Int(box.width) : Int(box.height), along = vertical ? Int(box.height) : Int(box.width)
        guard across > 0, along > 0 else { return vertical ? box.width : box.height }
        var counts = [Int](repeating: 0, count: across)
        for a in 0..<across {
            for b in stride(from: 0, to: along, by: max(1, along / 300)) {
                let p = vertical ? raster.pixel(Int(box.minX) + a, Int(box.minY) + b) : raster.pixel(Int(box.minX) + b, Int(box.minY) + a)
                if distance(p, background) > 0.3 { counts[a] += 1 }
            }
        }
        let most = counts.max() ?? 0
        let thickness = vertical ? box.width : box.height
        guard most > 0 else { return thickness }
        let dense = counts.indices.filter { Double(counts[$0]) >= Double(most) * 0.35 }
        let band = Double((dense.last ?? 0) - (dense.first ?? 0) + 1)
        return min(max(band / 0.48, thickness * 0.5), thickness * 1.5)
    }

    /// Runs on one line, of one size, closer than a wide space: one run (Vision may read one label as two).
    static func joinedAcross(_ runs: [Run], raster: Raster) -> [Run] {
        var runs = runs
        var merged = true
        while merged {
            merged = false
            outer: for i in runs.indices where !runs[i].vertical {
                for j in runs.indices where j != i && !runs[j].vertical {
                    let a = runs[i].box, b = runs[j].box
                    guard a.minX < b.minX, abs(a.midY - b.midY) < min(a.height, b.height) * 0.35,
                          max(a.height, b.height) < min(a.height, b.height) * 1.3 else { continue }
                    let gap = b.minX - a.maxX
                    let size = em(a.union(b), raster: raster)
                    guard gap > -size * 0.3, gap < size * 0.9 else { continue }
                    // Far wider than the spaces between their own words: two labels side by side.
                    // (A space is wider than the gaps between letters, a sixth of the em at least.)
                    let space = max(innerSpace(a, raster: raster), innerSpace(b, raster: raster))
                    if space > size * 0.16, gap > space * 2.5, gap > size * 0.45 { continue }
                    runs[i].text += " " + runs[j].text
                    runs[i].box = a.union(b)
                    runs[i].confidence = min(runs[i].confidence, runs[j].confidence)
                    if runs[j].anchor == .right { runs[i].anchor = runs[i].anchor == .left ? nil : .right }
                    runs.remove(at: j)
                    merged = true
                    break outer
                }
            }
        }
        return runs
    }

    /// The widest blank between the words inside a run (0 when it has none).
    static func innerSpace(_ box: CGRect, raster: Raster) -> Double {
        let background = ringColor(raster, box)
        func blank(_ x: Int) -> Bool {
            for y in Int(box.minY)..<max(Int(box.maxY), Int(box.minY) + 1) where distance(raster.pixel(x, y), background) > 0.3 { return false }
            return true
        }
        var widest = 0, current = 0, inked = false
        for x in Int(box.minX)..<max(Int(box.maxX), Int(box.minX) + 1) {
            if blank(x) { current += 1 } else { if inked { widest = max(widest, current) }; current = 0; inked = true }
        }
        return Double(widest)
    }

    /// Which way a sideways run of Latin letters reads: the tops of its letters face the side where more ink lies past
    /// the band of the small letters (ascenders outnumber descenders). Nil when it cannot tell.
    static func readsDown(_ run: Run, raster: Raster) -> Bool? {
        guard run.text.contains(where: { $0.isASCII && $0.isLetter }) else { return nil }
        let box = run.box
        let background = ringColor(raster, box)
        let across = Int(box.width), along = Int(box.height)
        guard across > 2, along > 2 else { return nil }
        var counts = [Int](repeating: 0, count: across)
        for a in 0..<across { for b in 0..<along where distance(raster.pixel(Int(box.minX) + a, Int(box.minY) + b), background) > 0.3 { counts[a] += 1 } }
        guard let most = counts.max(), most > 0 else { return nil }
        let dense = counts.indices.filter { Double(counts[$0]) >= Double(most) * 0.35 }
        guard let d0 = dense.first, let d1 = dense.last else { return nil }
        let left = counts[..<d0].reduce(0, +), right = counts[(d1 + 1)...].reduce(0, +)
        guard max(left, right) > min(left, right) * 3 / 2 + 2 else { return nil }
        // Tops to the right: reading down the page.
        return right > left
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Words worth translating: more letters than digits, not two letters or an abbreviation alone.
    static func isWords(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter).count, digits = text.filter(\.isNumber).count
        guard letters >= 2, letters > digits else { return false }
        // A word of two letters alone is a variable or an abbreviation (C₂ read as "Cz") more often than a word.
        if !text.contains(" "), letters <= 2 { return false }
        if !text.contains(" "), letters <= 4, text.filter(\.isLetter).allSatisfy(\.isUppercase) { return false }
        return true
    }

    /// Words, not a misreading: at most a quarter of them have characters that words do not (a "!" inside one, a symbol),
    /// mix scripts (Latin letters with Chinese characters; in a Latin-script paper, Cyrillic or Arabic letters at all) or
    /// switch between letters and digits back and forth.
    static func isReadable(_ text: String, latinScript: Bool = true) -> Bool {
        let tokens = text.split(separator: " ")
        guard !tokens.isEmpty else { return false }
        let allowed = Set("-–—/&+%'’.,:;()[]·×°=<>~#_")
        var odd = 0
        for token in tokens {
            let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}\"'“”‘’,.;:!?"))
            guard !core.isEmpty else { odd += 1; continue }
            let strange = core.contains { !($0.isLetter || $0.isNumber || allowed.contains($0)) }
            let latin = core.contains { $0.isASCII && $0.isLetter }
            let han = core.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
            // In a paper in a Latin script, letters of another script than Latin or Greek (α, β) are misreadings.
            let foreign = latinScript && core.unicodeScalars.contains { $0.properties.isAlphabetic && !(0x0000...0x024F).contains($0.value)
                && !(0x0370...0x03FF).contains($0.value) && !(0x1E00...0x1EFF).contains($0.value) }
            var switches = 0
            var last: Bool?
            for c in core where c.isLetter || c.isNumber {
                if let last, last != c.isNumber { switches += 1 }
                last = c.isNumber
            }
            // A word has two letters at least; a number, "a" or "I" stand alone too: a lone letter or a scrap of
            // figures and letters ("/T0", "e") is a misreading.
            let letterCount = core.filter(\.isLetter).count
            let number = core.allSatisfy { $0.isNumber || ".,%".contains($0) } && core.contains(where: \.isNumber)
            let scrap = letterCount < 2 && !number && !["a", "A", "I", "&", "+", "-", "×"].contains(core) && !han
            // A short word with a capital after a small letter ("eO") or two marks inside ("eO/'") is not a word either.
            let chars = Array(core)
            let flipped = letterCount <= 4 && chars.indices.dropFirst().contains { chars[$0].isUppercase && chars[$0 - 1].isLowercase }
            let marks = core.count <= 5 && core.filter({ !$0.isLetter && !$0.isNumber }).count >= 2
            // Sizes such as 1x1, 3×3 or 10x10 are written so.
            let dimension = core.wholeMatch(of: /\d+[x×]\d+[A-Za-z]*/) != nil
            if !dimension && (strange || (latin && han) || foreign || switches >= 2 || scrap || flipped || marks) { odd += 1 }
        }
        return odd * 4 <= tokens.count
    }

    // MARK: Taking the words out

    /// The words' strokes: pixels unlike the background around them and like the words' ink, as far as they belong to
    /// shapes touching the words' own box (an arrowhead beside a label is a shape of its own and stays). They are filled
    /// across from what is beside them (across rows for words across, columns for words up the page).
    static func erase(_ run: Run, raster: Raster) -> (patch: CGImage?, area: CGRect, color: RGBColor, size: Double?, baseline: Double?)? {
        let box = run.box
        let thickness = run.vertical ? box.width : box.height
        let along = thickness * 0.3, across = thickness * 0.12
        let area = box.insetBy(dx: -(run.vertical ? across : along), dy: -(run.vertical ? along : across))
            .intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        let px = Int(area.minX.rounded(.down)), py = Int(area.minY.rounded(.down))
        let pw = Int(area.maxX.rounded(.up)) - px, ph = Int(area.maxY.rounded(.up)) - py
        guard pw > 2, ph > 2, pw * ph < 4_000_000 else { return nil }
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
        // Only the shapes that reach into the words' box, and are letters: not a line running through or along them
        // (a box's edge, a dashed border), which stays.
        var label = [Int](repeating: 0, count: pw * ph)
        var keep: Set<Int> = [0]
        var next = 1
        for start in mask.indices where mask[start] && label[start] == 0 {
            var stack = [start]
            label[start] = next
            var touches = false
            var x0 = pw, x1 = 0, y0 = ph, y1 = 0
            defer {
                let across = run.vertical ? (x0, x1, pw) : (y0, y1, ph)
                let extentAcross = Double(across.1 - across.0 + 1), extentAlong = Double(run.vertical ? y1 - y0 + 1 : x1 - x0 + 1)
                let crossing = across.0 == 0 && across.1 == across.2 - 1
                let rule = extentAcross <= max(2, thickness * 0.12) && extentAlong >= thickness * 1.5
                // Mostly outside the words' box along the line (a bracket the reading left out, an icon): not theirs.
                let alongRange = run.vertical ? (y0, y1, by0, by1) : (x0, x1, bx0, bx1)
                let inside = Double(max(0, min(alongRange.1 + 1, alongRange.3) - max(alongRange.0, alongRange.2)))
                let outside = inside < extentAlong * 0.3
                if touches && !crossing && !rule && !outside { keep.insert(next) }
                next += 1
            }
            while let i = stack.popLast() {
                let x = i % pw, y = i / pw
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                if x >= bx0, x < bx1, y >= by0, y < by1 { touches = true }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < pw, ny >= 0, ny < ph else { continue }
                    let j = ny * pw + nx
                    if mask[j], label[j] == 0 { label[j] = next; stack.append(j) }
                }
            }
        }
        for i in mask.indices where mask[i] && !keep.contains(label[i]) { mask[i] = false }
        // The words' size, from their ink (Vision's boxes are taller or not as letters reach below the line, and a
        // bracket or a mark beside them reaches further still): the band the small letters fill, about half the em
        // (or, capitals and figures only, the band they fill, seven tenths of it). Its lower edge is the baseline.
        var size: Double?, baseline: Double?
        let letters = run.text.filter(\.isLetter)
        let ratio = letters.filter(\.isLowercase).count * 10 >= letters.count * 3 ? 0.48 : 0.70
        func band(_ counts: [Int]) -> ClosedRange<Int>? {
            guard let most = counts.max(), most > 0, let peak = counts.firstIndex(of: most) else { return nil }
            var a = peak, b = peak
            while a > 0, Double(counts[a - 1]) >= Double(most) * 0.35 { a -= 1 }
            while b < counts.count - 1, Double(counts[b + 1]) >= Double(most) * 0.35 { b += 1 }
            return a...b
        }
        if !run.vertical {
            var counts = [Int](repeating: 0, count: ph)
            for y in 0..<ph { for x in max(0, bx0)..<min(pw, max(bx1, bx0 + 1)) where mask[y * pw + x] { counts[y] += 1 } }
            if let rows = band(counts) {
                size = min(max(Double(rows.count) / ratio, box.height * 0.5), box.height * 1.5)
                baseline = Double(py + rows.upperBound + 1)
            }
        } else {
            var counts = [Int](repeating: 0, count: pw)
            for y in max(0, by0)..<min(ph, max(by1, by0 + 1)) { for x in 0..<pw where mask[y * pw + x] { counts[x] += 1 } }
            if let columns = band(counts) { size = min(max(Double(columns.count) / ratio, box.width * 0.5), box.width * 1.5) }
        }
        // Grown a little: the soft edges of the strokes.
        let grow = max(1, Int(thickness / 14))
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
                // From the colours beside the strokes; one still half ink (an edge left over) gives way to the background.
                var a = k > 0 ? colors[index(line, k - 1)] : background
                var b = end < length ? colors[index(line, end)] : background
                if distance(a, background) > contrast * 0.5 { a = background }
                if distance(b, background) > contrast * 0.5 { b = background }
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
        return (patch, CGRect(x: px, y: py, width: pw, height: ph), RGBColor(r: ink.0, g: ink.1, b: ink.2), size, baseline)
    }

    /// Sizes measured a little differently for words set at one size, made one: sizes in a run without a step of more
    /// than 8% (and within 30% of each other) take their median.
    static func harmonized(_ sizes: [Double?]) -> [Double?] {
        let known = sizes.indices.filter { sizes[$0] != nil }.sorted { sizes[$0]! < sizes[$1]! }
        var result = sizes
        var cluster: [Int] = []
        func close() {
            guard !cluster.isEmpty else { return }
            let values = cluster.map { sizes[$0]! }
            let middle = values[values.count / 2]
            for k in cluster { result[k] = middle }
            cluster = []
        }
        for k in known {
            // A step of more than 8% from the size before, or a cluster grown past 30%: another size.
            if let first = cluster.first, let last = cluster.last, sizes[k]! > sizes[last]! * 1.08 || sizes[k]! > sizes[first]! * 1.3 { close() }
            cluster.append(k)
        }
        close()
        return result
    }

    private static func median(_ colors: [(Double, Double, Double)]) -> (Double, Double, Double) {
        guard !colors.isEmpty else { return (1, 1, 1) }
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return (mid(colors.map(\.0)), mid(colors.map(\.1)), mid(colors.map(\.2)))
    }

    // MARK: How the labels stand

    /// For each run: its group and how it is aligned. Runs form a group when they are set one under the other as one
    /// label: about one size, close, overlapping across with an edge or their centres in line, and no line drawn
    /// between them (two boxes stacked). A group keeps whichever of its left edges, right edges or centres line up
    /// best. A run alone keeps its centre, or the edge an icon stood at.
    static func arrange(_ runs: [Run], separated: ((Int, Int) -> Bool)? = nil, yUp: Bool = false) -> [(group: Int, alignment: Alignment)] {
        var parent = Array(runs.indices)
        func root(_ i: Int) -> Int { parent[i] == i ? i : root(parent[i]) }
        for i in runs.indices {
            // Lines kept by an icon each (legend entries) go together only with lines kept the same way.
            for j in runs.indices where j > i && runs[i].vertical == runs[j].vertical && runs[i].readsDown == runs[j].readsDown && runs[i].anchor == runs[j].anchor {
                // Sideways lines stand side by side: the same tests, across and along swapped.
                let vertical = runs[i].vertical
                func swap(_ r: CGRect) -> CGRect { vertical ? CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width) : r }
                let a = swap(runs[i].box), b = swap(runs[j].box)
                let size = max(a.height, b.height)
                let gap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
                guard gap < size * 0.7, gap > -size * 0.5, size < min(a.height, b.height) * 1.3,
                      min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0 else { continue }
                let lined = min(abs(a.minX - b.minX), abs(a.midX - b.midX), abs(a.maxX - b.maxX))
                guard lined < size * 0.6, vertical || separated?(i, j) != true else { continue }
                parent[root(j)] = root(i)
            }
        }
        var result = [(group: Int, alignment: Alignment)](repeating: (0, .center), count: runs.count)
        for (key, members) in Dictionary(grouping: runs.indices, by: root) {
            var alignment: Alignment = .center
            if members.count >= 2 {
                let boxes: [CGRect] = members.map { runs[$0].box }
                func spread(_ values: [CGFloat]) -> CGFloat { (values.max() ?? 0) - (values.min() ?? 0) }
                let first = runs[members[0]]
                // Where each line starts and ends along its reading: across, left to right; up the page, from the
                // bottom; down the page, from the top (pixel rows run down, page space up).
                let fromLow = first.readsDown != yUp
                let starts = boxes.map { !first.vertical ? $0.minX : (fromLow ? $0.minY : -$0.maxY) }
                let ends = boxes.map { !first.vertical ? $0.maxX : (fromLow ? $0.maxY : -$0.minY) }
                let middles = boxes.map { !first.vertical ? $0.midX : $0.midY }
                let tolerance = (boxes.map { first.vertical ? $0.width : $0.height }.max() ?? 1) * 0.15
                let left = spread(starts), center = spread(middles), right = spread(ends)
                alignment = center <= min(left, right) + tolerance ? .center : (left <= right ? .left : .right)
                if let anchor = first.anchor { alignment = anchor }
            } else if let anchor = runs[members[0]].anchor {
                alignment = anchor
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

    /// Chinese, Japanese or Korean: their characters fill the em, so they look the size of Latin text a little larger.
    static func isCJK(_ language: String) -> Bool { ["zh", "ja", "ko"].contains { language.lowercased().hasPrefix($0) } }

    /// The translations of a page's pictures: first every patch (the words taken out), then the translations. Each is
    /// set at the size of the words it replaces (as large as they look), narrowed or made smaller only when it would
    /// run past them; words of one size keep one size, and a group's lines share theirs; each is aligned as the words
    /// were, on their line.
    static func draw(_ entries: [(line: Line, translation: String)], language: String, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .high
        for entry in entries { if let patch = entry.line.patch { context.draw(patch, in: entry.line.patchRect) } }
        context.restoreGState()
        let cjk = isCJK(language)
        func length(_ line: Line) -> Double { line.vertical ? line.rect.height : line.rect.width }
        func thickness(_ line: Line) -> Double { line.vertical ? line.rect.width : line.rect.height }
        func natural(_ line: Line) -> Double? { line.size.map { $0 * (cjk ? 0.9 : 1) } }
        var fits = entries.map { fit($0.translation, length: length($0.line), thickness: thickness($0.line), language: language, natural: natural($0.line)) }
        func refit(_ members: [Int], _ size: Double) {
            for m in members {
                fits[m] = fit(entries[m].translation, length: length(entries[m].line), thickness: thickness(entries[m].line), language: language, size: size)
            }
        }
        // Words of one size: one size, the smallest any needs, unless one needs far less (it alone is made smaller).
        let classes = Dictionary(grouping: entries.indices.filter { entries[$0].line.size != nil }) {
            "\(entries[$0].line.page)|\(entries[$0].line.vertical)|\(Int((entries[$0].line.size! * 4).rounded()))"
        }
        for (_, members) in classes where members.count > 1 {
            let target = natural(entries[members[0]].line)!
            let fitting = members.filter { fits[$0].size >= target * 0.8 }
            if let size = fitting.map({ fits[$0].size }).min() { refit(fitting, size) }
        }
        // One size for a group: the smallest any of its lines needs.
        for (_, members) in Dictionary(grouping: entries.indices, by: { entries[$0].line.group }) where members.count > 1 {
            refit(members, members.map { fits[$0].size }.min()!)
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
            var rise = (thickness(line) - (ascent + descent)) / 2 + descent
            if !line.vertical, let baseline = line.baseline, let size = line.size {
                // On the words' line: Latin on their baseline; Chinese characters centred on their capitals.
                rise = cjk ? baseline + size * 0.35 - f.size * 0.38 - line.rect.minY : baseline - line.rect.minY
            }
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
