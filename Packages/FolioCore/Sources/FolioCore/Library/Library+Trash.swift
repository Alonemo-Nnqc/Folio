import Foundation
import GRDB

extension Library {
    // MARK: Trash (TRASH-01…08)

    /// Moves items to the trash. Group memberships are kept so restore can return them (TRASH-05).
    public func trashItems(_ itemIds: [String]) throws {
        try writer.write { db in
            try Item.filter(itemIds.contains(Column("id")) && Column("trashedAt") == nil)
                .updateAll(db, Column("trashedAt").set(to: Date()))
        }
    }

    /// Trashes individual files. A file of a regular item is detached into its own trashed standalone
    /// item that remembers where it came from (TRASH-03); the default file moves on (FILE-05).
    public func trashFiles(_ fileIds: [String]) throws {
        try writer.write { db in
            let now = Date()
            for fileId in fileIds {
                guard var file = try FileRecord.fetchOne(db, key: fileId),
                      var parent = try Item.fetchOne(db, key: file.itemId), !parent.isTrashed else { continue }
                if parent.kind == .standalone {
                    parent.trashedAt = now
                    try parent.update(db)
                    continue
                }
                var detached = Item(kind: .standalone, title: file.fileName, dateAdded: file.dateAdded)
                detached.originItemId = parent.id
                detached.trashedAt = now
                detached.defaultFileId = file.id
                try detached.insert(db)
                file.itemId = detached.id
                try file.update(db)
                if parent.defaultFileId == fileId {
                    parent.defaultFileId = try Self.files(ofItem: parent.id, db).first?.id
                    try parent.update(db)
                }
            }
        }
    }

    /// Restores trashed items to their groups; detached files go back to their item when possible.
    public func restoreItems(_ itemIds: [String]) throws {
        try writer.write { db in
            for id in itemIds {
                guard var item = try Item.fetchOne(db, key: id), item.isTrashed else { continue }
                if let originId = item.originItemId, var origin = try Item.fetchOne(db, key: originId), !origin.isTrashed {
                    let files = try Self.files(ofItem: id, db)
                    for var file in files {
                        file.itemId = originId
                        try file.update(db)
                    }
                    if origin.defaultFileId == nil {
                        origin.defaultFileId = files.first?.id
                        try origin.update(db)
                    }
                    _ = try Item.deleteOne(db, key: id)
                } else {
                    item.trashedAt = nil
                    item.originItemId = nil
                    try item.update(db)
                }
            }
        }
    }

    /// Permanently deletes items, their stored files and index entries (TRASH-08).
    public func purgeItems(_ itemIds: [String]) throws {
        guard !itemIds.isEmpty else { return }
        let paths = try writer.write { db -> [String] in
            let files = try FileRecord.filter(itemIds.contains(Column("itemId"))).fetchAll(db)
            try Self.deleteFulltext(fileIds: files.map(\.id), db)
            try Item.filter(itemIds.contains(Column("originItemId"))).updateAll(db, Column("originItemId").set(to: nil))
            try Item.filter(itemIds.contains(Column("id"))).deleteAll(db)
            return files.map(\.relativePath)
        }
        paths.forEach(store.delete)
    }

    public func emptyTrash() throws {
        let ids = try writer.read { try String.fetchAll($0, sql: "SELECT id FROM item WHERE trashedAt IS NOT NULL") }
        try purgeItems(ids)
    }

    /// Permanently deletes trash entries older than `date` (TRASH-07).
    public func purgeTrash(olderThan date: Date) throws {
        let ids = try writer.read {
            try String.fetchAll($0, sql: "SELECT id FROM item WHERE trashedAt IS NOT NULL AND trashedAt < ?", arguments: [date])
        }
        try purgeItems(ids)
    }
}
