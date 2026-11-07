import Foundation
import FolioCore

/// Maps a raw Zotero `itemTypes.typeName` to Folio's `ItemType` (spec Task 2C field table).
enum ZoteroItemTypeMapping {
    static func map(_ zoteroTypeName: String) -> ItemType {
        switch zoteroTypeName {
        case "journalArticle": return .journalArticle
        case "conferencePaper": return .conferencePaper
        case "preprint": return .preprint
        case "book": return .book
        case "bookSection": return .bookChapter
        case "thesis": return .thesis
        case "report": return .report
        case "webpage": return .webpage
        case "dataset": return .dataset
        default: return .other
        }
    }
}

/// Field-level mapping rules that don't need a whole item's context.
enum ZoteroFieldMapping {
    /// `source` fallback chain: journal / proceedings / book / conference / repository /
    /// website / university / institution, and finally the publisher — but only for books.
    private static let sourceFallback = [
        "publicationTitle", "proceedingsTitle", "bookTitle", "conferenceName",
        "repository", "websiteTitle", "university", "institution",
    ]

    static func source(fields: [String: String], type: ItemType) -> String? {
        for name in sourceFallback {
            if let value = fields[name] { return value }
        }
        if type == .book, let publisher = fields["publisher"] { return publisher }
        return nil
    }

    /// Lowercases and strips a `doi.org` resolver prefix, per `Metadata.doi`'s contract.
    static func doi(from raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        var value = trimmed
        for prefix in ["https://doi.org/", "http://doi.org/", "doi:"] {
            if value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        return value.lowercased()
    }

    /// Looks for an arXiv id in `archiveID` (e.g. `"arXiv:2412.08345"`), then `extra`
    /// (e.g. `"arXiv:2412.08345 [cs]"`), then `url`
    /// (e.g. `"https://arxiv.org/abs/2412.08345v2"`) — in that order — and strips any
    /// version suffix, per `Metadata.arxivId`'s contract.
    static func arxivID(archiveID: String?, extra: String?, url: String?) -> String? {
        for candidate in [archiveID, extra, url] {
            if let candidate, let id = firstArxivID(in: candidate) { return id }
        }
        return nil
    }

    private static let newFormat = try! NSRegularExpression(pattern: #"\d{4}\.\d{4,5}(v\d+)?"#)
    private static let oldFormat = try! NSRegularExpression(pattern: #"[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?"#)

    private static func firstArxivID(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let match = newFormat.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
            return stripVersion(String(text[r]))
        }
        if let match = oldFormat.firstMatch(in: text, range: range), let r = Range(match.range, in: text) {
            return stripVersion(String(text[r]))
        }
        return nil
    }

    private static func stripVersion(_ id: String) -> String {
        guard let vRange = id.range(of: #"v\d+$"#, options: .regularExpression) else { return id }
        return String(id[..<vRange.lowerBound])
    }
}
