import Foundation
import GRDB

/// The library service: every mutation of the user's data goes through here.
///
/// Methods are synchronous and thread-safe; callers run slow ones (imports, hashing) off the main actor.
public final class Library: Sendable {
    public static let databaseFileName = "Folio.sqlite"

    public let root: URL
    public let database: AppDatabase
    let store: FileStore

    /// Opens (or creates) the library stored at `root`.
    public convenience init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try AppDatabase.open(at: root.appending(path: Self.databaseFileName))
        try self.init(root: root, database: db)
    }

    init(root: URL, database: AppDatabase) throws {
        self.root = root
        self.database = database
        self.store = FileStore(root: root)
        try store.prepare()
    }

    /// A throwaway library in a temporary folder with an in-memory database (tests).
    public static func temporary() throws -> Library {
        let root = FileManager.default.temporaryDirectory.appending(path: "folio-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try Library(root: root, database: .makeTemporary())
    }

    /// Closes the database so the library folder can be moved (STORE-01).
    public func close() throws {
        try database.writer.close()
    }

    public func fileURL(for file: FileRecord) -> URL {
        store.url(for: file.relativePath)
    }

    var writer: any DatabaseWriter { database.writer }

    // MARK: Lookups

    public func item(_ id: String) throws -> Item? {
        try writer.read { try Item.fetchOne($0, key: id) }
    }

    public func files(ofItem id: String) throws -> [FileRecord] {
        try writer.read { try Self.files(ofItem: id, $0) }
    }

    static func files(ofItem id: String, _ db: Database) throws -> [FileRecord] {
        try FileRecord.filter(Column("itemId") == id).order(Column("dateAdded"), Column("id")).fetchAll(db)
    }

    static func existingCitationKeys(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT citationKey FROM item WHERE citationKey IS NOT NULL"))
    }
}
