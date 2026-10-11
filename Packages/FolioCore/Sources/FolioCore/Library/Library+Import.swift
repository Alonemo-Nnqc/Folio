import Foundation
import GRDB

public enum ImportOutcome: Sendable, Equatable {
    /// A new standalone item was created for the file.
    case imported(itemId: String, isPDF: Bool)
    /// The same content already exists in the library (DUP-01). `addedToGroup` is true when the
    /// existing item was added to the target group as a side effect.
    case duplicateFile(existingItemId: String, addedToGroup: Bool)
    /// The same content exists but is in the trash (DUP-02).
    case duplicateInTrash(existingItemId: String)
    case failed(URL, String)
}

public enum ApplyOutcome: Sendable, Equatable {
    case created(itemId: String)
    /// A regular item describing the same work already exists; nothing was changed.
    case duplicateItem(existingItemId: String)
}

public enum CreateOutcome: Sendable, Equatable {
    case created(itemId: String)
    case duplicate(existingItemId: String)
}

public enum AddFileOutcome: Sendable, Equatable {
    case added(fileId: String)
    case duplicate(existingItemId: String)
    case failed(URL, String)
}

extension Library {
    // MARK: Importing files (META-01, DUP-01/02, STORE-02)

    public func importFiles(_ urls: [URL], toGroup groupId: String? = nil) throws -> [ImportOutcome] {
        var outcomes: [ImportOutcome] = []
        for url in urls {
            do {
                outcomes.append(try importFile(url, toGroup: groupId))
            } catch {
                outcomes.append(.failed(url, error.localizedDescription))
            }
        }
        return outcomes
    }

