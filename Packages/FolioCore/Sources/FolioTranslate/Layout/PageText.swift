import CoreGraphics
import Foundation
import PDFKit

/// One character of a page: PDFKit's text, position, size and baseline offset, joined with the font and colour
/// of the content-stream operator that drew it.
struct PageChar: Sendable {
    var text: String
    /// Selection bounds in page space: exact horizontally, a line's height vertically.
    var rect: CGRect
    var isSpace: Bool
    var isNewline: Bool
    /// Em size in page space.
    var size: Double
    var baseline: Double
    var font: FontInfo
    var color: RGBColor
    var run: Int?
    var isRotated: Bool
    var isMath = false
    /// Raised or lowered from the line's baseline (PDFKit's baseline offset): a superscript or subscript.
    var isScript = false

    var center: CGPoint { CGPoint(x: rect.midX, y: baseline + size * 0.3) }

    /// The glyph's box from its baseline and size.
    var glyphBox: CGRect {
        let width = min(rect.width, size * 1.1)
        var box = CGRect(x: rect.minX, y: baseline - size * 0.28, width: max(width, 0.1), height: size * 1.2)
        // Big operators and delimiters reach beyond the em box.
        if MathDetector.isMathFont(font.name), font.name.lowercased().contains("ex") { box = box.union(rect) }
        return box
    }
}

/// Serialises PDFKit text extraction with the rest of the app (PDFKit's attributed strings are not thread-safe).
public enum PDFKitAccess {
    nonisolated(unsafe) public static var serialize: (@Sendable (() -> Void) -> Void) = { body in
        lock.lock()
        defer { lock.unlock() }
        body()
    }
    private static let lock = NSRecursiveLock()
}

enum PageText {
    private static let baselineOffsetKey = NSAttributedString.Key("CTBaselineOffset")

