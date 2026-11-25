import CoreGraphics
import Foundation

/// A recognised scan as layout analysis needs it. The hidden text says which words are on the page and roughly where;
/// everything else is only in the picture: how large and how bold the type is, which lines stand upright, where rules and
/// drawings are, and which way round the page lies. All of it is measured from a render of the page, in a space where the
/// page lies upright and straight (`transform`), so the analysis goes on as with any other page.
/// (The Windows version does the same: Folio.Core/Translate/Layout/ScanPage.cs.)
struct ScanPage {
    /// The page's user space → the upright space everything below is in (identity for a page that lies straight already).
    var transform: CGAffineTransform = .identity
    /// The visible part of the page in that space.
    var crop: CGRect
    /// The recognised words as characters, line by line, with the type sizes measured.
    var chars: [PageChar] = []
    /// Rules, solid areas and drawings found in the picture.
    var marks: [GraphicMark] = []
    /// Small pieces of ink no word was read in: a symbol of a table, part of a formula.
    var bits: [CGRect] = []
    /// Where the ink of each word is, by the run that wrote it.
    var ink: [Int: CGRect] = [:]
    /// The rows of words, until `finish` makes characters of them.
    private var rows: [Row] = []
    private var usual = 10.0

    /// One word of the hidden text.
    struct Word {
        var run: Int
        var glyphs: [Int]
        var text: String
        var x0: Double, x1: Double
        /// The box it was read in.
        var bottom: Double, top: Double
        /// A space was written before it.
        var spaced: Bool
        /// Measured in the picture.
        var ink: CGRect?
        var size: Double?
        var baseline: Double?
        var stroke: Double?
        var bold = false
        var height: Double { top - bottom }
        var mid: Double { (top + bottom) / 2 }
        /// The type size that makes the word's ink as tall as it is.
        mutating func fit(xHeight: Double, usual: Double) {
            guard let ink, letters * 2 >= text.count else { return }
            let (low, high) = ScanPage.extent(of: text, xHeight: xHeight)
            guard high - low > 0.3 else { return }
            let size = ink.height / (high - low)
            guard size > usual * 0.25, size < usual * 6 else { return }
            self.size = size
            baseline = ink.minY - low * size
        }
        var letters: Int { text.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.count }
    }

    /// Words on one row, left to right.
    struct Row {
        var words: [Word]
        var size = 0.0
        var measured = false
        var baseline = 0.0
        var upright = false
        var x0: Double { words.map(\.x0).min()! }
        var x1: Double { words.map(\.x1).max()! }
        var letters: Int { words.reduce(0) { $0 + $1.letters } }
    }

    // MARK: Reading

    /// The page `interpreter` (run in the page's own space) is of, and the interpreter in the upright space.
    static func read(page: CGPDFPage, interpreter: ContentInterpreter) -> (ScanPage, ContentInterpreter) {
        let crop = ScannedPDF.effectiveCrop(page)
        let turn = turn(of: interpreter)
        var (transform, upright) = space(crop: crop, angle: turn.quarter + turn.skew)
        if turn.skew == 0, let small = Raster.render(page: page, crop: upright, transform: transform, scale: min(1.5, 1000 / max(upright.width, upright.height))) {
            // Text written level over lines that are not: an earlier recognition.
            let skew = small.skew()
            if skew != 0 { (transform, upright) = space(crop: crop, angle: turn.quarter + skew) }
        }
        var placed = interpreter
        if transform != .identity {
            placed = ContentInterpreter()
            placed.run(page: page, pageTransform: transform)
            placed.markRecognizedScan()
        }
        let raster = Raster.render(page: page, crop: upright, transform: transform, scale: min(3, 2400 / max(upright.width, upright.height, 1)))
        return (ScanPage(interpreter: placed, crop: upright, transform: transform, raster: raster), placed)
    }

    /// Which way the hidden text runs: quarter turns, and how much off them (radians).
    static func turn(of interpreter: ContentInterpreter) -> (quarter: Double, skew: Double) {
        var counts = [0, 0, 0, 0]
        var angles: [Double] = []
        for glyph in interpreter.glyphs where glyph.renderMode == 3 && !glyph.isClipped {
            let q = Int((glyph.angle / (.pi / 2)).rounded())
            counts[((q % 4) + 4) % 4] += 1
            angles.append(glyph.angle)
        }
        guard let q = counts.indices.max(by: { counts[$0] < counts[$1] }), counts[q] > 0 else { return (0, 0) }
        let quarter = Double(q) * .pi / 2
        let off = angles.map { remainder($0 - quarter, 2 * .pi) }.filter { abs($0) < .pi / 4 }.sorted()
        let skew = off[off.count / 2]
        return (remainder(quarter, 2 * .pi), abs(skew) < 0.003 ? 0 : skew)
    }

