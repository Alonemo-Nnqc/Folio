import CoreGraphics
import Foundation

/// How a font's strings split into character codes, which CID each code selects (composite fonts), and the
/// Unicode text of each code: from the ToUnicode CMap, else the encoding (base encoding, Differences, the
/// embedded Type 1 program's own encoding), glyph names read through the Adobe Glyph List and TeX's names.
///
/// Text the font states (ToUnicode, glyph names, an explicit encoding) is `reliable`; text inferred from a
/// default encoding is not, and the caller prefers what PDFKit reads at that position.
struct FontEncoding {
    private var known: [Int: String] = [:]
    private var guessed: [Int: String] = [:]
    /// Glyph names of a simple font's codes (Differences, the Type 1 program's encoding).
    private(set) var names: [Int: String] = [:]
    /// Codespace ranges of a composite font (empty: two bytes per code).
    private var codespace: [(length: Int, low: [UInt8], high: [UInt8])] = []
    /// Composite fonts with a CMap other than Identity: code → CID.
    private var cids: [Int: Int] = [:]
    private var cidRanges: [(low: Int, high: Int, first: Int)] = []
    private var identity = true
    /// UCS-2 / UTF-16 CMaps: the code is the text.
    private var codeIsUnicode = false
    let isComposite: Bool

    init(font dict: CGPDFDictionaryRef) {
        isComposite = PDFDictionary.name(dict, "Subtype") == "Type0"
        if isComposite {
            readCMap(dict)
        } else {
            (known, guessed, names) = Self.simpleEncoding(dict)
        }
        if let stream = PDFDictionary.stream(dict, "ToUnicode") {
            // ToUnicode overrides the encoding where it says something.
            for (code, text) in Self.parseToUnicode(ContentInterpreter.data(of: stream)) where Self.usable(text) {
                known[code] = text
            }
        }
    }

    // MARK: Codes

    /// The codes of a string, with their byte lengths.
    func codes(_ data: Data) -> [(code: Int, length: Int)] {
        let bytes = [UInt8](data)
        guard isComposite else { return bytes.map { (Int($0), 1) } }
        var result: [(code: Int, length: Int)] = []
        result.reserveCapacity(bytes.count / 2)
        var i = 0
        while i < bytes.count {
            let length = codeLength(bytes, at: i)
            var code = 0
            for k in 0..<length { code = code << 8 | Int(i + k < bytes.count ? bytes[i + k] : 0) }
            result.append((code, length))
            i += length
        }
        return result
    }

    private func codeLength(_ bytes: [UInt8], at i: Int) -> Int {
        if codespace.isEmpty { return 2 }
        for length in 1...4 where i + length <= bytes.count {
            for range in codespace where range.length == length {
                var inside = true
                for k in 0..<length where bytes[i + k] < range.low[k] || bytes[i + k] > range.high[k] {
                    inside = false
                    break
                }
                if inside { return length }
            }
        }
        // Not in any range: the shortest length the CMap uses (PDF 32000-1 §9.7.6.3).
        return max(1, min(codespace.map(\.length).min() ?? 2, bytes.count - i))
    }

    /// The CID a code selects (composite fonts); the code itself for simple fonts.
    func cid(_ code: Int) -> Int {
        if !isComposite || identity { return code }
        if let cid = cids[code] { return cid }
        for range in cidRanges where code >= range.low && code <= range.high { return range.first + code - range.low }
        return 0
    }

    // MARK: Text

    func text(_ code: Int) -> (text: String, reliable: Bool)? {
        if let text = known[code] { return (text, true) }
        if codeIsUnicode, let scalar = UnicodeScalar(code), Self.usable(String(Character(scalar))) { return (String(Character(scalar)), true) }
        if let text = guessed[code] { return (text, false) }
        return nil
    }

    /// Text worth using: not empty, not control characters, not the private use area.
    static func usable(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { $0.value < 0x20 || (0xE000...0xF8FF).contains($0.value) || $0.value == 0xFFFD }
    }

