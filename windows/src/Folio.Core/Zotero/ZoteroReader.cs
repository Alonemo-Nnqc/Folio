using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Services;
using Microsoft.Data.Sqlite;

namespace Folio.Core.Zotero;

// Port of macos/.../FolioZotero: reads a copy of a Zotero library and prepares it for Library.ImportPrepared.
// Only ever reads the user's Zotero folder; the database is copied out first (Zotero keeps its own copy locked).

public sealed class ZoteroReadOptions
{
    /// <summary>Zotero's automatically generated tags (publisher keywords, arXiv categories). Off by default.</summary>
    public bool IncludeAutomaticTags { get; set; }
}

/// <summary>Counts for the import sheet and its summary.</summary>
public sealed class ZoteroReadReport
{
    public int RegularItems, StandaloneFiles, Collections, Tags, AutomaticTagsAvailable;
    public int SkippedNotes, SkippedSnapshots, SkippedLinks, SkippedTrashed, SkippedAnnotations;
}

public sealed class ZoteroReaderException(string message) : Exception(message);

/// <summary>Locates a Zotero data directory. Only ever reads files.</summary>
public static class ZoteroLocator
{
    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>extensions.zotero.dataDir from the user's Zotero profile; else ~\Zotero.</summary>
    public static string? DefaultDataDirectory()
    {
        if (Pref("extensions.zotero.dataDir") is { } raw && Unquote(raw) is { } fromPrefs && Directory.Exists(fromPrefs)) return fromPrefs;
        var fallback = Path.Combine(Home, "Zotero");
        return Directory.Exists(fallback) ? fallback : null;
    }

    /// <summary>extensions.zotero.baseAttachmentPath, for linked attachments stored relative to it.</summary>
    public static string? BaseAttachmentPath() => Pref("extensions.zotero.baseAttachmentPath") is { } raw ? Unquote(raw) : null;

    static IEnumerable<string> ProfilePrefsFiles()
    {
        var bases = OperatingSystem.IsWindows()
            ? new[] { Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Zotero", "Zotero", "Profiles") }
            : [Path.Combine(Home, "Library/Application Support/Zotero/Profiles"), Path.Combine(Home, ".zotero/zotero")];
        foreach (var b in bases)
        {
            if (!Directory.Exists(b)) continue;
            foreach (var profile in Directory.EnumerateDirectories(b))
            {
                var prefs = Path.Combine(profile, "prefs.js");
                if (File.Exists(prefs)) yield return prefs;
            }
        }
    }

    static string? Pref(string name)
    {
        foreach (var file in ProfilePrefsFiles())
        {
            try { if (ValueForPref(name, File.ReadAllText(file)) is { } v) return v; } catch { }
        }
        return null;
    }

    /// <summary>The raw (still quoted) value of user_pref("name", ...).</summary>
    public static string? ValueForPref(string name, string text)
    {
        var marker = $"user_pref(\"{name}\",";
        int at = text.IndexOf(marker, StringComparison.Ordinal);
        if (at < 0) return null;
        var rest = text[(at + marker.Length)..];
        int semicolon = rest.IndexOf(';');
        if (semicolon < 0) return null;
        var segment = rest[..semicolon].Trim();
        if (segment.EndsWith(')')) segment = segment[..^1];
        return segment.Trim();
    }

    /// <summary>prefs.js strings are JavaScript literals: Windows paths come with doubled backslashes.</summary>
    public static string? Unquote(string value)
    {
        if (value.Length < 2 || value[0] != '"' || value[^1] != '"') return null;
        try { return JsonSerializer.Deserialize<string>(value); }
        catch { return value[1..^1].Replace("\\\"", "\"").Replace("\\\\", "\\"); }
    }
}

public sealed class ZoteroReader : IDisposable
{
    readonly string _dataDirectory;
    readonly string _temp;
    readonly string _database;
    readonly string? _baseAttachmentPath;

