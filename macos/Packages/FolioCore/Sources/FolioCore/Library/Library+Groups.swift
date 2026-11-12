import Foundation
import GRDB

public struct MembershipResult: Sendable, Equatable {
    public var added: [String] = []
    public var alreadyPresent: [String] = []
}

extension Library {
    // MARK: Groups (SIDE-05/06/08/09/12)

    @discardableResult
    public func createGroup(name: String, parentId: String? = nil) throws -> LibraryGroup {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LibraryError.emptyName }
        return try writer.write { db in
            if let parentId {
                guard try LibraryGroup.exists(db, key: parentId) else { throw LibraryError.notFound }
                guard try Self.depth(of: parentId, db) < LibraryGroup.maximumDepth else { throw LibraryError.groupDepthExceeded }
            }
            let siblings = try Self.siblings(of: parentId, db)
            try Self.ensureUniqueName(clean, among: siblings, excluding: nil)
            let group = LibraryGroup(parentId: parentId, name: clean,
                                     position: (siblings.map(\.position).max() ?? -1) + 1)
            try group.insert(db)
            return group
        }
    }

    public func renameGroup(_ id: String, to name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LibraryError.emptyName }
        try writer.write { db in
            guard var group = try LibraryGroup.fetchOne(db, key: id) else { throw LibraryError.notFound }
            try Self.ensureUniqueName(clean, among: try Self.siblings(of: group.parentId, db), excluding: id)
            group.name = clean
            try group.update(db)
        }
    }

    /// Sets the group's icon colour; nil restores the default (accent) colour.
    public func setGroupColor(_ id: String, colorHex: String?) throws {
        try writer.write { db in
            guard var group = try LibraryGroup.fetchOne(db, key: id) else { throw LibraryError.notFound }
            group.colorHex = colorHex
            try group.update(db)
        }
    }

    /// Deletes the group and all its descendants. Items stay in the library unless `trashItems` is true.
    public func deleteGroup(_ id: String, trashItems: Bool) throws {
        try writer.write { db in
            let ids = [id] + (try Self.descendantIds(of: id, db))
            if trashItems {
                try db.execute(sql: """
                    UPDATE item SET trashedAt = ? WHERE trashedAt IS NULL AND id IN
                      (SELECT itemId FROM itemGroup WHERE groupId IN (\(ids.map { _ in "?" }.joined(separator: ","))))
                    """, arguments: StatementArguments([Date()] + ids))
            }
            try db.execute(sql: "DELETE FROM itemOrder WHERE scope IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                           arguments: StatementArguments(ids.map { ViewScope.group($0).key }))
            // Subgroups go with it (ON DELETE CASCADE); deleting them explicitly keeps this independent of that.
            _ = try LibraryGroup.deleteAll(db, keys: ids)
        }
    }

    /// Whether `id` may become a child of `parentId` (nil = top level): not inside itself or one of its descendants,
    /// and with its subtree no deeper than `LibraryGroup.maximumDepth` levels.
    public func canMoveGroup(_ id: String, toParent parentId: String?) throws -> Bool {
        try writer.read { try Self.canMove(id, toParent: parentId, $0) }
    }

    /// Moves a group under `parentId` (nil = top level) at `index` among its new siblings.
    public func moveGroup(_ id: String, toParent parentId: String?, index: Int) throws {
        try writer.write { db in
            guard try Self.canMove(id, toParent: parentId, db) else { throw LibraryError.groupDepthExceeded }
            guard var group = try LibraryGroup.fetchOne(db, key: id) else { throw LibraryError.notFound }
            var siblings = try Self.siblings(of: parentId, db).filter { $0.id != id }
            if group.parentId != parentId {
                try Self.ensureUniqueName(group.name, among: siblings, excluding: id)
            }
            group.parentId = parentId
            siblings.insert(group, at: min(max(index, 0), siblings.count))
            for (position, var sibling) in siblings.enumerated() {
                sibling.position = Double(position)
                try sibling.update(db)
            }
        }
    }

    // MARK: Membership (DUP-05, TRASH-02)

    /// Adds items to a group. Items already visible in the group (directly, or through a subgroup when
    /// `includeSubgroups`) are reported as already present.
    @discardableResult
    public func addItems(_ itemIds: [String], toGroup groupId: String, includeSubgroups: Bool) throws -> MembershipResult {
        try writer.write { db in
            guard try LibraryGroup.exists(db, key: groupId) else { throw LibraryError.notFound }
            let present = Set(try Self.memberIds(ofGroup: groupId, includeSubgroups: includeSubgroups, db))
            var result = MembershipResult()
            for id in itemIds {
                if present.contains(id) {
                    result.alreadyPresent.append(id)
                } else {
                    try ItemGroup(itemId: id, groupId: groupId, dateAdded: Date()).insert(db, onConflict: .ignore)
                    result.added.append(id)
                }
            }
            return result
        }
    }

    public func removeItems(_ itemIds: [String], fromGroup groupId: String, includeSubgroups: Bool) throws {
        try writer.write { db in
            var groups = [groupId]
            if includeSubgroups {
                groups += try Self.descendantIds(of: groupId, db)
            }
            try ItemGroup
                .filter(itemIds.contains(Column("itemId")) && groups.contains(Column("groupId")))
                .deleteAll(db)
        }
    }

    // MARK: Helpers

    static func siblings(of parentId: String?, _ db: Database) throws -> [LibraryGroup] {
        try LibraryGroup.filter(Column("parentId") == parentId).order(Column("position")).fetchAll(db)
    }

    static func ensureUniqueName(_ name: String, among groups: [LibraryGroup], excluding id: String?) throws {
        let clash = groups.contains { $0.id != id && $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
        if clash { throw LibraryError.duplicateGroupName(name) }
    }

    static func canMove(_ id: String, toParent parentId: String?, _ db: Database) throws -> Bool {
        guard try LibraryGroup.exists(db, key: id) else { return false }
        guard let parentId else { return true }
        guard parentId != id, try LibraryGroup.exists(db, key: parentId),
              !(try descendantIds(of: id, db).contains(parentId)) else { return false }
        return try depth(of: parentId, db) + subtreeHeight(of: id, db) <= LibraryGroup.maximumDepth
    }

    /// Ids of every group below `id` (not `id` itself). `UNION` stops on a (corrupt) cycle.
    static func descendantIds(of id: String, _ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            WITH RECURSIVE sub(id) AS (
              SELECT id FROM libraryGroup WHERE parentId = ?
              UNION SELECT g.id FROM libraryGroup g JOIN sub ON g.parentId = sub.id)
            SELECT id FROM sub WHERE id <> ?
            """, arguments: [id, id])
    }

    /// The group's level: 1 for a top-level group.
    static func depth(of id: String, _ db: Database) throws -> Int {
        var depth = 1
        var seen: Set<String> = [id]
        var current = try String.fetchOne(db, sql: "SELECT parentId FROM libraryGroup WHERE id = ?", arguments: [id])
        while let parent = current, seen.insert(parent).inserted {
            depth += 1
            current = try String.fetchOne(db, sql: "SELECT parentId FROM libraryGroup WHERE id = ?", arguments: [parent])
        }
        return depth
    }

    /// Levels spanned by the group and its subtree: 1 without subgroups.
    static func subtreeHeight(of id: String, _ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            WITH RECURSIVE sub(id, level) AS (
              SELECT ?, 1
              UNION SELECT g.id, sub.level + 1 FROM libraryGroup g JOIN sub ON g.parentId = sub.id WHERE sub.level < 64)
            SELECT MAX(level) FROM sub
            """, arguments: [id]) ?? 1
    }

    static func memberIds(ofGroup groupId: String, includeSubgroups: Bool, _ db: Database) throws -> [String] {
        if includeSubgroups {
            let groups = [groupId] + (try descendantIds(of: groupId, db))
            return try String.fetchAll(db, sql: """
                SELECT DISTINCT itemId FROM itemGroup WHERE groupId IN (\(groups.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments(groups))
        }
        return try String.fetchAll(db, sql: "SELECT itemId FROM itemGroup WHERE groupId = ?", arguments: [groupId])
    }
}
