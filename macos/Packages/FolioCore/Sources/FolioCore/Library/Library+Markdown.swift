import Foundation
import GRDB

/// Markdown documents kept in the library (MD-01): written in Folio, as an item of their own or attached to a paper,
/// stored as `.md` files in `Files/` like any other file, so they stay readable and editable outside Folio.
extension Library {
    /// A new Markdown document as an item of its own (in `groupId` when given). Returns its item and file ids.
    @discardableResult
    public func createMarkdownDocument(title: String, inGroup groupId: String? = nil, text: String? = nil) throws -> (itemId: String, fileId: String) {
        // A new document starts empty: the title only names the file (and the item, until the first heading does).
        let body = text ?? ""
        let relative = try writeNewFile(baseName: FileNamer.sanitize(title), text: body)
        let now = Date()
        var item = Item(kind: .standalone, title: title, dateAdded: now)
        item.metadataState = .none
        let file = try record(for: relative, itemId: item.id, text: body, date: now)
        item.defaultFileId = file.id
        do {
            try writer.write { db in
                try item.insert(db)
                try file.insert(db)
                if let groupId { try ItemGroup(itemId: item.id, groupId: groupId, dateAdded: now).insert(db) }
                try Self.indexText(body, fileId: file.id, db)
            }
        } catch {
            store.delete(relative)
            throw error
        }
        return (item.id, file.id)
    }

    /// A new Markdown document attached to an item (a paper's reading notes, a summary). Returns the file id.
    @discardableResult
    public func createMarkdownAttachment(title: String, toItem itemId: String, text: String? = nil) throws -> String {
        guard try self.item(itemId) != nil else { throw LibraryError.notFound }
        let body = text ?? ""
        let relative = try writeNewFile(baseName: FileNamer.sanitize(title), text: body)
        let file = try record(for: relative, itemId: itemId, text: body, date: Date())
        do {
            try writer.write { db in
                try file.insert(db)
                if var owner = try Item.fetchOne(db, key: itemId), owner.defaultFileId == nil {
                    owner.defaultFileId = file.id
                    try owner.update(db)
                }
                try Self.indexText(body, fileId: file.id, db)
            }
        } catch {
            store.delete(relative)
            throw error
        }
        return file.id
    }

    /// The text of a text file in the library ("" when it cannot be read).
    public func text(ofFile fileId: String) throws -> String {
        guard let file = try writer.read({ try FileRecord.fetchOne($0, key: fileId) }) else { throw LibraryError.notFound }
        let url = store.url(for: file.relativePath)
        guard let data = try? Data(contentsOf: url) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Saves a text file's new contents: the file on disk, its size, date and hash, the search index, and — for a
    /// document that is an item of its own — the item's title from its first heading.
    public func writeText(_ text: String, toFile fileId: String) throws {
        guard var file = try writer.read({ try FileRecord.fetchOne($0, key: fileId) }) else { throw LibraryError.notFound }
        let url = store.url(for: file.relativePath)
        let data = Data(text.utf8)
        try data.write(to: url, options: .atomic)
        let now = Date()
        file.size = Int64(data.count)
        file.modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
        file.sha256 = (try? FileHasher.sha256(of: url)) ?? file.sha256
        let heading = Self.firstHeading(of: text)
        try writer.write { db in
            try file.update(db)
            try Self.indexText(text, fileId: file.id, db)
            if var item = try Item.fetchOne(db, key: file.itemId) {
                if item.kind == .standalone, item.defaultFileId == file.id, let heading, heading != item.title {
                    item.title = heading
                }
                item.dateModified = now
                try item.update(db)
            }
        }
    }

    /// Renames a Markdown file to `name.md` (a number added if taken); a document that is an item of its own takes the
    /// name as its title too. Returns the file as renamed.
    @discardableResult
    public func renameMarkdownFile(_ fileId: String, to name: String) throws -> FileRecord {
        guard var file = try writer.read({ try FileRecord.fetchOne($0, key: fileId) }) else { throw LibraryError.notFound }
        let base = FileNamer.sanitize(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !base.isEmpty else { return file }
        let renamed = try store.rename(file.relativePath, toBaseName: base)
        file.relativePath = renamed
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try writer.write { db in
            try file.update(db)
            if var item = try Item.fetchOne(db, key: file.itemId), item.kind == .standalone, item.defaultFileId == file.id {
                item.title = title
                item.dateModified = Date()
                try item.update(db)
            }
        }
        return file
    }

    /// The text of the document's first `#` heading.
    public static func firstHeading(of text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return String(title.prefix(200)) }
        }
        return nil
    }

    // MARK: Helpers

    private func writeNewFile(baseName: String, text: String) throws -> String {
        try store.prepare()
        let relative = store.uniqueRelativePath(baseName: baseName.isEmpty ? "Untitled" : baseName, ext: "md", ignoring: nil)
        try Data(text.utf8).write(to: store.url(for: relative), options: .atomic)
        return relative
    }

    private func record(for relative: String, itemId: String, text: String, date: Date) throws -> FileRecord {
        let url = store.url(for: relative)
        var file = FileRecord(itemId: itemId, relativePath: relative, originalName: (relative as NSString).lastPathComponent,
                              size: Int64(Data(text.utf8).count), sha256: try FileHasher.sha256(of: url),
                              modifiedAt: date, dateAdded: date, fulltextState: .indexed)
        // Two empty documents have the same contents: the hash an import compares against stays unique.
        file.originalSha256 = "md-" + file.id
        return file
    }

    static func indexText(_ text: String, fileId: String, _ db: Database) throws {
        try deleteFulltext(fileIds: [fileId], db)
        guard !text.isEmpty else { return }
        try db.execute(sql: "INSERT INTO fulltext (fileId, content) VALUES (?, ?)", arguments: [fileId, text])
    }
}
