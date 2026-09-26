import FolioCore
import Foundation

/// OpenAlex `/works` title search. Abstracts are rebuilt from `abstract_inverted_index`.
struct OpenAlexClient: Sendable {
    let transport: Transport
    let mailto: String?

    static let selectFields = "id,doi,title,display_name,publication_year,publication_date,type,type_crossref,"
        + "authorships,primary_location,biblio,abstract_inverted_index"

    /// Uses the `title.search` filter rather than full-text `search`: it only matches titles,
    /// which is both more precise and much cheaper for the service.
    func search(title: String, perPage: Int = 5) async throws(SourceError) -> [Metadata] {
        // Commas separate filters and colons introduce values in OpenAlex filter syntax.
        let query = TitleNormalizer.normalize(title)
        guard !query.isEmpty, let url = URL.make("https://api.openalex.org/works", query: [
            ("filter", "title.search:\(query)"), ("per-page", String(perPage)), ("select", Self.selectFields),
            ("mailto", mailto),
        ]) else { return [] }
        guard let response = try await transport.getJSON(Response.self, from: url) else { return [] }
        return response.results.compactMap(Self.metadata(from:))
    }

    static func parse(_ data: Data) throws -> [Metadata] {
        try JSONDecoder().decode(Response.self, from: data).results.compactMap(metadata(from:))
    }

    static func metadata(from work: Work) -> Metadata? {
        guard let title = FieldNormalizer.cleanTitle(work.title ?? work.displayName) else { return nil }
        var metadata = Metadata(title: title)
        let sourceType = work.primaryLocation?.source?.type
        metadata.type = itemType(type: work.type, crossrefType: work.typeCrossref, sourceType: sourceType)
        metadata.authors = (work.authorships ?? []).compactMap {
            $0.author?.displayName.flatMap(NameParser.author(fromDisplayName:))
        }
        if let parsed = FieldNormalizer.date(fromString: work.publicationDate) {
            metadata.year = parsed.year
            metadata.date = parsed.date
        } else if let year = work.publicationYear {
            metadata.year = year
            metadata.date = String(year)
        }
        metadata.source = FieldNormalizer.cleanText(work.primaryLocation?.source?.displayName)
        metadata.publisher = FieldNormalizer.cleanText(work.primaryLocation?.source?.hostOrganizationName)
        metadata.volume = FieldNormalizer.cleanText(work.biblio?.volume)
        metadata.issue = FieldNormalizer.cleanText(work.biblio?.issue)
        if let first = FieldNormalizer.cleanText(work.biblio?.firstPage) {
            let last = FieldNormalizer.cleanText(work.biblio?.lastPage)
            metadata.pages = last.map { $0 == first ? first : "\(first)-\($0)" } ?? first
        }
        metadata.doi = FieldNormalizer.normalizeDOI(work.doi)
        if let doi = metadata.doi, let arxiv = IdentifierExtractor.arxivID(fromDOI: doi) {
            metadata.arxivId = arxiv
            metadata.type = .preprint
            metadata.source = "arXiv"
            metadata.publisher = "arXiv"
        }
        metadata.url = metadata.doi.map { "https://doi.org/\($0)" }
            ?? FieldNormalizer.nonEmpty(work.primaryLocation?.landingPageURL)
        metadata.abstract = work.abstractInvertedIndex.flatMap(rebuildAbstract)
        return metadata
    }

    static func itemType(type: String?, crossrefType: String?, sourceType: String?) -> ItemType {
        let mapped = CrossrefClient.itemType(forCrossrefType: crossrefType)
        if mapped != .other { return mapped }
        switch type {
        case "article", "review", "letter", "editorial", "erratum":
            return sourceType == "conference" ? .conferencePaper : .journalArticle
        case "preprint": return .preprint
        case "book": return .book
        case "book-chapter": return .bookChapter
        case "dissertation": return .thesis
        case "report": return .report
        case "dataset": return .dataset
        default: return .other
        }
    }

    /// `{"Deep": [0], "learning": [1]}` -> "Deep learning".
    static func rebuildAbstract(_ index: [String: [Int]]) -> String? {
        var positioned: [(Int, String)] = []
        for (word, positions) in index {
            for position in positions { positioned.append((position, word)) }
        }
        guard !positioned.isEmpty, positioned.count < 20_000 else { return nil }
        let text = positioned.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
        return FieldNormalizer.cleanAbstract(text)
    }

    // MARK: - Wire format

    struct Response: Decodable {
        var results: [Work]
    }

    struct Work: Decodable {
        struct Authorship: Decodable {
            struct Person: Decodable {
                var displayName: String?
                private enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            var author: Person?
        }

        struct Location: Decodable {
            struct Source: Decodable {
                var displayName: String?
                var hostOrganizationName: String?
                var type: String?
                private enum CodingKeys: String, CodingKey {
                    case displayName = "display_name", hostOrganizationName = "host_organization_name", type
                }
            }
            var landingPageURL: String?
            var source: Source?
            private enum CodingKeys: String, CodingKey { case landingPageURL = "landing_page_url", source }
        }

        struct Biblio: Decodable {
            var volume: String?
            var issue: String?
            var firstPage: String?
            var lastPage: String?
            private enum CodingKeys: String, CodingKey {
                case volume, issue, firstPage = "first_page", lastPage = "last_page"
            }
        }

        var doi: String?
        var title: String?
        var displayName: String?
        var publicationYear: Int?
        var publicationDate: String?
        var type: String?
        var typeCrossref: String?
        var authorships: [Authorship]?
        var primaryLocation: Location?
        var biblio: Biblio?
        var abstractInvertedIndex: [String: [Int]]?

        private enum CodingKeys: String, CodingKey {
            case doi, title, type, authorships, biblio
            case displayName = "display_name"
            case publicationYear = "publication_year"
            case publicationDate = "publication_date"
            case typeCrossref = "type_crossref"
            case primaryLocation = "primary_location"
            case abstractInvertedIndex = "abstract_inverted_index"
        }
    }
}
