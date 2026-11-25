using System.Text;
using Microsoft.Data.Sqlite;
using static Folio.Core.AppDatabase;
using static Folio.Core.Records;

namespace Folio.Core;

/// <summary>Markdown documents kept in the library (MD-01): written in Folio, as an item of their own or attached to a
/// paper, stored as <c>.md</c> files in <c>Files/</c> like any other file, so they stay readable and editable outside
/// Folio. The same records as the macOS app (Library+Markdown.swift).</summary>
public sealed partial class Library
{
    static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    /// <summary>A new Markdown document as an item of its own (in groupId when given). Returns its item and file ids.</summary>
    public (string ItemId, string FileId) CreateMarkdownDocument(string title, string? groupId = null, string? text = null)
    {
        // A new document starts empty: the title only names the file (and the item, until the first heading does).
        var body = text ?? "";
        // Unnamed documents are told apart by a number: the first that no other document in the list has.
        var name = IsUnnamed(title) ? Free(title, Database.Read(DocumentTitles)) : title;
        var relative = WriteNewTextFile(FileNamer.Sanitize(name), body);
        var now = DateTime.UtcNow;
        var item = new Item(ItemKind.Standalone, name, now) { MetadataState = MetadataState.None };
        var file = TextFileRecord(relative, name, item.Id, body, now);
        item.DefaultFileId = file.Id;
        try
        {
            Database.Write((c, tx) =>
            {
                Insert(c, tx, item);
                Insert(c, tx, file);
                if (groupId != null) Exec(c, tx, "INSERT INTO itemGroup (itemId, groupId, dateAdded) VALUES (?, ?, ?)", item.Id, groupId, now);
                IndexText(body, file.Id, c, tx);
            });
        }
        catch
        {
            Store.Delete(relative);
            throw;
        }
        return (item.Id, file.Id);
    }

    /// <summary>A new Markdown document attached to an item (a paper's reading notes, a summary). Returns the file id.</summary>
    public string CreateMarkdownAttachment(string title, string itemId, string? text = null)
    {
        if (Item(itemId) == null) throw LibraryException.NotFound();
        var body = text ?? "";
        var name = Free(title, Files(itemId).Where(f => f.IsMarkdown).Select(f => f.DocumentName.ToLowerInvariant()).ToHashSet());
        var relative = WriteNewTextFile(FileNamer.Sanitize(name), body);
        var file = TextFileRecord(relative, name, itemId, body, DateTime.UtcNow);
        try
        {
            Database.Write((c, tx) =>
            {
                Insert(c, tx, file);
                Exec(c, tx, "UPDATE item SET defaultFileId = ? WHERE id = ? AND defaultFileId IS NULL", file.Id, itemId);
                IndexText(body, file.Id, c, tx);
            });
        }
        catch
        {
            Store.Delete(relative);
            throw;
        }
        return file.Id;
    }

    /// <summary>The text of a text file in the library ("" when it cannot be read).</summary>
    public string Text(string fileId)
    {
        var file = File(fileId) ?? throw LibraryException.NotFound();
        try { return System.IO.File.ReadAllText(Store.PathFor(file.RelativePath), Encoding.UTF8); }
        catch (IOException) { return ""; }
        catch (UnauthorizedAccessException) { return ""; }
    }

