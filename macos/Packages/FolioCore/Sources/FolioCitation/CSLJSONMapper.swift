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
        // A repository is not a container: preprints cite it as the publisher with the identifier as
        // the number (the CSL / Zotero convention), so styles print "arXiv:2401.12345" and a link.
        let isRepositoryPreprint = m.type == .preprint && m.arxivId != nil
        // Books, theses and reports are not in a container: what `source` holds for them is the publisher, university or
        // institution (#19).
        let publishedBy = [.book, .thesis, .report].contains(m.type)
        if let source = m.source, !source.isEmpty, !publishedBy, !(isRepositoryPreprint && source.lowercased() == "arxiv") {
            item["container-title"] = source
        }
        if isRepositoryPreprint, let arxiv = m.arxivId {
            item["publisher"] = "arXiv"
            item["number"] = "arXiv:\(arxiv)"
            if (m.doi ?? "").isEmpty { item["DOI"] = "10.48550/arXiv.\(arxiv)" }
            if (m.url ?? "").isEmpty { item["URL"] = "https://arxiv.org/abs/\(arxiv)" }
        }
        if let volume = m.volume, !volume.isEmpty { item["volume"] = volume }
        // A report's number is its "issue".
        if let issue = m.issue, !issue.isEmpty { item[m.type == .report ? "number" : "issue"] = issue }
        if let pages = m.pages, !pages.isEmpty { item["page"] = pages }
        let institution = m.type == .thesis || m.type == .report ? m.source.nonEmpty ?? m.publisher.nonEmpty : nil
        if let publisher = institution ?? m.publisher.nonEmpty ?? (m.type == .book ? m.source.nonEmpty : nil), !isRepositoryPreprint {
            item["publisher"] = publisher
        }
        if let place = m.place.nonEmpty {
            item["publisher-place"] = place
            if m.type == .conferencePaper { item["event-place"] = place }
        }
        if let edition = m.edition.nonEmpty { item["edition"] = edition }
        if !m.editors.isEmpty { item["editor"] = m.editors.map(cslName) }
        if !m.translators.isEmpty { item["translator"] = m.translators.map(cslName) }
        if let series = m.series.nonEmpty { item["collection-title"] = series }
        if let genre = m.genre.nonEmpty { item["genre"] = genre }
        if let doi = m.doi, !doi.isEmpty { item["DOI"] = doi }
        if let url = m.url, !url.isEmpty { item["URL"] = url }
        if let abstract = m.abstract, !abstract.isEmpty { item["abstract"] = abstract }
        return item
    }

    static func cslType(for type: ItemType) -> String {
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
    static func cslName(_ author: Author) -> [String: String] {
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

extension Optional where Wrapped == String {
    /// The text, unless missing or empty.
    var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