    /// <summary>Copies zotero.sqlite (and its WAL) out of the data directory and folds the WAL into the copy.</summary>
    public ZoteroReader(string dataDirectory)
    {
        _dataDirectory = dataDirectory;
        var source = Path.Combine(dataDirectory, "zotero.sqlite");
        if (!File.Exists(source)) throw new ZoteroReaderException(Loc.S("在 %@ 中找不到 zotero.sqlite", dataDirectory));
        _temp = Path.Combine(Path.GetTempPath(), $"FolioZotero-{Guid.NewGuid()}");
        Directory.CreateDirectory(_temp);
        _database = Path.Combine(_temp, "zotero.sqlite");
        Copy(source, _database);
        foreach (var suffix in new[] { "-wal", "-shm" })
            if (File.Exists(source + suffix)) try { Copy(source + suffix, _database + suffix); } catch { }
        using (var c = new SqliteConnection($"Data Source={_database};Pooling=False"))
        {
            c.Open();
            using var cmd = c.CreateCommand();
            cmd.CommandText = "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode = DELETE;";
            try { cmd.ExecuteNonQuery(); } catch { }
        }
        foreach (var suffix in new[] { "-wal", "-shm", "-journal" }) try { File.Delete(_database + suffix); } catch { }
        _baseAttachmentPath = ZoteroLocator.BaseAttachmentPath();
    }

    /// <summary>Copies a file Zotero may have open (shared read).</summary>
    static void Copy(string from, string to)
    {
        using var input = new FileStream(from, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var output = File.Create(to);
        input.CopyTo(output);
    }

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        try { Directory.Delete(_temp, true); } catch { }
    }

    public (PreparedLibrary Library, ZoteroReadReport Report) Read(ZoteroReadOptions options)
    {
        using var c = new SqliteConnection($"Data Source={_database};Mode=ReadOnly;Pooling=False");
        c.Open();
        var raw = RawLoader.Load(c);
        return Builder.Build(raw, _dataDirectory, _baseAttachmentPath, options);
    }

    /// <summary>Counts only, for the import sheet's preview.</summary>
    public ZoteroReadReport Probe() => Read(new ZoteroReadOptions()).Report;

    // MARK: Raw records

    sealed record RawItem(long ItemId, long TypeId, DateTime DateAdded, DateTime DateModified);
    sealed record RawAttachment(long ItemId, string Key, long? ParentItemId, int LinkMode, string? Path, string? ContentType, DateTime DateAdded, DateTime DateModified);
    sealed record RawCreator(int OrderIndex, string? FirstName, string? LastName, int FieldMode);
    sealed record RawCollection(long Id, string Key, string Name, long? ParentId);

    sealed class RawLibrary
    {
        public Dictionary<long, string> TypeNames = [];
        public List<RawItem> Items = [];
        public HashSet<long> Deleted = [];
        public Dictionary<long, Dictionary<string, string>> Fields = [];
        public Dictionary<long, List<RawCreator>> Creators = [];
        public Dictionary<long, List<RawAttachment>> AttachmentsByParent = [];
        public List<RawAttachment> Standalone = [];
        public List<RawCollection> Collections = [];
        public Dictionary<long, List<long>> ItemsByCollection = [];
        public Dictionary<long, List<(string Name, int Type)>> Tags = [];
        public HashSet<string> AutomaticTags = [];
        public Dictionary<string, string> TagColors = [];
    }

    static class RawLoader
    {
        static List<T> Rows<T>(SqliteConnection c, string sql, Func<SqliteDataReader, T> map, params object[] args)
        {
            using var cmd = c.CreateCommand();
            cmd.CommandText = sql;
            for (int i = 0; i < args.Length; i++) cmd.Parameters.AddWithValue($"$p{i}", args[i]);
            using var r = cmd.ExecuteReader();
            var list = new List<T>();
            while (r.Read()) list.Add(map(r));
            return list;
        }

        static string? S(SqliteDataReader r, string name) { int i = r.GetOrdinal(name); return r.IsDBNull(i) ? null : Convert.ToString(r.GetValue(i), CultureInfo.InvariantCulture); }
        static long L(SqliteDataReader r, string name) { int i = r.GetOrdinal(name); return r.IsDBNull(i) ? 0 : r.GetInt64(i); }
        static long? LN(SqliteDataReader r, string name) { int i = r.GetOrdinal(name); return r.IsDBNull(i) ? null : r.GetInt64(i); }

