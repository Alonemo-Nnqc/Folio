import Foundation
import GRDB

/// What a package (`.foliolib`) says about itself. A package is a zip file with this as `folio-package.json`; the library in
/// it is its database as `Folio.sqlite` and its files under `Files/`; the settings in it are `folio-settings.json`. macOS and
/// Windows read and write the same.
public struct LibraryPackageInfo: Codable, Sendable, Equatable {
    public static let fileExtension = "foliolib"
    /// What this version writes; packages of a later format are refused.
    public static let currentFormat = 1
    static let entryName = "folio-package.json"
    static let settingsName = "folio-settings.json"

    public var format = Self.currentFormat
    public var app: String
    public var exported: Date
    public var items = 0
    public var files = 0
    public var groups = 0
    public var tags = 0
}

/// A package to be imported: what is in it.
public struct LibraryPackage: Sendable {
    public let url: URL
    public let info: LibraryPackageInfo
    public let hasLibrary: Bool
    /// The settings, as `exportPackage` was given them.
    public let settings: Data?

    public init(url: URL) throws {
        let archive = try ZipReader(url: url)
        guard archive.contains(LibraryPackageInfo.entryName) else { throw ZipError.notAnArchive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let info = try? decoder.decode(LibraryPackageInfo.self, from: archive.data(LibraryPackageInfo.entryName)) else { throw ZipError.notAnArchive }
        guard info.format <= LibraryPackageInfo.currentFormat else {
            throw LibraryError.invalidOperation(String(localized: "这个文件由更新版本的 Folio 导出，请先更新 Folio", bundle: .module))
        }
        self.url = url
        self.info = info
        hasLibrary = archive.contains(Library.databaseFileName)
        settings = archive.contains(LibraryPackageInfo.settingsName) ? try archive.data(LibraryPackageInfo.settingsName) : nil
    }
}

public struct LibraryExportSummary: Sendable, Equatable {
    public var items = 0
    public var files = 0
    /// Files the library knows but does not have any more.
    public var missingFiles = 0
}

public struct LibraryImportSummary: Sendable, Equatable {
    public var itemsAdded = 0
    /// Already in the library, and changed by the package (newer details, a newer or further file).
    public var itemsUpdated = 0
    public var itemsUnchanged = 0
    public var filesAdded = 0
    public var filesUpdated = 0
    public var groupsCreated = 0
    public var tagsCreated = 0
    public var missingFiles = 0
}

extension Library {
    // MARK: Export

    /// Packs the library (all of it but its trash) and/or the settings into one file. `progress`: files packed, of how
    /// many. Stops when the surrounding task is cancelled, and leaves what was at `url` as it was.
    public func exportPackage(to url: URL, includingLibrary: Bool = true, settings: Data? = nil, appVersion: String,
                              progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> LibraryExportSummary {
        let staging = FileManager.default.temporaryDirectory.appending(path: "folio-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let partial = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).partial")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: partial)
        }
        var info = LibraryPackageInfo(app: appVersion, exported: Date())
        var files: [FileRecord] = []
        let copy = staging.appending(path: Self.databaseFileName)
        if includingLibrary { files = try copyDatabase(to: copy, &info) }

