import Foundation

// Intermediate format for bulk imports (e.g. from Zotero). Importers produce these values;
// `Library.importPrepared(_:progress:)` turns them into library records.

public struct PreparedGroup: Sendable, Hashable {
    /// Unique key on the source side (e.g. a Zotero collection key).
    public var key: String
    public var name: String
    /// Must already be flattened to two levels: the parent itself has no parent.
    public var parentKey: String?
    public var position: Double

    public init(key: String, name: String, parentKey: String? = nil, position: Double) {
        self.key = key
        self.name = name
        self.parentKey = parentKey
        self.position = position
    }
}

public struct PreparedTag: Sendable, Hashable {
    public var name: String
    /// "#RRGGBB"
    public var colorHex: String

    public init(name: String, colorHex: String) {
        self.name = name
        self.colorHex = colorHex
    }
}

public struct PreparedFile: Sendable, Hashable {
    /// Copied into the Folio library during import; never modified.
    public var sourceURL: URL
    public var originalName: String
    public var dateAdded: Date

    public init(sourceURL: URL, originalName: String, dateAdded: Date) {
        self.sourceURL = sourceURL
        self.originalName = originalName
        self.dateAdded = dateAdded
    }
}

public struct PreparedEntry: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case regular(Metadata)
        case standalone
    }

    public var kind: Kind
    /// The first file becomes the default file.
    public var files: [PreparedFile]
    public var groupKeys: [String]
    public var tagNames: [String]
    public var dateAdded: Date
    public var dateModified: Date

    public init(kind: Kind, files: [PreparedFile], groupKeys: [String] = [], tagNames: [String] = [],
                dateAdded: Date, dateModified: Date) {
        self.kind = kind
        self.files = files
        self.groupKeys = groupKeys
        self.tagNames = tagNames
        self.dateAdded = dateAdded
        self.dateModified = dateModified
    }
}

public struct PreparedLibrary: Sendable {
    public var groups: [PreparedGroup]
    public var tags: [PreparedTag]
    public var entries: [PreparedEntry]

    public init(groups: [PreparedGroup] = [], tags: [PreparedTag] = [], entries: [PreparedEntry] = []) {
        self.groups = groups
        self.tags = tags
        self.entries = entries
    }
}

public struct BulkImportSummary: Sendable, Equatable {
    public var itemsImported = 0
    public var filesImported = 0
    public var groupsCreated = 0
    public var tagsCreated = 0
    public var duplicatesSkipped = 0
    public var missingFiles = 0

    public init() {}
}
