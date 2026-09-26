import Foundation
import GRDB

/// Copies `zotero.sqlite` out of a Zotero data directory so it can be read while Zotero.app
/// still has its own copy open, and opens the copy read-only.
enum ZoteroDatabaseCopier {
    static func openReadOnlyCopy(of dataDirectory: URL) throws -> (queue: DatabaseQueue, tempDirectory: URL) {
        let source = dataDirectory.appendingPathComponent("zotero.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ZoteroReaderError.sourceDatabaseNotFound(source)
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioZotero-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let destination = tempDirectory.appendingPathComponent("zotero.sqlite")
        try FileManager.default.copyItem(at: source, to: destination)
        // If Zotero.app is running its database may be in WAL mode with committed data still
        // sitting in the sidecar files — copy those too so the checkpoint below is complete.
        for suffix in ["-wal", "-shm"] {
            let sidecar = dataDirectory.appendingPathComponent("zotero.sqlite\(suffix)")
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            try? FileManager.default.copyItem(at: sidecar, to: tempDirectory.appendingPathComponent("zotero.sqlite\(suffix)"))
        }

        try checkpointToSingleFile(at: destination)

        var readonlyConfig = Configuration()
        readonlyConfig.readonly = true
        let queue = try DatabaseQueue(path: destination.path, configuration: readonlyConfig)
        return (queue, tempDirectory)
    }

    /// Folds any WAL frames into the main file and switches to a rollback journal, so the
    /// read-only queue above never has to deal with `-wal`/`-shm` siblings.
    private static func checkpointToSingleFile(at path: URL) throws {
        do {
            let queue = try DatabaseQueue(path: path.path)
            try queue.writeWithoutTransaction { db in
                _ = try? Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                _ = try Row.fetchAll(db, sql: "PRAGMA journal_mode = DELETE")
            }
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path.path + suffix))
        }
    }
}
