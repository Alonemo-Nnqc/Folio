import Foundation

/// The words of a figure as the translator gets them (TRANS-40): a label set over several lines ("Specialist model
/// trained / for artery segmentation") is one text — translated line by line, its parts would read in the wrong order —
/// and its translation is shared out across the lines again, each line about as much as it held. A centred block of
/// lines is one label; lines set flush one under the other may be separate labels (a legend, two items with check
/// marks) and stay apart, unless a line starts in lower case or the one above ends with a hyphen or a word such as
/// "of" or "for".
/// The Windows engine does the same (ImageTextUnits in ImageText.cs).
enum ImageTextUnits {
    struct Unit: Equatable {
        var text: String
        /// Indices of its lines, top first.
        var members: [Int]
    }

    static let joiners: Set<String> = ["of", "and", "or", "for", "on", "in", "the", "to", "with", "a", "an", "by", "from", "at", "as", "via", "into"]

    static func continues(_ upper: String, _ lower: String) -> Bool {
        guard let first = lower.first(where: { !$0.isWhitespace }) else { return false }
        if first.isLetter && first.isLowercase { return true }
        if upper.hasSuffix("-") { return true }
        let last = upper.split(separator: " ").last.map { $0.lowercased() } ?? ""
        return joiners.contains(last)
    }

    /// One word that is a name: a capital after small letters inside it (SnakeSAM, ResNet, PyTorch), or a word ending
    /// in figures (YOLOv8, ResNet50). Kept as it is (a translation service would turn SnakeSAM into a snake).
    static func isName(_ text: String) -> Bool {
        guard !text.contains(" "), text.count >= 3 else { return false }
        let chars = Array(text)
        let innerCapital = chars.indices.dropFirst().contains { chars[$0].isUppercase && chars[$0 - 1].isLowercase }
        let numbered = chars.first!.isLetter && chars.last!.isNumber
        return innerCapital || numbered
    }

    static func units(_ lines: [ImageText.Line]) -> [Unit] {
        var units: [Unit] = []
        var placed = Set<Int>()
        for k in lines.indices where !placed.contains(k) {
            let line = lines[k]
            // The group's lines in reading order: across, top first; reading up the page, the left one first; down, the right.
            let group = lines.indices.filter { lines[$0].page == line.page && lines[$0].group == line.group && lines[$0].vertical == line.vertical && !placed.contains($0) }
                .sorted { a, b in
                    !line.vertical ? lines[a].rect.maxY > lines[b].rect.maxY
                        : (line.readsDown ? lines[a].rect.midX > lines[b].rect.midX : lines[a].rect.midX < lines[b].rect.midX)
                }
            var current = Unit(text: lines[group[0]].text, members: [group[0]])
            for m in group.dropFirst() {
                let upper = lines[current.members.last!].text
                // A centred block of lines is one label ("Prompt Class / Flag Embedding"), unless a line ends a sentence.
                let centred = line.alignment == .center && !(upper.last.map { ".:;!?".contains($0) } ?? false)
                if centred || continues(upper, lines[m].text) {
                    current.text = upper.hasSuffix("-") && lines[m].text.first?.isLowercase == true
                        ? String(current.text.dropLast()) + lines[m].text
                        : current.text + " " + lines[m].text
                    current.members.append(m)
                } else {
                    units.append(current)
                    current = Unit(text: lines[m].text, members: [m])
                }
            }
            units.append(current)
            placed.formUnion(group)
        }
        return units
    }

    /// `text` cut into as many pieces as there are weights, each about its share of the whole, at places a line may
    /// break: between spaces, or (Chinese, Japanese, Korean) between any two characters but not inside a Latin word or
    /// a number, nor before closing punctuation; after a comma or a pause preferred.
    static func split(_ text: String, weights: [Double], cjk: Bool, language: String? = nil) -> [String] {
        guard weights.count > 1 else { return [text] }
        let chars = Array(text)
        let pauses = Set("，、；：,;:")
        func width(_ c: Character) -> Double { c == " " ? 0.3 : (c.isASCII ? 0.55 : 1) }
        var cumulative = [0.0]
        for c in chars { cumulative.append(cumulative.last! + width(c)) }
        let total = cumulative.last!
        func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "." || c == "_") }
        let closing = Set("，。、；：！？）》」』】,.;:!?)]%")
        // Chinese and Japanese words run together: where they start, as the system's word breaker finds them.
        let starts = cjk ? language.map { wordStarts(text, language: $0) } ?? [] : []
        var breaks: [Int] = []
        var anywhere: [Int] = []
        for i in 1..<max(chars.count, 1) {
            let a = chars[i - 1], b = chars[i]
            if cjk {
                if closing.contains(b) || (latin(a) && latin(b)) || (a == " " && b == " ") { continue }
                anywhere.append(i)
                if starts.contains(i) || pauses.contains(a) || a == " " || b == " " { breaks.append(i) }
            } else if a == " " {
                breaks.append(i)
            }
        }
        if cjk, breaks.count < weights.count - 1 { breaks = anywhere }
        let shares = weights.map { max($0, 0.01) }
        let sum = shares.reduce(0, +)
        var cuts: [Int] = []
        var acc = 0.0
        for k in 0..<(weights.count - 1) {
            acc += shares[k]
            let target = total * acc / sum
            let remaining = weights.count - 2 - k
            let candidates = breaks.filter { $0 > (cuts.last ?? 0) }
            guard candidates.count > remaining else { break }
            let usable = candidates.dropLast(remaining)
            let best = usable.min { a, b in
                func cost(_ i: Int) -> Double { abs(cumulative[i] - target) - (pauses.contains(chars[i - 1]) ? 0.8 : 0) }
                return cost(a) < cost(b)
            }!
            cuts.append(best)
        }
        var pieces: [String] = []
        var start = 0
        for cut in cuts + [chars.count] {
            pieces.append(String(chars[start..<cut]).trimmingCharacters(in: .whitespaces))
            start = cut
        }
        // Not enough places to break: the rest of the lines get nothing (their words are taken out all the same).
        while pieces.count < weights.count { pieces.append("") }
        return pieces
    }

    /// Character offsets at which words start, by the system's word breaker for `language`.
    static func wordStarts(_ text: String, language: String) -> Set<Int> {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: string.length), kCFStringTokenizerUnitWordBoundary,
                                                CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: language as CFString)))
        var starts = Set<Int>()
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let index = String.Index(utf16Offset: range.location, in: text)
            starts.insert(text.distance(from: text.startIndex, to: index))
        }
        return starts
    }
}
