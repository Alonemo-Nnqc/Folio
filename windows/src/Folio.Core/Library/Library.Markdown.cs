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

    /// <summary>The text a new document starts with.</summary>
    public static string MarkdownTemplate(string title) => $"# {title}\n\n";

    /// <summary>A new Markdown document as an item of its own (in groupId when given). Returns its item and file ids.</summary>
    public (string ItemId, string FileId) CreateMarkdownDocument(string title, string? groupId = null, string? text = null)
    {
        var body = text ?? MarkdownTemplate(title);
        var relative = WriteNewTextFile(FileNamer.Sanitize(title), body);
        var now = DateTime.UtcNow;
        var item = new Item(ItemKind.Standalone, title, now) { MetadataState = MetadataState.None };
        var file = TextFileRecord(relative, item.Id, body, now);
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
        var body = text ?? MarkdownTemplate(title);
        var relative = WriteNewTextFile(FileNamer.Sanitize(title), body);
        var file = TextFileRecord(relative, itemId, body, DateTime.UtcNow);
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

    /// <summary>Saves a text file's new contents: the file on disk, its size, date and hash, the search index, and — for a
    /// document that is an item of its own — the item's title from its first heading.</summary>
    public void WriteText(string text, string fileId)
    {
        var file = File(fileId) ?? throw LibraryException.NotFound();
        var path = Store.PathFor(file.RelativePath);
        var temp = path + ".folio-tmp";
        System.IO.File.WriteAllText(temp, text, Utf8);
        System.IO.File.Move(temp, path, overwrite: true);
        var info = new FileInfo(path);
        var now = DateTime.UtcNow;
        file.Size = info.Length;
        file.ModifiedAt = info.LastWriteTimeUtc;
        try { file.Sha256 = FileHasher.Sha256(path); } catch (IOException) { }
        var heading = FirstHeading(text);
        Database.Write((c, tx) =>
        {
            Update(c, tx, file);
            IndexText(text, file.Id, c, tx);
            if (FetchItem(c, tx, file.ItemId) is { } item)
            {
                if (item.Kind == ItemKind.Standalone && item.DefaultFileId == file.Id && heading != null && heading != item.Title) item.Title = heading;
                item.DateModified = now;
                Update(c, tx, item);
            }
        });
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

    FileRecord TextFileRecord(string relative, string itemId, string text, DateTime date)
    {
        var path = Store.PathFor(relative);
        var file = new FileRecord(itemId, relative, relative.Split('/').Last(), Utf8.GetByteCount(text), FileHasher.Sha256(path), date, date, FulltextState.Indexed);
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
