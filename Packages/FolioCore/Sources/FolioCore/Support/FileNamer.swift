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
