import FolioCore
import Foundation

/// Zotero's PDF recognizer (`services.zotero.org/recognizer/recognize`), the service behind
/// Zotero's "Retrieve Metadata for PDF".
///
/// It takes the layout of the first pages (`RecognizerPayload`) and answers with an identifier
/// (arXiv ID, DOI, ISBN) and/or bibliographic fields. The service is undocumented and needs no
/// key; every failure is reported as a `SourceError` and the engine treats it as optional.
struct ZoteroRecognizerClient: Sendable {
    static let endpoint = URL(string: "https://services.zotero.org/recognizer/recognize")!

    let transport: Transport

    /// Nil when the service had nothing to say about the document.
    func recognize(_ payload: RecognizerPayload) async throws(SourceError) -> RecognizerResponse? {
        guard let body = payload.jsonData() else { throw .rejected(status: 0) }
        guard let data = try await transport.post(Self.endpoint, json: body) else { return nil }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws(SourceError) -> RecognizerResponse? {
        // An empty body or `null` means "not recognised".
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return nil }
        let response: RecognizerResponse?
        do {
            response = try JSONDecoder().decode(RecognizerResponse?.self, from: data)
        } catch {
            throw .malformed
        }
        guard let response, !response.isEmpty else { return nil }
        return response
    }
}

/// What the recognizer answered. Every field is optional and decoded leniently.
struct RecognizerResponse: Decodable, Sendable, Equatable {
    struct Person: Decodable, Sendable, Equatable {
        var firstName: String?
        var lastName: String?

        private enum CodingKeys: String, CodingKey { case firstName, lastName }

        init(firstName: String?, lastName: String?) {
            self.firstName = firstName
            self.lastName = lastName
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            firstName = (try? container.decode(LenientString.self, forKey: .firstName))?.value
            lastName = (try? container.decode(LenientString.self, forKey: .lastName))?.value
        }
    }

    var type: String?
    var title: String?
    var authors: [Person] = []
    var abstract: String?
    var year: String?
    var container: String?
    var volume: String?
    var issue: String?
    var pages: String?
    var publisher: String?
    var url: String?
    var issn: String?
    var isbn: String?
    var doi: String?
    var arxiv: String?
    var language: String?

    private enum CodingKeys: String, CodingKey {
        case type, title, authors, abstract, year, container, volume, issue, pages, publisher, url, language
        case doi, arxiv
        case issn = "ISSN"
        case isbn = "ISBN"
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? {
            FieldNormalizer.nonEmpty((try? container.decode(LenientString.self, forKey: key))?.value)
        }
        type = string(.type)
        title = string(.title)
        authors = (try? container.decode([Person].self, forKey: .authors)) ?? []
        abstract = string(.abstract)
        year = string(.year)
        self.container = string(.container)
        volume = string(.volume)
        issue = string(.issue)
        pages = string(.pages)
        publisher = string(.publisher)
        url = string(.url)
        issn = string(.issn)
        isbn = string(.isbn)
        doi = string(.doi)
        arxiv = string(.arxiv)
        language = string(.language)
    }

    var isEmpty: Bool { title == nil && identifiers.isEmpty }

    /// The identifiers the response names, in the order Zotero tries them: arXiv, DOI, ISBN.
    var identifiers: [Identifier] {
        var result: [Identifier] = []
        if let arxiv {
            let bare = arxiv.replacingOccurrences(of: #"(?i)^arxiv:\s*"#, with: "", options: .regularExpression)
            if case .arxiv(let id)? = Identifier.parse("arXiv:" + bare) { result.append(.arxiv(id)) }
        }
        if let doi = FieldNormalizer.normalizeDOI(doi) ?? doi.flatMap({ IdentifierExtractor.dois(in: $0).first }) {
            result.append(.doi(doi))
        }
        if let isbn {
            let digits = isbn.uppercased().filter { $0.isNumber || $0 == "X" }
            if digits.count == 10 || digits.count == 13 { result.append(.isbn(digits)) }
        }
        return result
    }

    /// The record Zotero builds from the fields alone: a book section for type "book-chapter",
    /// otherwise a journal article. Nil without a title.
    var metadata: Metadata? {
        guard let title = FieldNormalizer.cleanTitle(title) else { return nil }
        var metadata = Metadata(title: title)
        metadata.type = type == "book-chapter" ? .bookChapter : .journalArticle
        metadata.authors = authors.compactMap { NameParser.author(family: $0.lastName, given: $0.firstName, literal: nil) }
        if let parsed = FieldNormalizer.date(fromString: year) {
            metadata.year = parsed.year
            metadata.date = parsed.date
        }
        metadata.source = FieldNormalizer.cleanText(container)
        metadata.volume = FieldNormalizer.cleanText(volume)
        metadata.issue = FieldNormalizer.cleanText(issue)
        metadata.pages = FieldNormalizer.normalizePages(pages)
        metadata.publisher = FieldNormalizer.cleanText(publisher)
        metadata.url = FieldNormalizer.nonEmpty(url)
        metadata.abstract = FieldNormalizer.cleanAbstract(abstract)
        for identifier in identifiers {
            switch identifier {
            case .doi(let doi): metadata.doi = doi
            case .arxiv(let id): metadata.arxivId = id
            case .isbn(let isbn): metadata.isbn = isbn
            }
        }
        if metadata.url == nil, let doi = metadata.doi { metadata.url = "https://doi.org/\(doi)" }
        return metadata
    }
}
