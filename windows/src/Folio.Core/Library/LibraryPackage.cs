using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;
using static Folio.Core.AppDatabase;
using static Folio.Core.Records;

namespace Folio.Core;

// Port of macos/.../FolioCore/Library/LibraryPackage.swift: both write and read the same files.

/// <summary>What a package (<c>.foliolib</c>) says about itself. A package is a zip file with this as
/// <c>folio-package.json</c>; the library in it is its database as <c>Folio.sqlite</c> and its files under <c>Files/</c>;
/// the settings in it are <c>folio-settings.json</c>.</summary>
public sealed class LibraryPackageInfo
{
    public const string Extension = "foliolib";
    /// <summary>What this version writes; packages of a later format are refused.</summary>
    public const int CurrentFormat = 1;
    internal const string EntryName = "folio-package.json", SettingsName = "folio-settings.json";

    [JsonPropertyName("format")] public int Format { get; set; } = CurrentFormat;
    [JsonPropertyName("app")] public string App { get; set; } = "";
    /// <summary>To the second, in UTC, as the macOS app writes it.</summary>
    [JsonPropertyName("exported")] public string Exported { get; set; } = "";
    [JsonPropertyName("items")] public int Items { get; set; }
    [JsonPropertyName("files")] public int Files { get; set; }
    [JsonPropertyName("groups")] public int Groups { get; set; }
    [JsonPropertyName("tags")] public int Tags { get; set; }

    [JsonIgnore]
    public DateTime Date => DateTime.TryParse(Exported, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var d) ? d : DateTime.UnixEpoch;
}

/// <summary>A package to be imported: what is in it.</summary>
public sealed class LibraryPackage
{
    public string Path { get; }
    public LibraryPackageInfo Info { get; }
    public bool HasLibrary { get; }
    /// <summary>The settings, as <see cref="Library.ExportPackage"/> was given them.</summary>
    public byte[]? Settings { get; }

    public LibraryPackage(string path)
    {
        Path = path;
        using var archive = PackageArchive.Open(path);
        try { Info = JsonSerializer.Deserialize<LibraryPackageInfo>(archive.Bytes(LibraryPackageInfo.EntryName)!)!; }
        catch (Exception e) when (e is JsonException or ArgumentNullException) { throw PackageArchive.NotAPackage(); }
        if (Info.Format > LibraryPackageInfo.CurrentFormat) throw new LibraryException(Loc.S("这个文件由更新版本的 Folio 导出，请先更新 Folio"));
        HasLibrary = archive.Contains(Library.DatabaseFileName);
        Settings = archive.Bytes(LibraryPackageInfo.SettingsName);
    }
}

/// <summary>A package being read. Names are compared as Unicode does (é may be written in two ways), contents are checked.</summary>
sealed class PackageArchive : IDisposable
{
    readonly ZipArchive _zip;
    readonly Dictionary<string, ZipArchiveEntry> _entries = [];

    PackageArchive(ZipArchive zip)
    {
        _zip = zip;
        foreach (var entry in zip.Entries) _entries[entry.FullName.Normalize()] = entry;
    }

    public static Exception NotAPackage() => new LibraryException(Loc.S("文件已损坏，或不是 Folio 文献库包"));

    public static PackageArchive Open(string path)
    {
        try { return new PackageArchive(ZipFile.OpenRead(path)); }
        catch (InvalidDataException) { throw NotAPackage(); }
    }

    public void Dispose() => _zip.Dispose();

    public bool Contains(string name) => _entries.ContainsKey(name.Normalize());

    public byte[]? Bytes(string name)
    {
        if (!Contains(name)) return null;
        using var memory = new MemoryStream();
        return Copy(name, memory) ? memory.ToArray() : null;
    }

    /// <summary>False when it is not in the archive, or not whole.</summary>
    public bool Extract(string name, string path)
    {
        if (!Contains(name)) return false;
        bool whole;
        using (var output = System.IO.File.Create(path)) whole = Copy(name, output);
        if (!whole) System.IO.File.Delete(path);
        return whole;
    }

