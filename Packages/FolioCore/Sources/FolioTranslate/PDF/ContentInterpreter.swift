import CoreGraphics
import Foundation

/// Which content stream an operator belongs to: the page's own content (`[]`), or a form XObject reached through
/// `Do` operators at these indexes (`[12]` = the form drawn by op 12 of the page, `[12, 3]` = a form inside it).
/// Each invocation of a form is its own stream, so a form drawn twice can be edited differently each time.
typealias StreamPath = [Int]

struct OpLocation: Hashable, Sendable {
    var stream: StreamPath
    var index: Int
}

/// One text-showing operator (`Tj`, `TJ`, `'`, `"`) and where it draws, in page space.
struct TextRun: Sendable {
    var location: OpLocation
    var origin: CGPoint
    var end: CGPoint
    /// Em size in page space.
    var fontSize: Double
    /// Baseline direction in radians (0 = left to right).
    var angle: Double
    /// Text rendering mode in effect (`Tr`).
    var renderMode: Int
    /// Runs in the same chain are positioned relative to each other: removing one moves the later ones.
    var chain: Int
    var font: FontInfo
    /// Fill color as RGB 0…1.
    var color: RGBColor

    var isHorizontal: Bool { abs(angle) < 0.02 }
    /// The run's baseline box, one em high.
    var bounds: CGRect {
        let minX = min(origin.x, end.x), maxX = max(origin.x, end.x)
        return CGRect(x: minX, y: min(origin.y, end.y) - fontSize * 0.25, width: max(maxX - minX, 0.1), height: fontSize * 1.1)
    }
    var midpoint: CGPoint { CGPoint(x: (origin.x + end.x) / 2, y: (origin.y + end.y) / 2 + fontSize * 0.3) }
}

/// Something painted that is not text.
struct GraphicMark: Sendable {
    enum Kind: Sendable { case image, fill, stroke, shading }
    var kind: Kind
    var rect: CGRect
    /// Filled with white (a background or a mask, not content).
    var isWhite: Bool
    var location: OpLocation
    /// Bezier curves in the path (plots and drawings, unlike table rules and boxes).
    var hasCurves: Bool
    var segmentCount: Int
    /// The operators that built and painted it (path construction … paint), in `location.stream`.
    var opRange: ClosedRange<Int>
}

/// A content stream the interpreter visited.
struct InterpretedStream {
    /// The decoded stream; `ops` ranges index into it.
    var source: Data
    var ops: [ContentOp]
    /// The form's stream (nil for the page).
    var form: CGPDFStreamRef?
    var resources: CGPDFDictionaryRef?
}

/// Runs a page's content streams through the graphics and text state machine (PDF 32000-1 §8–9) without
/// rendering, collecting where each text operator draws and the bounds of images and paths.
final class ContentInterpreter {
    private(set) var runs: [TextRun] = []
    private(set) var marks: [GraphicMark] = []
    private(set) var streams: [StreamPath: InterpretedStream] = [:]

    private var fontCache: [Int: FontMetrics] = [:]
    private var chainCounter = 0

    private struct GState {
        var ctm: CGAffineTransform
        var clip: CGRect?
        var fillWhite = false
        var charSpacing = 0.0
        var wordSpacing = 0.0
        var hScale = 1.0
        var leading = 0.0
        var font: FontMetrics?
        var fontSize = 0.0
        var fillColor = RGBColor.black
        var rise = 0.0
        var render = 0
    }

    /// Interprets the page. `pageTransform` maps the page's user space to the space positions are reported in
    /// (identity for the page's own coordinates).
    func run(page: CGPDFPage, pageTransform: CGAffineTransform = .identity) {
        guard let dict = page.dictionary else { return }
        let source = PDFDictionary.contents(of: dict)
        let ops = ContentLexer.parse(source)
        let resources = PDFDictionary.resources(of: dict)
        streams[[]] = InterpretedStream(source: source, ops: ops, form: nil, resources: resources)
        var state = GState(ctm: pageTransform)
        interpret(ops, path: [], resources: resources, state: &state, depth: 0)
    }