        var summary = LibraryExportSummary(items: info.items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let archive = try ZipWriter(url: partial)
        try archive.add(encoder.encode(info), as: LibraryPackageInfo.entryName)
        if let settings { try archive.add(settings, as: LibraryPackageInfo.settingsName) }
        if includingLibrary { try archive.add(contentsOf: copy, as: Self.databaseFileName) { try Task.checkCancellation() } }
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let source = store.url(for: file.relativePath)
            if FileManager.default.fileExists(atPath: source.path) {
                try archive.add(contentsOf: source, as: file.relativePath) { try Task.checkCancellation() }
                summary.files += 1
            } else { summary.missingFiles += 1 }
            progress?(index + 1, files.count)
        }
        try archive.finish()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: url)
        }
        return summary
    }

    /// The database as it is this moment, without the trash, in one file.
    private func copyDatabase(to url: URL, _ info: inout LibraryPackageInfo) throws -> [FileRecord] {
        _ = try refreshFingerprints()
        try writer.writeWithoutTransaction { try $0.execute(sql: "VACUUM INTO ?", arguments: [url.path]) }
        var config = Configuration()
        config.foreignKeysEnabled = true
        let copy = try DatabaseQueue(path: url.path, configuration: config)
        let (files, counts) = try copy.write { db in
            try db.execute(sql: "DELETE FROM fulltext WHERE fileId IN (SELECT file.id FROM file JOIN item ON item.id = file.itemId WHERE item.trashedAt IS NOT NULL)")
            try db.execute(sql: "DELETE FROM item WHERE trashedAt IS NOT NULL")
            return (try FileRecord.fetchAll(db), [try Item.fetchCount(db), try LibraryGroup.fetchCount(db), try Tag.fetchCount(db)])
        }
        // What was deleted is not left in the file's free pages.
        try copy.vacuum()
        try copy.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try copy.close()
        (info.items, info.groups, info.tags, info.files) = (counts[0], counts[1], counts[2], files.count)
        return files
    }

    // MARK: Import

    /// Adds what a package holds to this library. What is here already (the same item, a file with the same contents, or
    /// the same work) is not added again: of its details, note and files the newer stay, its groups and tags come together.
    /// Nothing is taken away; a file replaced by a newer one goes to `discard` (the system's trash).
    /// `progress`: items done, of how many. Stops when the surrounding task is cancelled; importing again goes on.
    public func importPackage(_ package: LibraryPackage, progress: (@Sendable (Int, Int) -> Void)? = nil,
                              discard: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> LibraryImportSummary {
        guard package.hasLibrary else { return LibraryImportSummary() }
        let archive = try ZipReader(url: package.url)
        _ = try refreshFingerprints()
        let staging = FileManager.default.temporaryDirectory.appending(path: "folio-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let copyURL = staging.appending(path: Self.databaseFileName)
        try archive.extract(Self.databaseFileName, to: copyURL)
        // Brought up to this version's tables; what a later version added is left out.
        let source = try AppDatabase.open(at: copyURL)
        defer { try? source.writer.close() }
        var run = PackageImport(library: self, archive: archive, source: source.writer, staging: staging, discard: discard)
        return try run.run(progress)
    }
}

/// One import of a package.
private struct PackageImport {
    let library: Library
    let archive: ZipReader
    let source: any DatabaseWriter
    let staging: URL
    let discard: (URL) throws -> Void

    var summary = LibraryImportSummary()
    /// Ids of the package and what they are here.
    var itemIds: [String: String] = [:]
    var groupIds: [String: String] = [:]
    var tagIds: [String: String] = [:]
    var fileIds: [String: String] = [:]
    /// Files of the package whose contents (and so their text) are in the library now.
    var written: Set<String> = []

    private var writer: any DatabaseWriter { library.writer }

    init(library: Library, archive: ZipReader, source: any DatabaseWriter, staging: URL, discard: @escaping (URL) throws -> Void) {
        self.library = library; self.archive = archive; self.source = source; self.staging = staging; self.discard = discard
    }

    mutating func run(_ progress: (@Sendable (Int, Int) -> Void)?) throws -> LibraryImportSummary {
        let (items, filesOfItem, notes) = try source.read { db in
            (try Item.filter(Column("trashedAt") == nil).order(Column("dateAdded")).fetchAll(db),
             Dictionary(grouping: try FileRecord.order(Column("dateAdded"), Column("id")).fetchAll(db), by: \.itemId),
             Dictionary(uniqueKeysWithValues: try Note.fetchAll(db).map { ($0.itemId, $0) }))
        }
        try importGroups()
        try importTags()
        let matches = try match(items, filesOfItem)
        for item in items { itemIds[item.id] = matches[item.id] ?? item.id }
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            try importItem(item, into: matches[item.id], files: filesOfItem[item.id] ?? [], note: notes[item.id])
            progress?(index + 1, items.count)
        }
        try importFulltext()
        try importTheRest()
        return summary
    }

    // MARK: What is here already

    private func match(_ items: [Item], _ filesOfItem: [String: [FileRecord]]) throws -> [String: String] {
        let (here, hereFiles) = try writer.read { (try Item.fetchAll($0), try FileRecord.fetchAll($0)) }
        let byId = Dictionary(uniqueKeysWithValues: here.map { ($0.id, $0) })
        var owners: [String: String] = [:]
        // Two Markdown documents with the same text are two documents.
        for file in hereFiles where !file.isMarkdown && byId[file.itemId]?.isTrashed == false {
            owners[file.sha256] = file.itemId
            owners[file.originalSha256] = file.itemId
        }
        // Works by what they could be told by; a large library is not compared pair by pair.
        func keys(_ m: Metadata) -> [String] {
            [m.isbn.map { "i" + $0 }, m.doi.map { "d" + $0.lowercased() }, m.arxivId.map { "a" + $0.lowercased() }, "t" + TitleNormalizer.normalize(m.title)]
                .compactMap { $0 }.filter { $0.count > 1 }
        }
        var works: [String: [(String, Metadata)]] = [:]
        for item in here where item.kind == .regular && !item.isTrashed {
            for key in keys(item.metadata) { works[key, default: []].append((item.id, item.metadata)) }
        }
        var result: [String: String] = [:]
        // The same item first: what else might match may be another item of the package.
        for item in items where byId[item.id] != nil { result[item.id] = item.id }
        var taken = Set(result.values)
        for item in items where result[item.id] == nil {
            var found = (filesOfItem[item.id] ?? []).lazy.filter { !$0.isMarkdown }
                .compactMap { owners[$0.sha256] ?? owners[$0.originalSha256] }.first
            if found == nil, item.kind == .regular {
                let metadata = item.metadata
                found = keys(metadata).lazy.flatMap { works[$0] ?? [] }.first { _, other in
                    if let isbn = metadata.isbn, !isbn.isEmpty, other.isbn == isbn { return true }
                    return DuplicateMatcher.isSameWork(other, metadata)
                }?.0
            }
            if let found, taken.insert(found).inserted { result[item.id] = found }
        }
        return result
    }

    // MARK: Groups and tags

    private mutating func importGroups() throws {
        let groups = try source.read { try LibraryGroup.fetchAll($0) }
        let byId = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        func level(_ group: LibraryGroup) -> Int {
            var level = 1, parent = group.parentId, seen: Set<String> = [group.id]
            while let id = parent, seen.insert(id).inserted { level += 1; parent = byId[id]?.parentId }
            return level
        }
        // Parents before what is in them.
        let ordered = groups.map { (level($0), $0) }.sorted { ($0.0, $0.1.position) < ($1.0, $1.1.position) }.map(\.1)
        try writer.write { db in
            for group in ordered {
                if try LibraryGroup.exists(db, key: group.id) { groupIds[group.id] = group.id; continue }
                let parent = group.parentId.flatMap { groupIds[$0] }
                let siblings = try Library.siblings(of: parent, db)
                if let same = siblings.first(where: { $0.name.compare(group.name, options: .caseInsensitive) == .orderedSame }) {
                    groupIds[group.id] = same.id
                    continue
                }
                var depth = 1, up = parent
                while let id = up { depth += 1; up = try LibraryGroup.fetchOne(db, key: id)?.parentId }
                // Deeper than groups nest here: its items are in the group above.
                if depth > LibraryGroup.maximumDepth, let parent { groupIds[group.id] = parent; continue }
                var record = group
                record.parentId = parent
                record.position = (siblings.map(\.position).max() ?? -1) + 1
                try record.insert(db)
                groupIds[group.id] = group.id
                summary.groupsCreated += 1
            }
        }
    }

    private mutating func importTags() throws {
        let tags = try source.read { try Tag.order(Column("position")).fetchAll($0) }
        try writer.write { db in
            var position = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM tag") ?? -1
            for var tag in tags {
                if let same = try String.fetchOne(db, sql: "SELECT id FROM tag WHERE id = ? OR name = ? COLLATE NOCASE", arguments: [tag.id, tag.name]) {
                    tagIds[tag.id] = same
                    continue
                }
                position += 1
                tag.position = position
                try tag.insert(db)
                tagIds[tag.id] = tag.id
                summary.tagsCreated += 1
            }
        }
    }

    // MARK: Items

    private mutating func importItem(_ item: Item, into match: String?, files: [FileRecord], note: Note?) throws {
        let itemId = match ?? item.id
        let local = try match.flatMap { try library.item($0) }
        let localFiles = try local.map { try library.files(ofItem: $0.id) } ?? []
        var added: [FileRecord] = [], changed: [FileRecord] = []
        do {
            for file in files {
                if let have = localFiles.first(where: { $0.id == file.id })
                    ?? localFiles.first(where: { !file.isMarkdown && ($0.sha256 == file.sha256 || $0.originalSha256 == file.originalSha256) }) {
                    fileIds[file.id] = have.id
                    if have.sha256 != file.sha256, file.modifiedAt > have.modifiedAt.addingTimeInterval(1), let updated = try replace(have, with: file) {
                        changed.append(updated)
                    }
                } else if let record = try add(file, to: itemId) {
                    added.append(record)
                } else { summary.missingFiles += 1 }
            }
            // A file of its own whose file is gone is nothing.
            if local == nil, item.kind == .standalone, added.isEmpty {
                itemIds[item.id] = nil
                return
            }
            // Which file they were translated from, now that all are known.
            for index in added.indices { added[index].translationOf = added[index].translationOf.flatMap { fileIds[$0] } }
            let groups = groupIds, tags = tagIds, ids = fileIds
            let rewritten = note.map { Note(itemId: itemId, content: relinked($0.content), dateModified: $0.dateModified) }
            let new = added, newer = changed
            let touched = try writer.write { db -> Bool in
                var touched = !new.isEmpty || !newer.isEmpty
                if var kept = local {
                    let wasTrashed = kept.isTrashed
                    if item.dateModified > kept.dateModified, !(kept.kind == .regular && item.kind == .standalone) {
                        var updated = item
                        updated.id = kept.id
                        updated.dateAdded = kept.dateAdded
                        updated.originItemId = nil
                        updated.citationKey = kept.citationKey ?? item.citationKey
                        updated.defaultFileId = item.defaultFileId.flatMap { ids[$0] } ?? kept.defaultFileId
                        kept = updated
                        touched = true
                    }
                    if wasTrashed { touched = true }
                    kept.trashedAt = nil
                    for file in new { try file.insert(db) }
                    for file in newer { try file.update(db) }
                    if kept.defaultFileId == nil { kept.defaultFileId = new.first?.id }
                    try kept.update(db)
                } else {
                    var record = item
                    record.originItemId = nil
                    record.defaultFileId = item.defaultFileId.flatMap { ids[$0] } ?? new.first?.id
                    if let key = record.citationKey { record.citationKey = CitationKeyGenerator.uniqueKey(base: key, existing: try Library.existingCitationKeys(db)) }
                    try record.insert(db)
                    for file in new { try file.insert(db) }
                }
                if let rewritten, !rewritten.content.isEmpty {
                    let mine = try Note.fetchOne(db, key: itemId)
                    if mine == nil || mine!.content.isEmpty { try rewritten.save(db); touched = true }
                    else if mine!.content != rewritten.content {
                        if item.id == itemId {
                            if rewritten.dateModified > mine!.dateModified { try rewritten.save(db); touched = true }
                        } else if !mine!.content.contains(rewritten.content) {
                            // Written apart, about the same paper: both.
                            try Note(itemId: itemId, content: mine!.content + "\n\n" + rewritten.content).save(db)
                            touched = true
                        }
                    }
                }
                for membership in try source.read({ try ItemGroup.filter(Column("itemId") == item.id).fetchAll($0) }) {
                    guard let group = groups[membership.groupId], try !ItemGroup.exists(db, key: ["itemId": itemId, "groupId": group]) else { continue }
                    try ItemGroup(itemId: itemId, groupId: group, dateAdded: membership.dateAdded).insert(db)
                    touched = true
                }
                for tagging in try source.read({ try ItemTag.filter(Column("itemId") == item.id).fetchAll($0) }) {
                    guard let tag = tags[tagging.tagId], try !ItemTag.exists(db, key: ["itemId": itemId, "tagId": tag]) else { continue }
                    try ItemTag(itemId: itemId, tagId: tag).insert(db)
                    touched = true
                }
                return touched
            }
            summary.filesAdded += added.count
            summary.filesUpdated += changed.count
            if local == nil { summary.itemsAdded += 1 } else if touched { summary.itemsUpdated += 1 } else { summary.itemsUnchanged += 1 }
        } catch {
            added.forEach { library.store.delete($0.relativePath) }
            throw error
        }
    }

    /// Takes a file's contents out of the package. Nil when the package does not have them (whole).
    private func extract(_ file: FileRecord) throws -> URL? {
        guard archive.contains(file.relativePath) else { return nil }
        let url = staging.appending(path: UUID().uuidString)
        do { try archive.extract(file.relativePath, to: url) } catch is ZipError {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if file.isMarkdown, let text = try? String(contentsOf: url, encoding: .utf8) {
            let linked = relinked(text)
            if linked != text { try Data(linked.utf8).write(to: url) }
        }
        try? FileManager.default.setAttributes([.modificationDate: file.modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private mutating func add(_ file: FileRecord, to itemId: String) throws -> FileRecord? {
        guard let url = try extract(file) else { return nil }
        var record = file
        record.itemId = itemId
        if try writer.read({ try FileRecord.exists($0, key: file.id) }) {
            record.id = UUID().uuidString
            if file.originalSha256 == "md-" + file.id { record.originalSha256 = "md-" + record.id }
        }
        let name = (file.relativePath as NSString).lastPathComponent as NSString
        record.relativePath = library.store.uniqueRelativePath(baseName: FileNamer.sanitize(name.deletingPathExtension), ext: FileNamer.sanitize(name.pathExtension), ignoring: nil)
        try FileManager.default.moveItem(at: url, to: library.store.url(for: record.relativePath))
        try fingerprint(&record)
        fileIds[file.id] = record.id
        written.insert(file.id)
        return record
    }

    private mutating func replace(_ have: FileRecord, with file: FileRecord) throws -> FileRecord? {
        guard let url = try extract(file) else { return nil }
        let target = library.store.url(for: have.relativePath)
        if FileManager.default.fileExists(atPath: target.path) {
            // Where there is no trash the file that is here stays.
            do { try discard(target) } catch { return nil }
        }
        try FileManager.default.moveItem(at: url, to: target)
        var record = have
        record.fulltextState = file.fulltextState
        try fingerprint(&record)
        written.insert(file.id)
        return record
    }

    private func fingerprint(_ record: inout FileRecord) throws {
        let url = library.store.url(for: record.relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        record.size = (attributes[.size] as? NSNumber)?.int64Value ?? record.size
        record.modifiedAt = attributes[.modificationDate] as? Date ?? record.modifiedAt
        record.sha256 = try FileHasher.sha256(of: url)
    }

    /// Links to items that have another id here.
    private func relinked(_ text: String) -> String {
        guard text.contains("folio://") else { return text }
        var result = text
        for (old, new) in itemIds where old != new { result = result.replacingOccurrences(of: "item=" + old, with: "item=" + new) }
        return result
    }

    // MARK: What belongs to them

    /// The text of the files that came, so that they need not be read again.
    private func importFulltext() throws {
        guard !written.isEmpty else { return }
        try writer.write { db in
            let ids = written.compactMap { fileIds[$0] }
            for start in stride(from: 0, to: ids.count, by: 500) {
                try Library.deleteFulltext(fileIds: Array(ids[start..<min(start + 500, ids.count)]), db)
            }
            try source.read { from in
                let rows = try Row.fetchCursor(from, sql: "SELECT fileId, content FROM fulltext")
                while let row = try rows.next() {
                    let id: String = row["fileId"]
                    guard written.contains(id), let here = fileIds[id] else { continue }
                    try db.execute(sql: "INSERT INTO fulltext (fileId, content) VALUES (?, ?)", arguments: [here, row["content"] as String?])
                }
            }
        }
    }

    /// Where files were read to, the order of views, what is known of journals.
    private func importTheRest() throws {
        let (reading, orders, sorts, metrics) = try source.read { db in
            (try ReadingState.fetchAll(db), try ItemOrder.fetchAll(db), try ViewSortRecord.fetchAll(db),
             try Row.fetchAll(db, sql: "SELECT name, json, fetchedAt FROM journalMetrics"))
        }
        func scope(_ key: String) -> String? {
            if key == "trash" { return nil }
            for (prefix, ids) in [("group:", groupIds), ("tag:", tagIds)] where key.hasPrefix(prefix) {
                return ids[String(key.dropFirst(prefix.count))].map { prefix + $0 }
            }
            return key
        }
        try writer.write { db in
            for var state in reading {
                guard let file = fileIds[state.fileId], try FileRecord.exists(db, key: file) else { continue }
                state.fileId = file
                if let mine = try ReadingState.fetchOne(db, key: file), mine.dateModified >= state.dateModified { continue }
                try state.save(db)
            }
            for var order in orders {
                guard let key = scope(order.scope), let item = itemIds[order.itemId], try Item.exists(db, key: item) else { continue }
                order.scope = key
                order.itemId = item
                try order.insert(db, onConflict: .ignore)
            }
            for var sort in sorts {
                guard let key = scope(sort.scope) else { continue }
                sort.scope = key
                try sort.insert(db, onConflict: .ignore)
            }
            for row in metrics {
                try db.execute(sql: "INSERT OR IGNORE INTO journalMetrics (name, json, fetchedAt) VALUES (?, ?, ?)",
                               arguments: [row["name"], row["json"], row["fetchedAt"]])
            }
        }
    }
}
