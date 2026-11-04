import Foundation

/// Builds library file names of the form `Family_Year_Title` (requirement STORE-03).
public enum FileNamer {
    public static let maxTitleLength = 80

    public static func baseName(for metadata: Metadata) -> String {
        var parts: [String] = []
        if let family = metadata.authors.first?.family {
            let clean = sanitize(family)
            if !clean.isEmpty { parts.append(clean) }
        }
        if let year = metadata.year { parts.append(String(year)) }
        let title = truncate(sanitize(metadata.title), to: maxTitleLength)
        if !title.isEmpty { parts.append(title) }
        return parts.isEmpty ? "Untitled" : parts.joined(separator: "_")
    }

    /// What a translation adds to its paper's name, instead of a number: "（双语对照 · Google）".
    public static func translationSuffix(kind: TranslationKind, translatedBy: String?) -> String {
        // Lowercase in English, like Folio's own translations: "Paper (bilingual · Google)".
        let what = FileLabel.kindName(kind).lowercased()
        // Model names such as "Qwen/Qwen3-8B" have slashes.
        let translatedBy = translatedBy.map(sanitize)
        guard let translatedBy, !translatedBy.isEmpty else { return String(localized: "（\(what)）", bundle: .module) }
        return String(localized: "（\(what) · \(translatedBy)）", bundle: .module)
    }

    /// The bracketed note at the end of a translation's name — "（简体中文译文 · DeepSeek · deepseek-chat）",
    /// " (Bilingual · Google)" — so renaming the paper keeps it. Nil when the name has none.
    public static func translationSuffix(inName stem: String) -> String? {
        guard let range = stem.range(of: #"\s?[（(][^（）()]+ · [^（）()]+[）)]$"#, options: .regularExpression)
        else { return nil }
        return String(stem[range])
    }

    /// "DeepSeek · deepseek-chat" from "论文（简体中文译文 · DeepSeek · deepseek-chat）": the note minus what kind it is.
    public static func translatedBy(inName stem: String) -> String? {
        guard let suffix = translationSuffix(inName: stem) else { return nil }
        let inner = suffix.trimmingCharacters(in: CharacterSet(charactersIn: " （）()"))
        let parts = inner.components(separatedBy: " · ")
        guard parts.count > 1 else { return nil }
        return parts.dropFirst().joined(separator: " · ")
    }

    /// Makes text safe for macOS file names and readable in Finder.
    public static func sanitize(_ text: String) -> String {
        var result = ""
        for ch in text {
            switch ch {
            case ":": result += " -"
            case "/", "\\": result += "-"
            case "?", "*", "\"", "<", ">", "|": continue
            default:
                if ch.isNewline || ch.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
                    result += " "
                } else {
                    result.append(ch)
                }
            }
        }
        let collapsed = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let prefix = String(text.prefix(limit))
        if let space = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: space) > limit / 2 {
            return String(prefix[..<space]).trimmingCharacters(in: CharacterSet(charactersIn: " -,."))
        }
        return prefix
    }
}
