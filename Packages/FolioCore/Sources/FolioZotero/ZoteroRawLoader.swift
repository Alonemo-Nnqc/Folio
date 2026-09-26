import Foundation
import GRDB

/// Reads every table `ZoteroLibraryBuilder` needs, scoped to the `user` library, out of an
/// already-open (read-only) database connection.
enum ZoteroRawLoader {
    static func load(from db: Database) throws -> RawZoteroLibrary {
        guard let libraryID = try Int64.fetchOne(db, sql: "SELECT libraryID FROM libraries WHERE type = 'user' LIMIT 1") else {
            throw ZoteroReaderError.userLibraryNotFound
        }

        var raw = RawZoteroLibrary(libraryID: libraryID)

        for row in try Row.fetchAll(db, sql: "SELECT itemTypeID, typeName FROM itemTypes") {
            let id: Int64 = row["itemTypeID"]
            let name: String = row["typeName"]
            raw.itemTypeNameByID[id] = name
        }

        for row in try Row.fetchAll(db, sql: "SELECT itemID FROM deletedItems") {
            raw.deletedItemIDs.insert(row["itemID"])
        }

        raw.items = try Row.fetchAll(db, sql: """
            SELECT itemID, itemTypeID, dateAdded, dateModified FROM items WHERE libraryID = ?
            """, arguments: [libraryID]).map { row in
            RawItem(
                itemID: row["itemID"],
                itemTypeID: row["itemTypeID"],
                dateAdded: ZoteroDate.parseTimestamp(row["dateAdded"]),
                dateModified: ZoteroDate.parseTimestamp(row["dateModified"])
            )
        }

        for row in try Row.fetchAll(db, sql: """
            SELECT id.itemID as itemID, f.fieldName as fieldName, v.value as value
            FROM itemData id
            JOIN fields f ON f.fieldID = id.fieldID
            JOIN itemDataValues v ON v.valueID = id.valueID
            JOIN items i ON i.itemID = id.itemID
            WHERE i.libraryID = ?
            """, arguments: [libraryID]) {
            let itemID: Int64 = row["itemID"]
            let name: String = row["fieldName"]
            let value = (row["value"] as String?) ?? ""
            guard !value.isEmpty else { continue }
            raw.fieldsByItem[itemID, default: [:]][name] = value
        }

        let authorTypeID = try Int64.fetchOne(db, sql: "SELECT creatorTypeID FROM creatorTypes WHERE creatorType = 'author'")
        if let authorTypeID {
            for row in try Row.fetchAll(db, sql: """
                SELECT ic.itemID as itemID, ic.orderIndex as orderIndex,
                       c.firstName as firstName, c.lastName as lastName, c.fieldMode as fieldMode
                FROM itemCreators ic
                JOIN creators c ON c.creatorID = ic.creatorID
                JOIN items i ON i.itemID = ic.itemID
                WHERE i.libraryID = ? AND ic.creatorTypeID = ?
                """, arguments: [libraryID, authorTypeID]) {
                let itemID: Int64 = row["itemID"]
                raw.creatorsByItem[itemID, default: []].append(RawCreator(
                    orderIndex: row["orderIndex"] ?? 0,
                    firstName: row["firstName"],
                    lastName: row["lastName"],
                    fieldMode: (row["fieldMode"] as Int?) ?? 0
                ))
            }
        }

        for row in try Row.fetchAll(db, sql: """
            SELECT ia.itemID as itemID, i.key as key, ia.parentItemID as parentItemID,
                   ia.linkMode as linkMode, ia.path as path, i.dateAdded as dateAdded, i.dateModified as dateModified
            FROM itemAttachments ia
            JOIN items i ON i.itemID = ia.itemID
            WHERE i.libraryID = ?
            """, arguments: [libraryID]) {
            let attachment = RawAttachment(
                itemID: row["itemID"],
                key: row["key"],
                parentItemID: row["parentItemID"],
                linkMode: (row["linkMode"] as Int?) ?? 0,
                path: row["path"],
                dateAdded: ZoteroDate.parseTimestamp(row["dateAdded"]),
                dateModified: ZoteroDate.parseTimestamp(row["dateModified"])
            )
            if let parentItemID = attachment.parentItemID {
                raw.attachmentsByParent[parentItemID, default: []].append(attachment)
            } else {
                raw.standaloneAttachments.append(attachment)
            }
        }

        raw.collections = try Row.fetchAll(db, sql: """
            SELECT collectionID, key, collectionName, parentCollectionID FROM collections WHERE libraryID = ?
            """, arguments: [libraryID]).map { row in
            RawCollection(
                id: row["collectionID"],
                key: row["key"],
                name: row["collectionName"],
                parentID: row["parentCollectionID"]
            )
        }

        for row in try Row.fetchAll(db, sql: """
            SELECT ci.collectionID as collectionID, ci.itemID as itemID
            FROM collectionItems ci
            JOIN collections c ON c.collectionID = ci.collectionID
            WHERE c.libraryID = ?
            """, arguments: [libraryID]) {
            raw.itemIDsByCollection[row["collectionID"], default: []].append(row["itemID"])
        }

        for row in try Row.fetchAll(db, sql: """
            SELECT it.itemID as itemID, t.name as name, it.type as type
            FROM itemTags it
            JOIN tags t ON t.tagID = it.tagID
            JOIN items i ON i.itemID = it.itemID
            WHERE i.libraryID = ?
            """, arguments: [libraryID]) {
            let itemID: Int64 = row["itemID"]
            let name: String = row["name"]
            let type: Int = row["type"]
            raw.tagNamesByItem[itemID, default: []].append((name: name, type: type))
            if type == 1 { raw.automaticTagNames.insert(name) }
        }

        if let value = try String.fetchOne(db, sql: """
            SELECT value FROM syncedSettings WHERE setting = 'tagColors' AND libraryID = ?
            """, arguments: [libraryID]) {
            raw.tagColors = ZoteroTagColorParsing.parse(value)
        }

        return raw
    }
}
