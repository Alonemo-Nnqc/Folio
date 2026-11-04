import FolioCore
import Foundation

/// Field clean-up shared by all source clients.
enum FieldNormalizer {
    /// Removes HTML/JATS/MathML tags, decodes common entities and collapses whitespace.
    static func cleanText(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        if text.contains("<") {
            text = text.replacingOccurrences(of: #"<[^>]{0,200}>"#, with: " ", options: .regularExpression)
        }
        if text.contains("&") { text = decodeEntities(text) }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        // Tag removal leaves "word ," / "( word"; tighten those.
        let tightened = collapsed
            .replacingOccurrences(of: #" ([,.;:!?)\]])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([(\[]) "#, with: "$1", options: .regularExpression)
        return tightened.isEmpty ? nil : tightened
    }

    /// Title clean-up; DBLP appends a period to every title, which is dropped here too.
    static func cleanTitle(_ raw: String?, dropTrailingPeriod: Bool = false) -> String? {
        guard var title = cleanText(raw) else { return nil }
        if dropTrailingPeriod, title.hasSuffix("."), !title.hasSuffix("..") {
            title.removeLast()
        }
        return title.isEmpty ? nil : title
    }

    /// Abstract clean-up: tags removed and a leading "Abstract" heading dropped.
    static func cleanAbstract(_ raw: String?) -> String? {
        guard var text = cleanText(raw) else { return nil }
        for heading in ["Abstract", "ABSTRACT", "Summary", "SUMMARY"] where text.hasPrefix(heading) {
            // Only the separator after the heading goes; the abstract's final period stays.
            text = String(text.dropFirst(heading.count).drop { " :.—-".contains($0) })
            break
        }
        return text.isEmpty ? nil : text
    }

    /// Lowercased DOI without resolver prefix; nil when it does not look like a DOI.
    static func normalizeDOI(_ raw: String?) -> String? {
        guard var doi = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !doi.isEmpty else { return nil }
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"]
        where doi.lowercased().hasPrefix(prefix) {
            doi = String(doi.dropFirst(prefix.count))
            break
        }
        doi = doi.lowercased()
        return doi.hasPrefix("10.") && doi.contains("/") ? doi : nil
    }

    /// "123–130" -> "123-130".
    static func normalizePages(_ raw: String?) -> String? {
        guard let pages = cleanText(raw) else { return nil }
        return pages.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "--", with: "-")
    }

    static func nonEmpty(_ raw: String?) -> String? {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// Builds (year, "YYYY[-MM[-DD]]") from date parts such as `[2024, 5, 1]`.
    static func date(fromParts parts: [Int]) -> (year: Int, date: String)? {
        guard let year = parts.first, (1000...9999).contains(year) else { return nil }
        var date = String(year)
        if parts.count > 1, (1...12).contains(parts[1]) {
            date += String(format: "-%02d", parts[1])
            if parts.count > 2, (1...31).contains(parts[2]) {
                date += String(format: "-%02d", parts[2])
            }
        }
        return (year, date)
    }

    /// Parses ISO-like dates ("2024-05-04T17:24:09Z", "2024-05", "2024") and free text containing a year.
    static func date(fromString raw: String?) -> (year: Int, date: String)? {
        guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let match = text.range(of: #"^\d{4}(-\d{2}(-\d{2})?)?"#, options: .regularExpression) {
            let parts = text[match].split(separator: "-").compactMap { Int($0) }
            return date(fromParts: parts)
        }
        if let match = text.range(of: #"\b(1[5-9]|20)\d{2}\b"#, options: .regularExpression), let year = Int(text[match]) {
            return (year, String(year))
        }
        return nil
    }

    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&nbsp;": " ",
        "&ndash;": "–", "&mdash;": "—",
    ]

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric entities: &#8211; &#x2013;
        guard result.contains("&#") else { return result }
        let pattern = try! NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]{1,6});"#)
        let ns = result as NSString
        var output = ""
        var cursor = 0
        for match in pattern.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = match.range(at: 1).length > 0
            let digits = ns.substring(with: match.range(at: 2))
            if let value = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                output.unicodeScalars.append(scalar)
            }
            cursor = match.range.location + match.range.length
        }
        output += ns.substring(from: cursor)
        return output
    }
}
