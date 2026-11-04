import CoreGraphics
import CoreText
import Foundation

/// A link annotation of a page: a citation, a cross-reference, a web address.
struct PageLink: Sendable, Hashable {
    /// Its place among the page's links (`PageLinks.annotations` order).
    var index: Int
    /// Where it can be clicked: its quadrilaterals when it has them, else its rectangle.
    var rects: [CGRect]
    /// What it leads to: pieces of one citation broken over two lines are two links with the same target.
    var target: String = ""
}

/// Where a link's text went in a translated line (original page space).
struct SpanLink: Sendable, Hashable {
    var link: Int
    var rect: CGRect
}

enum PageLinks {
    /// The link annotations of a page, in order.
    static func annotations(of page: CGPDFDictionaryRef) -> [CGPDFDictionaryRef] {
        guard let annots = PDFDictionary.array(page, "Annots") else { return [] }
        var result: [CGPDFDictionaryRef] = []
        for index in 0..<CGPDFArrayGetCount(annots) {
            var annot: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(annots, index, &annot), let annot, PDFDictionary.name(annot, "Subtype") == "Link" else { continue }
            result.append(annot)
        }
        return result
    }

    static func links(of page: CGPDFPage) -> [PageLink] {
        guard let dict = page.dictionary else { return [] }
        return annotations(of: dict).enumerated().compactMap { index, annot in
            var rects: [CGRect] = []
            if let quads = PDFDictionary.array(annot, "QuadPoints") {
                let n = PDFDictionary.numbers(quads)
                for q in stride(from: 0, to: n.count - 7, by: 8) {
                    let xs = stride(from: q, to: q + 8, by: 2).map { n[$0] }, ys = stride(from: q + 1, to: q + 8, by: 2).map { n[$0] }
                    rects.append(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
                }
            }
            if rects.isEmpty, let rect = PDFDictionary.rect(annot, "Rect") { rects = [rect] }
            return rects.isEmpty ? nil : PageLink(index: index, rects: rects, target: target(of: annot))
        }
    }

    private static func target(of annot: CGPDFDictionaryRef) -> String {
        func describe(_ object: CGPDFObjectRef) -> String {
            switch CGPDFObjectGetType(object) {
            case .name:
                var name: UnsafePointer<CChar>?
                return CGPDFObjectGetValue(object, .name, &name) ? name.map { String(cString: $0) } ?? "" : ""
            case .string:
                var string: CGPDFStringRef?
                return CGPDFObjectGetValue(object, .string, &string) ? string.map { PDFCopier.data(of: $0).base64EncodedString() } ?? "" : ""
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &array), let array else { return "" }
                var page: CGPDFDictionaryRef?
                let key = CGPDFArrayGetDictionary(array, 0, &page) ? page.map { PDFCopier.key($0) } ?? 0 : 0
                return "\(key)|" + PDFDictionary.numbers(array).dropFirst().map { String($0) }.joined(separator: ",")
            default:
                return ""
            }
        }
        if let dest = PDFDictionary.object(annot, "Dest") { return describe(dest) }
        guard let action = PDFDictionary.dict(annot, "A") else { return "" }
        if let dest = PDFDictionary.object(action, "D") { return describe(dest) }
        if let uri = PDFDictionary.object(action, "URI") { return describe(uri) }
        return ""
    }

    /// Tells each character which link it is under. A link covering a good part of the page (a whole-page frame) is
    /// not about any words.
    static func assign(_ links: [PageLink], to chars: inout [PageChar], page: CGRect) {
        var targets: [String: Int] = [:]
        for link in links {
            let target = link.target.isEmpty ? targets.count + 1_000_000 : targets[link.target] ?? targets.count
            if !link.target.isEmpty { targets[link.target] = target }
            for rect in link.rects where rect.width * rect.height < page.width * page.height * 0.25 {
                let area = rect.insetBy(dx: -0.2, dy: -0.5)
                for i in chars.indices where !chars[i].isSpace && !chars[i].isNewline && chars[i].link == nil {
                    if area.contains(CGPoint(x: chars[i].rect.midX, y: chars[i].baseline + chars[i].size * 0.3)) {
                        chars[i].link = link.index
                        chars[i].linkTarget = target
                    }
                }
            }
        }
    }
}

/// What to do with the words a link covers when the text around them is translated. Citations stay as drawn, so
/// their numbers stay right and the link can follow them to wherever the translation puts them.
enum LinkText {
    enum Role: Equatable {
        /// Kept as drawn.
        case whole
        /// A label and its number ("Figure 3"): the label is translated, the number kept. Holds the label's length.
        case number(after: Int)
        /// Running words: translated, and the link cannot follow them.
        case prose
    }

