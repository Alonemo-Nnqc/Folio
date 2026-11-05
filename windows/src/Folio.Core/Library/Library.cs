using Microsoft.Data.Sqlite;
using static Folio.Core.AppDatabase;
using static Folio.Core.Records;

namespace Folio.Core;

public abstract record ImportOutcome
{
    /// <summary>A new standalone item was created for the file.</summary>
    public sealed record Imported(string ItemId, bool IsPdf) : ImportOutcome;
    /// <summary>The same content already exists; AddedToGroup when it joined the target group.</summary>
    public sealed record DuplicateFile(string ExistingItemId, bool AddedToGroup) : ImportOutcome;
    /// <summary>The same content exists but is in the trash.</summary>
    public sealed record DuplicateInTrash(string ExistingItemId) : ImportOutcome;
    public sealed record Failed(string Path, string Reason) : ImportOutcome;
}

public abstract record ApplyOutcome
{
    public sealed record Created(string ItemId) : ApplyOutcome;
    /// <summary>A regular item describing the same work already exists; nothing was changed.</summary>
    public sealed record DuplicateItem(string ExistingItemId) : ApplyOutcome;
}

public abstract record CreateOutcome
{
    public sealed record Created(string ItemId) : CreateOutcome;
    public sealed record Duplicate(string ExistingItemId) : CreateOutcome;
    public string Id => this switch { Created c => c.ItemId, Duplicate d => d.ExistingItemId, _ => "" };
}

public abstract record AddFileOutcome
{
    public sealed record Added(string FileId) : AddFileOutcome;
    public sealed record Duplicate(string ExistingItemId) : AddFileOutcome;
    public sealed record Failed(string Path, string Reason) : AddFileOutcome;
}

public sealed class MembershipResult
{
    public List<string> Added { get; } = [];
    public List<string> AlreadyPresent { get; } = [];
}

public sealed class ReferenceImportResult
{
    public List<string> Created { get; } = [];
    /// <summary>Records that matched an item already in the library.</summary>
    public List<string> Duplicates { get; } = [];
}

public sealed record FulltextHit(string ItemId, double Rank, string Snippet);

/// <summary>
/// The library service: every change to the user's data goes through here. Same operations and rules as the macOS
/// Library (Packages/FolioCore/Sources/FolioCore/Library). Thread-safe; callers run slow ones off the UI thread.
/// </summary>
public sealed partial class Library : IDisposable
{
    public const string DatabaseFileName = "Folio.sqlite";

    public string Root { get; }
    public AppDatabase Database { get; }
    internal FileStore Store { get; }

    /// <summary>Raised after every committed change made through this instance.</summary>
    public event Action? Changed;

    public Library(string root) : this(root, OpenDatabase(root)) { }

    Library(string root, AppDatabase database)
    {
        Root = root;
        Database = database;
        Store = new FileStore(root);
        Store.Prepare();
        Database.Committed += () => Changed?.Invoke();
    }

    static AppDatabase OpenDatabase(string root)
    {
        Directory.CreateDirectory(root);
        return AppDatabase.Open(Path.Combine(root, DatabaseFileName));
    }

    /// <summary>A throwaway library in a temporary folder with an in-memory database (tests).</summary>
    public static Library Temporary()
    {
        var root = Path.Combine(Path.GetTempPath(), $"folio-lib-{Guid.NewGuid()}");
        Directory.CreateDirectory(root);
        return new Library(root, AppDatabase.InMemory());
    }

    public void Dispose() => Database.Dispose();

    public string FilePath(FileRecord file) => Store.PathFor(file.RelativePath);

    // MARK: Lookups

    public Item? Item(string id) => Database.Read(c => FetchItem(c, null, id));
    public List<FileRecord> Files(string itemId) => Database.Read(c => FilesOf(c, null, itemId));
    public FileRecord? File(string id) => Database.Read(c => FetchFile(c, null, id));

    static HashSet<string> ExistingCitationKeys(SqliteConnection c, SqliteTransaction tx) =>
        Strings(c, tx, "SELECT citationKey FROM item WHERE citationKey IS NOT NULL").ToHashSet();

    // MARK: Importing files

    public List<ImportOutcome> ImportFiles(IEnumerable<string> paths, string? groupId = null)
    {
        var outcomes = new List<ImportOutcome>();
        foreach (var path in paths)
        {
            try { outcomes.Add(ImportFile(path, groupId)); }
            catch (Exception e) { outcomes.Add(new ImportOutcome.Failed(path, e.Message)); }
        }
        return outcomes;
    }

