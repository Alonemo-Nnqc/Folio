import Foundation
import SQLite3

/// Builds a minimal, throwaway Zotero-schema `zotero.sqlite` directly with SQL (via the
/// system libsqlite3, so the test target doesn't need to depend on GRDB) — just the
/// tables/columns `FolioZotero` actually reads, populated with only what each test needs.
///
/// Zotero's own field/creator-type vocabulary is fixed, so the constructor seeds `fields`,
/// `itemTypes` and `creatorTypes` with the subset the tests use; individual tests just insert
/// items, relations and values.
final class ZoteroFixtureDB {
    let directory: URL
    private var handle: OpaquePointer?

    enum FixtureError: Error { case openFailed, execFailed(String) }

    // Zotero's real itemTypeIDs, for readability when cross-checking against the live library.
    static let attachmentType = 3
    static let noteType = 28
    static let annotationType = 1
    static let journalArticleType = 22
    static let conferencePaperType = 11
    static let preprintType = 31
    static let bookType = 7
    static let bookSectionType = 8
    static let thesisType = 37
    static let reportType = 34
    static let webpageType = 40
    static let datasetType = 12
    static let filmType = 17 // maps to ItemType.other

    static let authorCreatorType = 10
    static let editorCreatorType = 12

    static let importedFileLinkMode = 0
    static let snapshotLinkMode = 1
    static let linkedFileLinkMode = 2
    static let linkedURLLinkMode = 3

