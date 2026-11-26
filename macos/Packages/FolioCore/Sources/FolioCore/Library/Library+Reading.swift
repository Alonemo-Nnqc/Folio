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

    /// When each item was last read in Folio's reader (the newest reading position of its files).
    public func lastReadDates() throws -> [String: Date] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT file.itemId AS itemId, MAX(readingState.dateModified) AS date
                FROM readingState JOIN file ON file.id = readingState.fileId GROUP BY file.itemId
                """)
            var dates: [String: Date] = [:]
            for row in rows {
                if let id: String = row["itemId"], let date: Date = row["date"] { dates[id] = date }
            }
            return dates
        }
    }

    /// How far each item has been read: the page reached in the file of it read furthest; `lastRead` is of the one read last.
    /// Items never opened in the reader are not in it.
    public func readingProgress() throws -> [String: ReadingProgress] {
        try writer.read { db in
            var result: [String: ReadingProgress] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT file.itemId AS itemId, file.id AS fileId, readingState.pageIndex AS pageIndex, readingState.pageCount AS pageCount,
                       readingState.seenPages AS seenPages, readingState.dateModified AS date
                FROM readingState JOIN file ON file.id = readingState.fileId ORDER BY readingState.dateModified
                """)
            for row in rows {
                guard let id: String = row["itemId"], let file: String = row["fileId"], let date: Date = row["date"], let page: Int = row["pageIndex"] else { continue }
                let count: Int? = row["pageCount"]
                let reached = count.flatMap { SeenPages(count: $0, saved: row["seenPages"], through: page).reached }
                var progress = ReadingProgress(pageIndex: reached ?? 0, pageCount: reached == nil ? nil : count, fileId: file, lastRead: date)
                if let other = result[id], other.fraction > progress.fraction {
                    progress.pageIndex = other.pageIndex
                    progress.pageCount = other.pageCount
                    progress.fileId = other.fileId
                }
                result[id] = progress
            }
            return result
        }
    }

    /// Files last read by a version before 1.6: how many pages they have was not noted.
    public func filesWithoutPageCount() throws -> [String] {
        try writer.read { try String.fetchAll($0, sql: "SELECT fileId FROM readingState WHERE pageCount IS NULL") }
    }

    /// Notes it: the pages up to where the file was left count as read. The date it was read stays.
    public func setPageCount(_ count: Int, ofFileLastReadBefore16 fileId: String) throws {
        try writer.write { db in
            guard var state = try ReadingState.fetchOne(db, key: fileId), state.pageCount == nil else { return }
            state.pageCount = count
            state.seenPages = state.seenPages ?? SeenPages(count: count, through: state.pageIndex).stored
            try state.update(db)
        }
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
                                  baseName: String, translatedBy: String? = nil) throws -> FileRecord {
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
                file.translatedBy = translatedBy
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
