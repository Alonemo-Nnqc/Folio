import Foundation

/// Generates BibTeX citation keys such as `zhang2026` (requirement CITE-03).
public enum CitationKeyGenerator {
    private static let stopWords: Set<String> = ["a", "an", "the", "on", "of", "for", "in", "and", "to", "with"]

    public static func baseKey(for metadata: Metadata) -> String {
        let stem: String
        if let family = metadata.authors.first?.family, !asciiSlug(family).isEmpty {
            stem = asciiSlug(family)
        } else {
            let words = TitleNormalizer.normalize(metadata.title).split(separator: " ").map(String.init)
            stem = words.first(where: { !stopWords.contains($0) }).map(asciiSlug) ?? "item"
        }
        return stem + (metadata.year.map(String.init) ?? "")
    }

    public static func uniqueKey(base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var suffix = ""
        repeat { suffix = nextSuffix(suffix) } while existing.contains(base + suffix)
        return base + suffix
    }

    /// "" → "a" … "z" → "aa" → "ab" …
    private static func nextSuffix(_ s: String) -> String {
        var chars = Array(s)
        var i = chars.count - 1
        while i >= 0 {
            if chars[i] != "z" {
                chars[i] = Character(UnicodeScalar(chars[i].unicodeScalars.first!.value + 1)!)
                return String(chars)
            }
            chars[i] = "a"
            i -= 1
        }
        return "a" + String(chars)
    }

    private static func asciiSlug(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let folded = latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
    }
}