    // MARK: CMaps

    private mutating func readCMap(_ dict: CGPDFDictionaryRef) {
        if let name = PDFDictionary.name(dict, "Encoding") {
            switch name {
            case "Identity-H", "Identity-V": break
            case let n where n.contains("UCS2") || n.contains("UTF16"):
                identity = false
                codeIsUnicode = true
            case let n where n.contains("RKSJ"):
                // Shift-JIS: single bytes 00–80 and A0–DF.
                identity = false
                codespace = [(1, [0x00], [0x80]), (1, [0xA0], [0xDF]), (2, [0x81, 0x40], [0x9F, 0xFC]), (2, [0xE0, 0x40], [0xFC, 0xFC])]
            default:
                // EUC and GBK style: single bytes below 0x80.
                identity = false
                codespace = [(1, [0x00], [0x80]), (2, [0x81, 0x40], [0xFE, 0xFE])]
            }
        } else if let stream = PDFDictionary.stream(dict, "Encoding") {
            identity = false
            for op in ContentLexer.parse(ContentInterpreter.data(of: stream)) {
                switch op.name {
                case "endcodespacerange":
                    var k = 0
                    while k + 1 < op.operands.count {
                        if case .string(let lo) = op.operands[k], case .string(let hi) = op.operands[k + 1], lo.count == hi.count, (1...4).contains(lo.count) {
                            codespace.append((lo.count, [UInt8](lo), [UInt8](hi)))
                        }
                        k += 2
                    }
                case "endcidrange":
                    var k = 0
                    while k + 2 < op.operands.count {
                        if let lo = Self.code(op.operands[k]), let hi = Self.code(op.operands[k + 1]), let first = op.operands[k + 2].number, hi >= lo {
                            cidRanges.append((lo, hi, Int(first)))
                        }
                        k += 3
                    }
                case "endcidchar":
                    var k = 0
                    while k + 1 < op.operands.count {
                        if let c = Self.code(op.operands[k]), let cid = op.operands[k + 1].number { cids[c] = Int(cid) }
                        k += 2
                    }
                default: break
                }
            }
            // An embedded Identity CMap.
            if cids.isEmpty, cidRanges.count == 1, cidRanges[0].low == 0, cidRanges[0].first == 0 { identity = true }
        }
    }

    private static func code(_ operand: ContentOperand) -> Int? {
        guard case .string(let bytes) = operand, !bytes.isEmpty, bytes.count <= 4 else { return nil }
        return bytes.reduce(0) { $0 << 8 | Int($1) }
    }