    bool Copy(string name, Stream output)
    {
        var entry = _entries[name.Normalize()];
        try
        {
            using var input = entry.Open();
            var buffer = new byte[1 << 20];
            uint crc = 0xFFFFFFFF;
            long size = 0;
            for (int n; (n = input.Read(buffer)) > 0; size += n)
            {
                for (int i = 0; i < n; i++) crc = Table[(crc ^ buffer[i]) & 0xFF] ^ crc >> 8;
                output.Write(buffer, 0, n);
            }
            return ~crc == entry.Crc32 && size == entry.Length;
        }
        catch (InvalidDataException) { return false; }
    }

    static readonly uint[] Table = Enumerable.Range(0, 256).Select(n =>
    {
        uint c = (uint)n;
        for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ c >> 1 : c >> 1;
        return c;
    }).ToArray();
}

public sealed record LibraryExportSummary(int Items, int Files, int MissingFiles);

public sealed class LibraryImportSummary
{
    public int ItemsAdded { get; set; }
    /// <summary>Already in the library, and changed by the package (newer details, a newer or further file).</summary>
    public int ItemsUpdated { get; set; }
    public int ItemsUnchanged { get; set; }
    public int FilesAdded { get; set; }
    public int FilesUpdated { get; set; }
    public int GroupsCreated { get; set; }
    public int TagsCreated { get; set; }
    public int MissingFiles { get; set; }
}

