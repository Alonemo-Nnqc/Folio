import FolioCore
import Foundation

/// `https://doi.org/{doi}` with `Accept: application/vnd.citationstyles.csl+json`.
/// Works for every registration agency (DataCite, mEDRA, …), not just Crossref.
struct DOIContentNegotiationClient: Sendable {
    let transport: Transport

    static let accept = "application/vnd.citationstyles.csl+json"

    func lookup(doi: String) async throws(SourceError) -> Metadata? {
        let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://doi.org/\(path)") else { throw .rejected(status: 0) }
        guard let item = try await transport.getJSON(Item.self, from: url, accept: Self.accept) else { return nil }
        return Self.metadata(from: item)
    }

    static func parse(_ data: Data) throws -> Metadata? {
        metadata(from: try JSONDecoder().decode(Item.self, from: data))
    }

    static func metadata(from item: Item) -> Metadata? {
        guard let title = FieldNormalizer.cleanTitle(item.title?.value) else { return nil }
        var metadata = Metadata(title: title)
        metadata.type = itemType(forCSLType: item.type)
        metadata.authors = (item.author ?? []).compactMap {
            NameParser.author(family: $0.family, given: $0.given, literal: $0.literal)
        }
        let dates = [item.publishedPrint, item.publishedOnline, item.issued, item.created]
        if let parsed = dates.lazy.compactMap({ $0.flatMap { FieldNormalizer.date(fromParts: $0.parts) } }).first {
            metadata.year = parsed.year
            metadata.date = parsed.date
        }
        metadata.publisher = FieldNormalizer.cleanText(item.publisher)
        metadata.source = FieldNormalizer.cleanText(item.containerTitle?.value)
        metadata.doi = FieldNormalizer.normalizeDOI(item.DOI)
        if let doi = metadata.doi, let arxiv = IdentifierExtractor.arxivID(fromDOI: doi) {
            metadata.type = .preprint
            metadata.arxivId = arxiv
            metadata.source = "arXiv"
        }
        if metadata.source == nil, [.book, .thesis, .report, .dataset].contains(metadata.type) {
            metadata.source = metadata.publisher
        }
        metadata.volume = FieldNormalizer.cleanText(item.volume?.value)
        metadata.issue = FieldNormalizer.cleanText(item.issue?.value)
        metadata.pages = FieldNormalizer.normalizePages(item.page?.value)
        metadata.isbn = item.ISBN?.value.map { $0.uppercased().filter { $0.isNumber || $0 == "X" } }
            .flatMap(FieldNormalizer.nonEmpty)
        metadata.url = FieldNormalizer.nonEmpty(item.URL) ?? metadata.doi.map { "https://doi.org/\($0)" }
        metadata.abstract = FieldNormalizer.cleanAbstract(item.abstract)
        return metadata
    }

    static func itemType(forCSLType type: String?) -> ItemType {
        switch type {
        case "article-journal", "journal-article": .journalArticle
        case "paper-conference", "proceedings-article": .conferencePaper
        case "article", "posted-content": .preprint
        case "book", "monograph": .book
        case "chapter", "book-chapter": .bookChapter
        case "thesis", "dissertation": .thesis
        case "report": .report
        case "dataset": .dataset
        case "webpage", "post-weblog": .webpage
        default: .other
        }
    }

    struct Person: Decodable {
        var family: String?
        var given: String?
        var literal: String?
    }

    struct Item: Decodable {
        var type: String?
        var title: LenientString?
        var author: [Person]?
        var issued: DateParts?
        var created: DateParts?
        var publishedPrint: DateParts?
        var publishedOnline: DateParts?
        var containerTitle: LenientString?
        var publisher: String?
        var volume: LenientString?
        var issue: LenientString?
        var page: LenientString?
        var DOI: String?
        var URL: String?
        var ISBN: LenientString?
        var abstract: String?

        private enum CodingKeys: String, CodingKey {
            case type, title, author, issued, created, publisher, volume, issue, page, DOI, URL, ISBN, abstract
            case containerTitle = "container-title"
            case publishedPrint = "published-print"
            case publishedOnline = "published-online"
        }
    }
}
