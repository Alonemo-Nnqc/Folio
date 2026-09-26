import FolioCore
import Foundation

/// Open Library: `/isbn/{isbn}.json` for the edition, then one request per author
/// (taken from the edition, or from its work when the edition lists none).
struct OpenLibraryClient: Sendable {
    let transport: Transport

    static let maxAuthors = 6

    func lookup(isbn: String) async throws(SourceError) -> Metadata? {
        guard let url = URL(string: "https://openlibrary.org/isbn/\(isbn).json") else { throw .rejected(status: 0) }
        guard let edition = try await transport.getJSON(Edition.self, from: url) else { return nil }
        guard var metadata = Self.metadata(from: edition, isbn: isbn) else { return nil }

        var authorKeys = edition.authors?.compactMap(\.key) ?? []
        if authorKeys.isEmpty, let workKey = edition.works?.first?.key,
           let workURL = URL(string: "https://openlibrary.org\(workKey).json"),
           let work = try? await transport.getJSON(Work.self, from: workURL) {
            authorKeys = work.authors?.compactMap { $0.author?.key } ?? []
        }
        metadata.authors = await authors(for: Array(authorKeys.prefix(Self.maxAuthors)))
        return metadata
    }

    /// Author records are secondary: failures just drop that author.
    private func authors(for keys: [String]) async -> [Author] {
        await withTaskGroup(of: (Int, Author?).self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask {
                    guard let url = URL(string: "https://openlibrary.org\(key).json"),
                          let record = try? await transport.getJSON(AuthorRecord.self, from: url),
                          let name = record.name ?? record.personalName
                    else { return (index, nil) }
                    return (index, NameParser.author(fromDisplayName: name))
                }
            }
            var named: [(Int, Author)] = []
            for await (index, author) in group {
                if let author { named.append((index, author)) }
            }
            return named.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: - Parsing

    static func parseEdition(_ data: Data, isbn: String) throws -> Metadata? {
        metadata(from: try JSONDecoder().decode(Edition.self, from: data), isbn: isbn)
    }

    static func parseAuthor(_ data: Data) throws -> Author? {
        let record = try JSONDecoder().decode(AuthorRecord.self, from: data)
        return (record.name ?? record.personalName).flatMap(NameParser.author(fromDisplayName:))
    }

    static func parseWorkAuthorKeys(_ data: Data) throws -> [String] {
        try JSONDecoder().decode(Work.self, from: data).authors?.compactMap { $0.author?.key } ?? []
    }

    static func metadata(from edition: Edition, isbn: String) -> Metadata? {
        guard var title = FieldNormalizer.cleanTitle(edition.title) else { return nil }
        if let subtitle = FieldNormalizer.cleanTitle(edition.subtitle) {
            title += ": " + subtitle
        }
        var metadata = Metadata(title: title)
        metadata.type = .book
        if let parsed = FieldNormalizer.date(fromString: edition.publishDate) {
            metadata.year = parsed.year
            metadata.date = parsed.date
        }
        metadata.publisher = FieldNormalizer.cleanText(edition.publishers?.first)
        metadata.source = metadata.publisher
        metadata.isbn = edition.isbn13?.first ?? edition.isbn10?.first ?? isbn
        metadata.url = edition.key.map { "https://openlibrary.org\($0)" }
        return metadata
    }

    // MARK: - Wire format

    struct Reference: Decodable {
        var key: String?
    }

    struct Edition: Decodable {
        var title: String?
        var subtitle: String?
        var publishers: [String]?
        var publishDate: String?
        var authors: [Reference]?
        var works: [Reference]?
        var isbn10: [String]?
        var isbn13: [String]?
        var key: String?

        private enum CodingKeys: String, CodingKey {
            case title, subtitle, publishers, authors, works, key
            case publishDate = "publish_date", isbn10 = "isbn_10", isbn13 = "isbn_13"
        }
    }

    struct Work: Decodable {
        struct Role: Decodable {
            var author: Reference?
        }
        var authors: [Role]?
    }

    struct AuthorRecord: Decodable {
        var name: String?
        var personalName: String?

        private enum CodingKeys: String, CodingKey {
            case name, personalName = "personal_name"
        }
    }
}
