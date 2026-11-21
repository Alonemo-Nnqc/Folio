import Foundation
import GRDB

public enum ItemKind: Int, Codable, Sendable {
    /// A work with metadata; owns zero or more files.
    case regular = 0
    /// A top-level file that has no metadata (retrieval failed or was never attempted).
    case standalone = 1
}

public enum ReadStatus: Int, Codable, Sendable, CaseIterable {
    case unread = 0, reading = 1, read = 2

    public var displayName: String {
        switch self {
        case .unread: String(localized: "未读", bundle: .module)
        case .reading: String(localized: "在读", bundle: .module)
        case .read: String(localized: "已读", bundle: .module)
        }
    }
}

public enum MetadataState: Int, Codable, Sendable {
    case none = 0, pending = 1, failed = 2, networkFailed = 3, resolved = 4
}

/// A top-level row in the library: either a regular item or a standalone file.
public struct Item: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item"

    public var id: String
    public var kind: ItemKind
    public var type: ItemType
    public var title: String
    public var authors: [Author]
    public var year: Int?
    public var date: String?
    public var source: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var publisher: String?
    public var doi: String?
    public var arxivId: String?
    public var isbn: String?
    public var url: String?
    public var abstract: String?
    public var place: String?
    public var edition: String?
    public var editors: [Author]
    public var translators: [Author]
    public var series: String?
    public var genre: String?
    public var citationKey: String?
    public var rating: Int
    public var readStatus: ReadStatus
    public var defaultFileId: String?
    public var metadataState: MetadataState
    public var retryCount: Int
    /// For a file deleted on its own: the item it belonged to, so restore can put it back.
    public var originItemId: String?
    public var dateAdded: Date
    public var dateModified: Date
    public var trashedAt: Date?

    public init(id: String = UUID().uuidString, kind: ItemKind, title: String, dateAdded: Date = Date()) {
        self.id = id
        self.kind = kind
        self.type = kind == .standalone ? .other : .journalArticle
        self.title = title
        self.authors = []
        self.editors = []
        self.translators = []
        self.rating = 0
        self.readStatus = .unread
        self.metadataState = .none
        self.retryCount = 0
        self.dateAdded = dateAdded
        self.dateModified = dateAdded
    }

    public var isTrashed: Bool { trashedAt != nil }

    public var metadata: Metadata {
        get {
            var m = Metadata(title: title)
            m.type = type; m.authors = authors; m.year = year; m.date = date; m.source = source
            m.volume = volume; m.issue = issue; m.pages = pages; m.publisher = publisher
            m.doi = doi; m.arxivId = arxivId; m.isbn = isbn; m.url = url; m.abstract = abstract
            m.place = place; m.edition = edition; m.editors = editors; m.translators = translators; m.series = series; m.genre = genre
            return m
        }
        set {
            type = newValue.type; title = newValue.title; authors = newValue.authors; year = newValue.year
            date = newValue.date; source = newValue.source; volume = newValue.volume; issue = newValue.issue
            pages = newValue.pages; publisher = newValue.publisher; doi = newValue.doi?.lowercased()
            arxivId = newValue.arxivId; isbn = newValue.isbn; url = newValue.url; abstract = newValue.abstract
            place = newValue.place; edition = newValue.edition; editors = newValue.editors; translators = newValue.translators
            series = newValue.series; genre = newValue.genre
        }
    }
}