    private func importFile(_ url: URL, toGroup groupId: String?) throws -> ImportOutcome {
        let hash = try FileHasher.sha256(of: url)
        if let duplicate = try duplicateOutcome(forHash: hash, groupId: groupId) {
            return duplicate
        }
        let ext = url.pathExtension
        let baseName = url.deletingPathExtension().lastPathComponent
        let relative = try store.copyIn(url, baseName: FileNamer.sanitize(baseName), ext: ext)
        let isPDF = ext.lowercased() == "pdf"
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: store.url(for: relative).path)
            let now = Date()
            var item = Item(kind: .standalone, title: url.lastPathComponent, dateAdded: now)
            item.metadataState = isPDF ? .pending : .none
            let file = FileRecord(itemId: item.id, relativePath: relative, originalName: url.lastPathComponent,
                                  size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, sha256: hash,
                                  modifiedAt: attributes[.modificationDate] as? Date ?? now, dateAdded: now,
                                  fulltextState: isPDF ? .pending : .notApplicable)
            item.defaultFileId = file.id
            try writer.write { db in
                try item.insert(db)
                try file.insert(db)
                if let groupId {
                    try ItemGroup(itemId: item.id, groupId: groupId, dateAdded: now).insert(db)
                }
            }
            return .imported(itemId: item.id, isPDF: isPDF)
        } catch {
            store.delete(relative)
            throw error
        }
    }

    private func duplicateOutcome(forHash hash: String, groupId: String?) throws -> ImportOutcome? {
        try writer.write { db -> ImportOutcome? in
            let owners = try Item.fetchAll(db, sql: """
                SELECT item.* FROM item JOIN file ON file.itemId = item.id
                WHERE file.sha256 = ? OR file.originalSha256 = ?
                """, arguments: [hash, hash])
            if let live = owners.first(where: { !$0.isTrashed }) {
                var added = false
                if let groupId, try !ItemGroup.exists(db, key: ["itemId": live.id, "groupId": groupId]) {
                    try ItemGroup(itemId: live.id, groupId: groupId, dateAdded: Date()).insert(db)
                    added = true
                }
                return .duplicateFile(existingItemId: live.id, addedToGroup: added)
            }
            if let trashed = owners.first {
                return .duplicateInTrash(existingItemId: trashed.id)
            }
            return nil
        }
    }

    // MARK: Retrieval results (META-03, DUP-03)

    public func applyMetadata(_ metadata: Metadata, toStandalone itemId: String, autoRename: Bool) throws -> ApplyOutcome {
        let outcome = try writer.write { db -> ApplyOutcome in
            guard var item = try Item.fetchOne(db, key: itemId), item.kind == .standalone else {
                throw LibraryError.notFound
            }
            if let existing = try Self.findSameWork(metadata, excluding: itemId, db) {
                return .duplicateItem(existingItemId: existing)
            }
            item.metadata = metadata
            item.kind = .regular
            item.metadataState = .resolved
            item.citationKey = CitationKeyGenerator.uniqueKey(
                base: CitationKeyGenerator.baseKey(for: metadata), existing: try Self.existingCitationKeys(db))
            item.dateModified = Date()
            try item.update(db)
            return .created(itemId: itemId)
        }
        if autoRename, case .created = outcome {
            try renameFiles(ofItem: itemId)
        }
        return outcome
    }

    /// Attaches the standalone item's files to `targetId`, moves its group memberships over and
    /// deletes the standalone item (DUP-03 "作为附件添加到该条目").
    public func mergeStandalone(_ itemId: String, intoItem targetId: String, autoRename: Bool) throws {
        try writer.write { db in
            guard try Item.fetchOne(db, key: itemId) != nil, var target = try Item.fetchOne(db, key: targetId) else {
                throw LibraryError.notFound
            }
            let moved = try Self.files(ofItem: itemId, db)
            for var file in moved {
                file.itemId = targetId
                try file.update(db)
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO itemGroup (itemId, groupId, dateAdded)
                SELECT ?, groupId, dateAdded FROM itemGroup WHERE itemId = ?
                """, arguments: [targetId, itemId])
            try db.execute(sql: "INSERT OR IGNORE INTO itemTag (itemId, tagId) SELECT ?, tagId FROM itemTag WHERE itemId = ?",
                           arguments: [targetId, itemId])
            // A note written on the standalone file is appended to the target's note (NOTE-05).
            if let note = try Note.fetchOne(db, key: itemId) {
                var merged = try Note.fetchOne(db, key: targetId) ?? Note(itemId: targetId, content: "")
                merged.content = merged.content.isEmpty ? note.content : merged.content + "\n\n" + note.content
                merged.dateModified = Date()
                try merged.save(db)
            }
            if target.defaultFileId == nil { target.defaultFileId = moved.first?.id }
            target.dateModified = Date()
            try target.update(db)
            _ = try Item.deleteOne(db, key: itemId)
        }
        if autoRename { try renameFiles(ofItem: targetId) }
    }

    /// Removes a standalone item and its stored file entirely (DUP-03 "放弃").
    public func discardStandalone(_ itemId: String) throws {
        let files = try self.files(ofItem: itemId)
        try writer.write { db in
            try Self.deleteFulltext(fileIds: files.map(\.id), db)
            _ = try Item.deleteOne(db, key: itemId)
        }
        files.forEach { store.delete($0.relativePath) }
    }

    public func setMetadataState(_ state: MetadataState, for itemId: String, incrementRetry: Bool = false) throws {
        try writer.write { db in
            guard var item = try Item.fetchOne(db, key: itemId) else { return }
            item.metadataState = state
            if incrementRetry { item.retryCount += 1 }
            try item.update(db)
        }
    }

    // MARK: Creating and editing items (META-08/09, DUP-04, FILE-06)

    public func createItem(_ metadata: Metadata, inGroup groupId: String? = nil) throws -> CreateOutcome {
        try writer.write { db in
            if let existing = try Self.findSameWork(metadata, excluding: nil, db) {
                return .duplicate(existingItemId: existing)
            }
            var item = Item(kind: .regular, title: metadata.title)
            item.metadata = metadata
            item.metadataState = .resolved
            item.citationKey = CitationKeyGenerator.uniqueKey(
                base: CitationKeyGenerator.baseKey(for: metadata), existing: try Self.existingCitationKeys(db))
            try item.insert(db)
            if let groupId {
                try ItemGroup(itemId: item.id, groupId: groupId, dateAdded: item.dateAdded).insert(db)
            }
            return .created(itemId: item.id)
        }
    }

    public func addFiles(_ urls: [URL], toItem itemId: String, autoRename: Bool) throws -> [AddFileOutcome] {
        guard let item = try self.item(itemId) else { throw LibraryError.notFound }
        var outcomes: [AddFileOutcome] = []
        for url in urls {
            do {
                let hash = try FileHasher.sha256(of: url)
                let owner = try writer.read { db in
                    try String.fetchOne(db, sql: """
                        SELECT file.itemId FROM file JOIN item ON item.id = file.itemId
                        WHERE (file.sha256 = ? OR file.originalSha256 = ?) AND item.trashedAt IS NULL
                        """, arguments: [hash, hash])
                }
                if let owner {
                    outcomes.append(.duplicate(existingItemId: owner))
                    continue
                }
                let base = autoRename && item.kind == .regular
                    ? FileNamer.baseName(for: item.metadata)
                    : FileNamer.sanitize(url.deletingPathExtension().lastPathComponent)
                let relative = try store.copyIn(url, baseName: base, ext: url.pathExtension)
                let attributes = try FileManager.default.attributesOfItem(atPath: store.url(for: relative).path)
                let isPDF = url.pathExtension.lowercased() == "pdf"
                let file = FileRecord(itemId: itemId, relativePath: relative, originalName: url.lastPathComponent,
                                      size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, sha256: hash,
                                      modifiedAt: attributes[.modificationDate] as? Date ?? Date(),
                                      fulltextState: isPDF ? .pending : .notApplicable)
                try writer.write { db in
                    try file.insert(db)
                    if var owner = try Item.fetchOne(db, key: itemId), owner.defaultFileId == nil {
                        owner.defaultFileId = file.id
                        try owner.update(db)
                    }
                }
                outcomes.append(.added(fileId: file.id))
            } catch {
                outcomes.append(.failed(url, error.localizedDescription))
            }
        }
        return outcomes
    }

    /// Overwrites bibliographic fields; tags, groups, rating, read status and files are kept (META-08).
    public func updateMetadata(_ itemId: String, _ metadata: Metadata, autoRename: Bool) throws {
        try writer.write { db in
            guard var item = try Item.fetchOne(db, key: itemId) else { throw LibraryError.notFound }
            item.metadata = metadata
            item.kind = .regular
            item.metadataState = .resolved
            if (item.citationKey ?? "").isEmpty {
                item.citationKey = CitationKeyGenerator.uniqueKey(
                    base: CitationKeyGenerator.baseKey(for: metadata), existing: try Self.existingCitationKeys(db))
            }
            item.dateModified = Date()
            try item.update(db)
        }
        if autoRename { try renameFiles(ofItem: itemId) }
    }

    /// Applies an arbitrary edit (inspector fields, rating, read status…).
    public func updateItem(_ itemId: String, _ change: (inout Item) -> Void) throws {
        try writer.write { db in
            guard var item = try Item.fetchOne(db, key: itemId) else { throw LibraryError.notFound }
            change(&item)
            item.doi = item.doi?.lowercased()
            item.dateModified = Date()
            try item.update(db)
        }
    }

    public func setDefaultFile(_ fileId: String) throws {
        try writer.write { db in
            guard let file = try FileRecord.fetchOne(db, key: fileId),
                  var item = try Item.fetchOne(db, key: file.itemId) else { throw LibraryError.notFound }
            item.defaultFileId = fileId
            try item.update(db)
        }
    }

    // MARK: Helpers

    /// Renames every file of a regular item to `Family_Year_Title` (STORE-03).
    func renameFiles(ofItem itemId: String) throws {
        guard let item = try self.item(itemId), item.kind == .regular else { return }
        let base = FileNamer.baseName(for: item.metadata)
        for var file in try files(ofItem: itemId) {
            let renamed = try store.rename(file.relativePath, toBaseName: base)
            guard renamed != file.relativePath else { continue }
            file.relativePath = renamed
            try writer.write { try file.update($0) }
        }
    }

    static func findSameWork(_ metadata: Metadata, excluding itemId: String?, _ db: Database) throws -> String? {
        let candidates = try Item
            .filter(Column("kind") == ItemKind.regular.rawValue && Column("trashedAt") == nil)
            .fetchAll(db)
        return candidates.first { candidate in
            if candidate.id == itemId { return false }
            if let isbn = metadata.isbn, !isbn.isEmpty, candidate.isbn == isbn { return true }
            return DuplicateMatcher.isSameWork(candidate.metadata, metadata)
        }?.id
    }
}