        public static RawLibrary Load(SqliteConnection c)
        {
            var library = Rows(c, "SELECT libraryID FROM libraries WHERE type = 'user' LIMIT 1", r => r.GetInt64(0));
            if (library.Count == 0) throw new ZoteroReaderException(Loc.S("Zotero 数据库中没有个人文库"));
            long id = library[0];
            var raw = new RawLibrary();
            foreach (var (typeId, name) in Rows(c, "SELECT itemTypeID, typeName FROM itemTypes", r => (L(r, "itemTypeID"), S(r, "typeName") ?? ""))) raw.TypeNames[typeId] = name;
            raw.Deleted = Rows(c, "SELECT itemID FROM deletedItems", r => r.GetInt64(0)).ToHashSet();
            raw.Items = Rows(c, "SELECT itemID, itemTypeID, dateAdded, dateModified FROM items WHERE libraryID = $p0",
                r => new RawItem(L(r, "itemID"), L(r, "itemTypeID"), ZoteroDate.ParseTimestamp(S(r, "dateAdded")), ZoteroDate.ParseTimestamp(S(r, "dateModified"))), id);
            foreach (var (itemId, field, value) in Rows(c, """
                SELECT id.itemID AS itemID, f.fieldName AS fieldName, v.value AS value
                FROM itemData id JOIN fields f ON f.fieldID = id.fieldID JOIN itemDataValues v ON v.valueID = id.valueID
                JOIN items i ON i.itemID = id.itemID WHERE i.libraryID = $p0
                """, r => (L(r, "itemID"), S(r, "fieldName") ?? "", S(r, "value") ?? ""), id))
            {
                if (value.Length == 0) continue;
                if (!raw.Fields.TryGetValue(itemId, out var fields)) raw.Fields[itemId] = fields = [];
                fields[field] = value;
            }
            var author = Rows(c, "SELECT creatorTypeID FROM creatorTypes WHERE creatorType = 'author'", r => r.GetInt64(0));
            if (author.Count > 0)
                foreach (var (itemId, creator) in Rows(c, """
                    SELECT ic.itemID AS itemID, ic.orderIndex AS orderIndex, c.firstName AS firstName, c.lastName AS lastName, c.fieldMode AS fieldMode
                    FROM itemCreators ic JOIN creators c ON c.creatorID = ic.creatorID JOIN items i ON i.itemID = ic.itemID
                    WHERE i.libraryID = $p0 AND ic.creatorTypeID = $p1
                    """, r => (L(r, "itemID"), new RawCreator((int)L(r, "orderIndex"), S(r, "firstName"), S(r, "lastName"), (int)L(r, "fieldMode"))), id, author[0]))
                {
                    if (!raw.Creators.TryGetValue(itemId, out var list)) raw.Creators[itemId] = list = [];
                    list.Add(creator);
                }
            foreach (var a in Rows(c, """
                SELECT ia.itemID AS itemID, i.key AS key, ia.parentItemID AS parentItemID, ia.linkMode AS linkMode, ia.path AS path,
                       ia.contentType AS contentType, i.dateAdded AS dateAdded, i.dateModified AS dateModified
                FROM itemAttachments ia JOIN items i ON i.itemID = ia.itemID WHERE i.libraryID = $p0
                """, r => new RawAttachment(L(r, "itemID"), S(r, "key") ?? "", LN(r, "parentItemID"), (int)L(r, "linkMode"), S(r, "path"), S(r, "contentType"),
                    ZoteroDate.ParseTimestamp(S(r, "dateAdded")), ZoteroDate.ParseTimestamp(S(r, "dateModified"))), id))
            {
                if (a.ParentItemId is { } parent)
                {
                    if (!raw.AttachmentsByParent.TryGetValue(parent, out var list)) raw.AttachmentsByParent[parent] = list = [];
                    list.Add(a);
                }
                else raw.Standalone.Add(a);
            }
            raw.Collections = Rows(c, "SELECT collectionID, key, collectionName, parentCollectionID FROM collections WHERE libraryID = $p0",
                r => new RawCollection(L(r, "collectionID"), S(r, "key") ?? "", S(r, "collectionName") ?? "", LN(r, "parentCollectionID")), id);
            foreach (var (collection, item) in Rows(c, """
                SELECT ci.collectionID AS collectionID, ci.itemID AS itemID FROM collectionItems ci
                JOIN collections c ON c.collectionID = ci.collectionID WHERE c.libraryID = $p0
                """, r => (L(r, "collectionID"), L(r, "itemID")), id))
            {
                if (!raw.ItemsByCollection.TryGetValue(collection, out var list)) raw.ItemsByCollection[collection] = list = [];
                list.Add(item);
            }
            foreach (var (item, name, type) in Rows(c, """
                SELECT it.itemID AS itemID, t.name AS name, it.type AS type FROM itemTags it
                JOIN tags t ON t.tagID = it.tagID JOIN items i ON i.itemID = it.itemID WHERE i.libraryID = $p0
                """, r => (L(r, "itemID"), S(r, "name") ?? "", (int)L(r, "type")), id))
            {
                if (!raw.Tags.TryGetValue(item, out var list)) raw.Tags[item] = list = [];
                list.Add((name, type));
                if (type == 1) raw.AutomaticTags.Add(name);
            }
            var colors = Rows(c, "SELECT value FROM syncedSettings WHERE setting = 'tagColors' AND libraryID = $p0", r => S(r, "value"), id).FirstOrDefault();
            if (colors != null) raw.TagColors = TagColors(colors);
            return raw;
        }
    }