    ImportOutcome ImportFile(string path, string? groupId)
    {
        var hash = FileHasher.Sha256(path);
        if (DuplicateOutcome(hash, groupId) is { } duplicate) return duplicate;
        var ext = Path.GetExtension(path).TrimStart('.');
        var relative = Store.CopyIn(path, FileNamer.Sanitize(Path.GetFileNameWithoutExtension(path)), ext);
        var isPdf = ext.Equals("pdf", StringComparison.OrdinalIgnoreCase);
        try
        {
            var info = new FileInfo(Store.PathFor(relative));
            var now = DateTime.UtcNow;
            var item = new Item(ItemKind.Standalone, Path.GetFileName(path), now) { MetadataState = isPdf ? MetadataState.Pending : MetadataState.None };
            var file = new FileRecord(item.Id, relative, Path.GetFileName(path), info.Length, hash, info.LastWriteTimeUtc, now,
                                      isPdf ? FulltextState.Pending : FulltextState.NotApplicable);
            item.DefaultFileId = file.Id;
            Database.Write((c, tx) =>
            {
                Insert(c, tx, item);
                Insert(c, tx, file);
                if (groupId != null) Exec(c, tx, "INSERT INTO itemGroup (itemId, groupId, dateAdded) VALUES (?, ?, ?)", item.Id, groupId, now);
            });
            return new ImportOutcome.Imported(item.Id, isPdf);
        }
        catch
        {
            Store.Delete(relative);
            throw;
        }
    }

    ImportOutcome? DuplicateOutcome(string hash, string? groupId) => Database.Write<ImportOutcome?>((c, tx) =>
    {
        var owners = Query(c, tx, "SELECT item.* FROM item JOIN file ON file.itemId = item.id WHERE file.sha256 = ? OR file.originalSha256 = ?",
                           ReadItem, hash, hash);
        if (owners.FirstOrDefault(o => !o.IsTrashed) is { } live)
        {
            bool added = false;
            if (groupId != null && Scalar(c, tx, "SELECT 1 FROM itemGroup WHERE itemId = ? AND groupId = ?", live.Id, groupId) == null)
            {
                Exec(c, tx, "INSERT INTO itemGroup (itemId, groupId, dateAdded) VALUES (?, ?, ?)", live.Id, groupId, DateTime.UtcNow);
                added = true;
            }
            return new ImportOutcome.DuplicateFile(live.Id, added);
        }
        return owners.FirstOrDefault() is { } trashed ? new ImportOutcome.DuplicateInTrash(trashed.Id) : null;
    });

    // MARK: Retrieval results

    public ApplyOutcome ApplyMetadata(Metadata metadata, string standaloneId, bool autoRename)
    {
        var outcome = Database.Write<ApplyOutcome>((c, tx) =>
        {
            var item = FetchItem(c, tx, standaloneId);
            if (item == null || item.Kind != ItemKind.Standalone) throw LibraryException.NotFound();
            if (FindSameWork(metadata, standaloneId, c, tx) is { } existing) return new ApplyOutcome.DuplicateItem(existing);
            item.Metadata = metadata;
            item.Kind = ItemKind.Regular;
            item.MetadataState = MetadataState.Resolved;
            item.CitationKey = CitationKeyGenerator.UniqueKey(CitationKeyGenerator.BaseKey(metadata), ExistingCitationKeys(c, tx));
            item.DateModified = DateTime.UtcNow;
            Update(c, tx, item);
            return new ApplyOutcome.Created(standaloneId);
        });
        if (autoRename && outcome is ApplyOutcome.Created) RenameFiles(standaloneId);
        return outcome;
    }

    /// <summary>Attaches the standalone item's files to targetId, moves its groups, tags and note over and deletes it.</summary>
    public void MergeStandalone(string itemId, string targetId, bool autoRename)
    {
        Database.Write((c, tx) =>
        {
            var target = FetchItem(c, tx, targetId);
            if (FetchItem(c, tx, itemId) == null || target == null) throw LibraryException.NotFound();
            var moved = FilesOf(c, tx, itemId);
            foreach (var f in moved) { f.ItemId = targetId; Update(c, tx, f); }
            Exec(c, tx, "INSERT OR IGNORE INTO itemGroup (itemId, groupId, dateAdded) SELECT ?, groupId, dateAdded FROM itemGroup WHERE itemId = ?", targetId, itemId);
            Exec(c, tx, "INSERT OR IGNORE INTO itemTag (itemId, tagId) SELECT ?, tagId FROM itemTag WHERE itemId = ?", targetId, itemId);
            var note = Scalar(c, tx, "SELECT content FROM note WHERE itemId = ?", itemId) as string;
            if (note != null)
            {
                var existing = Scalar(c, tx, "SELECT content FROM note WHERE itemId = ?", targetId) as string ?? "";
                var merged = existing.Length == 0 ? note : existing + "\n\n" + note;
                Exec(c, tx, "INSERT OR REPLACE INTO note (itemId, content, dateModified) VALUES (?, ?, ?)", targetId, merged, DateTime.UtcNow);
            }
            target.DefaultFileId ??= moved.FirstOrDefault()?.Id;
            target.DateModified = DateTime.UtcNow;
            Update(c, tx, target);
            Exec(c, tx, "DELETE FROM item WHERE id = ?", itemId);
        });
        if (autoRename) RenameFiles(targetId);
    }

    /// <summary>Removes a standalone item and its stored file entirely.</summary>
    public void DiscardStandalone(string itemId)
    {
        var files = Files(itemId);
        Database.Write((c, tx) =>
        {
            DeleteFulltext(files.Select(f => f.Id).ToList(), c, tx);
            Exec(c, tx, "DELETE FROM item WHERE id = ?", itemId);
        });
        foreach (var f in files) Store.Delete(f.RelativePath);
    }

    public void SetMetadataState(MetadataState state, string itemId, bool incrementRetry = false) => Database.Write((c, tx) =>
    {
        Exec(c, tx, "UPDATE item SET metadataState = ?, retryCount = retryCount + ? WHERE id = ?", (int)state, incrementRetry ? 1 : 0, itemId);
    });

