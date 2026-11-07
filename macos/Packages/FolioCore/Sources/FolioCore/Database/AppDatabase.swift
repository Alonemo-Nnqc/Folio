import Foundation
import GRDB

/// Owns the SQLite connection pool and schema migrations.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public static func open(at url: URL) throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Folio and its helper (folio-cli, used by AI agents) can write at the same time: wait for
        // the other side's transaction instead of failing with "database is locked".
        config.busyMode = .timeout(10)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(pool)
    }

    /// In-memory database for tests.
    public static func makeTemporary() throws -> AppDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try AppDatabase(DatabaseQueue(configuration: config))
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        Migrations.register(in: &migrator)
        return migrator
    }
}
