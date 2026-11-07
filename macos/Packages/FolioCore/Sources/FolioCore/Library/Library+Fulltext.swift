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

    /// Stores several results in one transaction (nil text = no text layer), so indexing a large
    /// library triggers a handful of snapshot refreshes instead of one per file.
    public func setFulltext(_ results: [(fileId: String, text: String?)]) throws {
        guard !results.isEmpty else { return }
        try writer.write { db in
            try Self.deleteFulltext(fileIds: results.map(\.fileId), db)
            for (fileId, text) in results {
                if let text {
                    try db.execute(sql: "INSERT INTO fulltext (fileId, content) VALUES (?, ?)", arguments: [fileId, text])
                }
                let state = text == nil ? FulltextState.notApplicable : .indexed
                try db.execute(sql: "UPDATE file SET fulltextState = ? WHERE id = ?", arguments: [state.rawValue, fileId])
            }
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

    /// A full-text hit: the item, how well it matched (lower is better, FTS5 bm25) and a short excerpt
    /// with the matched words in «guillemets».
    public struct FulltextHit: Sendable {
        public let itemId: String
        public let rank: Double
        public let snippet: String
    }

    /// Items whose indexed PDF text contains any token of `query` (prefix match), best first, one hit
    /// per item (its best file).
    public func fulltextHits(matching query: String, limit: Int = 200) throws -> [FulltextHit] {
        let tokens = SearchMatcher.tokens(query)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " OR ")
        return try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT file.itemId AS itemId, bm25(fulltext) AS rank,
                       snippet(fulltext, 1, '«', '»', '…', 24) AS snippet
                FROM fulltext JOIN file ON file.id = fulltext.fileId
                WHERE fulltext MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [match, limit * 2])
            var seen: Set<String> = []
            var hits: [FulltextHit] = []
            for row in rows {
                guard let itemId: String = row["itemId"], seen.insert(itemId).inserted else { continue }
                let snippet = (row["snippet"] as String? ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                hits.append(FulltextHit(itemId: itemId, rank: row["rank"] ?? 0, snippet: snippet))
            }
            return Array(hits.prefix(limit))
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
