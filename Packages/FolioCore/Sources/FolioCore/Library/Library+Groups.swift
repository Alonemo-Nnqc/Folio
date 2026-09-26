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
                guard let parent = try LibraryGroup.fetchOne(db, key: parentId) else { throw LibraryError.notFound }
                guard parent.parentId == nil else { throw LibraryError.groupDepthExceeded }
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

    /// Deletes the group and its subgroups. Items stay in the library unless `trashItems` is true.
    public func deleteGroup(_ id: String, trashItems: Bool) throws {
        try writer.write { db in
            let ids = [id] + (try String.fetchAll(db, sql: "SELECT id FROM libraryGroup WHERE parentId = ?", arguments: [id]))
            if trashItems {
                try db.execute(sql: """
                    UPDATE item SET trashedAt = ? WHERE trashedAt IS NULL AND id IN
                      (SELECT itemId FROM itemGroup WHERE groupId IN (\(ids.map { _ in "?" }.joined(separator: ","))))
                    """, arguments: StatementArguments([Date()] + ids))
            }
            try db.execute(sql: "DELETE FROM itemOrder WHERE scope IN (\(ids.map { _ in "?" }.joined(separator: ",")))",
                           arguments: StatementArguments(ids.map { ViewScope.group($0).key }))
            _ = try LibraryGroup.deleteOne(db, key: id)
        }
    }

    /// Whether `id` may become a child of `parentId` (nil = top level) without exceeding two levels.
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
                groups += try String.fetchAll(db, sql: "SELECT id FROM libraryGroup WHERE parentId = ?", arguments: [groupId])
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
        guard parentId != id, let parent = try LibraryGroup.fetchOne(db, key: parentId), parent.parentId == nil else {
            return false
        }
        let hasChildren = try LibraryGroup.filter(Column("parentId") == id).fetchCount(db) > 0
        return !hasChildren
    }

    static func memberIds(ofGroup groupId: String, includeSubgroups: Bool, _ db: Database) throws -> [String] {
        if includeSubgroups {
            return try String.fetchAll(db, sql: """
                SELECT itemId FROM itemGroup
                WHERE groupId = ? OR groupId IN (SELECT id FROM libraryGroup WHERE parentId = ?)
                """, arguments: [groupId, groupId])
        }
        return try String.fetchAll(db, sql: "SELECT itemId FROM itemGroup WHERE groupId = ?", arguments: [groupId])
    }
}