    private func interpret(_ ops: [ContentOp], path: StreamPath, resources: CGPDFDictionaryRef?, state initial: inout GState, depth: Int) {
        var gs = initial
        var stack: [GState] = []
        var tm = CGAffineTransform.identity
        var tlm = CGAffineTransform.identity
        var pathPoints: [CGPoint] = []
        var pathCurves = false
        var pathSegments = 0
        var pathStart: Int?
        var pendingClip = false
        var currentPoint = CGPoint.zero

        func newChain() { chainCounter += 1 }

        func addPoint(_ x: Double, _ y: Double) {
            let p = CGPoint(x: x, y: y).applying(gs.ctm)
            pathPoints.append(p)
        }

        func paint(_ kind: GraphicMark.Kind?, index: Int) {
            let start = pathStart ?? index
            defer {
                pathPoints = []
                pathCurves = false
                pathSegments = 0
                pathStart = nil
                pendingClip = false
            }
            guard !pathPoints.isEmpty else { return }
            var rect = Self.bounds(of: pathPoints)
            if pendingClip {
                gs.clip = gs.clip.map { $0.intersection(rect) } ?? rect
            }
            guard let kind else { return }
            if let clip = gs.clip {
                // Hairlines have zero height or width; keep them unless clipped away entirely.
                let clipped = rect.insetBy(dx: -0.01, dy: -0.01).intersection(clip)
                if clipped.isNull { return }
                rect = clipped
            }
            marks.append(GraphicMark(kind: kind, rect: rect, isWhite: kind == .fill && gs.fillWhite,
                                     location: OpLocation(stream: path, index: index),
                                     hasCurves: pathCurves, segmentCount: pathSegments, opRange: start...index))
        }

        func setFillColor(_ operands: [ContentOperand]) {
            let n = operands.compactMap(\.number)
            switch n.count {
            case 1: gs.fillColor = RGBColor(r: n[0], g: n[0], b: n[0])
            case 3: gs.fillColor = RGBColor(r: n[0], g: n[1], b: n[2])
            case 4: gs.fillColor = RGBColor(r: (1 - n[0]) * (1 - n[3]), g: (1 - n[1]) * (1 - n[3]), b: (1 - n[2]) * (1 - n[3]))
            default: gs.fillColor = .black
            }
            gs.fillWhite = n.count > 0 && gs.fillColor.r >= 0.99 && gs.fillColor.g >= 0.99 && gs.fillColor.b >= 0.99
        }

        func show(_ index: Int, _ elements: [ContentOperand]) {
            let trm = tm.concatenating(gs.ctm)
            let origin = CGPoint(x: 0, y: gs.rise).applying(trm)
            var tx = 0.0
            for element in elements {
                switch element {
                case .string(let data):
                    tx += gs.font?.advance(of: data, size: gs.fontSize, charSpacing: gs.charSpacing,
                                          wordSpacing: gs.wordSpacing, hScale: gs.hScale)
                        ?? Double(data.count) * gs.fontSize * 0.5 * gs.hScale
                case .number(let adjust):
                    tx -= adjust / 1000 * gs.fontSize * gs.hScale
                default: break
                }
            }
            let end = CGPoint(x: tx, y: gs.rise).applying(trm)
            let up = CGPoint(x: 0, y: gs.fontSize).applying(CGAffineTransform(a: trm.a, b: trm.b, c: trm.c, d: trm.d, tx: 0, ty: 0))
            let right = CGPoint(x: 1, y: 0).applying(CGAffineTransform(a: trm.a, b: trm.b, c: trm.c, d: trm.d, tx: 0, ty: 0))
            runs.append(TextRun(location: OpLocation(stream: path, index: index), origin: origin, end: end,
                                fontSize: hypot(up.x, up.y), angle: atan2(right.y, right.x),
                                renderMode: gs.render, chain: chainCounter, font: gs.font?.info ?? .unknown, color: gs.fillColor))
            tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm)
        }

        func nextLine() {
            tlm = CGAffineTransform(translationX: 0, y: -gs.leading).concatenating(tlm)
            tm = tlm
            newChain()
        }