    private static let fieldIDs: [String: Int] = [
        "title": 1, "abstractNote": 2, "date": 6, "DOI": 8, "url": 10, "extra": 19, "ISBN": 28, "archiveID": 107,
        "publicationTitle": 100, "proceedingsTitle": 101, "bookTitle": 102, "conferenceName": 103,
        "repository": 104, "websiteTitle": 105, "university": 106, "institution": 108, "publisher": 109,
        "volume": 110, "issue": 111, "pages": 112,
    ]

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ZoteroFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("zotero.sqlite").path
        guard sqlite3_open(path, &handle) == SQLITE_OK else { throw FixtureError.openFailed }
        try exec(Self.schemaSQL)
    }

    deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: directory)
    }

    func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errmsg) != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw FixtureError.execFailed("\(message)\nSQL:\n\(sql)")
        }
    }

    private func queryInt(_ sql: String) throws -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw FixtureError.execFailed("prepare failed: \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func quote(_ s: String?) -> String {
        s.map(quote) ?? "NULL"
    }

    private static func literal(_ i: Int?) -> String {
        i.map(String.init) ?? "NULL"
    }

    // MARK: - Fixture building blocks

    func addItem(id: Int, type: Int, dateAdded: String = "2026-01-01 00:00:00", dateModified: String? = nil, key: String? = nil) throws {
        try exec("""
            INSERT INTO items (itemID, itemTypeID, dateAdded, dateModified, libraryID, key)
            VALUES (\(id), \(type), \(Self.quote(dateAdded)), \(Self.quote(dateModified ?? dateAdded)), 1, \(Self.quote(key ?? "KEY\(id)")))
            """)
    }

    func addField(item: Int, name: String, value: String) throws {
        guard let fieldID = Self.fieldIDs[name] else {
            fatalError("ZoteroFixtureDB: unknown field name \(name) — add it to fieldIDs")
        }
        try exec("INSERT INTO itemDataValues (value) VALUES (\(Self.quote(value)))")
        let valueID = sqlite3_last_insert_rowid(handle)
        try exec("INSERT INTO itemData (itemID, fieldID, valueID) VALUES (\(item), \(fieldID), \(valueID))")
    }

    func addCreator(item: Int, order: Int, family: String, given: String = "", fieldMode: Int = 0, typeID: Int = authorCreatorType) throws {
        try exec("INSERT INTO creators (firstName, lastName, fieldMode) VALUES (\(Self.quote(given)), \(Self.quote(family)), \(fieldMode))")
        let creatorID = sqlite3_last_insert_rowid(handle)
        try exec("INSERT INTO itemCreators (itemID, creatorID, creatorTypeID, orderIndex) VALUES (\(item), \(creatorID), \(typeID), \(order))")
    }

    @discardableResult
    func addAttachment(id: Int, parent: Int?, linkMode: Int, path: String?, contentType: String? = nil, dateAdded: String = "2026-01-01 00:00:00", key: String? = nil) throws -> Int {
        try addItem(id: id, type: Self.attachmentType, dateAdded: dateAdded, key: key)
        try exec("""
            INSERT INTO itemAttachments (itemID, parentItemID, linkMode, path, contentType)
            VALUES (\(id), \(Self.literal(parent)), \(linkMode), \(Self.quote(path)), \(Self.quote(contentType)))
            """)
        return id
    }

    func addCollection(id: Int, key: String, name: String, parent: Int? = nil) throws {
        try exec("""
            INSERT INTO collections (collectionID, key, collectionName, parentCollectionID, libraryID)
            VALUES (\(id), \(Self.quote(key)), \(Self.quote(name)), \(Self.literal(parent)), 1)
            """)
    }

    func addToCollection(item: Int, collection: Int) throws {
        try exec("INSERT INTO collectionItems (collectionID, itemID) VALUES (\(collection), \(item))")
    }

    func addTag(item: Int, name: String, type: Int = 0) throws {
        let tagID: Int
        if let existing = try queryInt("SELECT tagID FROM tags WHERE name = \(Self.quote(name))") {
            tagID = existing
        } else {
            try exec("INSERT INTO tags (name) VALUES (\(Self.quote(name)))")
            tagID = Int(sqlite3_last_insert_rowid(handle))
        }
        try exec("INSERT INTO itemTags (itemID, tagID, type) VALUES (\(item), \(tagID), \(type))")
    }

    func setTagColors(_ json: String) throws {
        try exec("INSERT INTO syncedSettings (setting, libraryID, value) VALUES ('tagColors', 1, \(Self.quote(json)))")
    }

    func trash(item: Int, dateDeleted: String = "2026-01-01 00:00:00") throws {
        try exec("INSERT INTO deletedItems (itemID, dateDeleted) VALUES (\(item), \(Self.quote(dateDeleted)))")
    }

    private static let schemaSQL = """
    CREATE TABLE libraries (libraryID INTEGER PRIMARY KEY, type TEXT NOT NULL);
    CREATE TABLE itemTypes (itemTypeID INTEGER PRIMARY KEY, typeName TEXT);
    CREATE TABLE items (itemID INTEGER PRIMARY KEY, itemTypeID INT NOT NULL, dateAdded TIMESTAMP NOT NULL, dateModified TIMESTAMP NOT NULL, libraryID INT NOT NULL, key TEXT NOT NULL);
    CREATE TABLE deletedItems (itemID INTEGER PRIMARY KEY, dateDeleted TEXT);
    CREATE TABLE fields (fieldID INTEGER PRIMARY KEY, fieldName TEXT);
    CREATE TABLE itemDataValues (valueID INTEGER PRIMARY KEY, value);
    CREATE TABLE itemData (itemID INT, fieldID INT, valueID INT, PRIMARY KEY (itemID, fieldID));
    CREATE TABLE creatorTypes (creatorTypeID INTEGER PRIMARY KEY, creatorType TEXT);
    CREATE TABLE creators (creatorID INTEGER PRIMARY KEY, firstName TEXT, lastName TEXT, fieldMode INT);
    CREATE TABLE itemCreators (itemID INT, creatorID INT, creatorTypeID INT, orderIndex INT);
    CREATE TABLE itemAttachments (itemID INTEGER PRIMARY KEY, parentItemID INT, linkMode INT, path TEXT, contentType TEXT);
    CREATE TABLE collections (collectionID INTEGER PRIMARY KEY, key TEXT, collectionName TEXT, parentCollectionID INT, libraryID INT);
    CREATE TABLE collectionItems (collectionID INT, itemID INT);
    CREATE TABLE tags (tagID INTEGER PRIMARY KEY, name TEXT);
    CREATE TABLE itemTags (itemID INT, tagID INT, type INT);
    CREATE TABLE syncedSettings (setting TEXT, libraryID INT, value);

    INSERT INTO libraries VALUES (1, 'user');

    INSERT INTO itemTypes VALUES
      (3, 'attachment'), (28, 'note'), (1, 'annotation'),
      (22, 'journalArticle'), (11, 'conferencePaper'), (31, 'preprint'),
      (7, 'book'), (8, 'bookSection'), (37, 'thesis'), (34, 'report'),
      (40, 'webpage'), (12, 'dataset'), (17, 'film');

    INSERT INTO creatorTypes VALUES (10, 'author'), (12, 'editor');

    INSERT INTO fields VALUES
      (1, 'title'), (2, 'abstractNote'), (6, 'date'), (8, 'DOI'), (10, 'url'), (19, 'extra'), (28, 'ISBN'), (107, 'archiveID'),
      (100, 'publicationTitle'), (101, 'proceedingsTitle'), (102, 'bookTitle'), (103, 'conferenceName'),
      (104, 'repository'), (105, 'websiteTitle'), (106, 'university'), (108, 'institution'), (109, 'publisher'),
      (110, 'volume'), (111, 'issue'), (112, 'pages');
    """
}
