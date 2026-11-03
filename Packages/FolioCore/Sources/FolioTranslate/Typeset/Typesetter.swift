import CoreGraphics
import CoreText
import Foundation

/// Where a formula is drawn in the translation: the original's rectangle, scaled and moved so its baseline
/// sits on `origin`.
struct Transplant: Sendable, Hashable {
    var formula: FormulaSpan
    var origin: CGPoint
    var scale: Double

    var transform: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x - scale * formula.rect.minX, ty: origin.y - scale * formula.baseline)
    }
}

/// Sets a translation into the space of the original block with Core Text: the same first baseline and line
/// pitch as the original where possible, smaller type and tighter lines when the text needs more room — never
/// outside `frame`.
struct Typesetter {
    let language: String

    init(language: String) {
        self.language = language
    }

    struct Result {
        var lines: [(line: CTLine, origin: CGPoint)]
        var transplants: [Transplant]
        var scale: Double
        var fits: Bool
        var pitch: Double = 0
    }

    enum Alignment { case justified, left, center }

    /// The lines of a translation at the size that fits, and the range of line spacing that keeps them in their
    /// frame. The caller picks the spacing (`finish`), so paragraphs of a page can share one.
    struct Plan {
        var lines: [(line: CTLine, x: Double)]
        var scale: Double
        var fontSize: Double
        var firstBaseline: Double
        /// The tightest spacing used to make it fit.
        var minPitch: Double
        /// The widest spacing that still ends inside the frame and reads well.
        var maxPitch: Double
        /// The spacing that ends on the original's last line: the block looks as full as the original.
        var fillPitch: Double
        var fits: Bool
    }

    /// Lays out `text` (with `{vN}` placeholders) for `block` inside `frame`, filling the original's height.
    func layout(_ text: String, block: LayoutBlock, formulas: [FormulaSpan], frame: CGRect) -> Result {
        let plan = plan(text, block: block, formulas: formulas, frame: frame)
        return finish(plan, pitch: plan.fillPitch, formulas: formulas)
    }

    func plan(_ text: String, block: LayoutBlock, formulas: [FormulaSpan], frame: CGRect) -> Plan {
        let size = block.size
        let pitch = block.pitch
        let alignment: Alignment = switch block.kind {
        case .paragraph, .caption: block.lines.count > 1 ? .justified : .left
        case .tableCell: .center
        default: block.isCentered ? .center : .left
        }
        let indent = block.kind == .paragraph ? block.firstLineIndent : 0
        let bold = block.kind == .title || block.kind == .heading || block.font.isBold
        let top = block.rect.maxY
        let firstBaseline = block.lines[0].baseline
        let lastBaseline = block.lines.last!.baseline

        var best: Plan?
        var scale = 1.0
        while scale >= 0.4 {
            let fontSize = size * scale
            // Chinese and Japanese need a little more air than the original's Latin lines.
            let minPitch = max(pitch * scale * 0.96, fontSize * 1.14)
            let attributed = attributedString(text, fontSize: fontSize, bold: bold, serif: block.font.isSerif || block.font.name.isEmpty,
                                              italic: false, color: block.color, formulas: formulas, scale: scale)
            let ranges = breakLineRanges(attributed, width: frame.width, indent: indent * scale)
            let ctLines = ranges.map(\.line)
            let baseline0 = top - (top - firstBaseline) * scale
            var lines: [(CTLine, Double)] = []
            for (k, raw) in ctLines.enumerated() {
                var line = raw
                let lineIndent = k == 0 ? indent * scale : 0
                let available = frame.width - lineIndent
                let isLast = k == ctLines.count - 1
                // Justify full lines only: stretching a short one (before an unbreakable citation list) leaves holes.
                let natural = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
                if alignment == .justified, !isLast, natural > available * 0.86 {
                    if spacesBetweenCharacters {
                        // Chinese and Japanese justify by spacing every character a little, not by stretching spaces.
                        line = Self.justifiedByKerning(attributed, range: ranges[k].range, extra: available - natural, fontSize: fontSize) ?? line
                    } else if let justified = CTLineCreateJustifiedLine(line, 1.0, available) {
                        line = justified
                    }
                }
                let width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
                var x = frame.minX + lineIndent
                if alignment == .center { x = frame.minX + max(0, (frame.width - width) / 2) }
                lines.append((line, x))
            }
            let gaps = Double(max(lines.count - 1, 0))
            let room = baseline0 - fontSize * 0.22 - frame.minY
            let widest = lines.map { CTLineGetTypographicBounds($0.0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0.0) }.max() ?? 0
            let fits = gaps * minPitch <= room + 0.5 && widest <= frame.width + 0.5
            var maxPitch = minPitch, fillPitch = minPitch
            if gaps > 0 {
                maxPitch = max(minPitch, min(fontSize * 1.85, (room + 0.5) / gaps))
                fillPitch = min(max((baseline0 - lastBaseline) / gaps, minPitch), maxPitch)
            }
            let plan = Plan(lines: lines, scale: scale, fontSize: fontSize, firstBaseline: baseline0, minPitch: minPitch,
                            maxPitch: maxPitch, fillPitch: fillPitch, fits: fits)
            if fits { return plan }
            best = plan
            scale -= scale > 0.7 ? 0.04 : 0.05
        }
        return best!
    }

