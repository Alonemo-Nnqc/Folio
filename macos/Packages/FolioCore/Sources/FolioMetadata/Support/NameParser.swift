import FolioCore
import Foundation

/// Splits display names ("Andong Lu", "Lu, Andong", "Charette, Raoul de") into family/given.
enum NameParser {
    private static let particles: Set<String> = [
        "van", "von", "der", "den", "de", "del", "della", "di", "da", "du", "la", "le", "dos", "das", "ter", "ten",
    ]
    private static let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]

    static func author(fromDisplayName raw: String) -> Author? {
        var name = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // DBLP disambiguates homonyms with a numeric suffix: "Wei Zhang 0001".
        name = name.replacingOccurrences(of: #"\s+\d{4}$"#, with: "", options: .regularExpression)
        guard !name.isEmpty else { return nil }

        if let comma = name.firstIndex(of: ",") {
            let family = name[..<comma].trimmingCharacters(in: .whitespaces)
            let given = name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if !family.isEmpty, !suffixes.contains(given.lowercased()) {
                return Author(family: family, given: given)
            }
        }

        var tokens = name.split(separator: " ").map(String.init)
        if tokens.count == 1 {
            let only = tokens[0]
            // "张三" -> family "张", given "三".
            if (2...4).contains(only.count), TextMatcher.cjkRatio(only) == 1 {
                return Author(family: String(only.prefix(1)), given: String(only.dropFirst()))
            }
            return Author(family: only)
        }
        var suffix = ""
        if tokens.count > 2, let last = tokens.last, suffixes.contains(last.lowercased()) {
            suffix = " " + tokens.removeLast()
        }
        var familyStart = tokens.count - 1
        while familyStart > 1, particles.contains(tokens[familyStart - 1]) {
            familyStart -= 1
        }
        let family = tokens[familyStart...].joined(separator: " ") + suffix
        let given = tokens[..<familyStart].joined(separator: " ")
        return Author(family: family, given: given)
    }

    /// Structured names as delivered by Crossref / CSL; falls back to `literal`/`name` for organisations.
    static func author(family: String?, given: String?, literal: String?) -> Author? {
        let family = FieldNormalizer.nonEmpty(family)
        let given = FieldNormalizer.nonEmpty(given)
        if let family {
            return Author(family: family, given: given ?? "")
        }
        if let literal = FieldNormalizer.nonEmpty(literal) {
            return Author(family: literal)
        }
        if let given {
            return author(fromDisplayName: given)
        }
        return nil
    }
}
