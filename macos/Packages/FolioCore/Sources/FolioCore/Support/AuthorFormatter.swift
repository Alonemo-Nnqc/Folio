/// Formats author lists for list columns and citations (requirement LIST-04).
public enum AuthorFormatter {
    /// "Zhang, Tengya"; organisations render as their name alone.
    public static func full(_ author: Author) -> String {
        let family = author.family.trimmingCharacters(in: .whitespaces)
        let given = author.given.trimmingCharacters(in: .whitespaces)
        if given.isEmpty { return family }
        if family.isEmpty { return given }
        return "\(family), \(given)"
    }

    /// People as one line to read and edit: "Zhang, Tengya; Li, Wei; 王小明".
    public static func joined(_ people: [Author]) -> String {
        people.map(full).joined(separator: "; ")
    }

    /// People typed as one line: separated by ";", "；" or "、" (or " and "), each "Family, Given" or a name as it is
    /// ("王小明", "OpenAI", "Tengya Zhang").
    public static func people(_ text: String) -> [Author] {
        text.replacingOccurrences(of: " and ", with: ";")
            .split(whereSeparator: { $0 == ";" || $0 == "；" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { name in
                if let comma = name.firstIndex(where: { $0 == "," || $0 == "，" }) {
                    return Author(family: name[..<comma].trimmingCharacters(in: .whitespaces),
                                  given: name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces))
                }
                let parts = name.split(separator: " ")
                // CJK names and organisations stay whole; "Tengya Zhang" is given then family.
                guard parts.count > 1, !name.unicodeScalars.contains(where: { (0x3000...0x9FFF).contains($0.value) }) else {
                    return Author(family: name)
                }
                return Author(family: String(parts.last!), given: parts.dropLast().joined(separator: " "))
            }
    }

    /// One author: "Zhang, Tengya"; two: "Lou, Meng & Yu, Yizhou"; three or more: "Zhang, Tengya et al.".
    public static func listDisplay(_ authors: [Author]) -> String {
        switch authors.count {
        case 0: ""
        case 1: full(authors[0])
        case 2: "\(full(authors[0])) & \(full(authors[1]))"
        default: "\(full(authors[0])) et al."
        }
    }
}
