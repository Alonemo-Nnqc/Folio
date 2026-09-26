import Foundation

/// A row from `items`, scoped to the user library.
struct RawItem {
    let itemID: Int64
    let itemTypeID: Int64
    let dateAdded: Date
    let dateModified: Date
}

/// A row from `itemAttachments` joined with its own `items` row (for `key`/`dateAdded`).
struct RawAttachment {
    let itemID: Int64
    let key: String
    let parentItemID: Int64?
    let linkMode: Int
    let path: String?
    let contentType: String?
    let dateAdded: Date
    let dateModified: Date
}

/// A row from `itemCreators` (already filtered to the "author" creator type) joined with
/// `creators`.
struct RawCreator {
    let orderIndex: Int
    let firstName: String?
    let lastName: String?
    let fieldMode: Int
}

/// A row from `collections`.
struct RawCollection {
    let id: Int64
    let key: String
    let name: String
    let parentID: Int64?
}

/// Everything read out of the copied database in one pass, before any Zotero-specific rules
/// (flattening, skip reasons, field fallbacks, …) are applied.
struct RawZoteroLibrary {
    var libraryID: Int64
    var itemTypeNameByID: [Int64: String] = [:]
    var items: [RawItem] = []
    var deletedItemIDs: Set<Int64> = []
    var fieldsByItem: [Int64: [String: String]] = [:]
    var creatorsByItem: [Int64: [RawCreator]] = [:]
    /// Attachments whose `parentItemID` is non-nil, keyed by that parent.
    var attachmentsByParent: [Int64: [RawAttachment]] = [:]
    /// Attachments with no parent — independent (standalone) files.
    var standaloneAttachments: [RawAttachment] = []
    var collections: [RawCollection] = []
    /// collectionID -> member item ids (`collectionItems`).
    var itemIDsByCollection: [Int64: [Int64]] = [:]
    /// itemID -> (tag name, `itemTags.type`) pairs.
    var tagNamesByItem: [Int64: [(name: String, type: Int)]] = [:]
    /// Distinct tag names seen with `type == 1` anywhere in the library.
    var automaticTagNames: Set<String> = []
    /// Lowercased tag name -> `"#RRGGBB"`, from the `tagColors` synced setting.
    var tagColors: [String: String] = [:]
}