    /// <summary>Saves a text file's new contents: the file on disk, its size, date and hash, the search index, and the name
    /// of a document nobody has named, from what it starts with.</summary>
    public void WriteText(string text, string fileId)
    {
        var file = File(fileId) ?? throw LibraryException.NotFound();
        var path = Store.PathFor(file.RelativePath);
        string? before = null;
        try { before = NameFrom(System.IO.File.ReadAllText(path, Encoding.UTF8))?.Name; } catch (IOException) { } catch (UnauthorizedAccessException) { }
        var temp = path + ".folio-tmp";
        System.IO.File.WriteAllText(temp, text, Utf8);
        System.IO.File.Move(temp, path, overwrite: true);
        var info = new FileInfo(path);
        var now = DateTime.UtcNow;
        file.Size = info.Length;
        file.ModifiedAt = info.LastWriteTimeUtc;
        try { file.Sha256 = FileHasher.Sha256(path); } catch (IOException) { }
        // A document nobody has named is called after its first heading, or its first line; a name given by hand stays.
        string? title = null;
        if (file.IsMarkdown && NameFrom(text) is { } found && Item(file.ItemId) is { } owner)
        {
            bool own = owner.Kind == ItemKind.Standalone && owner.DefaultFileId == file.Id;
            var current = own ? owner.Title : file.DocumentName;
            if (IsUnnamed(current) || current == before)
            {
                if (own && found.Name != current) title = found.Name;
                // The file follows once the line is written, not letter by letter.
                var name = FileNamer.Sanitize(found.Name);
                if (found.IsFinished && name.Length > 0 && (own || found.Name != current) && (name != file.DocumentName || file.OriginalName != name + ".md"))
                    try
                    {
                        if (name != file.DocumentName) file.RelativePath = Store.Rename(file.RelativePath, name);
                        file.OriginalName = name + ".md";
                    }
                    catch (IOException) { }
            }
        }
        Database.Write((c, tx) =>
        {
            Update(c, tx, file);
            IndexText(text, file.Id, c, tx);
            if (FetchItem(c, tx, file.ItemId) is { } item)
            {
                if (title != null) item.Title = title;
                item.DateModified = now;
                Update(c, tx, item);
            }
        });
    }

    /// <summary>Renames a Markdown file to name.md (a number added if taken); a document that is an item of its own takes
    /// the name as its title too.</summary>
    public FileRecord RenameMarkdownFile(string fileId, string name)
    {
        var file = File(fileId) ?? throw LibraryException.NotFound();
        var title = name.Trim();
        var @base = FileNamer.Sanitize(title);
        if (@base.Length == 0) return file;
        file.RelativePath = Store.Rename(file.RelativePath, @base);
        file.OriginalName = @base + Path.GetExtension(file.RelativePath);
        Database.Write((c, tx) =>
        {
            Update(c, tx, file);
            if (FetchItem(c, tx, file.ItemId) is { Kind: ItemKind.Standalone } item && item.DefaultFileId == file.Id)
            {
                item.Title = title;
                item.DateModified = DateTime.UtcNow;
                Update(c, tx, item);
            }
        });
        return file;
    }