    /// Places the planned lines `pitch` apart and finds where their formulas go.
    func finish(_ plan: Plan, pitch requested: Double, formulas: [FormulaSpan]) -> Result {
        let pitch = min(max(requested, plan.minPitch), plan.maxPitch)
        var placed: [(CTLine, CGPoint)] = []
        var transplants: [Transplant] = []
        for (k, entry) in plan.lines.enumerated() {
            let origin = CGPoint(x: entry.x, y: plan.firstBaseline - Double(k) * pitch)
            placed.append((entry.line, origin))
            transplants += Self.transplants(in: entry.line, origin: origin, formulas: formulas, scale: plan.scale)
        }
        return Result(lines: placed, transplants: transplants, scale: plan.scale, fits: plan.fits, pitch: pitch)
    }

    func draw(_ result: Result, in context: CGContext) {
        for (line, origin) in result.lines {
            context.textPosition = origin
            CTLineDraw(line, context)
        }
    }

    // MARK: Text

    static let formulaKey = NSAttributedString.Key("FolioFormula")

    private final class Metrics {
        let ascent: CGFloat, descent: CGFloat, width: CGFloat
        init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
            self.ascent = ascent
            self.descent = descent
            self.width = width
        }
    }

    func attributedString(_ raw: String, fontSize: Double, bold: Bool, serif: Bool, italic: Bool, color: RGBColor,
                          formulas: [FormulaSpan], scale: Double) -> NSAttributedString {
        // Long citation lists ("[7,21,25,26,31]") may break after their commas.
        let text = raw.replacingOccurrences(of: #"([,，])(?=\s?\d)"#, with: "$1\u{200B}", options: .regularExpression)
        let font = FontCatalog.font(language: language, size: fontSize, bold: bold, serif: serif)
        let cgColor = CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
        let base: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor,
        ]
        let result = NSMutableAttributedString()
        var used: Set<Int> = []
        let pattern = try! NSRegularExpression(pattern: #"\{\s*[vV]\s*(\d+)\s*\}"#)
        let ns = text as NSString
        var cursor = 0
        func appendFormula(_ n: Int) {
            guard n >= 1, n <= formulas.count else { return }
            used.insert(n)
            let f = formulas[n - 1]
            let metrics = Metrics(ascent: max(0, f.rect.maxY - f.baseline) * scale, descent: max(0, f.baseline - f.rect.minY) * scale,
                                  width: f.rect.width * scale)
            var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { ref in
                Unmanaged<Metrics>.fromOpaque(ref).release()
            }, getAscent: { ref in
                Unmanaged<Metrics>.fromOpaque(ref).takeUnretainedValue().ascent
            }, getDescent: { ref in
                Unmanaged<Metrics>.fromOpaque(ref).takeUnretainedValue().descent
            }, getWidth: { ref in
                Unmanaged<Metrics>.fromOpaque(ref).takeUnretainedValue().width
            })
            guard let delegate = CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(metrics).toOpaque()) else { return }
            var attributes = base
            attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
            attributes[Self.formulaKey] = n
            result.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: base))
            }
            appendFormula(Int(ns.substring(with: match.range(at: 1))) ?? 0)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: base)) }
        // Formulas the translation dropped still appear, at the end.
        for n in 1...max(formulas.count, 1) where n <= formulas.count && !used.contains(n) {
            result.append(NSAttributedString(string: " ", attributes: base))
            appendFormula(n)
        }
        return result
    }

    private func breakLines(_ text: NSAttributedString, width: Double, indent: Double) -> [CTLine] {
        breakLineRanges(text, width: width, indent: indent).map(\.line)
    }

    private func breakLineRanges(_ text: NSAttributedString, width: Double, indent: Double) -> [(line: CTLine, range: CFRange)] {
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        var lines: [(line: CTLine, range: CFRange)] = []
        var start = 0
        let length = text.length
        while start < length {
            let available = max(lines.isEmpty ? width - indent : width, 4)
            var count = CTTypesetterSuggestLineBreak(typesetter, start, available)
            if count <= 0 { count = 1 }
            // No line starts with a space.
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            lines.append((line, CFRange(location: start, length: count)))
            start += count
            while start < length, (text.string as NSString).character(at: start) == 0x20 { start += 1 }
        }
        return lines
    }

    /// Scripts set without spaces between words.
    var spacesBetweenCharacters: Bool { ["zh", "ja"].contains { language.lowercased().hasPrefix($0) } }

    /// The line again with `extra` points spread over the gaps between its characters.
    static func justifiedByKerning(_ text: NSAttributedString, range: CFRange, extra: Double, fontSize: Double) -> CTLine? {
        let ns = text.string as NSString
        var length = range.length
        while length > 0, CharacterSet.whitespaces.contains(UnicodeScalar(ns.character(at: range.location + length - 1)) ?? " ") { length -= 1 }
        guard length > 1, extra > 0 else { return nil }
        let kern = extra / Double(length - 1)
        guard kern < fontSize * 0.3 else { return nil }
        let line = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: range.location, length: range.length)))
        line.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: kern, range: NSRange(location: 0, length: length - 1))
        return CTLineCreateWithAttributedString(line)
    }

    static func transplants(in line: CTLine, origin: CGPoint, formulas: [FormulaSpan], scale: Double) -> [Transplant] {
        var result: [Transplant] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let n = attributes[formulaKey] as? Int, n >= 1, n <= formulas.count, CTRunGetGlyphCount(run) > 0 else { continue }
            var position = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
            result.append(Transplant(formula: formulas[n - 1], origin: CGPoint(x: origin.x + position.x, y: origin.y + position.y), scale: scale))
        }
        return result
    }
}

