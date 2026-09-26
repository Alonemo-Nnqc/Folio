import FolioCore
import Foundation

/// Crossref REST API: `/works/{doi}` and `/works?query.bibliographic=`.
struct CrossrefClient: Sendable {
    let transport: Transport
    let mailto: String?

    /// Fields requested for searches; keeps responses around 8 KB instead of 100+ KB.
    static let selectFields = "DOI,title,subtitle,author,published-print,published-online,issued,created,"
        + "container-title,volume,issue,page,publisher,type,ISBN,URL,abstract"

    /// Record types that are never "the paper" (reviews of it, figures, journal containers …).
    static let ignoredSearchTypes: Set<String> = [
        "peer-review", "component", "grant", "journal", "journal-issue", "journal-volume",
        "proceedings", "proceedings-series", "book-series", "book-set", "report-series",
    ]

    private static let doiPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ";?#%")
        return allowed
    }()

    /// Nil when Crossref does not know the DOI (e.g. DataCite DOIs).
    func work(doi: String) async throws(SourceError) -> Metadata? {
        let path = doi.addingPercentEncoding(withAllowedCharacters: Self.doiPathAllowed) ?? doi
        guard let url = URL.make("https://api.crossref.org/works/\(path)", query: [("mailto", mailto)]) else {
            throw .rejected(status: 0)
        }
        guard let envelope = try await transport.getJSON(WorkEnvelope.self, from: url) else { return nil }
        return Self.metadata(from: envelope.message)
    }

    func search(title: String, rows: Int = 5) async throws(SourceError) -> [Metadata] {
        guard let url = URL.make("https://api.crossref.org/works", query: [
            ("query.bibliographic", title), ("rows", String(rows)), ("select", Self.selectFields), ("mailto", mailto),
        ]) else { throw .rejected(status: 0) }
        guard let envelope = try await transport.getJSON(SearchEnvelope.self, from: url) else { return [] }
        return Self.searchResults(envelope)
    }

    // MARK: - Parsing

    static func parseWork(_ data: Data) throws -> Metadata? {
        metadata(from: try JSONDecoder().decode(WorkEnvelope.self, from: data).message)
    }

    static func parseSearch(_ data: Data) throws -> [Metadata] {
        searchResults(try JSONDecoder().decode(SearchEnvelope.self, from: data))
    }

    private static func searchResults(_ envelope: SearchEnvelope) -> [Metadata] {
        envelope.message.items
            .filter { !ignoredSearchTypes.contains($0.type ?? "") }
            .compactMap(metadata(from:))
    }

    static func metadata(from item: Item) -> Metadata? {
        guard var title = FieldNormalizer.cleanTitle(item.title?.first) else { return nil }
        if let subtitle = FieldNormalizer.cleanTitle(item.subtitle?.first),
           !TitleNormalizer.normalize(title).contains(TitleNormalizer.normalize(subtitle)) {
            title += ": " + subtitle
        }
        var metadata = Metadata(title: title)
        metadata.type = itemType(forCrossrefType: item.type)
        metadata.authors = (item.author ?? []).compactMap {
            NameParser.author(family: $0.family, given: $0.given, literal: $0.name)
        }
        let dates = [item.publishedPrint, item.publishedOnline, item.issued, item.created]
        if let parsed = dates.lazy.compactMap({ $0.flatMap { FieldNormalizer.date(fromParts: $0.parts) } }).first {
            metadata.year = parsed.year
            metadata.date = parsed.date
        }
        metadata.publisher = FieldNormalizer.cleanText(item.publisher)
        metadata.source = FieldNormalizer.cleanText(item.containerTitle?.first)
        if metadata.source == nil, [.book, .thesis, .report].contains(metadata.type) {
            metadata.source = metadata.publisher
        }
        metadata.volume = FieldNormalizer.cleanText(item.volume?.value)
        metadata.issue = FieldNormalizer.cleanText(item.issue?.value)
        metadata.pages = FieldNormalizer.normalizePages(item.page?.value)
        metadata.doi = FieldNormalizer.normalizeDOI(item.DOI)
        metadata.isbn = item.ISBN?.first.map { $0.uppercased().filter { $0.isNumber || $0 == "X" } }
            .flatMap(FieldNormalizer.nonEmpty)
        metadata.url = FieldNormalizer.nonEmpty(item.URL) ?? metadata.doi.map { "https://doi.org/\($0)" }
        metadata.abstract = FieldNormalizer.cleanAbstract(item.abstract)
        return metadata
    }

    static func itemType(forCrossrefType type: String?) -> ItemType {
        switch type {
        case "journal-article": .journalArticle
        case "proceedings-article": .conferencePaper
        case "posted-content": .preprint
        case "book", "monograph", "edited-book", "reference-book": .book
        case "book-chapter", "book-section", "book-part", "reference-entry": .bookChapter
        case "dissertation": .thesis
        case "report", "report-component": .report
        case "dataset", "database": .dataset
        default: .other
        }
    }

    // MARK: - Wire format

    struct WorkEnvelope: Decodable {
        var message: Item
    }

    struct SearchEnvelope: Decodable {
        struct Message: Decodable {
            var items: [Item]
        }
        var message: Message
    }

    struct Person: Decodable {
        var given: String?
        var family: String?
        var name: String?
    }

    struct Item: Decodable {
        var DOI: String?
        var type: String?
        var title: [String]?
        var subtitle: [String]?
        var author: [Person]?
        var containerTitle: [String]?
        var publishedPrint: DateParts?
        var publishedOnline: DateParts?
        var issued: DateParts?
        var created: DateParts?
        var volume: LenientString?
        var issue: LenientString?
        var page: LenientString?
        var publisher: String?
        var ISBN: [String]?
        var URL: String?
        var abstract: String?

        private enum CodingKeys: String, CodingKey {
            case DOI, type, title, subtitle, author, volume, issue, page, publisher, ISBN, URL, abstract, issued, created
            case containerTitle = "container-title"
            case publishedPrint = "published-print"
            case publishedOnline = "published-online"
        }
    }
}
