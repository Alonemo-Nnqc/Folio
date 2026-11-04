import Foundation
import GRDB
import FolioCore

/// Reads a read-only copy of a Zotero library and prepares it for
/// `Library.importPrepared(_:progress:)` (spec Task 2C).
///
/// `init` copies `zotero.sqlite` out of `dataDirectory` into a private temporary directory —
/// Zotero.app keeps its own copy locked while running, and Folio must never write into the
/// user's real Zotero data directory.
public final class ZoteroReader: Sendable {
    private let queue: DatabaseQueue
    private let dataDirectory: URL
    private let tempDirectory: URL
    private let baseAttachmentPath: String?

    public init(dataDirectory: URL) throws {
        let (queue, tempDirectory) = try ZoteroDatabaseCopier.openReadOnlyCopy(of: dataDirectory)
        self.queue = queue
        self.tempDirectory = tempDirectory
        self.dataDirectory = dataDirectory
        self.baseAttachmentPath = ZoteroLocator.baseAttachmentPath()
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    /// Reads the full library and prepares it for bulk import.
    public func read(options: ZoteroReadOptions) throws -> (PreparedLibrary, ZoteroReadReport) {
        let raw = try queue.read(ZoteroRawLoader.load(from:))
        return ZoteroLibraryBuilder.build(
            from: raw, dataDirectory: dataDirectory, baseAttachmentPath: baseAttachmentPath, options: options
        )
    }

    /// Counts only, for the import sheet's preview (before the user picks options).
    public func probe() throws -> ZoteroReadReport {
        try read(options: ZoteroReadOptions()).1
    }
}