    /// `bfchar` and `bfrange` entries of a ToUnicode CMap.
    static func parseToUnicode(_ data: Data) -> [Int: String] {
        var result: [Int: String] = [:]
        func unicode(_ operand: ContentOperand) -> String? {
            guard case .string(let bytes) = operand, !bytes.isEmpty else { return nil }
            var units: [UInt16] = []
            var i = bytes.startIndex
            while i + 1 < bytes.endIndex {
                units.append(UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]))
                i += 2
            }
            if bytes.count % 2 == 1 { units.append(UInt16(bytes.last!)) }
            return String(utf16CodeUnits: units, count: units.count)
        }
        for op in ContentLexer.parse(data) {
            switch op.name {
            case "endbfchar":
                var k = 0
                while k + 1 < op.operands.count {
                    if let c = code(op.operands[k]) {
                        if let u = unicode(op.operands[k + 1]) { result[c] = u }
                        else if let name = op.operands[k + 1].name, let u = GlyphNames.unicode(name) { result[c] = u }
                    }
                    k += 2
                }
            case "endbfrange":
                var k = 0
                while k + 2 < op.operands.count {
                    defer { k += 3 }
                    guard let lo = code(op.operands[k]), let hi = code(op.operands[k + 1]), hi >= lo, hi - lo < 65536 else { continue }
                    switch op.operands[k + 2] {
                    case .array(let items):
                        for (offset, item) in items.enumerated() where lo + offset <= hi {
                            if let u = unicode(item) { result[lo + offset] = u }
                        }
                    case .string(let bytes):
                        // The last UTF-16 unit counts up through the range.
                        guard var units = unicode(.string(bytes)).map({ Array($0.utf16) }), !units.isEmpty else { continue }
                        for c in lo...hi {
                            result[c] = String(utf16CodeUnits: units, count: units.count)
                            units[units.count - 1] &+= 1
                        }
                    default: break
                    }
                }
            default: break
            }
        }
        return result
    }

    // MARK: Simple fonts

    /// Code → text the font states, code → text guessed from a default encoding, and code → glyph name.
    static func simpleEncoding(_ dict: CGPDFDictionaryRef) -> (known: [Int: String], guessed: [Int: String], names: [Int: String]) {
        var known: [Int: String] = [:]
        var guessed: [Int: String] = [:]
        var names: [Int: String] = [:]
        var base: String? = PDFDictionary.name(dict, "Encoding")
        var differences: CGPDFArrayRef?
        if let encoding = PDFDictionary.dict(dict, "Encoding") {
            base = PDFDictionary.name(encoding, "BaseEncoding")
            differences = PDFDictionary.array(encoding, "Differences")
        }
        let descriptor = PDFDictionary.dict(dict, "FontDescriptor")
        let flags = descriptor.flatMap { PDFDictionary.number($0, "Flags") }.map { Int($0) } ?? 0
        let symbolic = flags & 4 != 0 && flags & 32 == 0
        let subtype = PDFDictionary.name(dict, "Subtype")
        let baseFont = PDFDictionary.name(dict, "BaseFont") ?? ""
        if let base {
            // Symbolic TrueType fonts map codes through their own tables, whatever the encoding says.
            let stated = !(symbolic && subtype == "TrueType")
            for code in 0...255 {
                if let text = baseText(code, encoding: base) { if stated { known[code] = text } else { guessed[code] = text } }
            }
        } else if subtype == "Type1" || subtype == "MMType1", let program = descriptor.flatMap({ PDFDictionary.stream($0, "FontFile") }),
                  let builtIn = type1Encoding(ContentInterpreter.data(of: program)) {
            // The program's own encoding (TeX's fonts: OT1, the math fonts' symbols).
            names = builtIn
            known = builtIn.compactMapValues { GlyphNames.unicode($0) }
        } else if baseFont.hasSuffix("Symbol") {
            for (code, text) in symbolEncoding { known[code] = text }
        } else if !symbolic {
            for code in 0...255 { if let text = baseText(code, encoding: "StandardEncoding") { guessed[code] = text } }
        }
        if let differences {
            var code = 0
            for i in 0..<CGPDFArrayGetCount(differences) {
                var number: CGPDFInteger = 0
                var name: UnsafePointer<CChar>?
                if CGPDFArrayGetInteger(differences, i, &number) {
                    code = number
                } else if CGPDFArrayGetName(differences, i, &name), let name {
                    guessed[code] = nil
                    names[code] = String(cString: name)
                    known[code] = GlyphNames.unicode(String(cString: name))
                    code += 1
                }
            }
        }
        return (known, guessed, names)
    }

    static func baseText(_ code: Int, encoding: String) -> String? {
        guard code >= 32, code < 256 else { return nil }
        let byte = [UInt8(code)]
        switch encoding {
        case "MacRomanEncoding":
            return code == 127 ? nil : String(bytes: byte, encoding: .macOSRoman)
        case "StandardEncoding":
            if let text = standardOverrides[code] { return text }
            return code < 127 ? String(bytes: byte, encoding: .ascii) : nil
        default:
            if code == 0xAD { return "-" }
            if [127, 129, 141, 143, 144, 157].contains(code) { return nil }
            return String(bytes: byte, encoding: .windowsCP1252)
        }
    }

    /// The encoding vector (code → glyph name) in the clear-text part of a Type 1 font program.
    static func type1Encoding(_ program: Data) -> [Int: String]? {
        let head = program.prefix(65536)
        guard let text = String(data: head, encoding: .isoLatin1), let start = text.range(of: "/Encoding") else { return nil }
        let rest = text[start.upperBound...]
        if rest.prefix(40).contains("StandardEncoding") { return standardNames }
        let end = rest.range(of: "readonly def")?.lowerBound ?? rest.range(of: "eexec")?.lowerBound ?? rest.endIndex
        var map: [Int: String] = [:]
        for match in rest[..<end].matches(of: /dup\s+(\d+)\s*\/([^\s\/\[\]{}()<>]+)\s+put/) {
            guard let code = Int(match.output.1), code < 256 else { continue }
            map[code] = String(match.output.2)
        }
        return map.isEmpty ? nil : map
    }

    /// StandardEncoding as glyph names (the text it stands for, through `GlyphNames`).
    static let standardNames: [Int: String] = {
        let reverse = Dictionary(GlyphNames.table.map { ($0.value, $0.key) }, uniquingKeysWith: { a, b in a.count <= b.count ? a : b })
        var map: [Int: String] = [:]
        for code in 32...255 {
            guard let t = baseText(code, encoding: "StandardEncoding") else { continue }
            map[code] = reverse[t] ?? (t.count == 1 && t.first!.isLetter ? t : nil)
        }
        return map
    }()

    /// StandardEncoding where it differs from ASCII and Latin-1.
    static let standardOverrides: [Int: String] = [
        39: "’", 96: "‘", 161: "¡", 162: "¢", 163: "£", 164: "⁄", 165: "¥", 166: "ƒ", 167: "§", 168: "¤", 169: "'", 170: "“",
        171: "«", 172: "‹", 173: "›", 174: "fi", 175: "fl", 177: "–", 178: "†", 179: "‡", 180: "·", 182: "¶", 183: "•",
        184: "‚", 185: "„", 186: "”", 187: "»", 188: "…", 189: "‰", 191: "¿", 193: "`", 194: "´", 195: "ˆ", 196: "˜",
        197: "¯", 198: "˘", 199: "˙", 200: "¨", 202: "˚", 203: "¸", 205: "˝", 206: "˛", 207: "ˇ", 208: "—", 225: "Æ",
        227: "ª", 232: "Ł", 233: "Ø", 234: "Œ", 235: "º", 241: "æ", 245: "ı", 248: "ł", 249: "ø", 250: "œ", 251: "ß",
    ]

    /// The Symbol font's built-in encoding.
    static let symbolEncoding: [Int: String] = {
        var map: [Int: String] = [:]
        let ascii = " !∀#∃%&∋()∗+,−./0123456789:;<=>?≅ΑΒΧΔΕΦΓΗΙϑΚΛΜΝΟΠΘΡΣΤΥςΩΞΨΖ[∴]⊥_‾αβχδεφγηιϕκλμνοπθρστυϖωξψζ{|}∼"
        for (offset, ch) in ascii.enumerated() { map[32 + offset] = String(ch) }
        let high: [Int: String] = [
            0xA1: "ϒ", 0xA2: "′", 0xA3: "≤", 0xA4: "⁄", 0xA5: "∞", 0xA6: "ƒ", 0xA7: "♣", 0xA8: "♦", 0xA9: "♥", 0xAA: "♠",
            0xAB: "↔", 0xAC: "←", 0xAD: "↑", 0xAE: "→", 0xAF: "↓", 0xB0: "°", 0xB1: "±", 0xB2: "″", 0xB3: "≥", 0xB4: "×",
            0xB5: "∝", 0xB6: "∂", 0xB7: "•", 0xB8: "÷", 0xB9: "≠", 0xBA: "≡", 0xBB: "≈", 0xBC: "…", 0xC0: "ℵ", 0xC1: "ℑ",
            0xC2: "ℜ", 0xC3: "℘", 0xC4: "⊗", 0xC5: "⊕", 0xC6: "∅", 0xC7: "∩", 0xC8: "∪", 0xC9: "⊃", 0xCA: "⊇", 0xCB: "⊄",
            0xCC: "⊂", 0xCD: "⊆", 0xCE: "∈", 0xCF: "∉", 0xD0: "∠", 0xD1: "∇", 0xD5: "∏", 0xD6: "√", 0xD7: "⋅", 0xD8: "¬",
            0xD9: "∧", 0xDA: "∨", 0xDB: "⇔", 0xDC: "⇐", 0xDD: "⇑", 0xDE: "⇒", 0xDF: "⇓", 0xE0: "◊", 0xE1: "〈", 0xE5: "∑",
            0xF1: "〉", 0xF2: "∫",
        ]
        map.merge(high) { _, new in new }
        return map
    }()
}

