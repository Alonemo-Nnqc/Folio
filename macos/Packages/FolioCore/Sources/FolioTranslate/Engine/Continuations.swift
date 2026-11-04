import CoreGraphics
import Foundation

/// A paragraph that runs on into the next column or onto the next page: one sentence cut in two by the layout.
/// Translated apart, each half is a broken sentence and the first ends in a hyphenated fragment ("in-"). Translated
/// together, with `{v0}` where the break was, and set again in the two places.
struct Continuation: Sendable, Hashable {
    /// What is sent: the parts as one text, `{v0}` at each break, the later parts' formulas numbered on.
    var joined: TextSegment
    var parts: [TextSegment]
    /// How many formulas each part has.
    var counts: [Int]
    /// Each part's share of the joined text.
    var shares: [Double]
}

enum Continuations {
    /// Marks a break; numbered like a formula, so translators keep it as they keep formulas.
    static let marker = "{v0}"

    // MARK: Finding

    /// Paragraphs that go on in the next column or on the next page, in reading order.
    static func find(_ segments: [TextSegment], layouts: [PageLayout], maxCharacters: Int = 6000) -> [Continuation] {
        let pages = Dictionary(layouts.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<Int>()
        var result: [Continuation] = []
        for i in segments.indices where !used.contains(i) {
            var chain = [i]
            while chain.count < 3, let next = follower(of: chain.last!, in: segments, pages: pages), !used.contains(next) {
                let length = (chain + [next]).reduce(0) { $0 + segments[$1].source.count }
                guard length <= maxCharacters else { break }
                chain.append(next)
            }
            guard chain.count > 1 else { continue }
            used.formUnion(chain)
            result.append(make(chain.map { segments[$0] }))
        }
        return result
    }

    /// The paragraph that `segments[i]` runs on into, if it does.
    static func follower(of i: Int, in segments: [TextSegment], pages: [Int: PageLayout]) -> Int? {
        let a = segments[i]
        guard a.kind == .paragraph, !a.isLead, let pageA = pages[a.page], a.block < pageA.blocks.count else { return nil }
        // The next paragraph in reading order; captions, cells, footnotes and the like in between do not count.
        var j = i + 1
        while j < segments.count, j < i + 40 {
            let s = segments[j]
            if s.kind == .heading || s.kind == .title || s.isLead { return nil }
            if s.kind == .paragraph { break }
            j += 1
        }
        guard j < segments.count, j < i + 40 else { return nil }
        let b = segments[j]
        guard let pageB = pages[b.page], b.block < pageB.blocks.count else { return nil }
        let blockA = pageA.blocks[a.block], blockB = pageB.blocks[b.block]
        guard let lastA = blockA.lines.last, let firstB = blockB.lines.first, abs(blockA.size - blockB.size) < 0.6 else { return nil }
        // Only where the layout cuts it: the next column, or the next page.
        let nextColumn = b.page == a.page && firstB.baseline > lastA.baseline + blockA.size && firstB.minX > lastA.minX + blockA.rect.width * 0.5
        let nextPage = b.page == a.page + 1
        guard nextColumn || nextPage else { return nil }
        // The first part ends mid-sentence, in a full line.
        let tail = a.source.trimmingCharacters(in: .whitespaces)
        guard !endsSentence(tail) else { return nil }
        if blockA.lines.count >= 2 {
            guard lastA.maxX >= blockA.rect.maxX - blockA.size * 2 else { return nil }
        } else {
            guard lastA.rect.width >= firstB.rect.width * 0.7 else { return nil }
        }
        // The last paragraph of its column and the first of the next: nothing of the column's text below the one, above the other.
        func sameColumn(_ x: LayoutBlock, _ y: LayoutBlock) -> Bool {
            min(x.rect.maxX, y.rect.maxX) - max(x.rect.minX, y.rect.minX) > min(x.rect.width, y.rect.width) * 0.5
        }
        let body: Set<BlockKind> = [.paragraph, .heading]
        if pageA.blocks.contains(where: { $0.translate && body.contains($0.kind) && sameColumn($0, blockA) && $0.rect.maxY < blockA.rect.minY - 1 }) { return nil }
        if pageB.blocks.contains(where: { $0.translate && body.contains($0.kind) && sameColumn($0, blockB) && $0.rect.minY > blockB.rect.maxY + 1 }) { return nil }
        // The second goes on with it: a word in lower case, or after a comma or a word that cannot end a sentence.
        if blockB.lines.count >= 2, firstB.minX > blockB.lines[1].minX + blockB.size * 0.6 { return nil }
        let head = b.source.trimmingCharacters(in: .whitespaces)
        let firstWord = head.split(separator: " ").first { !$0.hasPrefix("{") }.map(String.init) ?? ""
        guard let initial = firstWord.first, initial.isLetter || initial.isNumber else { return nil }
        let lastWord = tail.split(separator: " ").last.map { String($0).lowercased() } ?? ""
        // A hyphenated word goes on in lower case ("op-" + "NightCity" is not one word).
        if tail.hasSuffix("-") { return initial.isLowercase ? j : nil }
        // A word begun elsewhere ("…con-" + "nected") is not this paragraph's: another one on these pages ends in a hyphen
        // and nothing follows it.
        if initial.isLowercase, segments.contains(where: { s in
            s.kind == .paragraph && (s.page == a.page || s.page == b.page) && s.source.trimmingCharacters(in: .whitespaces).hasSuffix("-")
                && s.source.trimmingCharacters(in: .whitespaces).dropLast().last?.isLetter == true
        }) { return nil }
        // A word or two is a label or a table's header, not the rest of a sentence.
        guard head.split(separator: " ").count >= 3 else { return nil }
        let carriesOn = initial.isLowercase || ((tail.hasSuffix(",") || connectives.contains(lastWord)) && !initial.isUppercase)
            || (connectives.contains(lastWord) && !head.hasPrefix("{"))
        return carriesOn ? j : nil
    }

    static let connectives: Set<String> = [
        "the", "a", "an", "of", "in", "on", "to", "for", "with", "by", "and", "or", "from", "as", "at", "that", "which", "is",
        "are", "be", "was", "were", "its", "their", "our", "this", "these", "into", "than", "between", "such", "not", "can",
    ]

    /// Ends with a full stop, question mark and so on (a closing bracket or quote may follow).
    static func endsSentence(_ text: String) -> Bool {
        var t = Substring(text)
        while let last = t.last, ")]}”’\"'".contains(last) { t = t.dropLast() }
        guard let last = t.last else { return true }
        return ".!?:;。！？：；".contains(last)
    }

    static func make(_ parts: [TextSegment]) -> Continuation {
        var text = parts[0].source
        var offset = parts[0].formulas.count
        for part in parts.dropFirst() {
            let shift = offset
            let shifted = Placeholders.replace(in: part.source) { TextSegment.placeholder($0 + shift) }
            // A word hyphenated over the break comes together after the marker; a compound keeps its hyphen.
            let words = text.split(separator: " ", omittingEmptySubsequences: false)
            if let last = words.last, last.count > 1, last.hasSuffix("-"), last.dropLast().last?.isLetter == true,
               shifted.first?.isLowercase == true {
                let word = String(last)
                let compound = word.dropLast().contains("-") || word.contains("/")
                text = String(text.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
                text += " " + marker + (compound ? word : String(word.dropLast())) + shifted
            } else {
                text += " " + marker + " " + shifted
            }
            offset += part.formulas.count
        }
        let total = Double(max(1, parts.reduce(0) { $0 + $1.source.count }))
        var joined = parts[0]
        joined.source = text
        joined.formulas = parts.flatMap(\.formulas)
        return Continuation(joined: joined, parts: parts, counts: parts.map(\.formulas.count),
                            shares: parts.map { Double($0.source.count) / total })
    }

    // MARK: Splitting

    /// The translation of the joined text, cut where each part ends: at the marker the translator kept, unless that puts a
    /// formula on the wrong side or leaves a part far too long for its place; then at the nearest boundary that does not.
    /// Nil when no cut keeps every formula with its part (the parts are then translated apart).
    static func split(_ text: String, _ c: Continuation) -> [String]? {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return nil }
        let matches = Placeholders.pattern.matches(in: text, range: NSRange(location: 0, length: length))
        var offsets: [Int] = []
        var running = 0
        for count in c.counts { offsets.append(running); running += count }
        func owner(_ n: Int) -> Int? {
            guard n > 0 else { return nil }
            return offsets.indices.last { offsets[$0] < n && n <= offsets[$0] + c.counts[$0] }
        }
        let formulas: [(range: NSRange, part: Int)] = matches.compactMap { m in
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            return owner(n).map { (m.range, $0) }
        }
        let markers = matches.filter { (Int(ns.substring(with: $0.range(at: 1))) ?? -1) == 0 }.map(\.range)
        func insidePlaceholder(_ p: Int) -> NSRange? { matches.first { $0.range.location < p && p < NSMaxRange($0.range) }?.range }

        var breaks: [Int] = []
        var previous = 0
        var share = 0.0
        for k in 0..<(c.parts.count - 1) {
            share += c.shares[k]
            let lo = max(previous, formulas.filter { $0.part <= k }.map { NSMaxRange($0.range) }.max() ?? 0)
            let hi = formulas.filter { $0.part > k }.map(\.range.location).min() ?? length
            guard lo <= hi else { return nil }
            let target = Int(Double(length) * share)
            var cut: Int?
            if markers.count == c.parts.count - 1 {
                let at = markers[k].location
                if at >= lo, at <= hi, abs(Double(at) / Double(length) - share) <= 0.25 { cut = at }
            }
            if cut == nil {
                // A boundary near where the part's share of the text ends: after punctuation, else at a space.
                let punctuation = Set("，,、；;：:。．.！!？? ）)".utf16)
                var best: (position: Int, score: Double)?
                for p in lo...hi where insidePlaceholder(p) == nil {
                    let before = p > 0 ? ns.character(at: p - 1) : 0
                    let score = abs(Double(p - target)) - (punctuation.contains(before) ? Double(length) * 0.08 : 0)
                    if best == nil || score < best!.score { best = (p, score) }
                }
                cut = best?.position
            }
            guard let at = cut else { return nil }
            breaks.append(at)
            previous = at
        }
        var pieces: [String] = []
        var start = 0
        for (k, end) in (breaks + [length]).enumerated() {
            var piece = ns.substring(with: NSRange(location: start, length: end - start))
            piece = Placeholders.replace(in: piece) { n in n == 0 ? "" : TextSegment.placeholder(n - offsets[k]) }
            piece = piece.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            if piece.isEmpty, SegmentBuilder.hasWords(c.parts[k].source) { return nil }
            pieces.append(piece)
            start = end
        }
        return pieces
    }
}
