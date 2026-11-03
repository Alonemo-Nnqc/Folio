import Foundation

/// Marks characters that belong to formulas: glyphs from math fonts, mathematical symbols, and sub- or
/// superscripts. Inline formulas are kept as drawn (moved into the translation) instead of being translated.
enum MathDetector {
    private static let mathFonts = [
        "cmmi", "cmsy", "cmex", "cmbsy", "cmmib", "msbm", "msam", "eufm", "eusm", "eurm", "rsfs", "lmmath", "math",
        "symbol", "mtmi", "mtsy", "mtex", "mathematica", "euclid", "esint", "wasy", "stmary", "txsy", "pxsy", "txmi",
        "pxmi", "txex", "pxex", "rtxmi", "ntxmi", "ntxsy", "zplm", "mnsymbol", "mdput", "mdbch", "lmsy", "lmmi", "cmbrm",
        "dsrom", "bbold", "bbm", "mathdesign", "stixgeneral-italic", "xits", "fourier", "lucidanewmath", "advp",
    ]

    static func isMathFont(_ name: String) -> Bool {
        let lower = name.lowercased()
        return mathFonts.contains { lower.contains($0) }
    }

    static func isMathScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2200...0x22FF, 0x27C0...0x27EF, 0x2980...0x2AFF, 0x1D400...0x1D7FF, 0x2190...0x21FF, 0x2A00...0x2AFF: true
        case 0x221E, 0x2032, 0x2033, 0x00B1, 0x00D7, 0x00F7, 0x2016: true
        // Accents set over symbols (ŷ, x̃, x̄): spacing modifiers and combining marks.
        case 0x02C6...0x02DD, 0x0300...0x036F, 0x00AF, 0x00A8, 0x00B4, 0x02D9, 0x20D0...0x20FF: true
        default: false
        }
    }

    static func isGreek(_ scalar: Unicode.Scalar) -> Bool { (0x0391...0x03C9).contains(scalar.value) || (0x03D0...0x03F5).contains(scalar.value) }

    /// Characters that continue a formula when they touch one: operators, digits, brackets.
    static let joiners: Set<Character> = Set("=+-−–×·*/()[]{}|^_<>0123456789'.,:;!∗")

    /// Sets `isMath` on `chars` (one page, reading order).
    static func mark(_ chars: inout [PageChar]) {
        // 1. Characters that are math by themselves.
        for i in chars.indices where !chars[i].isSpace && !chars[i].isNewline {
            let c = chars[i]
            let scalars = c.text.unicodeScalars
            if isMathFont(c.font.name) && !c.font.name.lowercased().contains("cmr") {
                chars[i].isMath = true
            } else if scalars.contains(where: isMathScalar) {
                chars[i].isMath = true
            } else if scalars.contains(where: isGreek), c.font.isItalic || isMathFont(c.font.name) {
                chars[i].isMath = true
            }
        }
        // 2. Sub- and superscripts: smaller and off the baseline of the text around them.
        for i in chars.indices where !chars[i].isSpace && !chars[i].isNewline && !chars[i].isMath && chars[i].run != nil {
            guard let host = neighbour(of: i, in: chars) else { continue }
            let c = chars[i]
            if c.size < host.size * 0.82, abs(c.baseline - host.baseline) > host.size * 0.12 {
                chars[i].isMath = true
            }
        }
        // 3. Grow formulas over touching operators and digits, and over spaces between two formula parts.
        var changed = true
        var passes = 0
        while changed && passes < 4 {
            changed = false
            passes += 1
            for i in chars.indices where !chars[i].isMath && !chars[i].isNewline {
                let prev = previousVisible(i, chars), next = nextVisible(i, chars)
                if chars[i].isSpace {
                    if let p = prev, let n = next, chars[p].isMath, chars[n].isMath, chars[n].rect.minX - chars[p].rect.maxX < chars[p].size * 0.9 {
                        chars[i].isMath = true
                        changed = true
                    }
                    continue
                }
                guard let ch = chars[i].text.first, joiners.contains(ch), chars[i].text.count == 1 else { continue }
                let touchesPrev = prev.map { $0 == i - 1 && chars[$0].isMath } ?? false
                let touchesNext = next.map { $0 == i + 1 && chars[$0].isMath } ?? false
                // Sentence punctuation after a formula stays text.
                if ".,:;!".contains(ch), !touchesNext { continue }
                if touchesPrev || touchesNext {
                    chars[i].isMath = true
                    changed = true
                }
            }
        }
        // 4. A lone italic letter between text is a variable only when a math font says so; drop single
        //    math-marked spaces at the edges of formulas.
        for i in chars.indices where chars[i].isMath && chars[i].isSpace {
            let p = previousVisible(i, chars), n = nextVisible(i, chars)
            if !(p.map { chars[$0].isMath } ?? false) || !(n.map { chars[$0].isMath } ?? false) { chars[i].isMath = false }
        }
    }

    private static func previousVisible(_ i: Int, _ chars: [PageChar]) -> Int? {
        var j = i - 1
        while j >= 0 {
            if chars[j].isNewline { return nil }
            if !chars[j].isSpace { return j }
            j -= 1
        }
        return nil
    }

    private static func nextVisible(_ i: Int, _ chars: [PageChar]) -> Int? {
        var j = i + 1
        while j < chars.count {
            if chars[j].isNewline { return nil }
            if !chars[j].isSpace { return j }
            j += 1
        }
        return nil
    }

    /// The nearest full-size character on the same line, to compare sizes and baselines with.
    private static func neighbour(of i: Int, in chars: [PageChar]) -> PageChar? {
        let c = chars[i]
        // Only on the same line: stop at line breaks.
        for step in [-1, 1] {
            var j = i + step
            var seen = 0
            while j >= 0, j < chars.count, seen < 6 {
                let o = chars[j]
                if o.isNewline { break }
                j += step
                if o.isSpace || o.isRotated || o.run == nil { continue }
                seen += 1
                if abs(o.baseline - c.baseline) > o.size * 0.7 || abs(o.rect.minX - c.rect.minX) > o.size * 8 { continue }
                if o.size >= c.size * 1.15 { return o }
            }
        }
        return nil
    }
}
