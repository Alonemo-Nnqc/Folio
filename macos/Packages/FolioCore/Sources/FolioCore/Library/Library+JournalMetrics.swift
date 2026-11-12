import Foundation
import GRDB

extension Library {
    // MARK: Journal ranks cache (META-30)

    /// The cached ranks of a journal (any spelling of its name).
    public func journalMetrics(named name: String) throws -> JournalMetrics? {
        try writer.read { try JournalMetricsRecord.fetchOne($0, key: JournalMetrics.key(for: name))?.metrics }
    }

    /// Stores fetched ranks (or "not listed", an empty `ranks`) per journal name, in one transaction.
    public func saveJournalMetrics(_ entries: [(name: String, metrics: JournalMetrics)]) throws {
        guard !entries.isEmpty else { return }
        try writer.write { db in
            for entry in entries {
                let key = JournalMetrics.key(for: entry.name)
                guard !key.isEmpty else { continue }
                try JournalMetricsRecord(name: key, metrics: entry.metrics).save(db)
            }
        }
    }

    /// Forgets every cached answer (a new key may see journals the old one could not).
    public func clearJournalMetrics() throws {
        _ = try writer.write { try JournalMetricsRecord.deleteAll($0) }
    }
}
