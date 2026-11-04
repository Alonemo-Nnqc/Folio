import FolioCore
import Foundation

/// DBLP publication search (`/search/publ/api?format=json`). Strong for CS conference papers.
struct DBLPClient: Sendable {
    let transport: Transport

    func search(title: String, hits: Int = 5) async throws(SourceError) -> [Metadata] {
        // DBLP matches words as prefixes; punctuation only hurts.
        let query = TitleNormalizer.normalize(title)
        guard !query.isEmpty, let url = URL.make("https://dblp.org/search/publ/api", query: [
            ("q", query), ("format", "json"), ("h", String(hits)),
        ]) else { return [] }
        guard let response = try await transport.getJSON(Response.self, from: url) else { return [] }
        return Self.results(response)
    }

    static func parse(_ data: Data) throws -> [Metadata] {
        results(try JSONDecoder().decode(Response.self, from: data))
    }

    private static func results(_ response: Response) -> [Metadata] {
        (response.result.hits.hit ?? []).compactMap { metadata(from: $0.info) }
    }

    static func metadata(from info: Info) -> Metadata? {
        guard let title = FieldNormalizer.cleanTitle(info.title, dropTrailingPeriod: true) else { return nil }
        var metadata = Metadata(title: title)
        let venue = FieldNormalizer.cleanText(info.venue?.value)
        metadata.authors = (info.authors?.author.values ?? []).compactMap {
            $0.text.flatMap(NameParser.author(fromDisplayName:))
        }
        if let year = info.year?.value.flatMap({ Int($0) }) {
            metadata.year = year
            metadata.date = String(year)
        }
        metadata.volume = FieldNormalizer.cleanText(info.volume?.value)
        metadata.issue = FieldNormalizer.cleanText(info.number?.value)
        metadata.pages = FieldNormalizer.normalizePages(info.pages?.value)
        metadata.doi = FieldNormalizer.normalizeDOI(info.doi)
        metadata.url = FieldNormalizer.nonEmpty(info.ee?.value) ?? FieldNormalizer.nonEmpty(info.url)
        metadata.source = venue

        switch info.type {
        case "Journal Articles": metadata.type = .journalArticle
        case "Conference and Workshop Papers": metadata.type = .conferencePaper
        case "Books and Theses": metadata.type = .book
        case "Parts in Books or Collections": metadata.type = .bookChapter
        case "Data and Artifacts": metadata.type = .dataset
        case "Informal and Other Publications", "Informal Publications": metadata.type = .preprint
        default: metadata.type = .other
        }
        if venue == "CoRR" {
            // arXiv preprints: volume is "abs/2405.02717".
            metadata.type = .preprint
            metadata.source = "arXiv"
            let fromVolume = metadata.volume.map { $0.replacingOccurrences(of: "abs/", with: "") }
            metadata.arxivId = [fromVolume, metadata.doi.flatMap(IdentifierExtractor.arxivID(fromDOI:))]
                .compactMap { $0 }
                .first { !IdentifierExtractor.arxivIDs(in: $0, requireContext: false).isEmpty || $0.contains("/") }
            metadata.volume = nil
            if let arxiv = metadata.arxivId, metadata.doi == nil {
                metadata.doi = "10.48550/arxiv.\(arxiv.lowercased())"
            }
        }
        return metadata
    }

    // MARK: - Wire format

    struct Response: Decodable {
        struct Result: Decodable {
            struct Hits: Decodable {
                var hit: [Hit]?
            }
            var hits: Hits
        }
        var result: Result
    }

    struct Hit: Decodable {
        var info: Info
    }

    struct Person: Decodable, Sendable {
        var text: String?
    }

    struct Authors: Decodable {
        var author: OneOrMany<Person>
    }

    struct Info: Decodable {
        var authors: Authors?
        var title: String?
        var venue: LenientString?
        var volume: LenientString?
        var number: LenientString?
        var pages: LenientString?
        var year: LenientString?
        var type: String?
        var doi: String?
        var ee: LenientString?
        var url: String?
    }
}
