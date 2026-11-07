import FolioCore
import Foundation

/// Fuzzy "does this title appear in that page" matching on normalised tokens.
enum TextMatcher {
    /// Normalised tokens (lowercase, no diacritics, punctuation removed), via `TitleNormalizer`.
    static func tokens(_ text: String) -> [String] {
        TitleNormalizer.normalize(text).split(separator: " ").map(String.init)
    }

    /// Best `TitleNormalizer.similarity` between `title` and any run of consecutive page tokens
    /// whose length is within one token of the title's.
    ///
    /// Windows are pre-filtered with a cheap token-overlap score so that only a handful of
    /// full (Levenshtein) comparisons are made per title.
    static func windowSimilarity(of title: String, in pageTokens: [String]) -> Double {
        let titleTokens = tokens(title)
        guard !titleTokens.isEmpty, !pageTokens.isEmpty else { return 0 }
        let normalizedTitle = titleTokens.joined(separator: " ")
        var titleCounts: [String: Int] = [:]
        for token in titleTokens { titleCounts[token, default: 0] += 1 }

        var shortlisted: [(overlap: Double, start: Int, length: Int)] = []
        let lengths = Set([titleTokens.count - 1, titleTokens.count, titleTokens.count + 1].filter { $0 > 0 })
        for length in lengths where length <= pageTokens.count {
            for start in 0...(pageTokens.count - length) {
                var remaining = titleCounts
                var shared = 0
                for token in pageTokens[start..<(start + length)] {
                    if let count = remaining[token], count > 0 {
                        shared += 1
                        remaining[token] = count - 1
                    }
                }
                let overlap = Double(2 * shared) / Double(titleTokens.count + length)
                if overlap >= 0.5 { shortlisted.append((overlap, start, length)) }
            }
        }
        var best = 0.0
        for window in shortlisted.sorted(by: { $0.overlap > $1.overlap }).prefix(6) {
            let text = pageTokens[window.start..<(window.start + window.length)].joined(separator: " ")
            best = max(best, TitleNormalizer.similarity(text, normalizedTitle))
            if best >= 1 { break }
        }
        return best
    }

    /// Whether the (possibly multi-word) name occurs as consecutive page tokens.
    ///
    /// The last token may carry up to two trailing characters, because affiliation markers
    /// are often glued to names in extracted text ("Konga,b" -> "konga b", "Bi1,3" -> "bi1 3").
    static func containsName(_ name: String, in pageTokens: [String]) -> Bool {
        let nameTokens = tokens(name)
        guard !nameTokens.isEmpty, nameTokens.count <= pageTokens.count else { return false }
        if nameTokens.count == 1, nameTokens[0].count < 2 { return false }
        for start in 0...(pageTokens.count - nameTokens.count) {
            var matched = true
            for (offset, token) in nameTokens.enumerated() {
                let page = pageTokens[start + offset]
                let isLast = offset == nameTokens.count - 1
                if page == token { continue }
                if isLast, page.hasPrefix(token), page.count - token.count <= 2 { continue }
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    /// Share of CJK ideographs / kana / hangul among the letters of `text`.
    static func cjkRatio(_ text: String) -> Double {
        var letters = 0
        var cjk = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                cjk += 1
            default:
                break
            }
        }
        return letters == 0 ? 0 : Double(cjk) / Double(letters)
    }
}