    /// <summary>[{"name": "...", "color": "#RRGGBB"}] → lowercased name → colour.</summary>
    public static Dictionary<string, string> TagColors(string json)
    {
        var result = new Dictionary<string, string>();
        try
        {
            using var doc = JsonDocument.Parse(json);
            foreach (var e in doc.RootElement.EnumerateArray())
                if (e.TryGetProperty("name", out var n) && e.TryGetProperty("color", out var col) && n.GetString() is { } name && col.GetString() is { } color)
                    result[name.ToLowerInvariant()] = color;
        }
        catch { }
        return result;
    }

    public const string DefaultTagColor = "#8E8E93";

    // MARK: Building

    static class Builder
    {
        static readonly HashSet<string> NonRegular = ["attachment", "note", "annotation"];
        const int ImportedUrl = 1, LinkedUrl = 3;

        public static (PreparedLibrary, ZoteroReadReport) Build(RawLibrary raw, string dataDirectory, string? baseAttachmentPath, ZoteroReadOptions options)
        {
            var report = new ZoteroReadReport();
            var (groups, exportKey) = Flatten(raw.Collections);
            report.Collections = groups.Count;
            var collectionsByItem = new Dictionary<long, List<long>>();
            foreach (var (collection, items) in raw.ItemsByCollection)
                foreach (var item in items)
                {
                    if (!collectionsByItem.TryGetValue(item, out var list)) collectionsByItem[item] = list = [];
                    list.Add(collection);
                }
            List<string> GroupKeys(long item) => (collectionsByItem.GetValueOrDefault(item) ?? []).Select(c => exportKey.GetValueOrDefault(c)).OfType<string>().Distinct().Order().ToList();
            List<string> TagNames(long item) => (raw.Tags.GetValueOrDefault(item) ?? []).Where(t => t.Type == 0 || (t.Type == 1 && options.IncludeAutomaticTags))
                .Select(t => t.Name).Distinct().Order().ToList();
            PreparedFile Resolved(RawAttachment a)
            {
                var path = ResolvePath(dataDirectory, a.Key, a.Path, baseAttachmentPath);
                var name = Path.GetFileName(path);
                var translation = Translation(name, raw.Fields.GetValueOrDefault(a.ItemId)?.GetValueOrDefault("title"));
                return new PreparedFile(path, name, a.DateAdded, translation?.Kind, translation?.Service);
            }

            var keptByParent = new Dictionary<long, List<PreparedFile>>();
            var keptStandalone = new List<RawAttachment>();
            void Keep(RawAttachment a)
            {
                if (a.ParentItemId is { } parent)
                {
                    if (!keptByParent.TryGetValue(parent, out var list)) keptByParent[parent] = list = [];
                    list.Add(Resolved(a));
                }
                else keptStandalone.Add(a);
            }
            void Classify(RawAttachment a)
            {
                if (raw.Deleted.Contains(a.ItemId)) { report.SkippedTrashed++; return; }
                switch (a.LinkMode)
                {
                    case ImportedUrl:
                        if (IsHtmlSnapshot(a.ContentType, a.Path)) report.SkippedSnapshots++; else Keep(a);
                        break;
                    case LinkedUrl: report.SkippedLinks++; break;
                    default: Keep(a); break;
                }
            }
            foreach (var list in raw.AttachmentsByParent.Values) foreach (var a in list) Classify(a);
            foreach (var a in raw.Standalone) Classify(a);
            foreach (var item in raw.Items)
            {
                if (!raw.TypeNames.TryGetValue(item.TypeId, out var name)) continue;
                if (name == "note") { if (raw.Deleted.Contains(item.ItemId)) report.SkippedTrashed++; else report.SkippedNotes++; }
                else if (name == "annotation") { if (raw.Deleted.Contains(item.ItemId)) report.SkippedTrashed++; else report.SkippedAnnotations++; }
            }

            var entries = new List<PreparedEntry>();
            var usedTags = new HashSet<string>();
            foreach (var item in raw.Items)
            {
                if (!raw.TypeNames.TryGetValue(item.TypeId, out var name) || NonRegular.Contains(name)) continue;
                if (raw.Deleted.Contains(item.ItemId)) { report.SkippedTrashed++; continue; }
                var metadata = BuildMetadata(name, raw.Fields.GetValueOrDefault(item.ItemId) ?? [], raw.Creators.GetValueOrDefault(item.ItemId) ?? []);
                var tags = TagNames(item.ItemId);
                usedTags.UnionWith(tags);
                entries.Add(new PreparedEntry(metadata, Order(keptByParent.GetValueOrDefault(item.ItemId) ?? []), GroupKeys(item.ItemId), tags, item.DateAdded, item.DateModified));
                report.RegularItems++;
            }
            foreach (var a in keptStandalone)
            {
                var tags = TagNames(a.ItemId);
                usedTags.UnionWith(tags);
                entries.Add(new PreparedEntry(null, [Resolved(a)], GroupKeys(a.ItemId), tags, a.DateAdded, a.DateModified));
                report.StandaloneFiles++;
            }
            var preparedTags = usedTags.Order().Select(n => new PreparedTag(n, raw.TagColors.GetValueOrDefault(n.ToLowerInvariant()) ?? DefaultTagColor)).ToList();
            report.Tags = preparedTags.Count;
            report.AutomaticTagsAvailable = raw.AutomaticTags.Count;
            return (new PreparedLibrary(groups, preparedTags, entries), report);
        }

