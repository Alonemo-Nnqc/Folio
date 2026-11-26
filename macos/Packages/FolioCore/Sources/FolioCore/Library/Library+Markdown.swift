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
        // Unnamed documents are told apart by a number: the first that no other document in the list has.
        let name = Self.isUnnamed(title) ? try writer.read { Self.free(title, among: try Self.documentTitles($0)) } : title
        let relative = try writeNewFile(baseName: FileNamer.sanitize(name), text: body)
        let now = Date()
        var item = Item(kind: .standalone, title: name, dateAdded: now)
        item.metadataState = .none
        let file = try record(for: relative, name: name, itemId: item.id, text: body, date: now)
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
        let name = Self.free(title, among: Set(try files(ofItem: itemId).filter(\.isMarkdown).map { $0.documentName.lowercased() }))
        let relative = try writeNewFile(baseName: FileNamer.sanitize(name), text: body)
        let file = try record(for: relative, name: name, itemId: itemId, text: body, date: Date())
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

    /// Saves a text file's new contents: the file on disk, its size, date and hash, the search index, and the name of a
    /// document nobody has named, from what it starts with.
    public func writeText(_ text: String, toFile fileId: String) throws {
        guard var file = try writer.read({ try FileRecord.fetchOne($0, key: fileId) }) else { throw LibraryError.notFound }
        var url = store.url(for: file.relativePath)
        let before = (try? Data(contentsOf: url)).flatMap { Self.name(from: String(decoding: $0, as: UTF8.self))?.name }
        let data = Data(text.utf8)
        try data.write(to: url, options: .atomic)
        let now = Date()
        file.size = Int64(data.count)
        file.modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? now
        file.sha256 = (try? FileHasher.sha256(of: url)) ?? file.sha256
        // A document nobody has named is called after its first heading, or its first line; a name given by hand stays.
        var title: String?
        let path = file.relativePath, named = file.originalName
        if file.isMarkdown, let found = Self.name(from: text), let item = try item(file.itemId) {
            let own = item.kind == .standalone && item.defaultFileId == file.id
            let current = own ? item.title : file.documentName
            if Self.isUnnamed(current) || current == before {
                if own, found.name != current { title = found.name }
                // The file follows once the line is written, not letter by letter.
                let base = FileNamer.sanitize(found.name)
                if found.isFinished, !base.isEmpty, own || found.name != current, base != file.documentName || named != base + ".md" {
                    if base != file.documentName, let renamed = try? store.rename(file.relativePath, toBaseName: base) {
                        file.relativePath = renamed
                        url = store.url(for: renamed)
                    }
                    file.originalName = base + ".md"
                }
            }
        }
        do { try writer.write { db in
            try file.update(db)
            try Self.indexText(text, fileId: file.id, db)
            if var item = try Item.fetchOne(db, key: file.itemId) {
                if let title { item.title = title }
                item.dateModified = now
                try item.update(db)
            }
        } } catch {
            if file.relativePath != path { try? FileManager.default.moveItem(at: url, to: store.url(for: path)) }
            throw error
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
        file.originalName = base + "." + (renamed as NSString).pathExtension
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

    /// "未命名文档", "Untitled Document 2": what Folio calls a new document.
    public static func isUnnamed(_ title: String) -> Bool {
        title.range(of: #"^(未命名文档|Untitled( Document)?)( \d+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    public static func withoutMarkdownExtension(_ name: String) -> String {
        ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) ? (name as NSString).deletingPathExtension : name
    }

    /// `title`, or the first of "title 2", "title 3"… that is not taken (`taken` in lower case).
    static func free(_ title: String, among taken: Set<String>) -> String {
        guard taken.contains(title.lowercased()) else { return title }
        var number = 2
        while taken.contains("\(title) \(number)".lowercased()) { number += 1 }
        return "\(title) \(number)"
    }

    /// The names of the documents that are items of their own (those in the trash aside).
    static func documentTitles(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT title FROM item WHERE kind = ? AND trashedAt IS NULL", arguments: [ItemKind.standalone.rawValue])
            .map { withoutMarkdownExtension($0).lowercased() })
    }

    /// What a document nobody has named is called: its first heading, else the first line it has. `isFinished`: more comes
    /// after that line, or it is a heading.
    public static func name(from text: String) -> (name: String, isFinished: Bool)? {
        if let heading = firstHeading(of: text) { return (heading, true) }
        var lines = text.components(separatedBy: "\n")[...]
        // Front matter says things about the document; it is not its text.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = lines[(end + 1)...]
        }
        var fence: String?
        for (index, line) in zip(lines.indices, lines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence { if trimmed.hasPrefix(open) { fence = nil }; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence = String(trimmed.prefix(3)); continue }
            let plain = plainText(ofLine: trimmed)
            guard plain.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            return (shortened(plain), index < lines.endIndex - 1)
        }
        return nil
    }

    /// A line without its marks: of a list, a quote, a task, emphasis, links and pictures.
    static func plainText(ofLine line: String) -> String {
        var text = line.replacingOccurrences(of: #"^(\s*(>|[-*+]\s|\d{1,9}[.)]\s|\[[ xX]\]\s))+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_~=`]{1,3}|<[^>]+>"#, with: "", options: .regularExpression)
        if text.hasPrefix("|") { text = text.replacingOccurrences(of: "|", with: " ") }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The first sentence of a long line, or as much as a name holds.
    private static func shortened(_ text: String) -> String {
        if text.count <= 40 { return text }
        if let end = text.firstIndex(where: { "。！？；!?;".contains($0) }), (4...40).contains(text.distance(from: text.startIndex, to: end)) { return String(text[..<end]) }
        let head = String(text.prefix(40))
        // Not in the middle of a Latin word.
        if let space = head.lastIndex(of: " "), head.distance(from: space, to: head.endIndex) < 16, text[text.index(text.startIndex, offsetBy: 40)].isASCII { return String(head[..<space]) }
        return head
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

    private func record(for relative: String, name: String, itemId: String, text: String, date: Date) throws -> FileRecord {
        let url = store.url(for: relative)
        var file = FileRecord(itemId: itemId, relativePath: relative, originalName: FileNamer.sanitize(name) + ".md",
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