        for (index, op) in ops.enumerated() {
            let o = op.operands
            func num(_ i: Int) -> Double { i < o.count ? (o[i].number ?? 0) : 0 }
            if pathStart == nil, Self.pathConstruction.contains(op.name) { pathStart = index }
            switch op.name {
            // Graphics state
            case "q": stack.append(gs)
            case "Q": if let last = stack.popLast() { gs = last }
            case "cm":
                let m = CGAffineTransform(a: num(0), b: num(1), c: num(2), d: num(3), tx: num(4), ty: num(5))
                gs.ctm = m.concatenating(gs.ctm)
            case "g", "rg", "k", "sc", "scn": setFillColor(o)
            case "cs":
                gs.fillWhite = false
                gs.fillColor = .black
            // Paths
            case "m":
                addPoint(num(0), num(1))
                currentPoint = CGPoint(x: num(0), y: num(1))
            case "l":
                addPoint(num(0), num(1))
                currentPoint = CGPoint(x: num(0), y: num(1))
                pathSegments += 1
            case "c":
                addPoint(num(0), num(1)); addPoint(num(2), num(3)); addPoint(num(4), num(5))
                currentPoint = CGPoint(x: num(4), y: num(5))
                pathCurves = true
                pathSegments += 1
            case "v", "y":
                addPoint(num(0), num(1)); addPoint(num(2), num(3))
                currentPoint = CGPoint(x: num(2), y: num(3))
                pathCurves = true
                pathSegments += 1
            case "re":
                let x = num(0), y = num(1), w = num(2), h = num(3)
                addPoint(x, y); addPoint(x + w, y); addPoint(x + w, y + h); addPoint(x, y + h)
                currentPoint = CGPoint(x: x, y: y)
                pathSegments += 4
            case "h": break
            case "W", "W*": pendingClip = true
            case "S", "s": paint(.stroke, index: index)
            case "f", "F", "f*": paint(.fill, index: index)
            case "B", "B*", "b", "b*": paint(.fill, index: index)
            case "n": paint(nil, index: index)
            case "sh":
                if let clip = gs.clip {
                    marks.append(GraphicMark(kind: .shading, rect: clip, isWhite: false, location: OpLocation(stream: path, index: index),
                                             hasCurves: false, segmentCount: 0, opRange: index...index))
                }
            // XObjects and inline images
            case "Do":
                guard let name = o.first?.name, let resources,
                      let xobjects = PDFDictionary.dict(resources, "XObject"),
                      let stream = PDFDictionary.stream(xobjects, name),
                      let dict = CGPDFStreamGetDictionary(stream) else { break }
                let subtype = PDFDictionary.name(dict, "Subtype")
                if subtype == "Image" {
                    addImageMark(ctm: gs.ctm, clip: gs.clip, location: OpLocation(stream: path, index: index))
                } else if subtype == "Form", depth < 12 {
                    let formPath = path + [index]
                    let formSource = Self.data(of: stream)
                    let formOps = ContentLexer.parse(formSource)
                    let formResources = PDFDictionary.dict(dict, "Resources") ?? resources
                    streams[formPath] = InterpretedStream(source: formSource, ops: formOps, form: stream, resources: formResources)
                    var inner = gs
                    if let matrix = PDFDictionary.matrix(dict, "Matrix") { inner.ctm = matrix.concatenating(gs.ctm) }
                    if let bbox = PDFDictionary.rect(dict, "BBox") {
                        let box = bbox.applying(inner.ctm)
                        inner.clip = inner.clip.map { $0.intersection(box) } ?? box
                    }
                    newChain()
                    interpret(formOps, path: formPath, resources: formResources, state: &inner, depth: depth + 1)
                    newChain()
                }
            case "BI":
                addImageMark(ctm: gs.ctm, clip: gs.clip, location: OpLocation(stream: path, index: index))
            // Text objects and state
            case "BT":
                tm = .identity
                tlm = .identity
                newChain()
            case "ET": newChain()
            case "Tc": gs.charSpacing = num(0)
            case "Tw": gs.wordSpacing = num(0)
            case "Tz": gs.hScale = num(0) / 100
            case "TL": gs.leading = num(0)
            case "Ts": gs.rise = num(0)
            case "Tr": gs.render = Int(num(0))
            case "Tf":
                gs.fontSize = num(1)
                gs.font = o.first?.name.flatMap { font(named: $0, resources: resources) }
            case "Td":
                tlm = CGAffineTransform(translationX: num(0), y: num(1)).concatenating(tlm)
                tm = tlm
                newChain()
            case "TD":
                gs.leading = -num(1)
                tlm = CGAffineTransform(translationX: num(0), y: num(1)).concatenating(tlm)
                tm = tlm
                newChain()
            case "Tm":
                tlm = CGAffineTransform(a: num(0), b: num(1), c: num(2), d: num(3), tx: num(4), ty: num(5))
                tm = tlm
                newChain()
            case "T*": nextLine()
            case "Tj":
                if let s = o.first { show(index, [s]) }
            case "'":
                nextLine()
                if let s = o.last { show(index, [s]) }
            case "\"":
                gs.wordSpacing = num(0)
                gs.charSpacing = num(1)
                nextLine()
                if let s = o.last { show(index, [s]) }
            case "TJ":
                if case .array(let elements)? = o.first { show(index, elements) }
            default:
                break
            }
        }
        _ = currentPoint
    }

    static let pathConstruction: Set<String> = ["m", "l", "c", "v", "y", "re", "h"]

    private func addImageMark(ctm: CGAffineTransform, clip: CGRect?, location: OpLocation) {
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(ctm)
        if let clip { rect = rect.intersection(clip) }
        guard !rect.isNull, rect.width > 0.5, rect.height > 0.5 else { return }
        marks.append(GraphicMark(kind: .image, rect: rect, isWhite: false, location: location, hasCurves: false, segmentCount: 0,
                                 opRange: location.index...location.index))
    }

    private func font(named name: String, resources: CGPDFDictionaryRef?) -> FontMetrics? {
        guard let resources, let fonts = PDFDictionary.dict(resources, "Font"),
              let dict = PDFDictionary.dict(fonts, name) else { return nil }
        let key = PDFCopier.key(dict)
        if let cached = fontCache[key] { return cached }
        let metrics = FontMetrics(dict)
        fontCache[key] = metrics
        return metrics
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func data(of stream: CGPDFStreamRef) -> Data {
        var format = CGPDFDataFormat.raw
        return (CGPDFStreamCopyData(stream, &format) as Data?) ?? Data()
    }
}

