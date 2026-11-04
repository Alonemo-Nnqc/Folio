import Foundation

/// Marks characters that belong to formulas: glyphs from math fonts, mathematical symbols, and sub- or
/// superscripts. Inline formulas are kept as drawn (moved into the translation) instead of being translated.
enum MathDetector {
    private static let mathFonts = [
        "cmmi", "cmsy", "cmex", "cmbsy", "cmmib", "msbm", "msam", "eufm", "eusm", "eurm", "rsfs", "lmmath", "math",
        "symbol", "lasy", "mathabx", "mtmi", "mtsy", "mtex", "mathematica", "euclid", "esint", "wasy", "stmary", "txsy", "pxsy", "txmi",
        "pxmi", "txex", "pxex", "rtxmi", "ntxmi", "ntxsy", "zplm", "mnsymbol", "mdput", "mdbch", "lmsy", "lmmi", "cmbrm",
        "dsrom", "bbold", "bbm", "mathdesign", "stixgeneral-italic", "xits", "fourier", "lucidanewmath",
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

    /// Function and operator names set upright in formulas.
    static let operatorNames: Set<String> = [
        "arg", "max", "min", "argmax", "argmin", "log", "ln", "lg", "exp", "sin", "cos", "tan", "tanh", "sinh", "cosh", "arctan",
        "sigmoid", "softmax", "Softmax", "lim", "sup", "inf", "det", "tr", "diag", "sgn", "mod", "Var", "Cov", "Pr", "ker", "gcd", "erf",
    ]

    /// Characters that continue a formula when they touch one: operators, digits, brackets.
    static let joiners: Set<Character> = Set("=+-−–×·*/()[]{}|^_<>0123456789'.,:;!∗")

    /// Sets `isMath` on `chars` (one page, reading order).
    static func mark(_ chars: inout [PageChar]) {
        // A "math" font setting most of the page is the page's text face.
        var fontCounts: [String: Int] = [:]
        var visible = 0
        for c in chars where !c.isSpace && !c.isNewline && c.text.first?.isLetter == true {
            fontCounts[c.font.name, default: 0] += 1
            visible += 1
        }
        let textFaces = Set(fontCounts.filter { $0.value >= 200 && Double($0.value) >= Double(visible) * 0.4 }.keys)
        // 1. Characters that are math by themselves.
        for i in chars.indices where !chars[i].isSpace && !chars[i].isNewline {
            let c = chars[i]
            let scalars = c.text.unicodeScalars
            if isMathFont(c.font.name) && !c.font.name.lowercased().contains("cmr") && !textFaces.contains(c.font.name) {
                chars[i].isMath = true
            } else if c.ink != nil {
                // Big delimiters and operators of an extension font.
                chars[i].isMath = true
            } else if scalars.contains(where: isMathScalar) {
                chars[i].isMath = true
            } else if scalars.contains(where: isGreek), c.font.isItalic || isMathFont(c.font.name) {
                chars[i].isMath = true
            }
        }
        // 1b. A letter standing alone in italic type is a variable (papers set in Times use the text italic for
        //     maths): "where m is …", "(x + m, y)". "a", "A" and "I" are words too, so they need maths beside them.
        for i in chars.indices where !chars[i].isMath && chars[i].font.isItalic && chars[i].text.count == 1
            && chars[i].text.first!.isLetter && !chars[i].isSpace && !chars[i].isNewline {
            let before = i > 0 ? chars[i - 1] : nil, after = i + 1 < chars.count ? chars[i + 1] : nil
            func separate(_ o: PageChar?) -> Bool {
                guard let o else { return true }
                return o.isSpace || o.isNewline || o.isMath || (o.text.count == 1 && "()[]{},.;:=+−-<>|/".contains(o.text.first!))
            }
            guard separate(before), separate(after) else { continue }
            // Abbreviations in italics ("e.g.", "i.e.", "et al.") are words.
            if after?.text == ".", i + 2 < chars.count, chars[i + 2].text.first?.isLetter == true { continue }
            if before?.text == ".", i >= 2, chars[i - 2].text.first?.isLetter == true { continue }
            if !["a", "A", "I"].contains(chars[i].text) {
                chars[i].isMath = true
            } else {
                let p = previousVisible(i, chars), n = nextVisible(i, chars)
                let operators: Set<Character> = Set("=+−-<>×·")
                if [p, n].contains(where: { $0.map { chars[$0].isMath || (chars[$0].text.count == 1 && operators.contains(chars[$0].text.first!)) } ?? false }) {
                    chars[i].isMath = true
                }
            }
        }
        // 1c. Operator names set in roman ("arg max", "exp", "softmax") are maths when maths or an argument list
        //     is next to them.
        var w = 0
        while w < chars.count {
            guard !chars[w].isSpace, !chars[w].isNewline, chars[w].text.first?.isLetter == true else { w += 1; continue }
            var e = w
            while e + 1 < chars.count, !chars[e + 1].isSpace, !chars[e + 1].isNewline, chars[e + 1].text.first?.isLetter == true,
                  !chars[e + 1].isMath { e += 1 }
            let word = chars[w...e].map(\.text).joined()
            if operatorNames.contains(word), chars[w...e].allSatisfy({ !$0.isMath }) {
                let p = previousVisible(w, chars), n = nextVisible(e, chars)
                let nextIsArgument = n.map { chars[$0].text == "(" || chars[$0].text == "[" } ?? false
                if p.map({ chars[$0].isMath }) == true || n.map({ chars[$0].isMath }) == true || nextIsArgument {
                    for k in w...e { chars[k].isMath = true }
                }
            }
            w = e + 1
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
                // Not a drop cap: far bigger than any script's base.
                if o.size >= c.size * 1.15, o.size <= c.size * 2.2 { return o }
            }
        }
        return nil
    }
}
