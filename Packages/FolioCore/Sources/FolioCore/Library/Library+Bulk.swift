import Foundation
import GRDB

extension Library {
    /// Imports a prepared library (e.g. read from Zotero): groups, tags, items and files, skipping
    /// duplicates by file hash and by work identity (ZOT-02/04/05). Imported items are not re-retrieved.
    public func importPrepared(_ prepared: PreparedLibrary, autoRename: Bool = true,
                               progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> BulkImportSummary {
        var summary = BulkImportSummary()
        let groupIds = try importGroups(prepared.groups, summary: &summary)
        let tagIds = try importTags(prepared.tags, entries: prepared.entries, summary: &summary)
        let total = prepared.entries.count
        for (index, entry) in prepared.entries.enumerated() {
            try importEntry(entry, groupIds: groupIds, tagIds: tagIds, autoRename: autoRename, summary: &summary)
            progress?(index + 1, total)
        }
        return summary
    }

    private func importGroups(_ groups: [PreparedGroup], summary: inout BulkImportSummary) throws -> [String: String] {
        var ids: [String: String] = [:]
        let ordered = groups.filter { $0.parentKey == nil }.sorted { $0.position < $1.position }
            + groups.filter { $0.parentKey != nil }.sorted { $0.position < $1.position }
        try writer.write { db in
            for group in ordered {
                let parentId = group.parentKey.flatMap { ids[$0] }
                if group.parentKey != nil && parentId == nil { continue }
                let siblings = try Self.siblings(of: parentId, db)
                if let existing = siblings.first(where: { $0.name.compare(group.name, options: .caseInsensitive) == .orderedSame }) {
                    ids[group.key] = existing.id
                    continue
                }
                let record = LibraryGroup(parentId: parentId, name: group.name,
                                          position: (siblings.map(\.position).max() ?? -1) + 1)
                try record.insert(db)
                ids[group.key] = record.id
                summary.groupsCreated += 1
            }
        }
        return ids
    }

    private func importTags(_ tags: [PreparedTag], entries: [PreparedEntry],
                            summary: inout BulkImportSummary) throws -> [String: String] {
        var colors: [String: String] = [:]
        for tag in tags { colors[tag.name.lowercased()] = tag.colorHex }
        var names: [String] = tags.map(\.name)
        for entry in entries { names += entry.tagNames }
        var ids: [String: String] = [:]
        try writer.write { db in
            var position = try Double.fetchOne(db, sql: "SELECT MAX(position) FROM tag") ?? -1
            for name in names {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = clean.lowercased()
                guard !clean.isEmpty, ids[key] == nil else { continue }
                if let existing = try String.fetchOne(db, sql: "SELECT id FROM tag WHERE name = ? COLLATE NOCASE", arguments: [clean]) {
                    ids[key] = existing
                    continue
                }
                position += 1
                let tag = Tag(name: clean, colorHex: colors[key] ?? "#8E8E93", position: position)
                try tag.insert(db)
                ids[key] = tag.id
                summary.tagsCreated += 1
            }
        }
        return ids
    }

    private func importEntry(_ entry: PreparedEntry, groupIds: [String: String], tagIds: [String: String],
                             autoRename: Bool, summary: inout BulkImportSummary) throws {
        var hashed: [(PreparedFile, String)] = []
        for file in entry.files {
            if FileManager.default.fileExists(atPath: file.sourceURL.path), let hash = try? FileHasher.sha256(of: file.sourceURL) {
                hashed.append((file, hash))
            } else {
                summary.missingFiles += 1
            }
        }
        let existingOwner = try writer.read { db -> String? in
            for (_, hash) in hashed {
                if let owner = try String.fetchOne(db, sql: "SELECT itemId FROM file WHERE sha256 = ? OR originalSha256 = ?",
                                                   arguments: [hash, hash]) { return owner }
            }
            if case .regular(let metadata) = entry.kind {
                return try Self.findSameWork(metadata, excluding: nil, db)
            }
            return nil
        }
        if existingOwner != nil {
            summary.duplicatesSkipped += 1
            return
        }

        var item: Item
        switch entry.kind {
        case .regular(let metadata):
            item = Item(kind: .regular, title: metadata.title, dateAdded: entry.dateAdded)
            item.metadata = metadata
            item.metadataState = .resolved
        case .standalone:
            item = Item(kind: .standalone, title: hashed.first?.0.originalName ?? entry.files.first?.originalName ?? String(localized: "未命名", bundle: .module),
                        dateAdded: entry.dateAdded)
        }
        item.dateModified = entry.dateModified
        let baseName = item.kind == .regular && autoRename ? FileNamer.baseName(for: item.metadata) : nil

        var copied: [FileRecord] = []
        for (file, hash) in hashed {
            let url = file.sourceURL
            let base = baseName ?? FileNamer.sanitize(url.deletingPathExtension().lastPathComponent)
            let relative = try store.copyIn(url, baseName: base, ext: url.pathExtension)
            let attributes = try FileManager.default.attributesOfItem(atPath: store.url(for: relative).path)
            let isPDF = url.pathExtension.lowercased() == "pdf"
            copied.append(FileRecord(itemId: item.id, relativePath: relative, originalName: file.originalName,
                                     size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, sha256: hash,
                                     modifiedAt: attributes[.modificationDate] as? Date ?? Date(),
                                     dateAdded: file.dateAdded, fulltextState: isPDF ? .pending : .notApplicable))
        }
        if item.kind == .standalone && copied.isEmpty { return }
        item.defaultFileId = copied.first?.id

        do {
            try writer.write { db in
                if item.kind == .regular {
                    item.citationKey = CitationKeyGenerator.uniqueKey(
                        base: CitationKeyGenerator.baseKey(for: item.metadata), existing: try Self.existingCitationKeys(db))
                }
                try item.insert(db)
                for file in copied { try file.insert(db) }
                for key in Set(entry.groupKeys) {
                    guard let groupId = groupIds[key] else { continue }
                    try ItemGroup(itemId: item.id, groupId: groupId, dateAdded: entry.dateAdded).insert(db, onConflict: .ignore)
                }
                for name in Set(entry.tagNames.map { $0.lowercased() }) {
                    guard let tagId = tagIds[name] else { continue }
                    try ItemTag(itemId: item.id, tagId: tagId).insert(db, onConflict: .ignore)
                }
            }
        } catch {
            copied.forEach { store.delete($0.relativePath) }
            throw error
        }
        summary.itemsImported += 1
        summary.filesImported += copied.count
    }
}