/// Glyph widths of a font, enough to advance the text position after a show operator.
final class FontMetrics {
    let twoByte: Bool
    let info: FontInfo
    private var widths: [Int: Double] = [:]
    private let defaultWidth: Double

    init(_ dict: CGPDFDictionaryRef) {
        let subtype = PDFDictionary.name(dict, "Subtype")
        info = FontInfo(dict)
        if subtype == "Type0" {
            twoByte = true
            var dw = 1000.0
            if let descendants = PDFDictionary.array(dict, "DescendantFonts") {
                var cid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(descendants, 0, &cid), let cid {
                    dw = PDFDictionary.number(cid, "DW") ?? 1000
                    if let w = PDFDictionary.array(cid, "W") { widths = Self.cidWidths(w) }
                }
            }
            defaultWidth = dw / 1000
        } else {
            twoByte = false
            var scale = 1.0 / 1000
            if subtype == "Type3", let matrix = PDFDictionary.array(dict, "FontMatrix") {
                scale = PDFDictionary.numbers(matrix).first ?? scale
            }
            let first = Int(PDFDictionary.number(dict, "FirstChar") ?? 0)
            if let w = PDFDictionary.array(dict, "Widths") {
                for (i, value) in PDFDictionary.numbers(w).enumerated() { widths[first + i] = value * scale }
            }
            var missing = 0.5
            if let descriptor = PDFDictionary.dict(dict, "FontDescriptor"),
               let value = PDFDictionary.number(descriptor, "MissingWidth"), value > 0 {
                missing = value * scale
            } else if !widths.isEmpty {
                let nonZero = widths.values.filter { $0 > 0 }
                if !nonZero.isEmpty { missing = nonZero.reduce(0, +) / Double(nonZero.count) }
            }
            defaultWidth = missing
        }
    }

