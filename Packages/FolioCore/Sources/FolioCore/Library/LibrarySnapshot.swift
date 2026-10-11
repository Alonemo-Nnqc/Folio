import Foundation
import GRDB

/// An immutable, fully-loaded view of the library, rebuilt whenever the database changes.
public struct LibrarySnapshot: Sendable, Equatable {
    public var items: [String: Item] = [:]
    public var files: [String: FileRecord] = [:]
    /// File ids per item, oldest first.
    public var filesByItem: [String: [String]] = [:]
    public var groupsById: [String: LibraryGroup] = [:]
    /// Top-level group ids in display order.
    public var topLevelGroups: [String] = []
    /// Child group ids per parent, in display order.
    public var childGroups: [String: [String]] = [:]
    /// Direct members per group.
    public var groupItems: [String: Set<String>] = [:]
    public var itemGroups: [String: Set<String>] = [:]
    /// Tags in display order.
    public var tags: [Tag] = []
    public var tagsById: [String: Tag] = [:]
    /// Tag ids per item, in tag display order.
    public var itemTags: [String: [String]] = [:]
    public var tagItems: [String: Set<String>] = [:]
    /// Custom order positions: scope key → item id → position.
    public var orders: [String: [String: Double]] = [:]
    public var sorts: [String: SortState] = [:]
    /// Items that have a note (NOTE-03).
    public var notedItems: Set<String> = []
    /// Lowercased text each item is searched against.
    public var searchText: [String: String] = [:]

    public init() {}

    public static let empty = LibrarySnapshot()

    public func sort(for scope: ViewScope) -> SortState {
        sorts[scope.key] ?? .manual
    }

    public func files(of itemId: String) -> [FileRecord] {
        (filesByItem[itemId] ?? []).compactMap { files[$0] }
    }

    public func tags(of itemId: String) -> [Tag] {
        (itemTags[itemId] ?? []).compactMap { tagsById[$0] }
    }

    /// Descendant ids including the group itself.
    public func groupAndChildren(_ groupId: String) -> [String] {
        [groupId] + (childGroups[groupId] ?? [])
    }

    static func fetch(_ db: Database) throws -> LibrarySnapshot {
        var s = LibrarySnapshot()
        for item in try Item.fetchAll(db) { s.items[item.id] = item }
        for file in try FileRecord.order(Column("dateAdded"), Column("id")).fetchAll(db) {
            s.files[file.id] = file
            s.filesByItem[file.itemId, default: []].append(file.id)
        }
        let groups = try LibraryGroup.order(Column("position"), Column("name")).fetchAll(db)
        for group in groups {
            s.groupsById[group.id] = group
            if let parent = group.parentId {
                s.childGroups[parent, default: []].append(group.id)
            } else {
                s.topLevelGroups.append(group.id)
            }
        }
        for link in try ItemGroup.fetchAll(db) {
            s.groupItems[link.groupId, default: []].insert(link.itemId)
            s.itemGroups[link.itemId, default: []].insert(link.groupId)
        }
        s.tags = try Tag.order(Column("position"), Column("name")).fetchAll(db)
        var tagRank: [String: Int] = [:]
        for (rank, tag) in s.tags.enumerated() {
            s.tagsById[tag.id] = tag
            tagRank[tag.id] = rank
        }
        for link in try ItemTag.fetchAll(db) {
            s.itemTags[link.itemId, default: []].append(link.tagId)
            s.tagItems[link.tagId, default: []].insert(link.itemId)
        }
        for key in s.itemTags.keys {
            s.itemTags[key]!.sort { (tagRank[$0] ?? 0) < (tagRank[$1] ?? 0) }
        }
        for order in try ItemOrder.fetchAll(db) {
            s.orders[order.scope, default: [:]][order.itemId] = order.position
        }
        for sort in try ViewSortRecord.fetchAll(db) {
            s.sorts[sort.scope] = SortState(column: sort.sortColumn, ascending: sort.ascending)
        }
        var notes: [String: String] = [:]
        for note in try Note.fetchAll(db) {
            notes[note.itemId] = note.content
            s.notedItems.insert(note.itemId)
        }
        for item in s.items.values {
            s.searchText[item.id] = SearchMatcher.haystack(for: item, tags: s.tags(of: item.id), files: s.files(of: item.id),
                                                           note: notes[item.id])
        }
        return s
    }
}

extension Library {
    public func snapshot() throws -> LibrarySnapshot {
        try writer.read { try LibrarySnapshot.fetch($0) }
    }

    /// Emits a fresh snapshot now and after every committed change.
    public func observeSnapshots() -> AsyncValueObservation<LibrarySnapshot> {
        ValueObservation
            .tracking { try LibrarySnapshot.fetch($0) }
            .removeDuplicates()
            .values(in: writer)
    }
}
