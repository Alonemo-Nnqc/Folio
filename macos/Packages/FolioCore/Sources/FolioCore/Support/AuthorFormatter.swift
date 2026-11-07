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
