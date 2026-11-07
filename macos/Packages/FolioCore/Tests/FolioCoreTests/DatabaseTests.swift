import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct DatabaseTests {
    @Test func roundTripsItemWithAuthors() throws {
        let db = try AppDatabase.makeTemporary()
        var item = Item(kind: .regular, title: "UNet++")
        item.authors = [Author(family: "Zhou", given: "Zongwei")]
        item.year = 2018
        try db.writer.write { try item.insert($0) }
        let loaded = try db.writer.read { try Item.fetchOne($0, key: item.id) }
        #expect(loaded?.authors == item.authors)
        #expect(loaded?.year == 2018)
        #expect(loaded?.readStatus == .unread)
    }

    @Test func deletingItemCascadesToRelations() throws {
        let db = try AppDatabase.makeTemporary()
        let item = Item(kind: .regular, title: "A")
        let group = LibraryGroup(name: "G", position: 0)
        let tag = Tag(name: "T", colorHex: "#FF0000", position: 0)
        let file = FileRecord(itemId: item.id, relativePath: "Files/a.pdf", originalName: "a.pdf",
                              size: 1, sha256: "x", modifiedAt: Date())
        try db.writer.write { db in
            try item.insert(db)
            try group.insert(db)
            try tag.insert(db)
            try file.insert(db)
            try ItemGroup(itemId: item.id, groupId: group.id, dateAdded: Date()).insert(db)
            try ItemTag(itemId: item.id, tagId: tag.id).insert(db)
            try ItemOrder(scope: "all", itemId: item.id, position: 0).insert(db)
            _ = try Item.deleteOne(db, key: item.id)
        }
        let counts = try db.writer.read { db in
            [try FileRecord.fetchCount(db), try ItemGroup.fetchCount(db), try ItemTag.fetchCount(db),
             try ItemOrder.fetchCount(db), try LibraryGroup.fetchCount(db)]
        }
        #expect(counts == [0, 0, 0, 0, 1])
    }

    @Test func tagNamesAreUniqueCaseInsensitively() throws {
        let db = try AppDatabase.makeTemporary()
        try db.writer.write { try Tag(name: "Mamba", colorHex: "#000000", position: 0).insert($0) }
        #expect(throws: DatabaseError.self) {
            try db.writer.write { try Tag(name: "mamba", colorHex: "#000000", position: 1).insert($0) }
        }
    }

    @Test func opensOnDiskWithWAL() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "folio-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.open(at: dir.appending(path: "Folio.sqlite"))
        let mode = try db.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }
}

@Suite struct RelocationTests {
    /// STORE-01: a closed library folder can be moved and reopened with all data and files.
    @Test func closeMoveAndReopen() throws {
        let base = try Fixture.directory()
        let original = base.appending(path: "Folio")
        var library: Library? = try Library(root: original)
        let id = try library!.importItem("Moving Paper")
        try library!.close()
        library = nil
        let moved = base.appending(path: "Elsewhere/Folio")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        let reopened = try Library(root: moved)
        let file = try #require(try reopened.files(ofItem: id).first)
        #expect(try reopened.item(id)?.title == "Moving Paper")
        #expect(FileManager.default.fileExists(atPath: reopened.fileURL(for: file).path))
    }
}
