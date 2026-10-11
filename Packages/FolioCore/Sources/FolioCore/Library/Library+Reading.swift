import Foundation
import GRDB

extension Library {
    // MARK: Notes (NOTE-01…05)

    public func note(for itemId: String) throws -> String {
        try writer.read { try Note.fetchOne($0, key: itemId)?.content } ?? ""
    }

    /// Saves the note; an empty (whitespace-only) note is removed.
    public func setNote(_ content: String, for itemId: String) throws {
        try writer.write { db in
            guard try Item.exists(db, key: itemId) else { throw LibraryError.notFound }
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try Note.deleteOne(db, key: itemId)
            } else if try Note.fetchOne(db, key: itemId)?.content != content {
                try Note(itemId: itemId, content: content).save(db)
            }
        }
    }

    // MARK: Reading positions (READER-06)

    public func readingState(fileId: String) throws -> ReadingState? {
        try writer.read { try ReadingState.fetchOne($0, key: fileId) }
    }

    public func saveReadingState(_ state: ReadingState) throws {
        try writer.write { db in
            guard try FileRecord.exists(db, key: state.fileId) else { return }
            try state.save(db)
        }
    }

    // MARK: Translations (TRANS-05)

    /// Copies a translation produced for `sourceFileId` into the library. It joins the source's item,
    /// or becomes a standalone file of its own when the source is a standalone file.
    @discardableResult
    public func addTranslatedFile(at url: URL, of sourceFileId: String, kind: TranslationKind,
                                  baseName: String) throws -> FileRecord {
        guard let source = try writer.read({ try FileRecord.fetchOne($0, key: sourceFileId) }),
              let owner = try item(source.itemId) else { throw LibraryError.notFound }
        let hash = try FileHasher.sha256(of: url)
        let relative = try store.copyIn(url, baseName: FileNamer.sanitize(baseName), ext: url.pathExtension)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: store.url(for: relative).path)
            let now = Date()
            return try writer.write { db in
                var itemId = owner.id
                if owner.kind == .standalone {
                    var item = Item(kind: .standalone, title: (relative as NSString).lastPathComponent, dateAdded: now)
                    item.metadataState = .none
                    try item.insert(db)
                    try db.execute(sql: "INSERT OR IGNORE INTO itemGroup (itemId, groupId, dateAdded) SELECT ?, groupId, ? FROM itemGroup WHERE itemId = ?",
                                   arguments: [item.id, now, owner.id])
                    itemId = item.id
                }
                var file = FileRecord(itemId: itemId, relativePath: relative, originalName: (relative as NSString).lastPathComponent,
                                      size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, sha256: hash,
                                      modifiedAt: attributes[.modificationDate] as? Date ?? now, dateAdded: now)
                file.translationOf = sourceFileId
                file.translationKind = kind
                try file.insert(db)
                if var item = try Item.fetchOne(db, key: itemId), item.defaultFileId == nil {
                    item.defaultFileId = file.id
                    try item.update(db)
                }
                return file
            }
        } catch {
            store.delete(relative)
            throw error
        }
    }
}
