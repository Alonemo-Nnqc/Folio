import Foundation
import GRDB

extension Library {
    // MARK: Full-text index (SEARCH-04) and change detection (FILE-08)

    public func setFulltext(fileId: String, text: String) throws {
        try writer.write { db in
            try Self.deleteFulltext(fileIds: [fileId], db)
            try db.execute(sql: "INSERT INTO fulltext (fileId, content) VALUES (?, ?)", arguments: [fileId, text])
            try db.execute(sql: "UPDATE file SET fulltextState = ? WHERE id = ?",
                           arguments: [FulltextState.indexed.rawValue, fileId])
        }
    }

    public func markFulltextNotApplicable(fileId: String) throws {
        try writer.write {
            try $0.execute(sql: "UPDATE file SET fulltextState = ? WHERE id = ?",
                           arguments: [FulltextState.notApplicable.rawValue, fileId])
        }
    }

    public func filesNeedingFulltext() throws -> [FileRecord] {
        try writer.read {
            try FileRecord.filter(Column("fulltextState") == FulltextState.pending.rawValue).fetchAll($0)
                .filter(\.isPDF)
        }
    }

    /// Items whose indexed PDF text contains every token of `query` (prefix match).
    public func fulltextItemIds(matching query: String) throws -> Set<String> {
        let tokens = SearchMatcher.tokens(query)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
        return try writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT file.itemId FROM fulltext JOIN file ON file.id = fulltext.fileId
                WHERE fulltext MATCH ?
                """, arguments: [match]))
        }
    }

    /// Detects files changed on disk (e.g. annotated in Preview): updates size, date and hash and
    /// queues them for re-indexing. Returns the ids of changed files.
    @discardableResult
    public func refreshFingerprints() throws -> [String] {
        let files = try writer.read { try FileRecord.fetchAll($0) }
        var changed: [FileRecord] = []
        for var file in files {
            let url = store.url(for: file.relativePath)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? file.size
            let modified = attributes[.modificationDate] as? Date ?? file.modifiedAt
            guard size != file.size || abs(modified.timeIntervalSince(file.modifiedAt)) > 0.5 else { continue }
            file.size = size
            file.modifiedAt = modified
            if let hash = try? FileHasher.sha256(of: url) { file.sha256 = hash }
            if file.isPDF { file.fulltextState = .pending }
            changed.append(file)
        }
        guard !changed.isEmpty else { return [] }
        try writer.write { db in
            for file in changed { try file.update(db) }
        }
        return changed.map(\.id)
    }

    static func deleteFulltext(fileIds: [String], _ db: Database) throws {
        guard !fileIds.isEmpty else { return }
        try db.execute(sql: "DELETE FROM fulltext WHERE fileId IN (\(fileIds.map { _ in "?" }.joined(separator: ",")))",
                       arguments: StatementArguments(fileIds))
    }
}