        /// <summary>Collections on levels 1–4 become groups (SIDE-17); deeper ones give their items to their fourth-level ancestor.</summary>
        static (List<PreparedGroup>, Dictionary<long, string>) Flatten(List<RawCollection> collections)
        {
            const int maximumDepth = LibraryGroup.MaximumDepth;
            var byId = collections.ToDictionary(c => c.Id);
            int Depth(long id)
            {
                int depth = 1;
                var seen = new HashSet<long>();
                for (long current = id; byId.TryGetValue(current, out var c) && c.ParentId is { } parent && seen.Add(current); current = parent) depth++;
                return depth;
            }
            long ExportAncestor(long id)
            {
                long current = id;
                var seen = new HashSet<long>();
                while (Depth(current) > maximumDepth && byId.TryGetValue(current, out var c) && c.ParentId is { } parent && seen.Add(current)) current = parent;
                return current;
            }
            var compare = Comparer<string>.Create((a, b) => CultureInfo.CurrentCulture.CompareInfo.Compare(a, b, CompareOptions.IgnoreCase | CompareOptions.NumericOrdering));
            var exportable = collections.Where(c => Depth(c.Id) <= maximumDepth).ToList();
            var position = new Dictionary<long, double>();
            foreach (var (c, i) in exportable.Where(c => c.ParentId == null).OrderBy(c => c.Name, compare).Select((c, i) => (c, i))) position[c.Id] = i;
            foreach (var siblings in exportable.Where(c => c.ParentId != null).GroupBy(c => c.ParentId))
                foreach (var (c, i) in siblings.OrderBy(c => c.Name, compare).Select((c, i) => (c, i))) position[c.Id] = i;
            var groups = exportable.Select(c => new PreparedGroup(c.Key, c.Name, c.ParentId is { } p && byId.TryGetValue(p, out var parent) ? parent.Key : null,
                                                                   position.GetValueOrDefault(c.Id))).ToList();
            var keys = new Dictionary<long, string>();
            foreach (var c in collections)
                if (byId.TryGetValue(ExportAncestor(c.Id), out var ancestor)) keys[c.Id] = ancestor.Key;
            return (groups, keys);
        }