    /// The space a page turned by `angle` is upright in. Pages that claim to be metres large (one point per pixel of the
    /// scan) come down to the size of a sheet, so that distances mean what they do on other pages.
    static func space(crop: CGRect, angle: Double) -> (CGAffineTransform, CGRect) {
        let long = max(crop.width, crop.height)
        let scale = long > 1300 ? 842 / long : 1
        if abs(angle) < 1e-6, scale == 1 { return (.identity, crop) }
        let quarter = Int((angle / (.pi / 2)).rounded())
        let size = quarter % 2 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        let upright = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        let transform = CGAffineTransform(translationX: -crop.midX, y: -crop.midY)
            .concatenating(CGAffineTransform(rotationAngle: -angle))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: upright.midX, y: upright.midY))
        return (transform, upright)
    }

    init(interpreter: ContentInterpreter, crop: CGRect, transform: CGAffineTransform, raster: Raster?) {
        self.crop = crop
        self.transform = transform
        rows = Self.rows(interpreter)
        guard !rows.isEmpty else { return }
        usual = Self.median(rows.flatMap { row in row.words.map(\.height) }) ?? 10
        if let raster {
            let mask = raster.mask()
            for r in rows.indices {
                for w in rows[r].words.indices { mask.measure(&rows[r].words[w], usual: usual) }
            }
            fit(Self.xHeight(Self.xRatios(rows)))
            let lines = mask.rules(words: rows.flatMap(\.words))
            rows = Self.joined(rows, mask: mask, uprights: lines.uprights)
            (marks, bits) = mask.marks(rows: rows, rules: lines.rules, uprights: lines.uprights, crop: crop)
        }
        for word in rows.flatMap(\.words) { if let rect = word.ink { ink[word.run] = ink[word.run].map { $0.union(rect) } ?? rect } }
    }

    private mutating func fit(_ xHeight: Double) {
        for r in rows.indices {
            for w in rows[r].words.indices { rows[r].words[w].fit(xHeight: xHeight, usual: usual) }
            Self.place(&rows[r])
        }
    }

    /// Makes the characters of the pages of one document: what is the same type on one page is the same on all of them.
    static func finish(_ pages: inout [(scan: ScanPage, interpreter: ContentInterpreter)]) {
        let ratios = pages.flatMap { xRatios($0.scan.rows) }
        let height = xHeight(ratios)
        for p in pages.indices { pages[p].scan.fit(height) }
        var rows = pages.map(\.scan.rows)
        for p in rows.indices { even(&rows[p]) }
        settle(&rows)
        markBold(&rows)
        for p in pages.indices {
            pages[p].scan.rows = []
            pages[p].scan.chars = characters(rows[p], interpreter: pages[p].interpreter)
        }
    }

    // MARK: Type

    private static let low = Set<Character>("acemnorsuvwxzαεικνοπστυω"), tails = Set<Character>("gpqyγημρφχψ")

    /// How tall a word's ink is, in ems from the baseline, when small letters are `xHeight` tall.
    static func extent(of text: String, xHeight: Double) -> (bottom: Double, top: Double) {
        var bottom = 1.0, top = -1.0
        for c in text {
            let part: (Double, Double)
            if c.unicodeScalars.contains(where: OCRTextLayer.isCJK) {
                part = (-0.1, 0.84)
            } else if low.contains(c) {
                part = (-0.01, xHeight)
            } else if tails.contains(c) {
                part = (-0.215, xHeight)
            } else if c == "t" {
                part = (-0.01, 0.6)
            } else if c.isLetter || c.isNumber {
                part = (c == "j" || c == "Q" ? -0.2 : -0.01, c.isUppercase || c.isNumber ? 0.67 : 0.69)
            } else {
                part = PageChar.verticalExtent(of: String(c))
            }
            bottom = min(bottom, part.0)
            top = max(top, part.1)
        }
        return (bottom, top)
    }

    /// How tall small letters are beside tall ones, on each row that has words with and without them.
    private static func xRatios(_ rows: [Row]) -> [Double] {
        var ratios: [Double] = []
        for row in rows where !row.upright {
            var small: [Double] = [], tall: [Double] = []
            for word in row.words where word.text.count >= 2 {
                guard let ink = word.ink else { continue }
                if word.text.allSatisfy({ low.contains($0) }) { small.append(ink.height) }
                if word.text.allSatisfy({ low.contains($0) || "bdfhkl".contains($0) }), word.text.contains(where: { "bdfhkl".contains($0) }) { tall.append(ink.height) }
            }
            if let s = median(small), let t = median(tall), t > 0 { ratios.append(s / t) }
        }
        return ratios
    }

    /// How tall small letters are, in ems.
    private static func xHeight(_ ratios: [Double]) -> Double {
        guard ratios.count >= 4, let ratio = median(ratios) else { return 0.46 }
        return min(max(ratio, 0.6), 0.82) * 0.7 - 0.01
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    // MARK: Words and rows

    /// The hidden text as rows of words, as it was written.
    static func rows(_ interpreter: ContentInterpreter) -> [Row] {
        var rows: [Row] = []
        var current: [Word] = []
        var spaced = false
        func flush() {
            if !current.isEmpty { rows.append(Row(words: current)) }
            current = []
        }
        var word: Word?
        var lastRun = -1
        func close() {
            guard let w = word else { return }
            word = nil
            guard !w.text.isEmpty, w.x1 > w.x0, w.height > 0.5 else { return }
            if let p = current.last {
                let h = min(p.height, w.height)
                let level = abs(p.mid - w.mid) < max(p.height, w.height) * 0.35
                let gap = w.x0 - p.x1
                // (A comma of Chinese takes the room of a character.)
                if !level || gap < -h * 0.8 || gap > h * (w.spaced ? 1.5 : endsCJK(p.text) ? 1.2 : 0.6) { flush() }
            }
            current.append(w)
        }
        for (g, glyph) in interpreter.glyphs.enumerated() where glyph.renderMode == 3 && !glyph.isClipped && glyph.size > 0.5 && glyph.size < 2000 {
            let text = glyph.text ?? ""
            if text.isEmpty || text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                close()
                spaced = true
                continue
            }
            let cjk = text.unicodeScalars.contains(where: OCRTextLayer.isCJK)
            if glyph.run != lastRun || cjk { close() }
            lastRun = glyph.run
            let x0 = min(glyph.origin.x, glyph.end.x), x1 = max(glyph.origin.x, glyph.end.x)
            let y = (glyph.origin.y + glyph.end.y) / 2
            // Across the line for text that stands upright in this space.
            let sideways = abs(glyph.angle) > 0.3
            let box = glyph.box
            if word == nil {
                word = Word(run: glyph.run, glyphs: [g], text: text, x0: sideways ? box.minX : x0, x1: sideways ? box.maxX : x1,
                            bottom: sideways ? box.minY : y - glyph.size * 0.2, top: sideways ? box.maxY : y + glyph.size * 0.8, spaced: spaced)
                spaced = false
            } else {
                word!.glyphs.append(g)
                word!.text += text
                word!.x0 = min(word!.x0, sideways ? box.minX : x0)
                word!.x1 = max(word!.x1, sideways ? box.maxX : x1)
                if sideways { word!.bottom = min(word!.bottom, box.minY); word!.top = max(word!.top, box.maxY) }
            }
        }
        close()
        flush()
        // Text written level over lines that tilt: each line's box is as high as the whole tilt. The words are put back on
        // their line, which goes through the middle of the box.
        for r in rows.indices {
            let tilt = rows[r].words.flatMap(\.glyphs).map { interpreter.glyphs[$0].angle }.sorted()
            let angle = tilt[tilt.count / 2]
            if abs(angle) > 0.3 { rows[r].upright = true; continue }
            guard abs(angle) > 0.003 else { continue }
            let x0 = rows[r].x0, x1 = rows[r].x1
            let middle = rows[r].words.map { $0.mid }.reduce(0, +) / Double(rows[r].words.count)
            let height = rows[r].words[0].height
            let real = max(height - abs(tan(angle)) * (x1 - x0), height * 0.3)
            for w in rows[r].words.indices {
                rows[r].words[w].bottom = middle - real / 2
                rows[r].words[w].top = middle + real / 2
            }
        }
        // Words that stand: far too many letters for the width of a box that high.
        let usual = median(rows.map { $0.words[0].height }) ?? 0
        for r in rows.indices where !rows[r].upright {
            let row = rows[r]
            let count = Double(row.words.reduce(0) { $0 + $1.text.count })
            if count >= 3, row.words[0].height > usual * 2, row.x1 - row.x0 < row.words[0].height * 0.8 { rows[r].upright = true }
        }
        return rows
    }

    /// Pieces of one line (recognition cuts lines at formulas and wide gaps) as one row: next to each other, or with
    /// something in between that was not read.
    static func joined(_ input: [Row], mask: Mask, uprights: [CGRect]) -> [Row] {
        var rows = input
        for r in rows.indices { place(&rows[r]) }
        var parent = Array(rows.indices)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { x = parent[x] }; return x }
        let order = rows.indices.filter { !rows[$0].upright }.sorted { rows[$0].x0 < rows[$1].x0 }
        for (n, a) in order.enumerated() {
            // The nearest piece to the right on the row.
            var best: Int?
            for b in order[(n + 1)...] {
                let size = min(rows[a].size, rows[b].size)
                guard abs(rows[a].baseline - rows[b].baseline) < size * 0.35, rows[b].x0 > rows[a].x1 - size * 1.6, rows[b].x1 > rows[a].x1 else { continue }
                best = b
                break
            }
            guard let b = best else { continue }
            let size = min(rows[a].size, rows[b].size), large = max(rows[a].size, rows[b].size)
            guard large < size * 1.4 else { continue }
            let gap = CGRect(x: rows[a].x1, y: rows[a].baseline - size * 0.25, width: rows[b].x0 - rows[a].x1, height: size * 1.1)
            if uprights.contains(where: { $0.midX > gap.minX - 1 && $0.midX < gap.maxX + 1 && $0.minY < gap.midY && $0.maxY > gap.midY }) { continue }
            let filled = gap.width > 0 ? mask.columnsFilled(gap) : 1
            // ("Figure 1." stands apart from its caption.)
            let label = gap.width < size * 2 && rows[a].words.count <= 2
                && rows[a].words.map(\.text).joined(separator: " ").range(of: #"^(Figure|Fig\.?|FIGURE|FIG\.?|Table|TABLE|图|表)\s*\d{1,2}\s*[.:：]?$"#, options: .regularExpression) != nil
            if label || gap.width < size * (endsCJK(rows[a].words.last!.text) ? 1.1 : 0.45) || gap.width < size * 7 && filled > 0.45 { parent[find(b)] = find(a) }
        }
        var result: [Row] = []
        var index: [Int: Int] = [:]
        for r in rows.indices {
            let root = find(r)
            if let k = index[root] {
                var words = rows[r].words
                words[0].spaced = true
                result[k].words += words
                result[k].words.sort { $0.x0 < $1.x0 }
            } else {
                index[root] = result.count
                result.append(rows[r])
            }
        }
        for r in result.indices { place(&result[r]) }
        return result
    }

    private static func endsCJK(_ text: String) -> Bool { text.unicodeScalars.last.map(OCRTextLayer.isCJK) ?? false }

    /// The row's type size and baseline: what most of its letters say.
    static func place(_ row: inout Row) {
        var sizes: [(value: Double, weight: Int)] = []
        for word in row.words { if let size = word.size { sizes.append((size, word.letters)) } }
        func weighted(_ values: [(value: Double, weight: Int)]) -> Double? {
            let sorted = values.sorted { $0.value < $1.value }
            let half = sorted.reduce(0) { $0 + $1.weight } / 2
            var sum = 0
            for entry in sorted {
                sum += entry.weight
                if sum > half { return entry.value }
            }
            return sorted.last?.value
        }
        if let size = weighted(sizes) {
            row.size = size
            row.measured = sizes.reduce(0) { $0 + $1.weight } >= 3
            row.baseline = weighted(row.words.compactMap { word in word.baseline.map { ($0, word.letters) } }) ?? row.words[0].bottom + row.words[0].height * 0.22
        } else {
            let heights = row.words.map(\.height).sorted()
            row.size = heights[heights.count / 2] * 0.92
            row.measured = false
            row.baseline = row.words[0].bottom + row.words[0].height * 0.2
        }
    }

    /// The lines of one paragraph have one size: those right under each other, as far apart and starting or ending at the
    /// same place, take the size in their middle.
    static func even(_ rows: inout [Row]) {
        let order = rows.indices.filter { !rows[$0].upright && rows[$0].measured }.sorted { rows[$0].baseline > rows[$1].baseline }
        var taken: Set<Int> = []
        for first in order where !taken.contains(first) {
            var chain = [first]
            var pitch: Double?
            while true {
                let last = rows[chain.last!]
                let next = order.filter { r in
                    let drop = last.baseline - rows[r].baseline
                    guard !taken.contains(r), drop > last.size * 0.8, drop < last.size * 1.7, abs(rows[r].size / last.size - 1) < 0.2 else { return false }
                    if let pitch, abs(drop - pitch) > pitch * 0.12 { return false }
                    return abs(rows[r].x0 - last.x0) < last.size * 0.5 || abs(rows[r].x1 - last.x1) < last.size * 0.5 && rows[r].x0 < last.x1
                }.max { rows[$0].baseline < rows[$1].baseline }
                guard let next else { break }
                pitch = pitch ?? last.baseline - rows[next].baseline
                chain.append(next)
            }
            taken.formUnion(chain)
            guard chain.count >= 3 else { continue }
            let sizes = chain.map { rows[$0].size }.sorted(), middle = sizes[sizes.count / 2]
            for r in chain where abs(rows[r].size / middle - 1) < 0.13 { rows[r].size = middle }
        }
    }

    /// The sizes of the document's type: rows within a tenth of each other share the size most of their letters have; a few
    /// stray letters take the size of the text around them.
    static func settle(_ pages: inout [[Row]]) {
        var rest: [(page: Int, row: Int, size: Double, letters: Int)] = []
        for p in pages.indices {
            for r in pages[p].indices where !pages[p][r].upright && pages[p][r].measured { rest.append((p, r, pages[p][r].size, pages[p][r].letters)) }
        }
        // (Counted by steps of a hundredth: documents have thousands of rows.)
        var sizes: [(size: Double, letters: Int)] = []
        while !rest.isEmpty {
            var steps: [Int: Int] = [:]
            for entry in rest { steps[Int((log(entry.size) * 100).rounded()), default: 0] += entry.letters }
            var best = 0, count = -1
            for step in steps.keys.sorted() {
                var n = 0
                for k in -7...7 { n += (steps[step + k] ?? 0) * (8 - abs(k)) }
                if n > count { count = n; best = step }
            }
            let centre = exp(Double(best) / 100)
            let members = rest.filter { $0.size >= centre * 0.89 && $0.size <= centre * 1.12 }
            let total = members.reduce(0) { $0 + $1.letters }
            // What is left beside a size with far more letters, close to it, is that size measured badly.
            let near = sizes.first { $0.letters > total * 12 && total < 60 && abs(centre / $0.size - 1) < (total < 8 ? 0.2 : 0.14) }
            if near == nil { sizes.append((centre, total)) }
            for m in members { pages[m.page][m.row].size = near?.size ?? centre }
            rest.removeAll { $0.size >= centre * 0.89 && $0.size <= centre * 1.12 }
        }
        for p in pages.indices {
            let rows = pages[p]
            let measured = rows.indices.filter { rows[$0].measured && !rows[$0].upright }
            for r in rows.indices where !rows[r].upright && !rows[r].measured {
                // Too little to measure: like the closest text.
                let near = measured.filter { rows[$0].x0 < rows[r].x1 + 60 && rows[$0].x1 > rows[r].x0 - 60 }
                    .min { abs(rows[$0].baseline - rows[r].baseline) < abs(rows[$1].baseline - rows[r].baseline) }
                if let near, abs(rows[near].baseline - rows[r].baseline) < rows[near].size * 3, rows[r].size < rows[near].size * 1.6, rows[r].size > rows[near].size * 0.6 {
                    pages[p][r].size = rows[near].size
                } else if let size = sizes.min(by: { abs($0.size / rows[r].size - 1) < abs($1.size / rows[r].size - 1) }), abs(size.size / rows[r].size - 1) < 0.25 {
                    pages[p][r].size = size.size
                }
            }
        }
    }

    /// Words set in bold: strokes clearly thicker, for their size, than most of the page's. A short word goes with the
    /// words beside it.
    static func markBold(_ pages: inout [[Row]]) {
        func weight(_ word: Word, _ row: Row) -> Double? {
            guard word.letters >= 3, let stroke = word.stroke, row.size > 0 else { return nil }
            return stroke / row.size
        }
        for p in pages.indices {
            var values: [(value: Double, letters: Int)] = []
            for row in pages[p] where !row.upright { for word in row.words { if let w = weight(word, row) { values.append((w, word.letters)) } } }
            // (Pages are scanned one by one, lighter or darker: each is its own measure.)
            guard values.reduce(0, { $0 + $1.letters }) >= 120 else { continue }
            let sorted = values.sorted { $0.value < $1.value }
            let half = sorted.reduce(0) { $0 + $1.letters } / 2
            var sum = 0, usual = sorted[0].value
            for entry in sorted { sum += entry.letters; if sum > half { usual = entry.value; break } }
            for r in pages[p].indices where !pages[p][r].upright {
                let row = pages[p][r]
                // The whole row first: heavier altogether, with hardly a word that is not.
                let weights = row.words.map { weight($0, row) }
                var total = 0.0, letters = 0, heavy = 0
                for (w, word) in zip(weights, row.words) {
                    guard let w else { continue }
                    total += w * Double(word.letters)
                    letters += word.letters
                    if w > usual * 1.08 { heavy += word.letters }
                }
                guard letters >= 3 else { continue }
                let all = total / Double(letters) > usual * (letters < 6 ? 1.5 : letters < 12 ? 1.25 : 1.17) && heavy * 10 >= letters * 8
                if all {
                    for k in row.words.indices { pages[p][r].words[k].bold = true }
                    continue
                }
                let marks = weights.map { w -> Bool? in w.map { $0 > usual * (letters < 6 ? 1.6 : 1.26) } }
                for k in row.words.indices {
                    if let mark = marks[k] { pages[p][r].words[k].bold = mark; continue }
                    let before = marks[..<k].last { $0 != nil } ?? nil, after = marks[(k + 1)...].first { $0 != nil } ?? nil
                    pages[p][r].words[k].bold = before == true && after != false || before == nil && after == true
                }
            }
        }
    }

    /// The characters of the rows, with the sizes and baselines measured.
    static func characters(_ rows: [Row], interpreter: ContentInterpreter) -> [PageChar] {
        var chars: [PageChar] = []
        for row in rows {
            var font = FontInfo.unknown
            var previous: Word?
            for word in row.words {
                if let p = previous, let last = chars.last {
                    let needed = word.spaced && OCRTextLayer.needsSpace(after: p.text, before: word.text)
                    if needed || word.x0 - p.x1 > row.size * 0.6 {
                        // Words read edge to edge, or over each other's edges, give way to the space between them.
                        let missing = row.size * 0.25 - (word.x0 - last.rect.maxX)
                        if missing > 0 { chars[chars.count - 1].rect.size.width = max(0.1, last.rect.width - min(missing, last.rect.width * 0.6)) }
                        var space = chars[chars.count - 1]
                        space.text = " "
                        space.isSpace = true
                        space.glyphs = []
                        space.run = nil
                        space.rect = CGRect(x: space.rect.maxX, y: space.rect.minY, width: max(word.x0 - space.rect.maxX, 0.1), height: space.rect.height)
                        chars.append(space)
                    }
                }
                font.isBold = word.bold
                // (Pieces of a line read twice over the same place: one after the other.)
                let end = chars.last.map { $0.isNewline ? -Double.infinity : Double($0.rect.maxX) } ?? -Double.infinity
                let from = min(max(word.x0, end), word.x0 + (word.x1 - word.x0) * 0.8), stretch = (word.x1 - from) / max(word.x1 - word.x0, 0.01)
                for g in word.glyphs {
                    let glyph = interpreter.glyphs[g]
                    let x0 = from + (min(glyph.origin.x, glyph.end.x) - word.x0) * stretch, x1 = from + (max(glyph.origin.x, glyph.end.x) - word.x0) * stretch
                    var char = PageChar(text: glyph.text ?? "", rect: row.upright ? glyph.box : CGRect(x: x0, y: row.baseline - row.size * 0.22, width: max(x1 - x0, 0.1), height: row.size * 1.2),
                                        isSpace: false, isNewline: false, size: row.size, baseline: row.baseline, font: font, color: .black,
                                        run: glyph.run, isRotated: row.upright)
                    char.glyphs = [g]
                    chars.append(char)
                }
                previous = word
            }
            if var br = chars.last {
                br.text = "\n"
                br.isNewline = true
                br.glyphs = []
                br.run = nil
                chars.append(br)
            }
        }
        return chars
    }
}
