import FolioCore
import Foundation

/// arXiv API (`export.arxiv.org/api/query`): lookup by ID and title search, Atom responses.
struct ArxivClient: Sendable {
    let transport: Transport

    static let accept = "application/atom+xml"

    func lookup(id: String) async throws(SourceError) -> Metadata? {
        guard let url = URL.make("https://export.arxiv.org/api/query", query: [("id_list", id), ("max_results", "1")]) else {
            throw .rejected(status: 0)
        }
        guard let data = try await transport.get(url, accept: Self.accept) else { return nil }
        return try Self.decode(data).first
    }

    func search(title: String, maxResults: Int = 5) async throws(SourceError) -> [Metadata] {
        guard let query = Self.searchQuery(for: title),
              let url = URL.make("https://export.arxiv.org/api/query", query: [
                  ("search_query", query), ("max_results", String(maxResults)),
              ])
        else { return [] }
        guard let data = try await transport.get(url, accept: Self.accept) else { return [] }
        return try Self.decode(data)
    }

    private static func decode(_ data: Data) throws(SourceError) -> [Metadata] {
        do {
            return try parse(data)
        } catch {
            throw .malformed
        }
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> [Metadata] {
        try ArxivFeedParser.parse(data).compactMap(metadata(from:))
    }

    static func metadata(from entry: ArxivFeedParser.Entry) -> Metadata? {
        // Invalid IDs come back as an entry pointing at /api/errors.
        guard !entry.id.contains("/api/errors"), let id = arxivID(fromEntryID: entry.id),
              let title = FieldNormalizer.cleanTitle(entry.title), title != "Error"
        else { return nil }
        var metadata = Metadata(title: title)
        metadata.type = .preprint
        metadata.authors = entry.authors.compactMap(NameParser.author(fromDisplayName:))
        if let parsed = FieldNormalizer.date(fromString: entry.published) {
            metadata.year = parsed.year
            metadata.date = parsed.date
        }
        metadata.source = "arXiv"
        metadata.publisher = "arXiv"
        metadata.doi = "10.48550/arxiv.\(id.lowercased())"
        metadata.arxivId = id
        metadata.url = "https://arxiv.org/abs/\(id)"
        metadata.abstract = FieldNormalizer.cleanAbstract(entry.summary)
        return metadata
    }

    /// "http://arxiv.org/abs/2405.02717v1" -> "2405.02717"; "…/abs/hep-th/9901001v2" -> "hep-th/9901001".
    static func arxivID(fromEntryID raw: String) -> String? {
        guard let range = raw.range(of: "/abs/") else { return nil }
        var id = String(raw[range.upperBound...])
        if let version = id.range(of: #"v\d+$"#, options: .regularExpression) {
            id.removeSubrange(version)
        }
        return id.isEmpty ? nil : id
    }

    private static let stopwords: Set<String> = [
        "a", "an", "the", "of", "for", "and", "or", "in", "on", "with", "to", "via", "by", "from", "at", "is",
        "are", "as", "its", "into", "towards", "toward", "we", "our", "not", "but", "be", "this", "that",
    ]

    /// `ti:w1 AND ti:w2 …` over distinctive title words. Words mixing letters and digits are skipped
    /// because arXiv tokenises them differently ("MSA$^2$Net").
    static func searchQuery(for title: String) -> String? {
        var seen = Set<String>()
        let words = TextMatcher.tokens(title).filter { word in
            word.count >= 3 && word.allSatisfy(\.isLetter) && !stopwords.contains(word) && seen.insert(word).inserted
        }
        guard words.count >= 2 else { return nil }
        return words.prefix(8).map { "ti:\($0)" }.joined(separator: " AND ")
    }
}