    /// The characters of `page` in PDFKit's reading order. `runs` come from interpreting the same page.
    static func characters(of page: PDFPage, runs: [TextRun]) -> [PageChar] {
        var string: String?
        var attributed: NSAttributedString?
        PDFKitAccess.serialize {
            string = page.string
            attributed = page.attributedString
        }
        guard let string, !string.isEmpty else { return [] }
        let ns = string as NSString
        let index = RunIndex(runs: runs)
        var chars: [PageChar] = []
        chars.reserveCapacity(ns.length)
        // Baseline of the line being read: offsets are relative to it.
        var lineBaseline: Double?
        var previousLineBaseline: Double?
        var lastRun: Int?
        var lastFont = FontInfo.unknown
        var lastColor = RGBColor.black
        var i = 0
        while i < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: i)
            let text = ns.substring(with: range)
            i = range.location + range.length
            if text.isEmpty || text == "\u{0}" { continue }
            // `characterBounds(at:)` drifts by one after every line break PDFKit inserts; selections are exact.
            var rect = CGRect.zero
            PDFKitAccess.serialize { rect = page.selection(for: range)?.bounds(for: page) ?? .zero }
            var size = rect.height / 1.2
            var offset = 0.0
            if let attributed, range.location < attributed.length {
                let attributes = attributed.attributes(at: range.location, effectiveRange: nil)
                if let font = attributes[.font] as? NSFont, font.pointSize > 0 { size = font.pointSize }
                if let value = attributes[baselineOffsetKey] as? NSNumber { offset = value.doubleValue }
            }
            let isNewline = text == "\n" || text == "\r" || text == "\r\n" || text == "\u{2028}"
            let isSpace = !isNewline && text.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
            var char = PageChar(text: text, rect: rect, isSpace: isSpace, isNewline: isNewline, size: max(size, 1),
                                baseline: (lineBaseline ?? rect.minY + rect.height * 0.22) + offset,
                                font: lastFont, color: lastColor, run: nil, isRotated: false, isScript: abs(offset) > 0.01)
            if isNewline {
                // PDFKit sometimes breaks a line between a superscript and its subscript: offsets still refer
                // to the line before.
                previousLineBaseline = lineBaseline ?? previousLineBaseline
                lineBaseline = nil
            }
            if !isSpace, !isNewline, rect.width > 0 || rect.height > 0 {
                let reference = lineBaseline ?? (abs(offset) > 0.01 ? previousLineBaseline : nil)
                // Without a line to refer to, the selection's bottom edge is about a fifth of an em below the baseline.
                let expected = reference.map { $0 + offset } ?? (rect.minY + char.size * 0.22 + offset)
                char.baseline = expected
                if let r = index.run(for: rect, size: char.size, baseline: expected, hint: lastRun)
                    ?? index.run(for: rect, size: char.size, baseline: nil, hint: lastRun) {
                    let run = runs[r]
                    char.run = r
                    char.size = run.fontSize
                    char.baseline = run.isHorizontal ? run.origin.y : char.baseline
                    char.font = run.font
                    char.color = run.color
                    char.isRotated = !run.isHorizontal
                    lastRun = r
                    lastFont = run.font
                    lastColor = run.color
                    if abs(offset) < 0.01, run.isHorizontal { lineBaseline = run.origin.y }
                    else if lineBaseline == nil, run.isHorizontal { lineBaseline = run.origin.y - offset }
                }
            }
            chars.append(char)
        }
        return chars
    }

    /// Finds the run that drew a glyph: the right size, overlapping horizontally, on the expected baseline.
    private struct RunIndex {
        let runs: [TextRun]
        var buckets: [Int: [Int]] = [:]
        static let bucketHeight = 8.0

        init(runs: [TextRun]) {
            self.runs = runs
            for (i, run) in runs.enumerated() {
                let box = run.box
                let lo = Int((box.minY / Self.bucketHeight).rounded(.down)), hi = Int((box.maxY / Self.bucketHeight).rounded(.down))
                guard hi - lo < 400 else { continue }
                for b in lo...hi { buckets[b, default: []].append(i) }
            }
        }

        func run(for rect: CGRect, size: Double, baseline: Double?, hint: Int?) -> Int? {
            let probeY = baseline.map { $0 + size * 0.3 } ?? rect.midY
            var candidates: Set<Int> = []
            for b in [probeY - size, probeY, probeY + size] {
                candidates.formUnion(buckets[Int((b / Self.bucketHeight).rounded(.down))] ?? [])
            }
            if let hint { candidates.insert(hint) }
            var best: Int?
            var bestScore = Double.infinity
            for i in candidates {
                let run = runs[i]
                let box = run.box
                // Horizontal overlap (run widths are estimates: allow a little slack).
                let overlap = min(box.maxX + 1.5, rect.maxX) - max(box.minX - 1.5, rect.minX)
                guard overlap > 0 || (rect.width < 0.5 && box.insetBy(dx: -1.5, dy: 0).contains(CGPoint(x: rect.midX, y: box.midY))) else { continue }
                guard rect.minY - 1 < box.maxY, rect.maxY + 1 > box.minY else { continue }
                var score = 0.0
                if run.isHorizontal {
                    let sizeDifference = abs(run.fontSize - size) / max(size, 1)
                    if sizeDifference > 0.2 { continue }
                    score += sizeDifference * 4
                    if let baseline { score += abs(run.origin.y - baseline) / max(size, 1) }
                    else { score += abs(box.midY - rect.midY) / max(box.height, 1) }
                } else {
                    score += 0.5
                }
                // Later runs draw on top; the hint is the previous glyph's run.
                score -= Double(i) * 1e-9
                if i == hint { score -= 0.05 }
                if score < bestScore {
                    bestScore = score
                    best = i
                }
            }
            return bestScore < 1.5 ? best : nil
        }
    }
}

extension TextRun {
    /// The run's em box in page space (rotated runs: the bounding box of the rotated box).
    var box: CGRect {
        let up = CGPoint(x: -sin(angle) * fontSize, y: cos(angle) * fontSize)
        let down = CGPoint(x: -up.x * 0.25, y: -up.y * 0.25)
        let points = [
            CGPoint(x: origin.x + down.x, y: origin.y + down.y), CGPoint(x: end.x + down.x, y: end.y + down.y),
            CGPoint(x: origin.x + up.x, y: origin.y + up.y), CGPoint(x: end.x + up.x, y: end.y + up.y),
        ]
        return ContentInterpreter.bounds(of: points)
    }
}