/// Glyph names to Unicode: the common part of the Adobe Glyph List, TeX's names, and `uniXXXX` / `uXXXX`.
enum GlyphNames {
    static func unicode(_ raw: String) -> String? {
        var name = raw
        if let dot = name.firstIndex(of: "."), dot != name.startIndex { name = String(name[..<dot]) }
        if name.contains("_"), !name.hasPrefix("_") {
            // Ligatures written as parts: "f_f_i".
            let parts = name.split(separator: "_").map { unicode(String($0)) }
            if !parts.isEmpty, parts.allSatisfy({ $0 != nil }) { return parts.map { $0! }.joined() }
        }
        if let text = table[name] { return text }
        if name.count == 1, let first = name.first, first.isLetter || first.isNumber { return name }
        if name.hasPrefix("uni"), name.count >= 7, let value = UInt32(name.dropFirst(3).prefix(4), radix: 16), let scalar = UnicodeScalar(value) {
            return String(Character(scalar))
        }
        if name.hasPrefix("u"), (5...7).contains(name.count), let value = UInt32(name.dropFirst(), radix: 16), let scalar = UnicodeScalar(value) {
            return String(Character(scalar))
        }
        // TeX's sized variants: "parenleftbig", "summationdisplay", "radicalBigg" …
        for suffix in ["display", "text", "Bigg", "bigg", "Big", "big", "BIG", "1", "2"] where name.hasSuffix(suffix) && name.count > suffix.count {
            if let text = table[String(name.dropLast(suffix.count))] { return text }
        }
        return nil
    }