public sealed partial class Library
{
    /// <summary>Packs the library (all of it but its trash) and/or the settings into one file. <paramref name="progress"/>:
    /// files packed, of how many. Cancelled, it leaves what was at <paramref name="path"/> as it was.</summary>
    public LibraryExportSummary ExportPackage(string path, string appVersion, bool includingLibrary = true, byte[]? settings = null,
                                              Action<int, int>? progress = null, CancellationToken cancel = default)
    {
        var staging = Directory.CreateTempSubdirectory("folio-export-").FullName;
        var partial = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(path))!, $".{Guid.NewGuid():N}.partial");
        try
        {
            var info = new LibraryPackageInfo { App = appVersion, Exported = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture) };
            var copy = Path.Combine(staging, DatabaseFileName);
            var files = includingLibrary ? CopyDatabase(copy, info) : [];
            int done = 0, missing = 0;
            using (var archive = new ZipArchive(System.IO.File.Create(partial), ZipArchiveMode.Create))
            {
                void Write(string name, Stream input, CompressionLevel level, DateTime? modified = null)
                {
                    using (input)
                    {
                        var entry = archive.CreateEntry(name, level);
                        if (modified is { Year: >= 1980 and <= 2107 } time) entry.LastWriteTime = time;
                        using var output = entry.Open();
                        var buffer = new byte[1 << 20];
                        for (int n; (n = input.Read(buffer)) > 0;)
                        {
                            cancel.ThrowIfCancellationRequested();
                            output.Write(buffer, 0, n);
                        }
                    }
                }
                Write(LibraryPackageInfo.EntryName, new MemoryStream(JsonSerializer.SerializeToUtf8Bytes(info)), CompressionLevel.Optimal);
                if (settings != null) Write(LibraryPackageInfo.SettingsName, new MemoryStream(settings), CompressionLevel.Optimal);
                if (includingLibrary) Write(DatabaseFileName, System.IO.File.OpenRead(copy), CompressionLevel.Optimal);
                foreach (var file in files)
                {
                    cancel.ThrowIfCancellationRequested();
                    var source = Store.PathFor(file.RelativePath);
                    // Papers are compressed already. Open elsewhere is no reason not to read it.
                    if (System.IO.File.Exists(source)) Write(file.RelativePath, new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete), CompressionLevel.NoCompression, System.IO.File.GetLastWriteTime(source));
                    else missing++;
                    progress?.Invoke(++done, files.Count);
                }
            }
            System.IO.File.Move(partial, path, overwrite: true);
            return new LibraryExportSummary(info.Items, files.Count - missing, missing);
        }
        finally
        {
            try { System.IO.File.Delete(partial); } catch (IOException) { }
            try { Directory.Delete(staging, true); } catch (IOException) { }
        }
    }

    /// <summary>The database as it is this moment, without the trash, in one file.</summary>
    List<FileRecord> CopyDatabase(string path, LibraryPackageInfo info)
    {
        RefreshFingerprints();
        using var copy = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
        copy.Open();
        Database.Read<object?>(c => { c.BackupDatabase(copy); return null; });
        Exec(copy, null, "PRAGMA foreign_keys = ON");
        Exec(copy, null, "DELETE FROM fulltext WHERE fileId IN (SELECT file.id FROM file JOIN item ON item.id = file.itemId WHERE item.trashedAt IS NOT NULL)");
        Exec(copy, null, "DELETE FROM item WHERE trashedAt IS NOT NULL");
        // What was deleted is not left in the file's free pages.
        Exec(copy, null, "VACUUM");
        Exec(copy, null, "PRAGMA journal_mode = DELETE");
        int Count(string table) => Convert.ToInt32(Scalar(copy, null, $"SELECT COUNT(*) FROM {table}"), CultureInfo.InvariantCulture);
        var files = Query(copy, null, "SELECT * FROM file", ReadFile);
        (info.Items, info.Files, info.Groups, info.Tags) = (Count("item"), files.Count, Count("libraryGroup"), Count("tag"));
        return files;
    }

    /// <summary>Adds what a package holds to this library. What is here already (the same item, a file with the same
    /// contents, or the same work) is not added again: of its details, note and files the newer stay, its groups and tags
    /// come together. Nothing is taken away; a file replaced by a newer one goes to <paramref name="discard"/> (the recycle
    /// bin). <paramref name="progress"/>: items done, of how many. Cancelled, importing again goes on.</summary>
    public LibraryImportSummary ImportPackage(LibraryPackage package, Action<string> discard, Action<int, int>? progress = null, CancellationToken cancel = default)
    {
        if (!package.HasLibrary) return new LibraryImportSummary();
        using var archive = PackageArchive.Open(package.Path);
        RefreshFingerprints();
        var staging = Directory.CreateTempSubdirectory("folio-import-").FullName;
        try
        {
            var copy = Path.Combine(staging, DatabaseFileName);
            if (!archive.Extract(DatabaseFileName, copy)) throw PackageArchive.NotAPackage();
            // Brought up to this version's tables; what a later version added is left out.
            using var source = AppDatabase.Open(copy);
            return new PackageImport(this, archive, source, staging, discard, cancel).Run(progress);
        }
        finally { try { Directory.Delete(staging, true); } catch (IOException) { } }
    }

    /// <summary>One import of a package.</summary>
    sealed class PackageImport(Library library, PackageArchive archive, AppDatabase source, string staging, Action<string> discard, CancellationToken cancel)
    {
        sealed record NoteRow(string Content, DateTime Date);

        readonly LibraryImportSummary _summary = new();
        /// <summary>Ids of the package and what they are here.</summary>
        readonly Dictionary<string, string> _items = [], _groups = [], _tags = [], _files = [];
        /// <summary>Files of the package whose contents (and so their text) are in the library now.</summary>
        readonly HashSet<string> _written = [];
        AppDatabase Database => library.Database;

        public LibraryImportSummary Run(Action<int, int>? progress)
        {
            var items = source.Read(c => Query(c, null, "SELECT * FROM item WHERE trashedAt IS NULL ORDER BY dateAdded", ReadItem));
            var files = source.Read(c => Query(c, null, "SELECT * FROM file ORDER BY dateAdded, id", ReadFile)).ToLookup(f => f.ItemId);
            var notes = source.Read(c => Query(c, null, "SELECT * FROM note", r => (Str(r, "itemId")!, NoteOf(r)))).ToDictionary(n => n.Item1, n => n.Item2);
            var memberships = source.Read(c => Query(c, null, "SELECT itemId, groupId, dateAdded FROM itemGroup", r => (Item: r.GetString(0), Group: r.GetString(1), Added: Date(r, "dateAdded") ?? DateTime.UtcNow))).ToLookup(m => m.Item);
            var taggings = source.Read(c => Query(c, null, "SELECT itemId, tagId FROM itemTag", r => (Item: r.GetString(0), Tag: r.GetString(1)))).ToLookup(t => t.Item);
            ImportGroups();
            ImportTags();
            var matches = Match(items, files);
            foreach (var item in items) _items[item.Id] = matches.GetValueOrDefault(item.Id, item.Id);
            for (int i = 0; i < items.Count; i++)
            {
                cancel.ThrowIfCancellationRequested();
                ImportItem(items[i], matches.GetValueOrDefault(items[i].Id), [.. files[items[i].Id]], notes.GetValueOrDefault(items[i].Id),
                           memberships[items[i].Id].Select(m => (m.Group, m.Added)).ToList(), taggings[items[i].Id].Select(t => t.Tag).ToList());
                progress?.Invoke(i + 1, items.Count);
            }
            ImportFulltext();
            ImportTheRest();
            return _summary;
        }

        static NoteRow NoteOf(SqliteDataReader r) => new(Str(r, "content") ?? "", Date(r, "dateModified") ?? DateTime.UnixEpoch);

        // MARK: What is here already

        Dictionary<string, string> Match(List<Item> items, ILookup<string, FileRecord> filesOf)
        {
            var here = Database.Read(c => Query(c, null, "SELECT * FROM item", ReadItem));
            var byId = here.ToDictionary(i => i.Id);
            var owners = new Dictionary<string, string>();
            // Two Markdown documents with the same text are two documents.
            foreach (var file in Database.Read(c => Query(c, null, "SELECT * FROM file", ReadFile)))
                if (!file.IsMarkdown && byId.TryGetValue(file.ItemId, out var owner) && !owner.IsTrashed)
                    owners[file.Sha256] = owners[file.OriginalSha256] = file.ItemId;
            // Works by what they could be told by; a large library is not compared pair by pair.
            static IEnumerable<string> Keys(Metadata m) => new[] { "i" + m.Isbn, "d" + m.Doi?.ToLowerInvariant(), "a" + m.ArxivId?.ToLowerInvariant(), "t" + TitleNormalizer.Normalize(m.Title) }.Where(k => k.Length > 1);
            var works = here.Where(i => i.Kind == ItemKind.Regular && !i.IsTrashed).SelectMany(i => Keys(i.Metadata).Select(k => (Key: k, i.Id, i.Metadata))).ToLookup(w => w.Key);
            var result = new Dictionary<string, string>();
            // The same item first: what else might match may be another item of the package.
            foreach (var item in items) if (byId.ContainsKey(item.Id)) result[item.Id] = item.Id;
            var taken = result.Values.ToHashSet();
            foreach (var item in items)
            {
                if (result.ContainsKey(item.Id)) continue;
                var found = filesOf[item.Id].Where(f => !f.IsMarkdown).Select(f => owners.GetValueOrDefault(f.Sha256) ?? owners.GetValueOrDefault(f.OriginalSha256)).FirstOrDefault(o => o != null);
                if (found == null && item.Kind == ItemKind.Regular)
                {
                    var metadata = item.Metadata;
                    found = Keys(metadata).SelectMany(k => works[k]).FirstOrDefault(w => !string.IsNullOrEmpty(metadata.Isbn) && w.Metadata.Isbn == metadata.Isbn || DuplicateMatcher.IsSameWork(w.Metadata, metadata)).Id;
                }
                if (found != null && taken.Add(found)) result[item.Id] = found;
            }
            return result;
        }

        // MARK: Groups and tags

        void ImportGroups()
        {
            var groups = source.Read(c => Query(c, null, "SELECT * FROM libraryGroup", ReadGroup));
            var byId = groups.ToDictionary(g => g.Id);
            int Level(LibraryGroup group)
            {
                int level = 1;
                var seen = new HashSet<string> { group.Id };
                for (var parent = group.ParentId; parent != null && seen.Add(parent); parent = byId.GetValueOrDefault(parent)?.ParentId) level++;
                return level;
            }
            // Parents before what is in them.
            var ordered = groups.OrderBy(Level).ThenBy(g => g.Position).ToList();
            if (ordered.Count == 0) return;
            Database.Write((c, tx) =>
            {
                foreach (var group in ordered)
                {
                    if (FetchGroup(c, tx, group.Id) != null) { _groups[group.Id] = group.Id; continue; }
                    var parent = group.ParentId == null ? null : _groups.GetValueOrDefault(group.ParentId);
                    var siblings = Siblings(parent, c, tx);
                    if (siblings.FirstOrDefault(s => string.Equals(s.Name, group.Name, StringComparison.CurrentCultureIgnoreCase)) is { } same) { _groups[group.Id] = same.Id; continue; }
                    int depth = 1;
                    for (var up = parent; up != null; up = FetchGroup(c, tx, up)?.ParentId) depth++;
                    // Deeper than groups nest here: its items are in the group above.
                    if (depth > LibraryGroup.MaximumDepth && parent != null) { _groups[group.Id] = parent; continue; }
                    group.ParentId = parent;
                    group.Position = siblings.Count == 0 ? 0 : siblings.Max(s => s.Position) + 1;
                    Insert(c, tx, group);
                    _groups[group.Id] = group.Id;
                    _summary.GroupsCreated++;
                }
            });
        }

        void ImportTags()
        {
            var tags = source.Read(c => Query(c, null, "SELECT * FROM tag ORDER BY position", ReadTag));
            if (tags.Count == 0) return;
            Database.Write((c, tx) =>
            {
                double position = Scalar(c, tx, "SELECT MAX(position) FROM tag") is { } max ? Convert.ToDouble(max, CultureInfo.InvariantCulture) : -1;
                foreach (var tag in tags)
                {
                    if (Scalar(c, tx, "SELECT id FROM tag WHERE id = ? OR name = ? COLLATE NOCASE", tag.Id, tag.Name) is string same) { _tags[tag.Id] = same; continue; }
                    Exec(c, tx, "INSERT INTO tag (id, name, colorHex, position) VALUES (?, ?, ?, ?)", tag.Id, tag.Name, tag.ColorHex, ++position);
                    _tags[tag.Id] = tag.Id;
                    _summary.TagsCreated++;
                }
            });
        }

        // MARK: Items

        void ImportItem(Item item, string? match, List<FileRecord> files, NoteRow? note, List<(string Group, DateTime Added)> groups, List<string> tags)
        {
            var itemId = match ?? item.Id;
            var local = match == null ? null : library.Item(match);
            var localFiles = local == null ? [] : library.Files(local.Id);
            List<FileRecord> added = [], changed = [];
            try
            {
                foreach (var file in files)
                {
                    var have = localFiles.FirstOrDefault(f => f.Id == file.Id)
                        ?? localFiles.FirstOrDefault(f => !file.IsMarkdown && (f.Sha256 == file.Sha256 || f.OriginalSha256 == file.OriginalSha256));
                    if (have != null)
                    {
                        _files[file.Id] = have.Id;
                        if (have.Sha256 != file.Sha256 && file.ModifiedAt > have.ModifiedAt.AddSeconds(1) && Replace(have, file) is { } updated) changed.Add(updated);
                    }
                    else if (Add(file, itemId) is { } record) added.Add(record);
                    else _summary.MissingFiles++;
                }
                // A file of its own whose file is gone is nothing.
                if (local == null && item.Kind == ItemKind.Standalone && added.Count == 0) { _items.Remove(item.Id); return; }
                // Which file they were translated from, now that all are known.
                foreach (var file in added) file.TranslationOf = file.TranslationOf == null ? null : _files.GetValueOrDefault(file.TranslationOf);
                var defaultFile = item.DefaultFileId == null ? null : _files.GetValueOrDefault(item.DefaultFileId);
                var text = note == null ? "" : Relinked(note.Content);
                var touched = Database.Write((c, tx) =>
                {
                    bool touched = added.Count > 0 || changed.Count > 0;
                    if (local is { } kept)
                    {
                        if (kept.IsTrashed) touched = true;
                        if (item.DateModified > kept.DateModified && !(kept.Kind == ItemKind.Regular && item.Kind == ItemKind.Standalone))
                        {
                            var updated = source.Read(s => FetchItem(s, null, item.Id))!;
                            updated.Id = kept.Id;
                            updated.DateAdded = kept.DateAdded;
                            updated.OriginItemId = null;
                            updated.CitationKey = kept.CitationKey ?? item.CitationKey;
                            updated.DefaultFileId = defaultFile ?? kept.DefaultFileId;
                            kept = updated;
                            touched = true;
                        }
                        kept.TrashedAt = null;
                        foreach (var file in added) Insert(c, tx, file);
                        foreach (var file in changed) Update(c, tx, file);
                        kept.DefaultFileId ??= added.FirstOrDefault()?.Id;
                        Update(c, tx, kept);
                    }
                    else
                    {
                        item.OriginItemId = null;
                        item.DefaultFileId = defaultFile ?? added.FirstOrDefault()?.Id;
                        if (item.CitationKey is { } key) item.CitationKey = CitationKeyGenerator.UniqueKey(key, ExistingCitationKeys(c, tx));
                        Insert(c, tx, item);
                        foreach (var file in added) Insert(c, tx, file);
                    }
                    if (text.Length > 0)
                    {
                        var mine = Query(c, tx, "SELECT * FROM note WHERE itemId = ?", NoteOf, itemId).FirstOrDefault();
                        void Save(string content, DateTime date)
                        {
                            Exec(c, tx, "INSERT OR REPLACE INTO note (itemId, content, dateModified) VALUES (?, ?, ?)", itemId, content, date);
                            touched = true;
                        }
                        if (mine == null || mine.Content.Length == 0) Save(text, note!.Date);
                        else if (mine.Content != text)
                        {
                            if (item.Id == itemId) { if (note!.Date > mine.Date) Save(text, note.Date); }
                            // Written apart, about the same paper: both.
                            else if (!mine.Content.Contains(text)) Save(mine.Content + "\n\n" + text, DateTime.UtcNow);
                        }
                    }
                    foreach (var (group, date) in groups)
                        if (_groups.TryGetValue(group, out var g)) touched |= Exec(c, tx, "INSERT OR IGNORE INTO itemGroup (itemId, groupId, dateAdded) VALUES (?, ?, ?)", itemId, g, date) > 0;
                    foreach (var tag in tags)
                        if (_tags.TryGetValue(tag, out var t)) touched |= Exec(c, tx, "INSERT OR IGNORE INTO itemTag (itemId, tagId) VALUES (?, ?)", itemId, t) > 0;
                    return touched;
                });
                _summary.FilesAdded += added.Count;
                _summary.FilesUpdated += changed.Count;
                if (local == null) _summary.ItemsAdded++; else if (touched) _summary.ItemsUpdated++; else _summary.ItemsUnchanged++;
            }
            catch
            {
                foreach (var file in added) library.Store.Delete(file.RelativePath);
                throw;
            }
        }

        /// <summary>Takes a file's contents out of the package. Null when the package does not have them (whole).</summary>
        string? Extract(FileRecord file)
        {
            var path = Path.Combine(staging, Guid.NewGuid().ToString("N"));
            if (!archive.Extract(file.RelativePath, path)) return null;
            if (file.IsMarkdown)
            {
                var text = System.IO.File.ReadAllText(path);
                var linked = Relinked(text);
                if (linked != text) System.IO.File.WriteAllText(path, linked, new UTF8Encoding(false));
            }
            try { System.IO.File.SetLastWriteTimeUtc(path, file.ModifiedAt); } catch (ArgumentOutOfRangeException) { }
            return path;
        }

        FileRecord? Add(FileRecord file, string itemId)
        {
            if (Extract(file) is not { } path) return null;
            var record = file.Clone();
            record.ItemId = itemId;
            if (library.File(file.Id) != null)
            {
                record.Id = Guid.NewGuid().ToString().ToUpperInvariant();
                if (file.OriginalSha256 == "md-" + file.Id) record.OriginalSha256 = "md-" + record.Id;
            }
            var name = file.FileName;
            record.RelativePath = library.Store.UniqueRelativePath(FileNamer.Sanitize(Path.GetFileNameWithoutExtension(name)), FileNamer.Sanitize(Path.GetExtension(name).TrimStart('.')), null);
            System.IO.File.Move(path, library.Store.PathFor(record.RelativePath));
            Fingerprint(record);
            _files[file.Id] = record.Id;
            _written.Add(file.Id);
            return record;
        }

        FileRecord? Replace(FileRecord have, FileRecord file)
        {
            if (Extract(file) is not { } path) return null;
            var target = library.Store.PathFor(have.RelativePath);
            // Where there is no recycle bin, or another program has it open, the file that is here stays.
            try { if (System.IO.File.Exists(target)) discard(target); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or OperationCanceledException) { return null; }
            if (System.IO.File.Exists(target)) return null;
            System.IO.File.Move(path, target);
            var record = have.Clone();
            record.FulltextState = file.FulltextState;
            Fingerprint(record);
            _written.Add(file.Id);
            return record;
        }

        void Fingerprint(FileRecord record)
        {
            var info = new FileInfo(library.Store.PathFor(record.RelativePath));
            record.Size = info.Length;
            record.ModifiedAt = info.LastWriteTimeUtc;
            record.Sha256 = FileHasher.Sha256(info.FullName);
        }

        /// <summary>Links to items that have another id here.</summary>
        string Relinked(string text)
        {
            if (!text.Contains("folio://")) return text;
            foreach (var (old, now) in _items) if (old != now) text = text.Replace("item=" + old, "item=" + now);
            return text;
        }

        // MARK: What belongs to them

        /// <summary>The text of the files that came, so that they need not be read again.</summary>
        void ImportFulltext()
        {
            if (_written.Count == 0) return;
            Database.Write((c, tx) =>
            {
                foreach (var ids in _written.Select(id => _files[id]).Chunk(500)) DeleteFulltext([.. ids], c, tx);
                using var from = source.Connect();
                using var command = Command(from, null, "SELECT fileId, content FROM fulltext");
                using var rows = command.ExecuteReader();
                while (rows.Read())
                    if (_written.Contains(rows.GetString(0)))
                        Exec(c, tx, "INSERT INTO fulltext (fileId, content) VALUES (?, ?)", _files[rows.GetString(0)], rows.IsDBNull(1) ? null : rows.GetString(1));
            });
        }

        /// <summary>Where files were read to, the order of views, what is known of journals.</summary>
        void ImportTheRest()
        {
            var reading = source.Read(c => Query(c, null, "SELECT * FROM readingState", ReadReading));
            var orders = source.Read(c => Query(c, null, "SELECT scope, itemId, position FROM itemOrder", r => (Scope: r.GetString(0), Item: r.GetString(1), Position: r.GetDouble(2))));
            var sorts = source.Read(c => Query(c, null, "SELECT scope, sortColumn, ascending FROM viewSort", r => (Scope: r.GetString(0), Column: r.IsDBNull(1) ? null : r.GetString(1), Ascending: r.GetInt64(2))));
            var metrics = source.Read(c => Query(c, null, "SELECT name, json, fetchedAt FROM journalMetrics", r => (Name: r.GetString(0), Json: r.GetString(1), At: r.GetValue(2))));
            string? Scope(string key)
            {
                if (key == "trash") return null;
                foreach (var (prefix, ids) in new[] { ("group:", _groups), ("tag:", _tags) })
                    if (key.StartsWith(prefix)) return ids.TryGetValue(key[prefix.Length..], out var id) ? prefix + id : null;
                return key;
            }
            Database.Write((c, tx) =>
            {
                foreach (var state in reading)
                {
                    if (!_files.TryGetValue(state.FileId, out var file) || FetchFile(c, tx, file) == null) continue;
                    var mine = Query(c, tx, "SELECT * FROM readingState WHERE fileId = ?", ReadReading, file).FirstOrDefault();
                    if (mine != null && mine.DateModified >= state.DateModified) continue;
                    Exec(c, tx, "INSERT OR REPLACE INTO readingState (fileId, pageIndex, pointX, pointY, scale, autoScale, displayMode, dateModified, pageCount, seenPages) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                         file, state.PageIndex, state.PointX, state.PointY, state.Scale, state.AutoScale, state.DisplayMode, state.DateModified, state.PageCount, state.SeenPages);
                }
                foreach (var (scope, item, position) in orders)
                    if (Scope(scope) is { } key && _items.TryGetValue(item, out var id) && FetchItem(c, tx, id) != null)
                        Exec(c, tx, "INSERT OR IGNORE INTO itemOrder (scope, itemId, position) VALUES (?, ?, ?)", key, id, position);
                foreach (var (scope, column, ascending) in sorts)
                    if (Scope(scope) is { } key) Exec(c, tx, "INSERT OR IGNORE INTO viewSort (scope, sortColumn, ascending) VALUES (?, ?, ?)", key, column, ascending);
                foreach (var (name, json, at) in metrics) Exec(c, tx, "INSERT OR IGNORE INTO journalMetrics (name, json, fetchedAt) VALUES (?, ?, ?)", name, json, at);
            });
        }
    }
}
