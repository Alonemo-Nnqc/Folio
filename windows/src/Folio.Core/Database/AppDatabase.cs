using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Folio.Core;

/// <summary>
/// Owns the SQLite database and its schema. The schema, the migration identifiers and the value encodings (dates as
/// "yyyy-MM-dd HH:mm:ss.fff" UTC, authors as JSON, enums as their raw values) are those of the macOS app (GRDB), so a
/// library folder works in both apps.
/// </summary>
public sealed class AppDatabase : IDisposable
{
    readonly string _connectionString;
    readonly SemaphoreSlim _writeGate = new(1, 1);
    /// <summary>Keeps an in-memory database alive; null for a file.</summary>
    readonly SqliteConnection? _keepAlive;

    /// <summary>Raised after every committed write, on the writing thread.</summary>
    public event Action? Committed;

    AppDatabase(string connectionString, SqliteConnection? keepAlive)
    {
        _connectionString = connectionString;
        _keepAlive = keepAlive;
        using var c = Connect();
        Migrations.Migrate(c);
    }

    public static AppDatabase Open(string path)
    {
        var builder = new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = true, DefaultTimeout = 10 };
        var db = new AppDatabase(builder.ToString(), null);
        // WAL like GRDB's DatabasePool: folio-cli (AI agents) and the app read and write side by side.
        using var c = db.Connect();
        Exec(c, null, "PRAGMA journal_mode = WAL");
        return db;
    }

    /// <summary>In-memory database for tests.</summary>
    public static AppDatabase InMemory()
    {
        var cs = new SqliteConnectionStringBuilder { DataSource = $"folio-{Guid.NewGuid():N}", Mode = SqliteOpenMode.Memory, Cache = SqliteCacheMode.Shared }.ToString();
        var keep = new SqliteConnection(cs);
        keep.Open();
        return new AppDatabase(cs, keep);
    }

    /// <summary>A connection of its own for watching data_version: the number is only comparable within one connection,
    /// and pooled connections take turns.</summary>
    public SqliteConnection OpenWatcher()
    {
        var builder = new SqliteConnectionStringBuilder(_connectionString) { Pooling = false, Mode = SqliteOpenMode.ReadOnly };
        var c = new SqliteConnection(builder.ToString());
        c.Open();
        return c;
    }

    public SqliteConnection Connect()
    {
        var c = new SqliteConnection(_connectionString);
        c.Open();
        Exec(c, null, "PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 10000; PRAGMA synchronous = NORMAL");
        return c;
    }

    public T Read<T>(Func<SqliteConnection, T> body)
    {
        using var c = Connect();
        return body(c);
    }

    /// <summary>Runs <paramref name="body"/> in one IMMEDIATE transaction, then raises Committed.</summary>
    public T Write<T>(Func<SqliteConnection, SqliteTransaction, T> body)
    {
        _writeGate.Wait();
        T result;
        try
        {
            using var c = Connect();
            using var tx = c.BeginTransaction(deferred: false);
            result = body(c, tx);
            tx.Commit();
        }
        finally
        {
            _writeGate.Release();
        }
        Committed?.Invoke();
        return result;
    }

    public void Write(Action<SqliteConnection, SqliteTransaction> body) => Write<object?>((c, t) => { body(c, t); return null; });

    /// <summary>SQLite's data_version: changes when another connection (e.g. folio-cli) commits.</summary>
    public long DataVersion(SqliteConnection c) => Convert.ToInt64(Scalar(c, null, "PRAGMA data_version"));

    public void Dispose()
    {
        _keepAlive?.Dispose();
        SqliteConnection.ClearAllPools();
    }

    // MARK: Command helpers. SQL uses '?' placeholders, as in the macOS sources.

    public static SqliteCommand Command(SqliteConnection c, SqliteTransaction? tx, string sql, params object?[] args)
    {
        var cmd = c.CreateCommand();
        cmd.Transaction = tx;
        var text = new StringBuilder(sql.Length + 16);
        int index = 0;
        bool quoted = false;
        foreach (var ch in sql)
        {
            if (ch == '\'') quoted = !quoted;
            if (ch == '?' && !quoted)
            {
                text.Append("@p").Append(index.ToString(CultureInfo.InvariantCulture));
                index++;
            }
            else text.Append(ch);
        }
        cmd.CommandText = text.ToString();
        for (int i = 0; i < args.Length; i++) cmd.Parameters.AddWithValue($"@p{i}", ToDb(args[i]));
        return cmd;
    }

    public static int Exec(SqliteConnection c, SqliteTransaction? tx, string sql, params object?[] args)
    {
        using var cmd = Command(c, tx, sql, args);
        return cmd.ExecuteNonQuery();
    }

    public static object? Scalar(SqliteConnection c, SqliteTransaction? tx, string sql, params object?[] args)
    {
        using var cmd = Command(c, tx, sql, args);
        var v = cmd.ExecuteScalar();
        return v is DBNull ? null : v;
    }

    public static List<T> Query<T>(SqliteConnection c, SqliteTransaction? tx, string sql, Func<SqliteDataReader, T> map, params object?[] args)
    {
        using var cmd = Command(c, tx, sql, args);
        using var r = cmd.ExecuteReader();
        var list = new List<T>();
        while (r.Read()) list.Add(map(r));
        return list;
    }

    public static List<string> Strings(SqliteConnection c, SqliteTransaction? tx, string sql, params object?[] args) =>
        Query(c, tx, sql, r => r.IsDBNull(0) ? "" : r.GetString(0), args);

    public static string Placeholders(int count) => string.Join(",", Enumerable.Repeat("?", count));

    static object ToDb(object? v) => v switch
    {
        null => DBNull.Value,
        DateTime d => FormatDate(d),
        bool b => b ? 1 : 0,
        Enum e => Convert.ToInt32(e, CultureInfo.InvariantCulture),
        _ => v,
    };

    // MARK: Value encodings shared with GRDB

    public static string FormatDate(DateTime d) =>
        (d.Kind == DateTimeKind.Local ? d.ToUniversalTime() : d).ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);

    public static DateTime ParseDate(string s)
    {
        if (DateTime.TryParseExact(s, ["yyyy-MM-dd HH:mm:ss.fff", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss.fff", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"],
                                   CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d))
            return DateTime.SpecifyKind(d, DateTimeKind.Utc);
        if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var unix))
            return DateTime.UnixEpoch.AddSeconds(unix);
        return DateTime.Parse(s, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
    }

    public static DateTime? Date(SqliteDataReader r, string column)
    {
        int i = r.GetOrdinal(column);
        if (r.IsDBNull(i)) return null;
        var v = r.GetValue(i);
        return v switch
        {
            string s => ParseDate(s),
            long l => DateTime.UnixEpoch.AddSeconds(l),
            double dd => DateTime.UnixEpoch.AddSeconds(dd),
            _ => ParseDate(Convert.ToString(v, CultureInfo.InvariantCulture)!),
        };
    }

    public static string? Str(SqliteDataReader r, string column)
    {
        int i = r.GetOrdinal(column);
        return r.IsDBNull(i) ? null : Convert.ToString(r.GetValue(i), CultureInfo.InvariantCulture);
    }

    public static long? Long(SqliteDataReader r, string column)
    {
        int i = r.GetOrdinal(column);
        return r.IsDBNull(i) ? null : Convert.ToInt64(r.GetValue(i), CultureInfo.InvariantCulture);
    }

    public static double Double(SqliteDataReader r, string column) => Convert.ToDouble(r.GetValue(r.GetOrdinal(column)), CultureInfo.InvariantCulture);

    static readonly JsonSerializerOptions AuthorJson = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static string EncodeAuthors(List<Author> authors) => JsonSerializer.Serialize(authors, AuthorJson);

    public static List<Author> DecodeAuthors(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.EnumerateArray().Select(e => new Author(
                e.TryGetProperty("family", out var f) ? f.GetString() ?? "" : "",
                e.TryGetProperty("given", out var g) ? g.GetString() ?? "" : "")).ToList();
        }
        catch (JsonException) { return []; }
    }
}

