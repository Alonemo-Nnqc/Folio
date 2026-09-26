import Foundation

/// Metadata search (SEARCH-02): every token must appear somewhere in the item's text.
public enum SearchMatcher {
    public static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func matches(tokens: [String], haystack: String) -> Bool {
        tokens.allSatisfy { haystack.contains($0) }
    }

    static func haystack(for item: Item, tags: [Tag], files: [FileRecord]) -> String {
        var parts: [String] = [item.title]
        parts += item.authors.map { "\($0.given) \($0.family)" }
        parts += [item.source, item.year.map(String.init), item.doi, item.arxivId, item.isbn,
                  item.abstract, item.citationKey, item.publisher].compactMap { $0 }
        parts += tags.map(\.name)
        parts += files.flatMap { [$0.fileName, $0.originalName] }
        return parts.joined(separator: "\n").lowercased()
    }
}
