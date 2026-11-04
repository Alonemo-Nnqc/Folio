using Microsoft.Data.Sqlite;
using static Folio.Core.AppDatabase;

namespace Folio.Core;

/// <summary>Reading and writing records, column for column as GRDB does on macOS.</summary>
static class Records
{
    public static Item ReadItem(SqliteDataReader r)
    {
        var item = new Item((ItemKind)Long(r, "kind")!.Value, Str(r, "title") ?? "", Date(r, "dateAdded"), Str(r, "id"))
        {
            Type = ItemTypes.Parse(Str(r, "type")),
            Authors = DecodeAuthors(Str(r, "authors")),
            Year = (int?)Long(r, "year"),
            Date = Str(r, "date"),
            Source = Str(r, "source"),
            Volume = Str(r, "volume"),
            Issue = Str(r, "issue"),
            Pages = Str(r, "pages"),
            Publisher = Str(r, "publisher"),
            Doi = Str(r, "doi"),
            ArxivId = Str(r, "arxivId"),
            Isbn = Str(r, "isbn"),
            Url = Str(r, "url"),
            Abstract = Str(r, "abstract"),
            CitationKey = Str(r, "citationKey"),
            Rating = (int)(Long(r, "rating") ?? 0),
            ReadStatus = (ReadStatus)(Long(r, "readStatus") ?? 0),
            DefaultFileId = Str(r, "defaultFileId"),
            MetadataState = (MetadataState)(Long(r, "metadataState") ?? 0),
            RetryCount = (int)(Long(r, "retryCount") ?? 0),
            OriginItemId = Str(r, "originItemId"),
            DateModified = Date(r, "dateModified") ?? DateTime.UtcNow,
            TrashedAt = Date(r, "trashedAt"),
        };
        return item;
    }

    static object?[] ItemValues(Item i) =>
    [
        i.Id, (int)i.Kind, i.Type.Raw(), i.Title, EncodeAuthors(i.Authors), i.Year, i.Date, i.Source, i.Volume, i.Issue, i.Pages,
        i.Publisher, i.Doi, i.ArxivId, i.Isbn, i.Url, i.Abstract, i.CitationKey, i.Rating, (int)i.ReadStatus, i.DefaultFileId,
        (int)i.MetadataState, i.RetryCount, i.OriginItemId, i.DateAdded, i.DateModified, i.TrashedAt,
    ];

    const string ItemColumns = "id, kind, type, title, authors, year, date, source, volume, issue, pages, publisher, doi, arxivId, isbn, url, " +
                               "abstract, citationKey, rating, readStatus, defaultFileId, metadataState, retryCount, originItemId, dateAdded, dateModified, trashedAt";

    public static void Insert(SqliteConnection c, SqliteTransaction tx, Item i) =>
        Exec(c, tx, $"INSERT INTO item ({ItemColumns}) VALUES ({Placeholders(27)})", ItemValues(i));

    public static void Update(SqliteConnection c, SqliteTransaction tx, Item i)
    {
        var values = ItemValues(i);
        var sets = string.Join(", ", ItemColumns.Split(", ").Skip(1).Select(col => $"{col} = ?"));
        Exec(c, tx, $"UPDATE item SET {sets} WHERE id = ?", [.. values.Skip(1), i.Id]);
    }

    public static Item? FetchItem(SqliteConnection c, SqliteTransaction? tx, string id) =>
        Query(c, tx, "SELECT * FROM item WHERE id = ?", ReadItem, id).FirstOrDefault();

    public static FileRecord ReadFile(SqliteDataReader r)
    {
        var tk = Long(r, "translationKind");
        return new FileRecord(Str(r, "itemId")!, Str(r, "relativePath")!, Str(r, "originalName") ?? "", Long(r, "size") ?? 0,
                              Str(r, "sha256") ?? "", Date(r, "modifiedAt") ?? DateTime.UtcNow, Date(r, "dateAdded"),
                              (FulltextState)(Long(r, "fulltextState") ?? 0), Str(r, "id"))
        {
            OriginalSha256 = Str(r, "originalSha256") ?? "",
            TranslationOf = Str(r, "translationOf"),
            TranslationKind = tk == null ? null : (TranslationKind)tk.Value,
            TranslatedBy = Str(r, "translatedBy"),
        };
    }

