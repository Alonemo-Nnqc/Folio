import Foundation
import GRDB

extension Library {
    // MARK: Tags (TAG-01…07)

    @discardableResult
    public func createTag(name: String, colorHex: String) throws -> Tag {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LibraryError.emptyName }
        return try writer.write { db in
            try Self.ensureUniqueTagName(clean, excluding: nil, db)
            let maxPosition = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM tag") ?? -1
            let tag = Tag(name: clean, colorHex: colorHex, position: maxPosition + 1)
            try tag.insert(db)
            return tag
        }
    }

    public func updateTag(_ id: String, name: String, colorHex: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw LibraryError.emptyName }
        try writer.write { db in
            guard var tag = try Tag.fetchOne(db, key: id) else { throw LibraryError.notFound }
            try Self.ensureUniqueTagName(clean, excluding: id, db)
            tag.name = clean
            tag.colorHex = colorHex
            try tag.update(db)
        }
    }

    public func deleteTag(_ id: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM itemOrder WHERE scope = ?", arguments: [ViewScope.tag(id).key])
            _ = try Tag.deleteOne(db, key: id)
        }
    }

    public func setTag(_ tagId: String, onItems itemIds: [String], enabled: Bool) throws {
        try writer.write { db in
            if enabled {
                for id in itemIds {
                    try ItemTag(itemId: id, tagId: tagId).insert(db, onConflict: .ignore)
                }
            } else {
                try ItemTag.filter(Column("tagId") == tagId && itemIds.contains(Column("itemId"))).deleteAll(db)
            }
        }
    }

    /// Number of items carrying the tag (shown in the delete confirmation, TAG-04).
    public func itemCount(withTag tagId: String) throws -> Int {
        try writer.read { try ItemTag.filter(Column("tagId") == tagId).fetchCount($0) }
    }

    static func ensureUniqueTagName(_ name: String, excluding id: String?, _ db: Database) throws {
        let clash = try String.fetchOne(db, sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE", arguments: [name])
        if let clash, clash != id { throw LibraryError.duplicateTagName(name) }
    }
}