        static Metadata BuildMetadata(string typeName, Dictionary<string, string> fields, List<RawCreator> creators)
        {
            var type = typeName switch
            {
                "journalArticle" => ItemType.JournalArticle, "conferencePaper" => ItemType.ConferencePaper, "preprint" => ItemType.Preprint,
                "book" => ItemType.Book, "bookSection" => ItemType.BookChapter, "thesis" => ItemType.Thesis, "report" => ItemType.Report,
                "webpage" => ItemType.Webpage, "dataset" => ItemType.Dataset, _ => ItemType.Other,
            };
            var metadata = new Metadata(fields.GetValueOrDefault("title") ?? "") { Type = type };
            metadata.Authors = creators.OrderBy(c => c.OrderIndex)
                .Select(c => c.FieldMode == 1 ? new Author(c.LastName ?? c.FirstName ?? "") : new Author(c.LastName ?? "", c.FirstName ?? "")).ToList();
            if (fields.GetValueOrDefault("date") is { } date)
            {
                var (year, normalized) = ZoteroDate.ParseFieldValue(date);
                metadata.Year = year;
                metadata.Date = normalized;
            }
            metadata.Source = new[] { "publicationTitle", "proceedingsTitle", "bookTitle", "conferenceName", "repository", "websiteTitle", "university", "institution" }
                                  .Select(fields.GetValueOrDefault).FirstOrDefault(v => v != null)
                              ?? (type == ItemType.Book ? fields.GetValueOrDefault("publisher") : null);
            metadata.Volume = fields.GetValueOrDefault("volume");
            metadata.Issue = fields.GetValueOrDefault("issue");
            metadata.Pages = fields.GetValueOrDefault("pages");
            metadata.Publisher = fields.GetValueOrDefault("publisher");
            metadata.Doi = Doi(fields.GetValueOrDefault("DOI"));
            metadata.ArxivId = ArxivId(fields.GetValueOrDefault("archiveID"), fields.GetValueOrDefault("extra"), fields.GetValueOrDefault("url"));
            metadata.Isbn = fields.GetValueOrDefault("ISBN");
            metadata.Url = fields.GetValueOrDefault("url");
            metadata.Abstract = fields.GetValueOrDefault("abstractNote");
            return metadata;
        }

        static string? Doi(string? raw)
        {
            var value = raw?.Trim();
            if (string.IsNullOrEmpty(value)) return null;
            foreach (var prefix in new[] { "https://doi.org/", "http://doi.org/", "doi:" })
                if (value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) { value = value[prefix.Length..]; break; }
            return value.ToLowerInvariant();
        }

        static string? ArxivId(params string?[] candidates)
        {
            foreach (var text in candidates)
            {
                if (text == null) continue;
                var m = Regex.Match(text, @"\d{4}\.\d{4,5}(v\d+)?");
                if (!m.Success) m = Regex.Match(text, @"[a-z\-]+(\.[A-Z]{2})?/\d{7}(v\d+)?");
                if (m.Success) return Regex.Replace(m.Value, @"v\d+$", "");
            }
            return null;
        }
    }

    /// <summary>imported files: storage\&lt;key&gt;\&lt;name&gt;; linked: an absolute path or attachments:&lt;relative&gt;.</summary>
    public static string ResolvePath(string dataDirectory, string key, string? path, string? baseAttachmentPath)
    {
        if (string.IsNullOrEmpty(path)) return Path.Combine(dataDirectory, "storage", key);
        if (path.StartsWith("storage:")) return Path.Combine(dataDirectory, "storage", key, path["storage:".Length..]);
        if (path.StartsWith("attachments:"))
        {
            var relative = path["attachments:".Length..].Replace('/', Path.DirectorySeparatorChar);
            return string.IsNullOrEmpty(baseAttachmentPath) ? relative : Path.Combine(baseAttachmentPath, relative);
        }
        return path;
    }

