import FolioCore
import Foundation

/// Renders `CitationEntry` values as BibTeX source (requirement CITE-02).
public enum BibTeXWriter {
    /// One `@type{key, field = {value}, ...}` entry, without a trailing blank line.
    public static func entry(_ entry: CitationEntry) -> String {
        let m = entry.metadata
        var fields: [(String, String)] = []
        fields.append(("author", authorField(m.authors)))
        fields.append(("title", titleField(m.title)))
        fields.append(contentsOf: extraFields(for: m))

        let body = fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
        return "@\(kind(for: m.type)){\(entry.citationKey),\n\(body)\n}"
    }

    /// All entries, separated by a blank line, terminated with a trailing newline.
    public static func document(_ entries: [CitationEntry]) -> String {
        entries.map(entry).joined(separator: "\n\n") + "\n"
    }

    // MARK: - Entry type mapping

    private static func kind(for type: ItemType) -> String {
        switch type {
        case .journalArticle: "article"
        case .conferencePaper: "inproceedings"
        case .preprint: "misc"
        case .book: "book"
        case .bookChapter: "incollection"
        case .thesis: "phdthesis"
        case .report: "techreport"
        case .webpage, .dataset, .other: "misc"
        }
    }

    // MARK: - Field selection per type

    private static func extraFields(for m: Metadata) -> [(String, String)] {
        var fields: [(String, String)] = []
        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append((name, escape(value)))
        }

        switch m.type {
        case .journalArticle:
            add("journal", m.source)
            add("year", yearField(m))
            add("volume", m.volume)
            add("number", m.issue)
            add("pages", pagesField(m.pages))
            add("doi", m.doi)
        case .conferencePaper:
            add("booktitle", m.source)
            add("year", yearField(m))
            add("volume", m.volume)
            add("pages", pagesField(m.pages))
            add("doi", m.doi)
        case .preprint:
            add("year", yearField(m))
            if let arxivId = m.arxivId, !arxivId.isEmpty {
                fields.append(("eprint", escape(arxivId)))
                fields.append(("archivePrefix", "arXiv"))
            }
            add("doi", m.doi)
            add("url", m.url)
        case .book:
            add("publisher", m.publisher)
            add("year", yearField(m))
            add("isbn", m.isbn)
            add("doi", m.doi)
            add("url", m.url)
        case .bookChapter:
            add("booktitle", m.source)
            add("publisher", m.publisher)
            add("year", yearField(m))
            add("pages", pagesField(m.pages))
            add("doi", m.doi)
        case .thesis:
            add("school", m.source)
            add("year", yearField(m))
            add("doi", m.doi)
            add("url", m.url)
        case .report:
            add("institution", m.source)
            add("year", yearField(m))
            add("doi", m.doi)
            add("url", m.url)
        case .webpage, .dataset, .other:
            add("year", yearField(m))
            add("note", m.source)
            add("url", m.url)
            add("doi", m.doi)
        }
        return fields
    }

    private static func yearField(_ m: Metadata) -> String? {
        if let year = m.year { return String(year) }
        guard let date = m.date else { return nil }
        return String(date.prefix(4))
    }

    /// BibTeX convention uses an en-dash-like "--" for page ranges.
    private static func pagesField(_ pages: String?) -> String? {
        guard let pages, !pages.isEmpty else { return nil }
        if pages.contains("--") { return pages }
        return pages.replacingOccurrences(of: "-", with: "--")
    }

    // MARK: - Author formatting

    private static func authorField(_ authors: [Author]) -> String {
        authors.map { escape(AuthorFormatter.full($0)) }.joined(separator: " and ")
    }

    // MARK: - Title formatting (escaping + acronym brace-protection)

    private static func titleField(_ title: String) -> String {
        protectAcronyms(escape(title))
    }

    /// Wraps whole words containing two or more consecutive uppercase ASCII
    /// letters in braces, so BibTeX styles that lowercase titles leave
    /// acronyms such as "UNet" or "GPU" untouched.
    private static func protectAcronyms(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\S*[A-Z]{2,}\\S*") else { return text }
        let ns = text as NSString
        var result = ""
        var lastEnd = 0
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let range = match.range
            result += ns.substring(with: NSRange(location: lastEnd, length: range.location - lastEnd))
            result += "{\(ns.substring(with: range))}"
            lastEnd = range.location + range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    // MARK: - Escaping

    /// Escapes the LaTeX-special characters `& % $ # _ { } ~ ^ \`.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\\": result += "\\textbackslash{}"
            case "&": result += "\\&"
            case "%": result += "\\%"
            case "$": result += "\\$"
            case "#": result += "\\#"
            case "_": result += "\\_"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "~": result += "\\textasciitilde{}"
            case "^": result += "\\textasciicircum{}"
            default: result.append(ch)
            }
        }
        return result
    }
}
