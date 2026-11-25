using Microsoft.Data.Sqlite;
using static Folio.Core.AppDatabase;
using static Folio.Core.Records;

namespace Folio.Core;

/// <summary>A folder dropped on Folio, with what can be imported from it: it becomes a group, its subfolders that group's subgroups
/// (the macOS app's Library+Folders.swift).</summary>
public sealed record ImportFolder(string Name, List<string> Files, List<ImportFolder> Children)
{
    public int FileCount => Files.Count + Children.Sum(c => c.FileCount);
    /// <summary>Everything in it, whatever folder it is in.</summary>
    public IEnumerable<string> AllFiles => Files.Concat(Children.SelectMany(c => c.AllFiles));

    /// <summary>Reads a folder (hidden files and links to other folders aside): papers and Markdown documents. Folders with nothing to
    /// import are left out; null when there is nothing at all.</summary>
    public static ImportFolder? Scan(string path, int depth = 0)
    {
        if (depth >= 24) return null;
        var folder = new ImportFolder(Path.GetFileName(Path.TrimEndingDirectorySeparator(path)).Trim(), [], []);
        try
        {
            var info = new DirectoryInfo(path);
            static bool Skipped(FileSystemInfo e) => e.Name.StartsWith('.') || (e.Attributes & (FileAttributes.Hidden | FileAttributes.ReparsePoint)) != 0;
            foreach (var file in info.EnumerateFiles().Where(f => !f.Name.StartsWith('.') && (f.Attributes & FileAttributes.Hidden) == 0).OrderBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase))
                if (file.Extension.ToLowerInvariant() is ".pdf" or ".md" or ".markdown") folder.Files.Add(file.FullName);
            foreach (var child in info.EnumerateDirectories().Where(d => !Skipped(d)).OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase))
                if (Scan(child.FullName, depth + 1) is { } found) folder.Children.Add(found);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return folder.FileCount == 0 ? null : folder;
    }
}

public sealed partial class Library
{
    /// <summary>Imports a folder as a group under parentId (null: the top level), at index among its groups (null: the end); a group of
    /// that name there is gone on with. Folders deeper than groups go are put in the last level's group. GroupId is null at that level:
    /// its files went to the group they were dropped on.</summary>
    public (string? GroupId, List<ImportOutcome> Outcomes) ImportFolder(ImportFolder folder, string? parentId = null, int? index = null)
    {
        int depth = parentId == null ? 0 : Database.Read(c => Depth(parentId, c, null));
        if (depth >= LibraryGroup.MaximumDepth) return (null, ImportFiles(folder.AllFiles, parentId));
        var name = folder.Name.Length == 0 ? "Folder" : folder.Name;
        var siblings = Database.Read(c => Siblings(parentId, c, null));
        var group = siblings.FirstOrDefault(g => g.Name.Equals(name, StringComparison.CurrentCultureIgnoreCase));
        if (group == null)
        {
            group = CreateGroup(name, parentId);
            if (index is { } at && at < siblings.Count) MoveGroup(group.Id, parentId, at);
        }
        var outcomes = ImportFiles(folder.Files, group.Id);
        // What is in the trash will be in the group once it is put back.
        foreach (var trashed in outcomes.OfType<ImportOutcome.DuplicateInTrash>())
            Database.Write((c, tx) => Exec(c, tx, "INSERT OR IGNORE INTO itemGroup (itemId, groupId, dateAdded) VALUES (?, ?, ?)", trashed.ExistingItemId, group.Id, DateTime.UtcNow));
        foreach (var child in folder.Children) outcomes.AddRange(ImportFolder(child, group.Id).Outcomes);
        return (group.Id, outcomes);
    }
}
