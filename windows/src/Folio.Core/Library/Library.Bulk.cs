using Microsoft.Data.Sqlite;
using static Folio.Core.AppDatabase;
using static Folio.Core.Records;

namespace Folio.Core;

// Ports of macos/.../FolioCore/Models/Prepared.swift and Library/Library+Bulk.swift.

public sealed partial class Library
{
    /// <summary>Imports a prepared library (e.g. read from Zotero): groups, tags, items and files, skipping duplicates by
    /// file hash and by work identity. Imported items are not re-retrieved.</summary>
    public BulkImportSummary ImportPrepared(PreparedLibrary prepared, bool autoRename = true, Action<int, int>? progress = null, CancellationToken cancel = default)
    {
        var summary = new BulkImportSummary();
        var groupIds = ImportGroups(prepared.Groups, summary);
        var tagIds = ImportTags(prepared.Tags, prepared.Entries, summary);
        for (int i = 0; i < prepared.Entries.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            ImportEntry(prepared.Entries[i], groupIds, tagIds, autoRename, summary);
            progress?.Invoke(i + 1, prepared.Entries.Count);
        }
        return summary;
    }

    Dictionary<string, string> ImportGroups(List<PreparedGroup> groups, BulkImportSummary summary)
    {
        var ids = new Dictionary<string, string>();
        // Parents before children: by level, then position. Groups deeper than the limit are skipped.
        var byKey = new Dictionary<string, PreparedGroup>();
        foreach (var g in groups) byKey.TryAdd(g.Key, g);
        int Level(PreparedGroup group)
        {
            int level = 1;
            var seen = new HashSet<string> { group.Key };
            for (var key = group.ParentKey; key != null && seen.Add(key); key = byKey.GetValueOrDefault(key)?.ParentKey) level++;
            return level;
        }
        var ordered = groups.Select(g => (Group: g, Level: Level(g))).Where(x => x.Level <= LibraryGroup.MaximumDepth)
            .OrderBy(x => x.Level).ThenBy(x => x.Group.Position).Select(x => x.Group).ToList();
        Database.Write((c, tx) =>
        {
            foreach (var group in ordered)
            {
                string? parentId = group.ParentKey != null ? ids.GetValueOrDefault(group.ParentKey) : null;
                if (group.ParentKey != null && parentId == null) continue;
                var siblings = Siblings(parentId, c, tx);
                if (siblings.FirstOrDefault(s => string.Equals(s.Name, group.Name, StringComparison.OrdinalIgnoreCase)) is { } existing)
                {
                    ids[group.Key] = existing.Id;
                    continue;
                }
                var record = new LibraryGroup(group.Name, (siblings.Count == 0 ? -1 : siblings.Max(s => s.Position)) + 1, parentId);
                Insert(c, tx, record);
                ids[group.Key] = record.Id;
                summary.GroupsCreated++;
            }
        });
        return ids;
    }

    Dictionary<string, string> ImportTags(List<PreparedTag> tags, List<PreparedEntry> entries, BulkImportSummary summary)
    {
        var colors = new Dictionary<string, string>();
        foreach (var t in tags) colors[t.Name.ToLowerInvariant()] = t.ColorHex;
        var names = tags.Select(t => t.Name).Concat(entries.SelectMany(e => e.TagNames));
        var ids = new Dictionary<string, string>();
        Database.Write((c, tx) =>
        {
            var max = Scalar(c, tx, "SELECT MAX(position) FROM tag");
            double position = max == null || max is DBNull ? -1 : Convert.ToDouble(max);
            foreach (var name in names)
            {
                var clean = name.Trim();
                var key = clean.ToLowerInvariant();
                if (clean.Length == 0 || ids.ContainsKey(key)) continue;
                if (Scalar(c, tx, "SELECT id FROM tag WHERE name = ? COLLATE NOCASE", clean) is string existing)
                {
                    ids[key] = existing;
                    continue;
                }
                position++;
                var tag = new Tag(clean, colors.GetValueOrDefault(key) ?? "#8E8E93", position);
                Exec(c, tx, "INSERT INTO tag (id, name, colorHex, position) VALUES (?, ?, ?, ?)", tag.Id, tag.Name, tag.ColorHex, tag.Position);
                ids[key] = tag.Id;
                summary.TagsCreated++;
            }
        });
        return ids;
    }