    static let table: [String: String] = {
        var t: [String: String] = [
            "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%", "ampersand": "&",
            "quoteright": "’", "quotesingle": "'", "parenleft": "(", "parenright": ")", "asterisk": "*", "plus": "+", "comma": ",",
            "hyphen": "-", "period": ".", "slash": "/", "colon": ":", "semicolon": ";", "less": "<", "equal": "=", "greater": ">",
            "question": "?", "at": "@", "bracketleft": "[", "backslash": "\\", "bracketright": "]", "asciicircum": "^",
            "underscore": "_", "quoteleft": "‘", "grave": "`", "braceleft": "{", "bar": "|", "braceright": "}", "asciitilde": "~",
            "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
            "fi": "fi", "fl": "fl", "ff": "ff", "ffi": "ffi", "ffl": "ffl", "dotlessi": "ı", "dotlessj": "ȷ", "exclamdown": "¡",
            "questiondown": "¿", "quotedblleft": "“", "quotedblright": "”", "quotesinglbase": "‚", "quotedblbase": "„",
            "endash": "–", "emdash": "—", "bullet": "•", "dagger": "†", "daggerdbl": "‡", "section": "§", "paragraph": "¶",
            "periodcentered": "·", "ellipsis": "…", "copyright": "©", "registered": "®", "trademark": "™", "degree": "°",
            "guillemotleft": "«", "guillemotright": "»", "guilsinglleft": "‹", "guilsinglright": "›", "perthousand": "‰",
            "sterling": "£", "yen": "¥", "cent": "¢", "currency": "¤", "florin": "ƒ", "fraction": "⁄", "ordfeminine": "ª",
            "ordmasculine": "º", "brokenbar": "¦", "onehalf": "½", "onequarter": "¼", "threequarters": "¾",
            "onesuperior": "¹", "twosuperior": "²", "threesuperior": "³", "mu1": "µ", "logicalnot": "¬",
            "germandbls": "ß", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "oslash": "ø", "Oslash": "Ø", "lslash": "ł", "Lslash": "Ł",
            "eth": "ð", "Eth": "Ð", "thorn": "þ", "Thorn": "Þ",
            "acute": "´", "circumflex": "ˆ", "tilde": "˜", "macron": "¯", "breve": "˘", "dotaccent": "˙", "dieresis": "¨",
            "ring": "˚", "cedilla": "¸", "hungarumlaut": "˝", "ogonek": "˛", "caron": "ˇ", "hacek": "ˇ", "tie": "⁀",
            "minus": "−", "multiply": "×", "divide": "÷", "plusminus": "±", "minusplus": "∓", "infinity": "∞", "partialdiff": "∂",
            "nabla": "∇", "gradient": "∇", "summation": "∑", "product": "∏", "coproduct": "∐", "integral": "∫", "contintegral": "∮",
            "contourintegral": "∮", "radical": "√", "element": "∈", "notelement": "∉", "owner": "∋", "subset": "⊂", "superset": "⊃",
            "reflexsubset": "⊆", "reflexsuperset": "⊇", "propersubset": "⊂", "propersuperset": "⊃", "subsetequal": "⊆",
            "supersetequal": "⊇", "intersection": "∩", "union": "∪", "unionmulti": "⊎", "unionsq": "⊔", "intersectionsq": "⊓",
            "logicaland": "∧", "logicalor": "∨", "similar": "∼", "similarequal": "≃", "approxequal": "≈", "congruent": "≅",
            "notequal": "≠", "lessequal": "≤", "greaterequal": "≥", "equivalence": "≡", "proportional": "∝",
            "arrowright": "→", "arrowleft": "←", "arrowup": "↑", "arrowdown": "↓", "arrowboth": "↔", "arrowupdown": "↕",
            "arrowdblright": "⇒", "arrowdblleft": "⇐", "arrowdblboth": "⇔", "arrowdblup": "⇑", "arrowdbldown": "⇓",
            "arrownortheast": "↗", "arrowsoutheast": "↘", "arrownorthwest": "↖", "arrowsouthwest": "↙",
            "universal": "∀", "existential": "∃", "emptyset": "∅", "angbracketleft": "⟨", "angbracketright": "⟩", "prime": "′",
            "dotmath": "⋅", "asteriskmath": "∗", "openbullet": "◦", "circlemultiply": "⊗", "circleplus": "⊕", "circledot": "⊙",
            "circleminus": "⊖", "circledivide": "⊘", "circlecopyrt": "◯", "perpendicular": "⊥", "angle": "∠", "therefore": "∴",
            "aleph": "ℵ", "weierstrass": "℘", "Ifraktur": "ℑ", "Rfraktur": "ℜ", "floorleft": "⌊", "floorright": "⌋",
            "ceilingleft": "⌈", "ceilingright": "⌉", "bardbl": "‖", "mapsto": "↦", "lessmuch": "≪", "greatermuch": "≫",
            "precedes": "≺", "follows": "≻", "precedesequal": "⪯", "followsequal": "⪰", "turnstileleft": "⊢", "turnstileright": "⊣",
            "latticetop": "⊤", "triangle": "△", "triangleinv": "▽", "triangleleft": "◁", "triangleright": "▷", "star": "⋆",
            "diamond": "⋄", "diamondmath": "⋄", "heart": "♡", "club": "♣", "spade": "♠", "checkmark": "✓", "xmark": "✗",
            "backslashmath": "∖", "setminus": "∖", "wreathproduct": "≀", "negationslash": "̸", "square": "□", "lozenge": "◊",
            "colonequal": "≔", "defines": "≜", "hbar": "ℏ", "planckover2pi": "ℏ", "planckover2pi1": "ℏ",
            "ell": "ℓ", "wp": "℘", "Re": "ℜ", "Im": "ℑ", "vector": "⃗", "harpoonleftright": "⇌",
            "arrowhookleft": "↩", "arrowhookright": "↪", "notsubset": "⊄", "notsuperset": "⊅",
            "sharp": "♯", "flat": "♭", "natural": "♮", "bottom": "⊥", "top": "⊤", "parallel": "∥", "divides": "∣",
            "visiblespace": "␣", "slurabove": "⌢", "slurbelow": "⌣", "followsorequal": "⪰", "precedesorequal": "⪯",
            "bracketleftbt": "⎣", "bracketrightbt": "⎦", "bracketlefttp": "⎡", "bracketrighttp": "⎤",
            "bracketleftex": "⎢", "bracketrightex": "⎥", "parenlefttp": "⎛", "parenleftbt": "⎝", "parenleftex": "⎜",
            "parenrighttp": "⎞", "parenrightbt": "⎠", "parenrightex": "⎟", "bracelefttp": "⎧", "braceleftmid": "⎨",
            "braceleftbt": "⎩", "bracerighttp": "⎫", "bracerightmid": "⎬", "bracerightbt": "⎭", "braceex": "⎪",
            "integraltp": "⌠", "integralbt": "⌡", "radicalex": "⎷", "arrowvertex": "⏐", "arrowdblvertex": "‖",
            "hatwide": "ˆ", "tildewide": "˜", "hatwider": "ˆ", "tildewider": "˜", "hatwidest": "ˆ", "tildewidest": "˜",
            // Greek, with TeX's variants.
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "epsilon1": "ε", "zeta": "ζ", "eta": "η",
            "theta": "θ", "theta1": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
            "pi": "π", "pi1": "ϖ", "rho": "ρ", "rho1": "ϱ", "sigma": "σ", "sigma1": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
            "phi1": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "varepsilon": "ε", "vartheta": "ϑ", "varpi": "ϖ", "varrho": "ϱ",
            "varsigma": "ς", "varphi": "φ", "epsilonvariant": "ε", "thetavariant": "ϑ", "phivariant": "φ", "pivariant": "ϖ",
            "rhovariant": "ϱ", "sigmavariant": "ς", "kappavariant": "ϰ",
            "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Epsilon": "Ε", "Zeta": "Ζ", "Eta": "Η", "Theta": "Θ", "Iota": "Ι",
            "Kappa": "Κ", "Lambda": "Λ", "Mu": "Μ", "Nu": "Ν", "Xi": "Ξ", "Omicron": "Ο", "Pi": "Π", "Rho": "Ρ", "Sigma": "Σ",
            "Tau": "Τ", "Upsilon": "Υ", "Upsilon1": "ϒ", "Phi": "Φ", "Chi": "Χ", "Psi": "Ψ", "Omega": "Ω",
        ]
        // Accented Latin letters: base letter + accent name ("eacute", "Odieresis").
        let accents: [String: String] = ["acute": "\u{301}", "grave": "\u{300}", "circumflex": "\u{302}", "tilde": "\u{303}",
                                         "dieresis": "\u{308}", "ring": "\u{30A}", "cedilla": "\u{327}", "caron": "\u{30C}",
                                         "macron": "\u{304}", "breve": "\u{306}", "ogonek": "\u{328}", "dotaccent": "\u{307}",
                                         "hungarumlaut": "\u{30B}", "commaaccent": "\u{326}"]
        for letter in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            for (accent, mark) in accents {
                t[String(letter) + accent] = (String(letter) + mark).precomposedStringWithCanonicalMapping
            }
        }
        return t
    }()
}