    public static bool IsHtmlSnapshot(string? contentType, string? path)
    {
        if (!string.IsNullOrEmpty(contentType)) return contentType.Equals("text/html", StringComparison.OrdinalIgnoreCase);
        return path != null && (path.EndsWith(".html", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".htm", StringComparison.OrdinalIgnoreCase));
    }

    static readonly Dictionary<string, string> PluginServiceIds = new() { ["openailiked"] = "openaicompatible" };

    /// <summary>What Zotero's pdf2zh plugin made, from the file name (Paper.compare.pdf, Paper-mono.pdf) and the
    /// attachment's title, which names the service (ConDSeg-google-compare).</summary>
    public static (TranslationKind Kind, string? Service)? Translation(string fileName, string? title)
    {
        var lower = fileName.ToLowerInvariant();
        var tokens = (title ?? "").ToLowerInvariant().Split('-').Select(t => t.Trim()).ToList();
        var mode = tokens.Count > 1 ? tokens[^1] : null;
        TranslationKind kind;
        if (Regex.IsMatch(lower, @"[.-](dual|compare)\.pdf$") || mode is "dual" or "compare") kind = TranslationKind.Dual;
        else if (Regex.IsMatch(lower, @"[.-]mono\.pdf$") || mode == "mono") kind = TranslationKind.Mono;
        else return null;
        string? service = null;
        if (mode is "dual" or "compare" or "mono")
        {
            var word = tokens[^2];
            service = ServiceName(PluginServiceIds.GetValueOrDefault(word) ?? word);
        }
        return (kind, service);
    }

    /// <summary>The name of a translation service by id, including pdf2zh's that Folio does not offer.</summary>
    static string? ServiceName(string id)
    {
        id = id.ToLowerInvariant();
        if (TranslationServiceCatalog.Service(id) is { } s) return TranslationNaming.NameOf(s);
        return id switch
        {
            "siliconflowfree" => Loc.S("SiliconFlow 免费"), "xinference" => "Xinference", "anythingllm" => "AnythingLLM", "dify" => "Dify",
            "apple" => "Apple", _ => null,
        };
    }

    /// <summary>The original (not a translation) first when both exist; else the earliest.</summary>
    static List<PreparedFile> Order(List<PreparedFile> files) =>
        files.Select((f, i) => (f, i)).OrderBy(x => x.f.TranslationKind != null).ThenBy(x => x.f.DateAdded).ThenBy(x => x.i).Select(x => x.f).ToList();
}

/// <summary>Zotero's two date encodings.</summary>
public static class ZoteroDate
{
    /// <summary>A UTC "YYYY-MM-DD HH:MM:SS" timestamp.</summary>
    public static DateTime ParseTimestamp(string? s) =>
        DateTime.TryParseExact(s, "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d)
            ? d : DateTime.UnixEpoch;

    /// <summary>"2024-09-00 09/2024" → (2024, "2024-09"); "2021-00-00 2021" → (2021, "2021").</summary>
    public static (int? Year, string? Normalized) ParseFieldValue(string raw)
    {
        var head = raw.Split(' ', 2)[0];
        var parts = head.Split('-');
        if (parts.Length != 3 || parts[0].Length != 4 || !int.TryParse(parts[0], out var year) || year <= 0)
        {
            var m = Regex.Match(raw, @"(?<!\d)(\d{4})(?!\d)");
            while (m.Success)
            {
                if (int.TryParse(m.Groups[1].Value, out var y) && y > 1000 && y < 3000) return (y, y.ToString());
                m = m.NextMatch();
            }
            return (null, null);
        }
        int month = int.TryParse(parts[1], out var mo) ? mo : 0, day = int.TryParse(parts[2], out var da) ? da : 0;
        if (month is <= 0 or > 12) return (year, year.ToString());
        if (day is <= 0 or > 31) return (year, $"{year:D4}-{month:D2}");
        return (year, $"{year:D4}-{month:D2}-{day:D2}");
    }
}