/// Fonts for translated text: a Latin face like the paper's (Times or Helvetica) with the target script's
/// system font behind it for everything Latin fonts lack.
enum FontCatalog {
    nonisolated(unsafe) private static var cache: [String: CTFontDescriptor] = [:]
    private static let lock = NSLock()

    static func font(language: String, size: Double, bold: Bool, serif: Bool) -> CTFont {
        let key = "\(language)|\(bold)|\(serif)"
        lock.lock()
        defer { lock.unlock() }
        if let descriptor = cache[key] { return CTFontCreateWithFontDescriptor(descriptor, size, nil) }
        let latin = serif ? (bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT") : (bold ? "Helvetica-Bold" : "Helvetica")
        let script = scriptFont(language: language, bold: bold, serif: serif)
        var attributes: [CFString: Any] = [kCTFontNameAttribute: latin]
        if let script {
            attributes[kCTFontCascadeListAttribute] = [CTFontDescriptorCreateWithNameAndSize(script as CFString, 0)]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        cache[key] = descriptor
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    static func scriptFont(language: String, bold: Bool, serif: Bool) -> String? {
        switch language.lowercased() {
        case "zh", "zh-cn", "zh-hans", "zh-sg":
            serif ? (bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular") : (bold ? "PingFangSC-Semibold" : "PingFangSC-Regular")
        case "zh-tw", "zh-hk", "zh-hant":
            serif ? (bold ? "STSongti-TC-Bold" : "STSongti-TC-Regular") : (bold ? "PingFangTC-Semibold" : "PingFangTC-Regular")
        case "ja":
            serif ? (bold ? "HiraMinProN-W6" : "HiraMinProN-W3") : (bold ? "HiraginoSans-W6" : "HiraginoSans-W3")
        case "ko":
            serif ? (bold ? "AppleMyungjo" : "AppleMyungjo") : (bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular")
        case "ar":
            "GeezaPro"
        case "th":
            "Thonburi"
        case "hi":
            "KohinoorDevanagari-Regular"
        default:
            nil
        }
    }
}
