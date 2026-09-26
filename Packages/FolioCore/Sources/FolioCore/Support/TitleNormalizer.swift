import Foundation

/// Canonicalises titles so that trivially different spellings compare equal.
public enum TitleNormalizer {
    /// Lowercases, strips diacritics, replaces punctuation with spaces and collapses whitespace.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
            } else {
                scalars.append(" ")
            }
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Similarity in 0...1: the larger of token Dice coefficient and normalised Levenshtein similarity.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }
        return max(dice(na, nb), levenshteinSimilarity(na, nb))
    }

    static func dice(_ a: String, _ b: String) -> Double {
        let ta = a.split(separator: " ").map(String.init)
        let tb = b.split(separator: " ").map(String.init)
        var counts: [String: Int] = [:]
        for t in tb { counts[t, default: 0] += 1 }
        var shared = 0
        for t in ta where (counts[t] ?? 0) > 0 {
            shared += 1
            counts[t]! -= 1
        }
        return Double(2 * shared) / Double(ta.count + tb.count)
    }

    static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.utf16)
        let y = Array(b.utf16)
        let longest = max(x.count, y.count)
        // Beyond this size the quadratic cost is not worth it; Dice already covers long strings.
        guard longest <= 600 else { return 0 }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[y.count]) / Double(longest)
    }
}