static class Migrations
{
    /// <summary>The macOS app's migrations, with GRDB's bookkeeping table, so each app recognizes the other's schema.</summary>
    static readonly (string Id, string Sql)[] All =
    [
        ("v1", """
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
            """),
        ("v2", """
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
            """),
        ("v3", "ALTER TABLE libraryGroup ADD COLUMN colorHex TEXT"),
        ("v4", "ALTER TABLE file ADD COLUMN translatedBy TEXT"),
    ];

    public static void Migrate(SqliteConnection c)
    {
        AppDatabase.Exec(c, null, "CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)");
        var done = AppDatabase.Strings(c, null, "SELECT identifier FROM grdb_migrations").ToHashSet();
        foreach (var (id, sql) in All)
        {
            if (done.Contains(id)) continue;
            using var tx = c.BeginTransaction();
            AppDatabase.Exec(c, tx, sql);
            if (id == "v4") BackfillTranslatedBy(c, tx);
            AppDatabase.Exec(c, tx, "INSERT INTO grdb_migrations (identifier) VALUES (?)", id);
            tx.Commit();
        }
    }

    /// <summary>v4: who translated a file, read from Folio's earlier translation names.</summary>
    static void BackfillTranslatedBy(SqliteConnection c, SqliteTransaction tx)
    {
        var rows = AppDatabase.Query(c, tx, "SELECT id, relativePath FROM file WHERE translationKind IS NOT NULL",
                                     r => (r.GetString(0), r.GetString(1)));
        foreach (var (id, path) in rows)
        {
            var stem = Path.GetFileNameWithoutExtension(path.Split('/').Last());
            if (FileNamer.TranslatedBy(stem) is { } by)
                AppDatabase.Exec(c, tx, "UPDATE file SET translatedBy = ? WHERE id = ?", by, id);
        }
    }
}