    /// `/W [c [w1 w2 …] cFirst cLast w …]` → widths in text space units.
    private static func cidWidths(_ array: CGPDFArrayRef) -> [Int: Double] {
        var result: [Int: Double] = [:]
        let count = CGPDFArrayGetCount(array)
        var i = 0
        func number(_ index: Int) -> Double? {
            var value: CGPDFReal = 0
            return CGPDFArrayGetNumber(array, index, &value) ? Double(value) : nil
        }
        while i < count {
            guard let first = number(i) else { break }
            var list: CGPDFArrayRef?
            if CGPDFArrayGetArray(array, i + 1, &list), let list {
                for (offset, w) in PDFDictionary.numbers(list).enumerated() { result[Int(first) + offset] = w / 1000 }
                i += 2
            } else if let last = number(i + 1), let w = number(i + 2) {
                if last - first <= 65535, last >= first {
                    for c in Int(first)...Int(last) { result[c] = w / 1000 }
                }
                i += 3
            } else {
                break
            }
        }
        return result
    }

    func advance(of data: Data, size: Double, charSpacing: Double, wordSpacing: Double, hScale: Double) -> Double {
        var total = 0.0
        if twoByte {
            var i = data.startIndex
            while i + 1 < data.endIndex {
                let code = Int(data[i]) << 8 | Int(data[i + 1])
                total += ((widths[code] ?? defaultWidth) * size + charSpacing) * hScale
                i += 2
            }
        } else {
            for byte in data {
                let code = Int(byte)
                total += ((widths[code] ?? defaultWidth) * size + charSpacing + (code == 32 ? wordSpacing : 0)) * hScale
            }
        }
        return total
    }
}


struct RGBColor: Sendable, Hashable {
    var r: Double, g: Double, b: Double
    static let black = RGBColor(r: 0, g: 0, b: 0)
}

/// What the layout needs to know about a font: its name and style.
struct FontInfo: Sendable, Hashable {
    /// BaseFont without the subset prefix ("ABCDEF+Times-Bold" → "Times-Bold").
    var name: String
    var isBold: Bool
    var isItalic: Bool
    var isMonospace: Bool
    var isSerif: Bool
    var isSymbolic: Bool

    static let unknown = FontInfo(name: "", isBold: false, isItalic: false, isMonospace: false, isSerif: true, isSymbolic: false)

    init(name: String, isBold: Bool, isItalic: Bool, isMonospace: Bool, isSerif: Bool, isSymbolic: Bool) {
        self.name = name
        self.isBold = isBold
        self.isItalic = isItalic
        self.isMonospace = isMonospace
        self.isSerif = isSerif
        self.isSymbolic = isSymbolic
    }

    init(_ dict: CGPDFDictionaryRef) {
        var base = PDFDictionary.name(dict, "BaseFont") ?? ""
        var descriptor = PDFDictionary.dict(dict, "FontDescriptor")
        if PDFDictionary.name(dict, "Subtype") == "Type0", let descendants = PDFDictionary.array(dict, "DescendantFonts") {
            var cid: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(descendants, 0, &cid), let cid {
                descriptor = PDFDictionary.dict(cid, "FontDescriptor") ?? descriptor
                if base.isEmpty { base = PDFDictionary.name(cid, "BaseFont") ?? "" }
            }
        }
        if let plus = base.firstIndex(of: "+"), base.distance(from: base.startIndex, to: plus) == 6 {
            base = String(base[base.index(after: plus)...])
        }
        let flags = descriptor.flatMap { PDFDictionary.number($0, "Flags") }.map { Int($0) } ?? 0
        let weight = descriptor.flatMap { PDFDictionary.number($0, "FontWeight") } ?? 0
        let lower = base.lowercased()
        name = base
        isMonospace = flags & 1 != 0 || ["mono", "courier", "cmtt", "consol", "menlo", "inconsolata", "lmtt", "sfmono", "typewriter"].contains { lower.contains($0) }
        isSerif = flags & 2 != 0 || ["times", "roman", "serif", "cmr", "lmroman", "nimbusrom", "garamond", "georgia", "palatino", "minion", "cambria", "utopia", "charter", "stix", "libertine", "mincho", "song"].contains { lower.contains($0) } && !lower.contains("sans")
        isSymbolic = flags & 4 != 0 && flags & 32 == 0
        isItalic = flags & 64 != 0 || ["italic", "oblique", "-it", "cmti", "cmmi"].contains { lower.contains($0) }
        isBold = flags & 262144 != 0 || weight >= 600 || ["bold", "black", "heavy", "semibold", "cmbx", "-bd", "demi"].contains { lower.contains($0) }
    }
}
