import CoreGraphics
import Foundation

extension ScanPage {
    /// A page as grey levels, the top row first, in the upright space.
    struct Raster {
        var width: Int, height: Int
        var pixels: [UInt8]
        /// Pixels per point.
        var scale: Double
        var crop: CGRect

        static func render(page: CGPDFPage, crop: CGRect, transform: CGAffineTransform, scale: Double) -> Raster? {
            let width = Int(crop.width * scale), height = Int(crop.height * scale)
            guard width > 8, height > 8, width * height < 40_000_000,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -crop.minX, y: -crop.minY)
            context.concatenate(transform)
            context.drawPDFPage(page)
            guard let data = context.data else { return nil }
            let pixels = [UInt8](UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height), count: width * height))
            return Raster(width: width, height: height, pixels: pixels, scale: scale, crop: crop)
        }

        /// Ink (1) and paper (0): what is clearly darker than the paper around it. A page with light words on dark is read
        /// the other way round; a pale watermark is paper.
        func mask() -> Mask {
            let block = max(8, Int(32 * scale))
            let cols = (width + block - 1) / block, rows = (height + block - 1) / block
            var ground = [Double](repeating: 255, count: cols * rows)
            var levels = [Double]()
            func grounds(_ invert: Bool) {
                for by in 0..<rows {
                    for bx in 0..<cols {
                        var histogram = [Int](repeating: 0, count: 256)
                        var n = 0
                        var y = by * block
                        while y < min(height, (by + 1) * block) {
                            var x = bx * block
                            while x < min(width, (bx + 1) * block) {
                                let v = Int(pixels[y * width + x])
                                histogram[invert ? 255 - v : v] += 1
                                n += 1
                                x += 2
                            }
                            y += 2
                        }
                        var left = n / 10, level = 255
                        while level > 0 { left -= histogram[level]; if left < 0 { break }; level -= 1 }
                        ground[by * cols + bx] = Double(level)
                    }
                }
            }
            grounds(false)
            // Mostly dark paper: the middle of all the page's pixels says so.
            var histogram = [Int](repeating: 0, count: 256)
            for k in stride(from: 0, to: pixels.count, by: 7) { histogram[Int(pixels[k])] += 1 }
            var left = histogram.reduce(0, +) / 2, middle = 0
            while middle < 255 { left -= histogram[middle]; if left <= 0 { break }; middle += 1 }
            let inverted = middle < 110
            if inverted { grounds(true) }
            levels = ground
            for by in 0..<rows {
                for bx in 0..<cols {
                    var best = 0.0
                    for y in max(0, by - 1)...min(rows - 1, by + 1) { for x in max(0, bx - 1)...min(cols - 1, bx + 1) { best = max(best, ground[y * cols + x]) } }
                    levels[by * cols + bx] = best
                }
            }
            var ink = [UInt8](repeating: 0, count: width * height)
            var faint = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                let by = y / block
                for x in 0..<width {
                    let v = Int(pixels[y * width + x])
                    let level = levels[by * cols + x / block]
                    let light = Double(inverted ? 255 - v : v) / max(level, 60)
                    if light < 0.72 { ink[y * width + x] = 1 }
                    if light < 0.9 { faint[y * width + x] = 1 }
                }
            }
            return Mask(width: width, height: height, ink: ink, faint: faint, scale: scale, crop: crop)
        }

        /// How far the lines of the page tilt (radians, counter-clockwise up), when the rows of ink say so clearly.
        func skew() -> Double {
            let mask = mask()
            var points: [(Double, Double)] = []
            let step = max(1, mask.ink.lazy.filter { $0 == 1 }.count / 40_000)
            var n = 0
            for y in 0..<height { for x in 0..<width where mask.ink[y * width + x] == 1 {
                n += 1
                if n % step == 0 { points.append((Double(x) - Double(width) / 2, Double(y))) }
            } }
            guard points.count > 500 else { return 0 }
            func score(_ angle: Double) -> Double {
                let t = tan(angle)
                var bins = [Double](repeating: 0, count: height + width)
                for (x, y) in points {
                    let b = Int(y + x * t) + width / 2
                    if b >= 0, b < bins.count { bins[b] += 1 }
                }
                return zip(bins, bins.dropFirst()).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
            }
            let level = score(0)
            var best = 0.0, bestScore = level
            for k in -16...16 where k != 0 {
                let angle = Double(k) * 0.2 * .pi / 180, s = score(angle)
                if s > bestScore { best = angle; bestScore = s }
            }
            let around = best
            for k in -3...3 {
                let angle = around + Double(k) * 0.05 * .pi / 180, s = score(angle)
                if s > bestScore { best = angle; bestScore = s }
            }
            return abs(best) >= 0.3 * .pi / 180 && bestScore > level * 1.15 ? best : 0
        }
    }

    /// Where a page has ink.
    struct Mask {
        var width: Int, height: Int
        var ink: [UInt8]
        /// Ink and what is hardly darker than the paper: hairlines.
        var faint: [UInt8]
        var scale: Double
        var crop: CGRect

        func px(_ x: Double) -> Int { Int(((x - crop.minX) * scale).rounded(.down)) }
        func py(_ y: Double) -> Int { Int(((crop.maxY - y) * scale).rounded(.down)) }
        /// Pixels (columns, rows: both ends in) as a rectangle of the page.
        func rect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> CGRect {
            CGRect(x: crop.minX + Double(x0) / scale, y: crop.maxY - Double(y1 + 1) / scale, width: Double(x1 - x0 + 1) / scale, height: Double(y1 - y0 + 1) / scale)
        }

        // MARK: Words

        /// Finds the word's ink in its box, and how thick its strokes are.
        func measure(_ word: inout Word, usual: Double) {
            let x0 = max(0, px(word.x0)), x1 = min(width - 1, px(word.x1))
            let top = py(word.top), bottom = py(word.bottom)
            guard x1 > x0, bottom > top else { return }
            let h = bottom - top
            let y0 = max(0, top - h / 3), y1 = min(height - 1, bottom + h / 3)
            guard y1 > y0 else { return }
            var profile = [Int](repeating: 0, count: y1 - y0 + 1)
            for y in y0...y1 {
                var n = 0
                let row = y * width
                for x in x0...x1 { n += Int(ink[row + x]) }
                profile[y - y0] = n
            }
            // The row with the most ink in the box, and on from it both ways to where the paper begins (the dot of an i is
            // a little way off).
            let inBox = max(top, y0)...min(bottom, y1)
            guard let middle = inBox.filter({ word.letters < 3 || profile[$0 - y0] <= (x1 - x0 + 1) * 93 / 100 }).max(by: { profile[$0 - y0] < profile[$1 - y0] }), profile[middle - y0] > 0 else { return }
            let gapAllowed = max(1, Int(min(usual, Double(h) / scale) * 0.14 * scale))
            let solid = word.letters >= 3 ? (x1 - x0 + 1) * 93 / 100 : Int.max
            func reach(_ step: Int) -> Int {
                var y = middle, last = middle, gap = 0
                while y + step >= y0, y + step <= y1 {
                    y += step
                    // A rule, or the edge of a filled box, right under or over the word.
                    if profile[y - y0] > solid, abs(y - middle) > h / 6 { break }
                    if profile[y - y0] > 0 {
                        last = y
                        gap = 0
                    } else {
                        gap += 1
                        if gap > (y >= top && y <= bottom ? gapAllowed : 1) { break }
                    }
                }
                return last
            }
            var a = reach(-1), b = reach(1)
            // Touching the line above or below: no further than the box.
            if a == y0 { a = max(a, top) }
            if b == y1 { b = min(b, bottom) }
            guard b > a else { return }
            word.ink = rect(x0, a, x1, b)
            // Strokes: ink over half its outline.
            var area = 0, edges = 0
            for y in a...b {
                let row = y * width
                for x in x0...x1 where ink[row + x] == 1 {
                    area += 1
                    if x == 0 || ink[row + x - 1] == 0 { edges += 1 }
                    if x + 1 >= width || ink[row + x + 1] == 0 { edges += 1 }
                    if y == 0 || ink[row - width + x] == 0 { edges += 1 }
                    if y + 1 >= height || ink[row + width + x] == 0 { edges += 1 }
                }
            }
            if edges > 0 { word.stroke = 2 * Double(area) / Double(edges) / scale }
        }

        /// The share of the columns of `rect` with ink in them.
        func columnsFilled(_ rect: CGRect) -> Double {
            let x0 = max(0, px(rect.minX)), x1 = min(width - 1, px(rect.maxX))
            let y0 = max(0, py(rect.maxY)), y1 = min(height - 1, py(rect.minY))
            guard x1 > x0, y1 > y0 else { return 0 }
            var filled = 0
            for x in x0...x1 where (y0...y1).contains(where: { ink[$0 * width + x] == 1 }) { filled += 1 }
            return Double(filled) / Double(x1 - x0 + 1)
        }

        // MARK: Rules

        /// Level and upright rules, and solid areas long enough to look like them at first (thick ones keep their size).
        func rules(words: [Word]) -> (rules: [CGRect], uprights: [CGRect]) {
            let inWords = words.compactMap(\.ink)
            func free(_ r: CGRect) -> Bool {
                !inWords.contains { $0.insetBy(dx: -1, dy: -1).contains(r) && r.width < $0.width * 0.95 + 1 }
            }
            let level = strokes(count: height, along: width, least: Int(16 * scale)) { row, x in ink[row * width + x] == 1 }
                .map { rect($0.start, $0.first, $0.end, $0.last) }
            let up = strokes(count: width, along: height, least: Int(12 * scale)) { column, y in ink[y * width + column] == 1 }
                .map { rect($0.first, $0.start, $0.last, $0.end) }
            // Hairlines too pale for ink: long, thin, and level.
            let hair = strokes(count: height, along: width, least: Int(60 * scale)) { row, x in faint[row * width + x] == 1 }
                .map { rect($0.start, $0.first, $0.end, $0.last) }
                .filter { r in r.height < 2.2 && !level.contains { $0.insetBy(dx: -2, dy: -2).intersects(r) } }
            // A filled area full of grain shows as many upright strokes side by side; a grid's lines are apart.
            let posts = up.filter { r in
                r.width > 3.2 || up.filter { $0 != r && abs($0.midX - r.midX) < 5 && min($0.maxY, r.maxY) - max($0.minY, r.minY) > r.height * 0.6 }.count < 2
            }
            return ((level + hair).filter(free), posts.filter(free))
        }

        private struct Stroke { var start: Int, end: Int, first: Int, last: Int, area: Int }

        /// Unbroken runs of ink along one direction, next to each other ones together.
        private func strokes(count: Int, along: Int, least: Int, at: (Int, Int) -> Bool) -> [Stroke] {
            var open: [Stroke] = []
            var done: [Stroke] = []
            // A rule tilting by a pixel or a nick in it breaks a run in two: short pieces join along the rule too.
            let joint = max(1, Int(scale * 0.7))
            for line in 0..<count {
                var runs: [(Int, Int)] = []
                var start = -1, lastInk = -10
                for x in 0..<along {
                    if at(line, x) {
                        if start < 0 { start = x }
                        lastInk = x
                    } else if start >= 0, x - lastInk > joint {
                        if lastInk - start + 1 >= least { runs.append((start, lastInk)) }
                        start = -1
                    }
                }
                if start >= 0, lastInk - start + 1 >= least { runs.append((start, lastInk)) }
                for run in runs {
                    if let k = open.firstIndex(where: { $0.start <= run.1 + 3 && $0.end >= run.0 - 3 }) {
                        open[k].start = min(open[k].start, run.0)
                        open[k].end = max(open[k].end, run.1)
                        open[k].last = line
                        open[k].area += run.1 - run.0 + 1
                    } else {
                        open.append(Stroke(start: run.0, end: run.1, first: line, last: line, area: run.1 - run.0 + 1))
                    }
                }
                done += open.filter { $0.last < line - 1 }
                open.removeAll { $0.last < line - 1 }
            }
            return (done + open)
        }

        // MARK: Drawings

        /// The rules as marks, and the drawings: ink that is neither words nor rules, in pieces too large to be the bits a
        /// recognition leaves out of a line.
        func marks(rows: [Row], rules: [CGRect], uprights: [CGRect], crop page: CGRect) -> (marks: [GraphicMark], bits: [CGRect]) {
            var marks: [GraphicMark] = []
            var bits: [CGRect] = []
            func add(_ kind: GraphicMark.Kind, _ rect: CGRect) {
                marks.append(GraphicMark(kind: kind, rect: rect, isWhite: false, location: OpLocation(stream: [-1], index: marks.count),
                                         hasCurves: false, segmentCount: 4, opRange: 0...0))
            }
            // The dark edge a scanner leaves around the page says nothing.
            let edge = page.insetBy(dx: page.width * 0.012, dy: page.height * 0.012)
            let thin = 3.2
            for rule in rules where rule.height <= thin && rule.intersects(edge) && edge.contains(CGPoint(x: edge.midX, y: rule.midY)) { add(.fill, rule) }
            for rule in uprights where rule.width <= thin && edge.contains(CGPoint(x: rule.midX, y: edge.midY)) { add(.fill, rule) }

            // Ink left over on a coarse grid.
            let cell = max(2, Int(2 * scale))
            let cols = width / cell + 1, lines = height / cell + 1
            var left = ink
            func clear(_ r: CGRect, _ dx: Double, _ dy: Double) {
                let x0 = max(0, px(r.minX - dx)), x1 = min(width - 1, px(r.maxX + dx))
                let y0 = max(0, py(r.maxY + dy)), y1 = min(height - 1, py(r.minY - dy))
                guard x1 >= x0, y1 >= y0 else { return }
                for y in y0...y1 { for x in x0...x1 { left[y * width + x] = 0 } }
            }
            for rule in rules where rule.height <= thin { clear(rule, 0.5, 0.5) }
            for rule in uprights where rule.width <= thin { clear(rule, 0.5, 0.5) }
            for row in rows {
                for word in row.words {
                    clear(word.ink ?? CGRect(x: word.x0, y: word.bottom, width: word.x1 - word.x0, height: word.height), row.size * 0.22, row.size * 0.12)
                }
                // A line of running text is words from end to end, whatever was not read in it.
                if !row.upright, row.letters >= 24 {
                    clear(CGRect(x: row.x0, y: row.baseline - row.size * 0.25, width: row.x1 - row.x0, height: row.size * 1.05), row.size * 0.3, row.size * 0.1)
                }
            }
            var grid = [Bool](repeating: false, count: cols * lines)
            let least = max(2, cell * cell / 12)
            for cy in 0..<lines {
                for cx in 0..<cols {
                    var n = 0
                    for y in cy * cell..<min(height, (cy + 1) * cell) {
                        let row = y * width
                        for x in cx * cell..<min(width, (cx + 1) * cell) { n += Int(left[row + x]) }
                    }
                    if n >= least { grid[cy * cols + cx] = true }
                }
            }
            // Cells within two of each other go together.
            var seen = [Bool](repeating: false, count: grid.count)
            for start in grid.indices where grid[start] && !seen[start] {
                var stack = [start]
                seen[start] = true
                var x0 = cols, x1 = 0, y0 = lines, y1 = 0, count = 0
                while let k = stack.popLast() {
                    let cx = k % cols, cy = k / cols
                    count += 1
                    x0 = min(x0, cx); x1 = max(x1, cx); y0 = min(y0, cy); y1 = max(y1, cy)
                    for ny in max(0, cy - 2)...min(lines - 1, cy + 2) {
                        for nx in max(0, cx - 2)...min(cols - 1, cx + 2) {
                            let j = ny * cols + nx
                            if grid[j], !seen[j] { seen[j] = true; stack.append(j) }
                        }
                    }
                }
                let r = rect(x0 * cell, y0 * cell, min(width - 1, (x1 + 1) * cell - 1), min(height - 1, (y1 + 1) * cell - 1))
                guard r.width >= 24, r.height >= 24, count >= 24 else {
                    if count >= 2, r.width < 80, r.height < 60, bits.count < 2000 { bits.append(r) }
                    continue
                }
                // The edge of the scan, all around or along a side.
                if r.width > page.width * 0.95 && r.height > page.height * 0.95 && Double(count * cell * cell) / scale / scale < r.width * r.height * 0.1 { continue }
                if !edge.contains(CGPoint(x: r.midX, y: r.midY)) { continue }
                add(.image, r)
            }
            return (marks, bits)
        }
    }
}