    static object?[] FileValues(FileRecord f) =>
    [
        f.Id, f.ItemId, f.RelativePath, f.OriginalName, f.Size, f.Sha256, f.OriginalSha256, f.ModifiedAt, f.DateAdded,
        (int)f.FulltextState, f.TranslationOf, f.TranslationKind == null ? null : (int)f.TranslationKind.Value, f.TranslatedBy,
    ];

    const string FileColumns = "id, itemId, relativePath, originalName, size, sha256, originalSha256, modifiedAt, dateAdded, fulltextState, translationOf, translationKind, translatedBy";

    public static void Insert(SqliteConnection c, SqliteTransaction tx, FileRecord f) =>
        Exec(c, tx, $"INSERT INTO file ({FileColumns}) VALUES ({Placeholders(13)})", FileValues(f));

    public static void Update(SqliteConnection c, SqliteTransaction tx, FileRecord f)
    {
        var sets = string.Join(", ", FileColumns.Split(", ").Skip(1).Select(col => $"{col} = ?"));
        Exec(c, tx, $"UPDATE file SET {sets} WHERE id = ?", [.. FileValues(f).Skip(1), f.Id]);
    }

    public static FileRecord? FetchFile(SqliteConnection c, SqliteTransaction? tx, string id) =>
        Query(c, tx, "SELECT * FROM file WHERE id = ?", ReadFile, id).FirstOrDefault();

    public static List<FileRecord> FilesOf(SqliteConnection c, SqliteTransaction? tx, string itemId) =>
        Query(c, tx, "SELECT * FROM file WHERE itemId = ? ORDER BY dateAdded, id", ReadFile, itemId);

    public static LibraryGroup ReadGroup(SqliteDataReader r) =>
        new(Str(r, "name") ?? "", AppDatabase.Double(r, "position"), Str(r, "parentId"), Date(r, "dateCreated"), Str(r, "id"))
        {
            ColorHex = Str(r, "colorHex"),
        };

    public static void Insert(SqliteConnection c, SqliteTransaction tx, LibraryGroup g) =>
        Exec(c, tx, "INSERT INTO libraryGroup (id, parentId, name, position, dateCreated, colorHex) VALUES (?, ?, ?, ?, ?, ?)",
             g.Id, g.ParentId, g.Name, g.Position, g.DateCreated, g.ColorHex);

    public static void Update(SqliteConnection c, SqliteTransaction tx, LibraryGroup g) =>
        Exec(c, tx, "UPDATE libraryGroup SET parentId = ?, name = ?, position = ?, dateCreated = ?, colorHex = ? WHERE id = ?",
             g.ParentId, g.Name, g.Position, g.DateCreated, g.ColorHex, g.Id);

    public static LibraryGroup? FetchGroup(SqliteConnection c, SqliteTransaction? tx, string id) =>
        Query(c, tx, "SELECT * FROM libraryGroup WHERE id = ?", ReadGroup, id).FirstOrDefault();

    public static Tag ReadTag(SqliteDataReader r) =>
        new(Str(r, "name") ?? "", Str(r, "colorHex") ?? "#8E8E93", AppDatabase.Double(r, "position"), Str(r, "id"));

    public static ReadingState ReadReading(SqliteDataReader r) =>
        new(Str(r, "fileId")!, (int)(Long(r, "pageIndex") ?? 0), AppDatabase.Double(r, "pointX"), AppDatabase.Double(r, "pointY"),
            AppDatabase.Double(r, "scale"), (Long(r, "autoScale") ?? 0) != 0, (int)(Long(r, "displayMode") ?? 0),
            Date(r, "dateModified") ?? DateTime.UtcNow);
}