    private static let label = try! NSRegularExpression(pattern: #"^\s*((?:Figures?|Figs?\.?|Tables?|Tabs?\.?|Sections?|Secs?\.?|Sects?\.?|§+|Equations?|Eqs?\.?|Eqns?\.?|Algorithms?|Algs?\.?|Appendix|Appendices|Apps?\.?|Theorems?|Thms?\.?|Lemmas?|Corollary|Corollaries|Cors?\.?|Propositions?|Props?\.?|Definitions?|Defs?\.?|Chapters?|Chaps?\.?|Ch\.?|Parts?|Steps?|Lines?|Remarks?|Examples?|Exps?\.?|Experiments?|Assumptions?)\s*)(\(?[A-Z]?[\d.]*\d[a-z]?\)?|[A-Z])\s*$"#)

    static func role(of text: String) -> Role {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let match = label.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.range(at: 1).location != NSNotFound {
            return .number(after: match.range(at: 1).location + match.range(at: 1).length)
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count <= 3 { return .whole }
        if trimmed.range(of: #"://|www\.|doi|@|\.(com|org|net|edu|io|ai)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return .whole }
        // Author and year; several names.
        if trimmed.range(of: #"et al|(19|20)\d\d"#, options: .regularExpression) != nil { return .whole }
        let lowerWords = words.filter { word in
            word.first?.isLowercase == true && !["and", "of", "de", "van", "von", "der", "la", "le"].contains(String(word))
        }
        return lowerWords.isEmpty && words.count <= 8 ? .whole : .prose
    }

    /// Which characters of each line of `block` stay as drawn: its formulas and its citations, whole
    /// ("[12, 13]" with its brackets and commas, though only the numbers are links). `breaks` are characters where a
    /// long list of citations may be parted into pieces (so it can run over a line break).
    static func held(in block: LayoutBlock) -> (held: [[Bool]], breaks: [Set<Int>]) {
        var held = block.lines.map { $0.chars.map(\.isMath) }
        var breaks = block.lines.map { _ in Set<Int>() }
        // The characters of each link, wherever they are in the block.
        var byLink: [Int: [(line: Int, char: Int)]] = [:]
        for (l, line) in block.lines.enumerated() {
            for (c, char) in line.chars.enumerated() {
                if let link = char.link { byLink[link, default: []].append((l, c)) }
            }
        }
        guard !byLink.isEmpty else { return (held, breaks) }
        var numeric: Set<Int> = []
        for (link, places) in byLink {
            var text = ""
            var previous: (line: Int, char: Int)?
            for place in places {
                if let previous, previous.line != place.line || place.char > previous.char + 1 { text += " " }
                text += block.lines[place.line].chars[place.char].text
                previous = place
            }
            let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "[](),;. "))
            if bare.range(of: #"^\d+[a-z]?([–—\-]\d+[a-z]?)?$"#, options: .regularExpression) != nil { numeric.insert(link) }
            switch role(of: text) {
            case .prose:
                continue
            case .whole:
                for place in places { held[place.line][place.char] = true }
            case .number(let after):
                var offset = 0
                for (k, place) in places.enumerated() {
                    // Characters of the link, and a space where it jumps over one.
                    if k > 0, places[k - 1].line != place.line || place.char > places[k - 1].char + 1 { offset += 1 }
                    if offset >= after { held[place.line][place.char] = true }
                    offset += block.lines[place.line].chars[place.char].text.count
                }
            }
            // Spaces inside it, on each of its lines.
            for (a, b) in zip(places, places.dropFirst()) where a.line == b.line && b.char > a.char + 1 {
                if held[a.line][a.char], held[b.line][b.char] {
                    for k in (a.char + 1)..<b.char where block.lines[a.line].chars[k].isSpace { held[a.line][k] = true }
                }
            }
        }
        // A list of numbers: the separators between them, and the brackets around them.
        for (l, line) in block.lines.enumerated() {
            let chars = line.chars
            func isNumber(_ k: Int) -> Bool { chars[k].link.map { numeric.contains($0) && held[l][k] } ?? false }
            func isSeparator(_ k: Int) -> Bool { chars[k].isSpace || (chars[k].text.count == 1 && ",;–—-".contains(chars[k].text.first!)) }
            var i = 0
            while i < chars.count {
                guard isNumber(i) else { i += 1; continue }
                var last = i, j = i + 1
                while j < chars.count, isNumber(j) || isSeparator(j) {
                    if isNumber(j) { last = j }
                    j += 1
                }
                for k in i...last { held[l][k] = true }
                var first = i
                if i > 0, last + 1 < chars.count, let open = chars[i - 1].text.first, let close = chars[last + 1].text.first,
                   ["[": "]", "(": ")"][open] == close, chars[i - 1].text.count == 1, chars[last + 1].text.count == 1 {
                    held[l][i - 1] = true
                    held[l][last + 1] = true
                    first = i - 1
                    last += 1
                }
                // A long list parts after its commas.
                if chars[last].rect.maxX - chars[first].rect.minX > line.size * 7 {
                    var k = first + 1
                    while k <= last {
                        if chars[k - 1].text == "," || chars[k - 1].text == ";" { breaks[l].insert(k) }
                        k += 1
                    }
                }
                i = max(j, last + 1)
            }
        }
        return (held, breaks)
    }
}

extension LinkText {
    /// Where a link over running words goes when they are translated: the same stretch of the translation (a link
    /// over a whole line of a table of contents covers all of it).
    static func places(of link: Int, in block: LayoutBlock, lines: [(line: CTLine, origin: CGPoint)], fontSize: Double) -> [CGRect] {
        var before = 0, inside = 0, after = 0
        for line in block.lines {
            for c in line.chars where !c.isSpace {
                if c.link == link {
                    inside += 1
                    after = 0
                } else if inside == 0 {
                    before += 1
                } else {
                    after += 1
                }
            }
        }
        let total = before + inside + after
        guard inside > 0, total > 0 else { return [] }
        let widths = lines.map { CTLineGetTypographicBounds($0.line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0.line) }
        let length = widths.reduce(0, +)
        let start = length * Double(before) / Double(total), end = length * Double(before + inside) / Double(total)
        var result: [CGRect] = []
        var position = 0.0
        for (k, entry) in lines.enumerated() {
            let from = max(start, position), to = min(end, position + widths[k])
            if to > from {
                result.append(CGRect(x: entry.origin.x + from - position, y: entry.origin.y - fontSize * 0.25, width: to - from, height: fontSize * 1.15))
            }
            position += widths[k]
        }
        return result
    }
}