    /// <summary>"未命名文档", "Untitled Document 2": what Folio calls a new document.</summary>
    public static bool IsUnnamed(string title) =>
        System.Text.RegularExpressions.Regex.IsMatch(title, @"^(未命名文档|Untitled( Document)?)( \d+)?$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    public static string WithoutMarkdownExtension(string name) =>
        Path.GetExtension(name).ToLowerInvariant() is ".md" or ".markdown" ? Path.GetFileNameWithoutExtension(name) : name;

    /// <summary>title, or the first of "title 2", "title 3"… that is not taken (in lower case).</summary>
    static string Free(string title, HashSet<string> taken)
    {
        if (!taken.Contains(title.ToLowerInvariant())) return title;
        int number = 2;
        while (taken.Contains($"{title} {number}".ToLowerInvariant())) number++;
        return $"{title} {number}";
    }

    /// <summary>The names of the documents that are items of their own (those in the trash aside).</summary>
    static HashSet<string> DocumentTitles(SqliteConnection c) =>
        Strings(c, null, "SELECT title FROM item WHERE kind = ? AND trashedAt IS NULL", (int)ItemKind.Standalone).Select(t => WithoutMarkdownExtension(t).ToLowerInvariant()).ToHashSet();

    /// <summary>What a document nobody has named is called: its first heading, else the first line it has. IsFinished: more
    /// comes after that line, or it is a heading.</summary>
    public static (string Name, bool IsFinished)? NameFrom(string text)
    {
        if (FirstHeading(text) is { } heading) return (heading, true);
        var lines = text.Split('\n').Select(l => l.Trim(' ', '\t', '\r')).ToList();
        int start = 0;
        // Front matter says things about the document; it is not its text.
        if (lines[0] == "---" && lines.FindIndex(1, l => l == "---") is > 0 and var end) start = end + 1;
        string? fence = null;
        for (int k = start; k < lines.Count; k++)
        {
            var line = lines[k];
            if (fence != null) { if (line.StartsWith(fence, StringComparison.Ordinal)) fence = null; continue; }
            if (line.StartsWith("```") || line.StartsWith("~~~")) { fence = line[..3]; continue; }
            var plain = PlainLine(line);
            if (plain.Any(char.IsLetterOrDigit)) return (Shortened(plain), k < lines.Count - 1);
        }
        return null;
    }

    /// <summary>A line without its marks: of a list, a quote, a task, emphasis, links and pictures.</summary>
    static string PlainLine(string line)
    {
        static string R(string text, string pattern, string by) => System.Text.RegularExpressions.Regex.Replace(text, pattern, by);
        var text = R(line, @"^(\s*(>|[-*+]\s|\d{1,9}[.)]\s|\[[ xX]\]\s))+", "");
        text = R(text, @"!\[([^\]]*)\]\([^)]*\)", "$1");
        text = R(text, @"\[([^\]]+)\]\([^)]*\)", "$1");
        text = R(text, @"[*_~=`]{1,3}|<[^>]+>", "");
        if (text.StartsWith('|')) text = text.Replace('|', ' ');
        return R(text, @"\s+", " ").Trim();
    }

    /// <summary>The first sentence of a long line, or as much as a name holds.</summary>
    static string Shortened(string text)
    {
        var parts = System.Globalization.StringInfo.ParseCombiningCharacters(text);
        if (parts.Length <= 40) return text;
        int end = text.IndexOfAny([.. "。！？；!?;"]);
        if (end >= 4 && end <= 40) return text[..end];
        var head = text[..parts[40]];
        // Not in the middle of a Latin word.
        int space = head.LastIndexOf(' ');
        return space >= 0 && head.Length - space < 16 && text[parts[40]] < 128 ? head[..space] : head;
    }

    /// <summary>The text of the document's first <c>#</c> heading.</summary>
    public static string? FirstHeading(string text)
    {
        foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Take(40))
        {
            var trimmed = line.Trim(' ', '\t', '\r');
            if (!trimmed.StartsWith('#')) continue;
            var title = trimmed.TrimStart('#').Trim(' ', '\t');
            if (title.Length > 0) return title.Length > 200 ? title[..200] : title;
        }
        return null;
    }

    // MARK: Helpers

    string WriteNewTextFile(string baseName, string text)
    {
        Store.Prepare();
        var relative = Store.UniqueRelativePath(baseName.Length == 0 ? "Untitled" : baseName, "md", null);
        System.IO.File.WriteAllText(Store.PathFor(relative), text, Utf8);
        return relative;
    }

    FileRecord TextFileRecord(string relative, string name, string itemId, string text, DateTime date)
    {
        var path = Store.PathFor(relative);
        var file = new FileRecord(itemId, relative, FileNamer.Sanitize(name) + ".md", Utf8.GetByteCount(text), FileHasher.Sha256(path), date, date, FulltextState.Indexed);
        // Two empty documents have the same contents: the hash an import compares against stays unique.
        file.OriginalSha256 = "md-" + file.Id;
        return file;
    }

    static void IndexText(string text, string fileId, SqliteConnection c, SqliteTransaction tx)
    {
        DeleteFulltext([fileId], c, tx);
        if (text.Length > 0) Exec(c, tx, "INSERT INTO fulltext (fileId, content) VALUES (?, ?)", fileId, text);
    }
}
