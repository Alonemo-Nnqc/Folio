import FolioCore
import Foundation

/// Converts `Metadata` into a CSL-JSON item (a `[String: Any]` dictionary
/// ready to bridge into JavaScriptCore) for rendering with citeproc-js.
enum CSLJSONMapper {
    static func csljson(id: String, metadata m: Metadata) -> [String: Any] {
        var item: [String: Any] = [
            "id": id,
            "type": cslType(for: m.type),
            "title": m.title,
            "language": containsCJK(m.title) ? "zh" : "en",
        ]
        if !m.authors.isEmpty {
            item["author"] = m.authors.map(cslName)
        }
        if let issued = cslIssued(m) {
            item["issued"] = issued
        }
        if let source = m.source, !source.isEmpty { item["container-title"] = source }
        if let volume = m.volume, !volume.isEmpty { item["volume"] = volume }
        if let issue = m.issue, !issue.isEmpty { item["issue"] = issue }
        if let pages = m.pages, !pages.isEmpty { item["page"] = pages }
        if let publisher = m.publisher, !publisher.isEmpty { item["publisher"] = publisher }
        if let doi = m.doi, !doi.isEmpty { item["DOI"] = doi }
        if let url = m.url, !url.isEmpty { item["URL"] = url }
        if let abstract = m.abstract, !abstract.isEmpty { item["abstract"] = abstract }
        return item
    }

    private static func cslType(for type: ItemType) -> String {
        switch type {
        case .journalArticle: "article-journal"
        case .conferencePaper: "paper-conference"
        case .preprint: "article"
        case .book: "book"
        case .bookChapter: "chapter"
        case .thesis: "thesis"
        case .report: "report"
        case .webpage: "webpage"
        case .dataset: "dataset"
        case .other: "document"
        }
    }

    /// Organisational authors (empty `given`) are emitted as a CSL `literal`
    /// name so citeproc does not try to invert them like a personal name.
    private static func cslName(_ author: Author) -> [String: String] {
        let given = author.given.trimmingCharacters(in: .whitespaces)
        if given.isEmpty {
            return ["literal": author.family]
        }
        return ["family": author.family, "given": given]
    }

    private static func cslIssued(_ m: Metadata) -> [String: Any]? {
        if let parts = dateParts(from: m.date), !parts.isEmpty {
            return ["date-parts": [parts]]
        }
        if let year = m.year {
            return ["date-parts": [[year]]]
        }
        return nil
    }

    /// "YYYY", "YYYY-MM" or "YYYY-MM-DD" -> [Y], [Y, M] or [Y, M, D].
    private static func dateParts(from date: String?) -> [Int]? {
        guard let date else { return nil }
        let parts = date.split(separator: "-").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
        }
    }
}