    /// <summary>For an entry already in the library: its translations imported before as plain files learn what they are
    /// and who made them, and are renamed after it. Returns how many changed.</summary>
    int RecognizeTranslations(List<(PreparedFile File, string Hash)> hashed, bool autoRename)
    {
        var originalHashes = hashed.Where(h => h.File.TranslationKind == null).Select(h => h.Hash).ToList();
        int changed = 0;
        foreach (var (prepared, hash) in hashed)
        {
            if (prepared.TranslationKind is not { } kind) continue;
            var file = Database.Read(c => Query(c, null, "SELECT * FROM file WHERE (sha256 = ? OR originalSha256 = ?) AND translationKind IS NULL", ReadFile, hash, hash).FirstOrDefault());
            if (file == null) continue;
            var original = Database.Read(c => Query(c, null, "SELECT * FROM file WHERE itemId = ? AND translationKind IS NULL", ReadFile, file.ItemId)
                .FirstOrDefault(f => originalHashes.Contains(f.Sha256) || originalHashes.Contains(f.OriginalSha256)));
            file.TranslationKind = kind;
            file.TranslatedBy = prepared.TranslatedBy;
            file.TranslationOf = original?.Id;
            var suffix = FileNamer.TranslationSuffix(kind, prepared.TranslatedBy);
            string @base;
            if (autoRename && Item(file.ItemId) is { Kind: ItemKind.Regular } item) @base = FileNamer.BaseName(item.Metadata);
            else @base = System.Text.RegularExpressions.Regex.Replace(Path.GetFileNameWithoutExtension(file.FileName), @" \d+$", "");
            file.RelativePath = Store.Rename(file.RelativePath, @base + suffix);
            Database.Write((c, tx) => Update(c, tx, file));
            changed++;
        }
        return changed;
    }

    void ImportEntry(PreparedEntry entry, Dictionary<string, string> groupIds, Dictionary<string, string> tagIds, bool autoRename, BulkImportSummary summary)
    {
        var hashed = new List<(PreparedFile File, string Hash)>();
        foreach (var file in entry.Files)
        {
            if (System.IO.File.Exists(file.SourcePath))
            {
                try { hashed.Add((file, FileHasher.Sha256(file.SourcePath))); continue; } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            summary.MissingFiles++;
        }
        var existingOwner = Database.Read(c =>
        {
            foreach (var (_, hash) in hashed)
                if (Scalar(c, null, "SELECT itemId FROM file WHERE sha256 = ? OR originalSha256 = ?", hash, hash) is string owner) return owner;
            return entry.Metadata is { } metadata ? FindSameWork(metadata, null, c, null!) : null;
        });
        if (existingOwner != null)
        {
            summary.TranslationsRecognized += RecognizeTranslations(hashed, autoRename);
            summary.DuplicatesSkipped++;
            return;
        }

        Item item;
        if (entry.Metadata is { } m)
            item = new Item(ItemKind.Regular, m.Title, entry.DateAdded) { Metadata = m, MetadataState = MetadataState.Resolved };
        else
            item = new Item(ItemKind.Standalone, hashed.FirstOrDefault().File?.OriginalName ?? entry.Files.FirstOrDefault()?.OriginalName ?? Loc.S("未命名"), entry.DateAdded);
        item.DateModified = entry.DateModified;
        var baseName = item.Kind == ItemKind.Regular && autoRename ? FileNamer.BaseName(item.Metadata) : null;

        var copied = new List<FileRecord>();
        try
        {
            foreach (var (file, hash) in hashed)
            {
                var @base = baseName ?? FileNamer.Sanitize(Path.GetFileNameWithoutExtension(file.SourcePath));
                if (file.TranslationKind is { } kind) @base += FileNamer.TranslationSuffix(kind, file.TranslatedBy);
                var ext = Path.GetExtension(file.SourcePath).TrimStart('.');
                var relative = Store.CopyIn(file.SourcePath, @base, ext);
                var info = new FileInfo(Store.PathFor(relative));
                bool isPdf = ext.Equals("pdf", StringComparison.OrdinalIgnoreCase);
                var record = new FileRecord(item.Id, relative, file.OriginalName, info.Length, hash, info.LastWriteTimeUtc, file.DateAdded,
                                            isPdf ? FulltextState.Pending : FulltextState.NotApplicable);
                if (file.TranslationKind is { } translation)
                {
                    record.TranslationKind = translation;
                    record.TranslatedBy = file.TranslatedBy;
                    // Translated from the entry's original, which comes first.
                    record.TranslationOf = copied.FirstOrDefault(f => f.TranslationKind == null)?.Id;
                }
                copied.Add(record);
            }
            if (item.Kind == ItemKind.Standalone && copied.Count == 0) return;
            item.DefaultFileId = copied.FirstOrDefault()?.Id;
            Database.Write((c, tx) =>
            {
                if (item.Kind == ItemKind.Regular)
                    item.CitationKey = CitationKeyGenerator.UniqueKey(CitationKeyGenerator.BaseKey(item.Metadata), ExistingCitationKeys(c, tx));
                Insert(c, tx, item);
                foreach (var file in copied) Insert(c, tx, file);
                foreach (var key in entry.GroupKeys.Distinct())
                    if (groupIds.TryGetValue(key, out var groupId))
                        Exec(c, tx, "INSERT OR IGNORE INTO itemGroup (itemId, groupId, dateAdded) VALUES (?, ?, ?)", item.Id, groupId, entry.DateAdded);
                foreach (var name in entry.TagNames.Select(n => n.ToLowerInvariant()).Distinct())
                    if (tagIds.TryGetValue(name, out var tagId))
                        Exec(c, tx, "INSERT OR IGNORE INTO itemTag (itemId, tagId) VALUES (?, ?)", item.Id, tagId);
            });
        }
        catch
        {
            foreach (var f in copied) Store.Delete(f.RelativePath);
            throw;
        }
        summary.ItemsImported++;
        summary.FilesImported += copied.Count;
    }
}
