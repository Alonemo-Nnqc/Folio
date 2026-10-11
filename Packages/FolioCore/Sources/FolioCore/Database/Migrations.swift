import GRDB

enum Migrations {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE item (
              id TEXT PRIMARY KEY, kind INTEGER NOT NULL,
              type TEXT NOT NULL, title TEXT NOT NULL, authors TEXT NOT NULL DEFAULT '[]',
              year INTEGER, date TEXT, source TEXT, volume TEXT, issue TEXT, pages TEXT, publisher TEXT,
              doi TEXT, arxivId TEXT, isbn TEXT, url TEXT, abstract TEXT, citationKey TEXT,
              rating INTEGER NOT NULL DEFAULT 0, readStatus INTEGER NOT NULL DEFAULT 0,
              defaultFileId TEXT, metadataState INTEGER NOT NULL DEFAULT 0,
              retryCount INTEGER NOT NULL DEFAULT 0, originItemId TEXT,
              dateAdded DATETIME NOT NULL, dateModified DATETIME NOT NULL, trashedAt DATETIME);
            CREATE INDEX item_doi ON item(doi);
            CREATE INDEX item_trashed ON item(trashedAt);
            CREATE TABLE file (
              id TEXT PRIMARY KEY, itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
              relativePath TEXT NOT NULL UNIQUE, originalName TEXT NOT NULL, size INTEGER NOT NULL,
              sha256 TEXT NOT NULL, originalSha256 TEXT NOT NULL, modifiedAt DATETIME NOT NULL,
              dateAdded DATETIME NOT NULL, fulltextState INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX file_item ON file(itemId);
            CREATE INDEX file_sha ON file(sha256);
            CREATE INDEX file_osha ON file(originalSha256);
            CREATE TABLE libraryGroup (
              id TEXT PRIMARY KEY, parentId TEXT REFERENCES libraryGroup(id) ON DELETE CASCADE,
              name TEXT NOT NULL, position DOUBLE NOT NULL, dateCreated DATETIME NOT NULL);
            CREATE TABLE itemGroup (
              itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
              groupId TEXT NOT NULL REFERENCES libraryGroup(id) ON DELETE CASCADE,
              dateAdded DATETIME NOT NULL, PRIMARY KEY (itemId, groupId));
            CREATE INDEX itemGroup_group ON itemGroup(groupId);
            CREATE TABLE tag (
              id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE,
              colorHex TEXT NOT NULL, position DOUBLE NOT NULL);
            CREATE TABLE itemTag (
              itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
              tagId TEXT NOT NULL REFERENCES tag(id) ON DELETE CASCADE, PRIMARY KEY (itemId, tagId));
            CREATE TABLE itemOrder (
              scope TEXT NOT NULL, itemId TEXT NOT NULL REFERENCES item(id) ON DELETE CASCADE,
              position DOUBLE NOT NULL, PRIMARY KEY (scope, itemId));
            CREATE TABLE viewSort (scope TEXT PRIMARY KEY, sortColumn TEXT, ascending BOOLEAN NOT NULL);
            CREATE VIRTUAL TABLE fulltext USING fts5(fileId UNINDEXED, content, tokenize = 'unicode61 remove_diacritics 2');
            """)
        }
        // v2.0: item notes, per-file reading positions, translated files linked to their source.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
            CREATE TABLE note (
              itemId TEXT PRIMARY KEY REFERENCES item(id) ON DELETE CASCADE,
              content TEXT NOT NULL, dateModified DATETIME NOT NULL);
            CREATE TABLE readingState (
              fileId TEXT PRIMARY KEY REFERENCES file(id) ON DELETE CASCADE,
              pageIndex INTEGER NOT NULL, pointX DOUBLE NOT NULL, pointY DOUBLE NOT NULL,
              scale DOUBLE NOT NULL, autoScale BOOLEAN NOT NULL, displayMode INTEGER NOT NULL,
              dateModified DATETIME NOT NULL);
            ALTER TABLE file ADD COLUMN translationOf TEXT;
            ALTER TABLE file ADD COLUMN translationKind INTEGER;
            """)
        }
    }
}
