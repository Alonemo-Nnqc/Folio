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
    /// easyScholar ranks per journal (`JournalMetrics.key(for:)`), including journals it does not list (META-30).
    public var journalMetrics: [String: JournalMetrics] = [:]

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

    // MARK: Group hierarchy (SIDE-17)

    /// The group followed by all its descendants, depth first in display order.
    public func groupAndDescendants(_ groupId: String) -> [String] {
        [groupId] + groupDescendants(groupId)
    }

    /// All descendants of a group (not the group itself), depth first in display order.
    public func groupDescendants(_ groupId: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = [groupId]
        func visit(_ id: String) {
            for child in childGroups[id] ?? [] where seen.insert(child).inserted {
                result.append(child)
                visit(child)
            }
        }
        visit(groupId)
        return result
    }

    /// Ancestor ids from the top level down, not including the group itself.
    public func groupAncestors(_ groupId: String) -> [String] {
        var chain: [String] = []
        var seen: Set<String> = [groupId]
        var current = groupsById[groupId]?.parentId
        while let id = current, seen.insert(id).inserted, let group = groupsById[id] {
            chain.insert(id, at: 0)
            current = group.parentId
        }
        return chain
    }

    /// The group's level: 1 for a top-level group.
    public func groupDepth(_ groupId: String) -> Int {
        groupAncestors(groupId).count + 1
    }

    /// How many levels the group and its subtree span: 1 for a group without subgroups.
    public func groupSubtreeHeight(_ groupId: String) -> Int {
        var seen: Set<String> = [groupId]
        func height(_ id: String) -> Int {
            1 + (childGroups[id] ?? []).filter { seen.insert($0).inserted }.map(height).reduce(0, max)
        }
        return height(groupId)
    }

    /// Names from the top-level ancestor down to the group, e.g. ["课题", "文献", "综述"].
    public func groupPath(_ groupId: String) -> [String] {
        (groupAncestors(groupId) + [groupId]).compactMap { groupsById[$0]?.name }
    }

    /// Whether a new subgroup may be created inside the group.
    public func canAddSubgroup(to groupId: String) -> Bool {
        groupsById[groupId] != nil && groupDepth(groupId) < LibraryGroup.maximumDepth
    }

    /// Whether `groupId` (with its subtree) may move under `parentId` (nil = top level): not into itself or
    /// one of its descendants, and no deeper than `LibraryGroup.maximumDepth` levels.
    public func canMoveGroup(_ groupId: String, toParent parentId: String?) -> Bool {
        guard groupsById[groupId] != nil else { return false }
        guard let parentId else { return true }
        guard parentId != groupId, groupsById[parentId] != nil, !groupAncestors(parentId).contains(groupId) else { return false }
        return groupDepth(parentId) + groupSubtreeHeight(groupId) <= LibraryGroup.maximumDepth
    }

    /// Every group in sidebar order, each followed by its subgroups; `depth` is 0 for top-level groups.
    public var groupsInOrder: [(group: LibraryGroup, depth: Int)] {
        var result: [(group: LibraryGroup, depth: Int)] = []
        var seen: Set<String> = []
        func visit(_ ids: [String], depth: Int) {
            for id in ids where seen.insert(id).inserted {
                guard let group = groupsById[id] else { continue }
                result.append((group, depth))
                visit(childGroups[id] ?? [], depth: depth + 1)
            }
        }
        visit(topLevelGroups, depth: 0)
        return result
    }

    /// The cached ranks of an item's journal, if it has a journal and they were fetched.
    public func journalMetrics(for item: Item) -> JournalMetrics? {
        guard let name = JournalMetrics.journalName(of: item) else { return nil }
        return journalMetrics[JournalMetrics.key(for: name)]
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
        for record in try JournalMetricsRecord.fetchAll(db) {
            s.journalMetrics[record.name] = record.metrics
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