    // MARK: Creating and editing items

    public CreateOutcome CreateItem(Metadata metadata, string? groupId = null) => Database.Write<CreateOutcome>((c, tx) =>
    {
        if (FindSameWork(metadata, null, c, tx) is { } existing) return new CreateOutcome.Duplicate(existing);
        var item = new Item(ItemKind.Regular, metadata.Title) { Metadata = metadata, MetadataState = MetadataState.Resolved };
        item.CitationKey = CitationKeyGenerator.UniqueKey(CitationKeyGenerator.BaseKey(metadata), ExistingCitationKeys(c, tx));
        Insert(c, tx, item);
        if (groupId != null) Exec(c, tx, "INSERT INTO itemGroup (itemId, groupId, dateAdded) VALUES (?, ?, ?)", item.Id, groupId, item.DateAdded);
        return new CreateOutcome.Created(item.Id);
    });

    public List<AddFileOutcome> AddFiles(IEnumerable<string> paths, string itemId, bool autoRename)
    {
        var item = Item(itemId) ?? throw LibraryException.NotFound();
        var outcomes = new List<AddFileOutcome>();
        foreach (var path in paths)
        {
            try
            {
                var hash = FileHasher.Sha256(path);
                var owner = Database.Read(c => Scalar(c, null,
                    "SELECT file.itemId FROM file JOIN item ON item.id = file.itemId WHERE (file.sha256 = ? OR file.originalSha256 = ?) AND item.trashedAt IS NULL",
                    hash, hash) as string);
                if (owner != null) { outcomes.Add(new AddFileOutcome.Duplicate(owner)); continue; }
                var @base = autoRename && item.Kind == ItemKind.Regular
                    ? FileNamer.BaseName(item.Metadata)
                    : FileNamer.Sanitize(Path.GetFileNameWithoutExtension(path));
                var relative = Store.CopyIn(path, @base, Path.GetExtension(path).TrimStart('.'));
                var info = new FileInfo(Store.PathFor(relative));
                var isPdf = Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase);
                var file = new FileRecord(itemId, relative, Path.GetFileName(path), info.Length, hash, info.LastWriteTimeUtc,
                                          fulltextState: isPdf ? FulltextState.Pending : FulltextState.NotApplicable);
                Database.Write((c, tx) =>
                {
                    Insert(c, tx, file);
                    Exec(c, tx, "UPDATE item SET defaultFileId = ? WHERE id = ? AND defaultFileId IS NULL", file.Id, itemId);
                });
                outcomes.Add(new AddFileOutcome.Added(file.Id));
            }
            catch (Exception e)
            {
                outcomes.Add(new AddFileOutcome.Failed(path, e.Message));
            }
        }
        return outcomes;
    }

    /// <summary>Overwrites bibliographic fields; tags, groups, rating, read status and files are kept.</summary>
    public void UpdateMetadata(string itemId, Metadata metadata, bool autoRename)
    {
        Database.Write((c, tx) =>
        {
            var item = FetchItem(c, tx, itemId) ?? throw LibraryException.NotFound();
            item.Metadata = metadata;
            item.Kind = ItemKind.Regular;
            item.MetadataState = MetadataState.Resolved;
            if (string.IsNullOrEmpty(item.CitationKey))
                item.CitationKey = CitationKeyGenerator.UniqueKey(CitationKeyGenerator.BaseKey(metadata), ExistingCitationKeys(c, tx));
            item.DateModified = DateTime.UtcNow;
            Update(c, tx, item);
        });
        if (autoRename) RenameFiles(itemId);
    }

    /// <summary>Applies an arbitrary edit (inspector fields, rating, read status…).</summary>
    public void UpdateItem(string itemId, Action<Item> change) => Database.Write((c, tx) =>
    {
        var item = FetchItem(c, tx, itemId) ?? throw LibraryException.NotFound();
        change(item);
        item.Doi = item.Doi?.ToLowerInvariant();
        item.DateModified = DateTime.UtcNow;
        Update(c, tx, item);
    });

    public void UpdateItems(IEnumerable<string> itemIds, Action<Item> change) => Database.Write((c, tx) =>
    {
        foreach (var id in itemIds)
        {
            if (FetchItem(c, tx, id) is not { } item) continue;
            change(item);
            item.DateModified = DateTime.UtcNow;
            Update(c, tx, item);
        }
    });

    public void SetDefaultFile(string fileId) => Database.Write((c, tx) =>
    {
        var file = FetchFile(c, tx, fileId) ?? throw LibraryException.NotFound();
        Exec(c, tx, "UPDATE item SET defaultFileId = ? WHERE id = ?", fileId, file.ItemId);
    });

    /// <summary>Renames every file of a regular item to Family_Year_Title; a translation keeps its note.</summary>
    public void RenameFiles(string itemId)
    {
        var item = Item(itemId);
        if (item == null || item.Kind != ItemKind.Regular) return;
        var @base = FileNamer.BaseName(item.Metadata);
        foreach (var file in Files(itemId))
        {
            var name = @base;
            if (file.TranslationKind is { } kind)
            {
                var stem = Path.GetFileNameWithoutExtension(file.FileName);
                name += FileNamer.TranslationSuffix(stem) ?? FileNamer.TranslationSuffix(kind, file.TranslatedBy);
            }
            var renamed = Store.Rename(file.RelativePath, name);
            if (renamed == file.RelativePath) continue;
            file.RelativePath = renamed;
            Database.Write((c, tx) => Update(c, tx, file));
        }
    }

    /// <summary>Renames a single file (inspector ▸ rename); keeps the extension.</summary>
    public void RenameFile(string fileId, string newBaseName)
    {
        var file = File(fileId) ?? throw LibraryException.NotFound();
        var clean = FileNamer.Sanitize(newBaseName);
        if (clean.Length == 0) throw LibraryException.EmptyName();
        var renamed = Store.Rename(file.RelativePath, clean);
        if (renamed == file.RelativePath) return;
        file.RelativePath = renamed;
        Database.Write((c, tx) =>
        {
            Update(c, tx, file);
            Exec(c, tx, "UPDATE item SET title = ? WHERE id = ? AND kind = ?", Path.GetFileName(renamed), file.ItemId, (int)ItemKind.Standalone);
        });
    }

    static string? FindSameWork(Metadata metadata, string? excluding, SqliteConnection c, SqliteTransaction tx)
    {
        var candidates = Query(c, tx, "SELECT * FROM item WHERE kind = ? AND trashedAt IS NULL", ReadItem, (int)ItemKind.Regular);
        return candidates.FirstOrDefault(candidate =>
        {
            if (candidate.Id == excluding) return false;
            if (!string.IsNullOrEmpty(metadata.Isbn) && candidate.Isbn == metadata.Isbn) return true;
            return DuplicateMatcher.IsSameWork(candidate.Metadata, metadata);
        })?.Id;
    }

    // MARK: Groups

    public LibraryGroup CreateGroup(string name, string? parentId = null)
    {
        var clean = name.Trim();
        if (clean.Length == 0) throw LibraryException.EmptyName();
        return Database.Write((c, tx) =>
        {
            if (parentId != null)
            {
                var parent = FetchGroup(c, tx, parentId) ?? throw LibraryException.NotFound();
                if (parent.ParentId != null) throw LibraryException.GroupDepthExceeded();
            }
            var siblings = Siblings(parentId, c, tx);
            EnsureUniqueName(clean, siblings, null);
            var group = new LibraryGroup(clean, (siblings.Count == 0 ? -1 : siblings.Max(s => s.Position)) + 1, parentId);
            Insert(c, tx, group);
            return group;
        });
    }

    public void RenameGroup(string id, string name)
    {
        var clean = name.Trim();
        if (clean.Length == 0) throw LibraryException.EmptyName();
        Database.Write((c, tx) =>
        {
            var group = FetchGroup(c, tx, id) ?? throw LibraryException.NotFound();
            EnsureUniqueName(clean, Siblings(group.ParentId, c, tx), id);
            group.Name = clean;
            Update(c, tx, group);
        });
    }

    public void SetGroupColor(string id, string? colorHex) => Database.Write((c, tx) =>
    {
        if (Exec(c, tx, "UPDATE libraryGroup SET colorHex = ? WHERE id = ?", colorHex, id) == 0) throw LibraryException.NotFound();
    });

    /// <summary>Deletes the group and its subgroups. Items stay in the library unless trashItems.</summary>
    public void DeleteGroup(string id, bool trashItems) => Database.Write((c, tx) =>
    {
        var ids = new List<string> { id };
        ids.AddRange(Strings(c, tx, "SELECT id FROM libraryGroup WHERE parentId = ?", id));
        if (trashItems)
            Exec(c, tx, $"UPDATE item SET trashedAt = ? WHERE trashedAt IS NULL AND id IN (SELECT itemId FROM itemGroup WHERE groupId IN ({Placeholders(ids.Count)}))",
                 [DateTime.UtcNow, .. ids]);
        Exec(c, tx, $"DELETE FROM itemOrder WHERE scope IN ({Placeholders(ids.Count)})", [.. ids.Select(g => ViewScope.Group(g).Key)]);
        Exec(c, tx, "DELETE FROM libraryGroup WHERE id = ?", id);
    });

    public bool CanMoveGroup(string id, string? parentId) => Database.Read(c => CanMove(id, parentId, c, null));

    public void MoveGroup(string id, string? parentId, int index) => Database.Write((c, tx) =>
    {
        if (!CanMove(id, parentId, c, tx)) throw LibraryException.GroupDepthExceeded();
        var group = FetchGroup(c, tx, id) ?? throw LibraryException.NotFound();
        var siblings = Siblings(parentId, c, tx).Where(s => s.Id != id).ToList();
        if (group.ParentId != parentId) EnsureUniqueName(group.Name, siblings, id);
        group.ParentId = parentId;
        siblings.Insert(Math.Clamp(index, 0, siblings.Count), group);
        for (int position = 0; position < siblings.Count; position++)
        {
            siblings[position].Position = position;
            Update(c, tx, siblings[position]);
        }
    });

    public MembershipResult AddItems(IEnumerable<string> itemIds, string groupId, bool includeSubgroups) => Database.Write((c, tx) =>
    {
        if (FetchGroup(c, tx, groupId) == null) throw LibraryException.NotFound();
        var present = MemberIds(groupId, includeSubgroups, c, tx).ToHashSet();
        var result = new MembershipResult();
        foreach (var id in itemIds)
        {
            if (present.Contains(id)) { result.AlreadyPresent.Add(id); continue; }
            Exec(c, tx, "INSERT OR IGNORE INTO itemGroup (itemId, groupId, dateAdded) VALUES (?, ?, ?)", id, groupId, DateTime.UtcNow);
            result.Added.Add(id);
        }
        return result;
    });

    public void RemoveItems(IEnumerable<string> itemIds, string groupId, bool includeSubgroups) => Database.Write((c, tx) =>
    {
        var groups = new List<string> { groupId };
        if (includeSubgroups) groups.AddRange(Strings(c, tx, "SELECT id FROM libraryGroup WHERE parentId = ?", groupId));
        var ids = itemIds.ToList();
        if (ids.Count == 0) return;
        Exec(c, tx, $"DELETE FROM itemGroup WHERE itemId IN ({Placeholders(ids.Count)}) AND groupId IN ({Placeholders(groups.Count)})", [.. ids, .. groups]);
    });

    static List<LibraryGroup> Siblings(string? parentId, SqliteConnection c, SqliteTransaction? tx) => parentId == null
        ? Query(c, tx, "SELECT * FROM libraryGroup WHERE parentId IS NULL ORDER BY position", ReadGroup)
        : Query(c, tx, "SELECT * FROM libraryGroup WHERE parentId = ? ORDER BY position", ReadGroup, parentId);

    static void EnsureUniqueName(string name, List<LibraryGroup> groups, string? excluding)
    {
        if (groups.Any(g => g.Id != excluding && string.Equals(g.Name, name, StringComparison.CurrentCultureIgnoreCase)))
            throw LibraryException.DuplicateGroupName(name);
    }

    static bool CanMove(string id, string? parentId, SqliteConnection c, SqliteTransaction? tx)
    {
        if (FetchGroup(c, tx, id) == null) return false;
        if (parentId == null) return true;
        if (parentId == id || FetchGroup(c, tx, parentId) is not { ParentId: null }) return false;
        return Convert.ToInt64(Scalar(c, tx, "SELECT COUNT(*) FROM libraryGroup WHERE parentId = ?", id)) == 0;
    }

    static List<string> MemberIds(string groupId, bool includeSubgroups, SqliteConnection c, SqliteTransaction? tx) => includeSubgroups
        ? Strings(c, tx, "SELECT itemId FROM itemGroup WHERE groupId = ? OR groupId IN (SELECT id FROM libraryGroup WHERE parentId = ?)", groupId, groupId)
        : Strings(c, tx, "SELECT itemId FROM itemGroup WHERE groupId = ?", groupId);

    // MARK: Tags

    public Tag CreateTag(string name, string colorHex)
    {
        var clean = name.Trim();
        if (clean.Length == 0) throw LibraryException.EmptyName();
        return Database.Write((c, tx) =>
        {
            EnsureUniqueTagName(clean, null, c, tx);
            var max = Scalar(c, tx, "SELECT MAX(position) FROM tag");
            var tag = new Tag(clean, colorHex, (max == null ? -1 : Convert.ToDouble(max)) + 1);
            Exec(c, tx, "INSERT INTO tag (id, name, colorHex, position) VALUES (?, ?, ?, ?)", tag.Id, tag.Name, tag.ColorHex, tag.Position);
            return tag;
        });
    }

    public void UpdateTag(string id, string name, string colorHex)
    {
        var clean = name.Trim();
        if (clean.Length == 0) throw LibraryException.EmptyName();
        Database.Write((c, tx) =>
        {
            EnsureUniqueTagName(clean, id, c, tx);
            if (Exec(c, tx, "UPDATE tag SET name = ?, colorHex = ? WHERE id = ?", clean, colorHex, id) == 0) throw LibraryException.NotFound();
        });
    }

    public void DeleteTag(string id) => Database.Write((c, tx) =>
    {
        Exec(c, tx, "DELETE FROM itemOrder WHERE scope = ?", ViewScope.TagOf(id).Key);
        Exec(c, tx, "DELETE FROM tag WHERE id = ?", id);
    });

    /// <summary>Moves a tag to index among the tags (sidebar drag and drop).</summary>
    public void MoveTag(string id, int index) => Database.Write((c, tx) =>
    {
        var tags = Query(c, tx, "SELECT * FROM tag ORDER BY position, name", ReadTag);
        var tag = tags.FirstOrDefault(t => t.Id == id) ?? throw LibraryException.NotFound();
        tags.Remove(tag);
        tags.Insert(Math.Clamp(index, 0, tags.Count), tag);
        for (int i = 0; i < tags.Count; i++) Exec(c, tx, "UPDATE tag SET position = ? WHERE id = ?", (double)i, tags[i].Id);
    });

    public void SetTag(string tagId, IEnumerable<string> itemIds, bool enabled) => Database.Write((c, tx) =>
    {
        foreach (var id in itemIds)
        {
            if (enabled) Exec(c, tx, "INSERT OR IGNORE INTO itemTag (itemId, tagId) VALUES (?, ?)", id, tagId);
            else Exec(c, tx, "DELETE FROM itemTag WHERE tagId = ? AND itemId = ?", tagId, id);
        }
    });

    public int ItemCount(string tagId) => Database.Read(c => Convert.ToInt32(Scalar(c, null, "SELECT COUNT(*) FROM itemTag WHERE tagId = ?", tagId)));

    static void EnsureUniqueTagName(string name, string? excluding, SqliteConnection c, SqliteTransaction tx)
    {
        if (Scalar(c, tx, "SELECT id FROM tag WHERE name = ? COLLATE NOCASE", name) is string clash && clash != excluding)
            throw LibraryException.DuplicateTagName(name);
    }

    /// <summary>The tag named name (any case), created with the next preset colour when missing.</summary>
    public string EnsureTag(string name)
    {
        var clean = name.Trim();
        var existing = Database.Read(c => Scalar(c, null, "SELECT id FROM tag WHERE name = ? COLLATE NOCASE", clean) as string);
        if (existing != null) return existing;
        var count = Database.Read(c => Convert.ToInt32(Scalar(c, null, "SELECT COUNT(*) FROM tag")));
        return CreateTag(clean, TagPalette.Presets[count % TagPalette.Presets.Length].Hex).Id;
    }

    // MARK: Trash

    /// <summary>Moves items to the trash. Group memberships are kept so restore can return them.</summary>
    public void TrashItems(IEnumerable<string> itemIds) => Database.Write((c, tx) =>
    {
        var now = DateTime.UtcNow;
        foreach (var id in itemIds) Exec(c, tx, "UPDATE item SET trashedAt = ? WHERE id = ? AND trashedAt IS NULL", now, id);
    });

    /// <summary>Trashes individual files. A file of a regular item is detached into its own trashed standalone item.</summary>
    public void TrashFiles(IEnumerable<string> fileIds) => Database.Write((c, tx) =>
    {
        var now = DateTime.UtcNow;
        foreach (var fileId in fileIds)
        {
            var file = FetchFile(c, tx, fileId);
            var parent = file == null ? null : FetchItem(c, tx, file.ItemId);
            if (file == null || parent == null || parent.IsTrashed) continue;
            if (parent.Kind == ItemKind.Standalone)
            {
                parent.TrashedAt = now;
                Update(c, tx, parent);
                continue;
            }
            var detached = new Item(ItemKind.Standalone, file.FileName, file.DateAdded) { OriginItemId = parent.Id, TrashedAt = now, DefaultFileId = file.Id };
            Insert(c, tx, detached);
            file.ItemId = detached.Id;
            Update(c, tx, file);
            if (parent.DefaultFileId == fileId)
            {
                parent.DefaultFileId = FilesOf(c, tx, parent.Id).FirstOrDefault()?.Id;
                Update(c, tx, parent);
            }
        }
    });

    /// <summary>Restores trashed items to their groups; detached files go back to their item when possible.</summary>
    public void RestoreItems(IEnumerable<string> itemIds) => Database.Write((c, tx) =>
    {
        foreach (var id in itemIds)
        {
            var item = FetchItem(c, tx, id);
            if (item == null || !item.IsTrashed) continue;
            if (item.OriginItemId is { } originId && FetchItem(c, tx, originId) is { IsTrashed: false } origin)
            {
                var files = FilesOf(c, tx, id);
                foreach (var f in files) { f.ItemId = originId; Update(c, tx, f); }
                if (origin.DefaultFileId == null)
                {
                    origin.DefaultFileId = files.FirstOrDefault()?.Id;
                    Update(c, tx, origin);
                }
                Exec(c, tx, "DELETE FROM item WHERE id = ?", id);
            }
            else
            {
                item.TrashedAt = null;
                item.OriginItemId = null;
                Update(c, tx, item);
            }
        }
    });

    /// <summary>Permanently deletes items, their stored files and index entries.</summary>
    public void PurgeItems(IReadOnlyCollection<string> itemIds)
    {
        if (itemIds.Count == 0) return;
        var paths = Database.Write((c, tx) =>
        {
            var ids = itemIds.ToList();
            var files = Query(c, tx, $"SELECT * FROM file WHERE itemId IN ({Placeholders(ids.Count)})", ReadFile, [.. ids]);
            DeleteFulltext(files.Select(f => f.Id).ToList(), c, tx);
            Exec(c, tx, $"UPDATE item SET originItemId = NULL WHERE originItemId IN ({Placeholders(ids.Count)})", [.. ids]);
            Exec(c, tx, $"DELETE FROM item WHERE id IN ({Placeholders(ids.Count)})", [.. ids]);
            return files.Select(f => f.RelativePath).ToList();
        });
        foreach (var p in paths) Store.Delete(p);
    }

    public void EmptyTrash() => PurgeItems(Database.Read(c => Strings(c, null, "SELECT id FROM item WHERE trashedAt IS NOT NULL")));

    public void PurgeTrash(DateTime olderThan) =>
        PurgeItems(Database.Read(c => Strings(c, null, "SELECT id FROM item WHERE trashedAt IS NOT NULL AND trashedAt < ?", olderThan)));

    // MARK: Full-text index and change detection

    public void SetFulltext(IReadOnlyList<(string FileId, string? Text)> results)
    {
        if (results.Count == 0) return;
        Database.Write((c, tx) =>
        {
            DeleteFulltext(results.Select(r => r.FileId).ToList(), c, tx);
            foreach (var (fileId, text) in results)
            {
                if (text != null) Exec(c, tx, "INSERT INTO fulltext (fileId, content) VALUES (?, ?)", fileId, text);
                Exec(c, tx, "UPDATE file SET fulltextState = ? WHERE id = ?", (int)(text == null ? FulltextState.NotApplicable : FulltextState.Indexed), fileId);
            }
        });
    }

    public List<FileRecord> FilesNeedingFulltext() =>
        Database.Read(c => Query(c, null, "SELECT * FROM file WHERE fulltextState = ?", ReadFile, (int)FulltextState.Pending)).Where(f => f.IsPdf).ToList();

    static string MatchExpression(string query, string joiner)
    {
        var tokens = SearchMatcher.Tokens(query);
        return string.Join(joiner, tokens.Select(t => $"\"{t.Replace("\"", "\"\"")}\"*"));
    }

    /// <summary>Items whose indexed PDF text contains every token of query (prefix match).</summary>
    public HashSet<string> FulltextItemIds(string query)
    {
        var match = MatchExpression(query, " AND ");
        if (match.Length == 0) return [];
        return Database.Read(c => Strings(c, null,
            "SELECT DISTINCT file.itemId FROM fulltext JOIN file ON file.id = fulltext.fileId WHERE fulltext MATCH ?", match)).ToHashSet();
    }

    /// <summary>Items whose PDF text contains any token of query, best first, with an excerpt («matches»).</summary>
    public List<FulltextHit> FulltextHits(string query, int limit = 200)
    {
        var match = MatchExpression(query, " OR ");
        if (match.Length == 0) return [];
        var rows = Database.Read(c => Query(c, null, """
            SELECT file.itemId AS itemId, bm25(fulltext) AS rank, snippet(fulltext, 1, '«', '»', '…', 24) AS snippet
            FROM fulltext JOIN file ON file.id = fulltext.fileId WHERE fulltext MATCH ? ORDER BY rank LIMIT ?
            """, r => (r.GetString(0), r.GetDouble(1), r.IsDBNull(2) ? "" : r.GetString(2)), match, limit * 2));
        var seen = new HashSet<string>();
        var hits = new List<FulltextHit>();
        foreach (var (itemId, rank, snippet) in rows)
        {
            if (!seen.Add(itemId)) continue;
            hits.Add(new FulltextHit(itemId, rank, System.Text.RegularExpressions.Regex.Replace(snippet, @"\s+", " ")));
        }
        return hits.Take(limit).ToList();
    }

    /// <summary>Detects files changed on disk (annotated in the reader or elsewhere) and queues them for re-indexing.</summary>
    public List<string> RefreshFingerprints()
    {
        var files = Database.Read(c => Query(c, null, "SELECT * FROM file", ReadFile));
        var changed = new List<FileRecord>();
        foreach (var file in files)
        {
            var info = new FileInfo(Store.PathFor(file.RelativePath));
            if (!info.Exists) continue;
            if (info.Length == file.Size && Math.Abs((info.LastWriteTimeUtc - file.ModifiedAt).TotalSeconds) <= 0.5) continue;
            file.Size = info.Length;
            file.ModifiedAt = info.LastWriteTimeUtc;
            try { file.Sha256 = FileHasher.Sha256(info.FullName); } catch (IOException) { }
            if (file.IsPdf) file.FulltextState = FulltextState.Pending;
            changed.Add(file);
        }
        if (changed.Count == 0) return [];
        Database.Write((c, tx) => { foreach (var f in changed) Update(c, tx, f); });
        return changed.Select(f => f.Id).ToList();
    }

    static void DeleteFulltext(List<string> fileIds, SqliteConnection c, SqliteTransaction tx)
    {
        if (fileIds.Count == 0) return;
        Exec(c, tx, $"DELETE FROM fulltext WHERE fileId IN ({Placeholders(fileIds.Count)})", [.. fileIds]);
    }

    // MARK: Custom order and sorting

    public void MoveItems(IReadOnlyCollection<string> itemIds, ViewScope scope, IReadOnlyList<string> displayedOrder, int toIndex)
    {
        var moving = itemIds.ToHashSet();
        var clamped = Math.Clamp(toIndex, 0, displayedOrder.Count);
        var insertAt = displayedOrder.Take(clamped).Count(id => !moving.Contains(id));
        var order = displayedOrder.Where(id => !moving.Contains(id)).ToList();
        order.InsertRange(insertAt, displayedOrder.Where(moving.Contains));
        Database.Write((c, tx) =>
        {
            Exec(c, tx, "DELETE FROM itemOrder WHERE scope = ?", scope.Key);
            for (int i = 0; i < order.Count; i++) Exec(c, tx, "INSERT INTO itemOrder (scope, itemId, position) VALUES (?, ?, ?)", scope.Key, order[i], (double)i);
            Exec(c, tx, "INSERT OR REPLACE INTO viewSort (scope, sortColumn, ascending) VALUES (?, NULL, 1)", scope.Key);
        });
    }

    public void SetSort(SortState sort, ViewScope scope) => Database.Write((c, tx) =>
        Exec(c, tx, "INSERT OR REPLACE INTO viewSort (scope, sortColumn, ascending) VALUES (?, ?, ?)", scope.Key, sort.Column?.Raw(), sort.Ascending));

    // MARK: Notes and reading positions

    public string Note(string itemId) => Database.Read(c => Scalar(c, null, "SELECT content FROM note WHERE itemId = ?", itemId) as string) ?? "";

    /// <summary>Saves the note; an empty (whitespace-only) note is removed.</summary>
    public void SetNote(string content, string itemId) => Database.Write((c, tx) =>
    {
        if (FetchItem(c, tx, itemId) == null) throw LibraryException.NotFound();
        if (string.IsNullOrWhiteSpace(content)) Exec(c, tx, "DELETE FROM note WHERE itemId = ?", itemId);
        else if (Scalar(c, tx, "SELECT content FROM note WHERE itemId = ?", itemId) as string != content)
            Exec(c, tx, "INSERT OR REPLACE INTO note (itemId, content, dateModified) VALUES (?, ?, ?)", itemId, content, DateTime.UtcNow);
    });

    public ReadingState? ReadingState(string fileId) =>
        Database.Read(c => Query(c, null, "SELECT * FROM readingState WHERE fileId = ?", ReadReading, fileId).FirstOrDefault());

    /// <summary>Saved without raising Changed: scrolling never refreshes the list.</summary>
    public void SaveReadingState(ReadingState s) => Database.Read(c =>
        Exec(c, null, """
            INSERT OR REPLACE INTO readingState (fileId, pageIndex, pointX, pointY, scale, autoScale, displayMode, dateModified)
            SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM file WHERE id = ?)
            """, s.FileId, s.PageIndex, s.PointX, s.PointY, s.Scale, s.AutoScale, s.DisplayMode, s.DateModified, s.FileId));

    public Dictionary<string, DateTime> LastReadDates() => Database.Read(c => Query(c, null, """
        SELECT file.itemId AS itemId, MAX(readingState.dateModified) AS date
        FROM readingState JOIN file ON file.id = readingState.fileId GROUP BY file.itemId
        """, r => (Str(r, "itemId")!, Date(r, "date"))).Where(x => x.Item2 != null).ToDictionary(x => x.Item1, x => x.Item2!.Value));

    // MARK: Translations

    /// <summary>Copies a translation into the library: it joins the source's item, or becomes its own standalone file.</summary>
    public FileRecord AddTranslatedFile(string path, string sourceFileId, TranslationKind kind, string baseName, string? translatedBy = null)
    {
        var source = File(sourceFileId) ?? throw LibraryException.NotFound();
        var owner = Item(source.ItemId) ?? throw LibraryException.NotFound();
        var hash = FileHasher.Sha256(path);
        var relative = Store.CopyIn(path, FileNamer.Sanitize(baseName), Path.GetExtension(path).TrimStart('.'));
        try
        {
            var info = new FileInfo(Store.PathFor(relative));
            var now = DateTime.UtcNow;
            return Database.Write((c, tx) =>
            {
                var itemId = owner.Id;
                if (owner.Kind == ItemKind.Standalone)
                {
                    var item = new Item(ItemKind.Standalone, relative.Split('/').Last(), now);
                    Insert(c, tx, item);
                    Exec(c, tx, "INSERT OR IGNORE INTO itemGroup (itemId, groupId, dateAdded) SELECT ?, groupId, ? FROM itemGroup WHERE itemId = ?", item.Id, now, owner.Id);
                    itemId = item.Id;
                }
                var file = new FileRecord(itemId, relative, relative.Split('/').Last(), info.Length, hash, info.LastWriteTimeUtc, now)
                {
                    TranslationOf = sourceFileId, TranslationKind = kind, TranslatedBy = translatedBy,
                };
                Insert(c, tx, file);
                Exec(c, tx, "UPDATE item SET defaultFileId = ? WHERE id = ? AND defaultFileId IS NULL", file.Id, itemId);
                return file;
            });
        }
        catch
        {
            Store.Delete(relative);
            throw;
        }
    }

    // MARK: References (BibTeX / RIS / CSL JSON import)

    public ReferenceImportResult ImportReferences(IEnumerable<(Metadata Metadata, string? CitationKey)> references, string? groupId = null)
    {
        var result = new ReferenceImportResult();
        foreach (var (metadata, key) in references)
        {
            switch (CreateItem(metadata, groupId))
            {
                case CreateOutcome.Created created:
                    result.Created.Add(created.ItemId);
                    if (key?.Trim() is { Length: > 0 } clean)
                        Database.Write((c, tx) =>
                        {
                            if (!ExistingCitationKeys(c, tx).Contains(clean)) Exec(c, tx, "UPDATE item SET citationKey = ? WHERE id = ?", clean, created.ItemId);
                        });
                    break;
                case CreateOutcome.Duplicate duplicate:
                    result.Duplicates.Add(duplicate.ExistingItemId);
                    if (groupId != null) AddItems([duplicate.ExistingItemId], groupId, false);
                    break;
            }
        }
        return result;
    }

    // MARK: Snapshot

    public LibrarySnapshot Snapshot() => Database.Read(LibrarySnapshot.Fetch);
}
