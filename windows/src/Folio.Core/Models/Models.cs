using System.Text.Json.Serialization;

namespace Folio.Core;

// The library's records. Field names, raw values and meanings match the macOS app's (Packages/FolioCore/Models),
// so both apps read and write the same Folio.sqlite.

/// <summary>A person (or organisation) credited as an author. Organisations store their full name in Family.</summary>
public sealed record Author(
    [property: JsonPropertyName("family")] string Family,
    [property: JsonPropertyName("given")] string Given = "");

/// <summary>The bibliographic kind of an item. Raw values are persisted, never rename them.</summary>
public enum ItemType { JournalArticle, ConferencePaper, Preprint, Book, BookChapter, Thesis, Report, Webpage, Dataset, Other }

public static class ItemTypes
{
    public static readonly ItemType[] All = Enum.GetValues<ItemType>();

    public static string Raw(this ItemType t) => t switch
    {
        ItemType.JournalArticle => "journalArticle",
        ItemType.ConferencePaper => "conferencePaper",
        ItemType.Preprint => "preprint",
        ItemType.Book => "book",
        ItemType.BookChapter => "bookChapter",
        ItemType.Thesis => "thesis",
        ItemType.Report => "report",
        ItemType.Webpage => "webpage",
        ItemType.Dataset => "dataset",
        _ => "other",
    };

    public static ItemType Parse(string? raw) => All.FirstOrDefault(t => t.Raw() == raw, ItemType.Other);

    public static string DisplayName(this ItemType t) => t switch
    {
        ItemType.JournalArticle => Loc.S("期刊文章"),
        ItemType.ConferencePaper => Loc.S("会议论文"),
        ItemType.Preprint => Loc.S("预印本"),
        ItemType.Book => Loc.S("图书"),
        ItemType.BookChapter => Loc.S("图书章节"),
        ItemType.Thesis => Loc.S("学位论文"),
        ItemType.Report => Loc.S("报告"),
        ItemType.Webpage => Loc.S("网页"),
        ItemType.Dataset => Loc.S("数据集"),
        _ => Loc.S("其他"),
    };
}

public enum ItemKind
{
    /// <summary>A work with metadata; owns zero or more files.</summary>
    Regular = 0,
    /// <summary>A top-level file that has no metadata (retrieval failed or was never attempted).</summary>
    Standalone = 1,
}

public enum ReadStatus { Unread = 0, Reading = 1, Read = 2 }

public static class ReadStatuses
{
    public static string DisplayName(this ReadStatus s) => s switch
    {
        ReadStatus.Unread => Loc.S("未读"),
        ReadStatus.Reading => Loc.S("在读"),
        _ => Loc.S("已读"),
    };
}

public enum MetadataState { None = 0, Pending = 1, Failed = 2, NetworkFailed = 3, Resolved = 4 }

/// <summary>Bibliographic fields shared by the retrieval engine, citation formatting and importers.</summary>
public sealed record Metadata
{
    public Metadata(string title) { Title = title; }

    public ItemType Type { get; set; } = ItemType.JournalArticle;
    public string Title { get; set; }
    public List<Author> Authors { get; set; } = [];
    public int? Year { get; set; }
    /// <summary>"YYYY", "YYYY-MM" or "YYYY-MM-DD".</summary>
    public string? Date { get; set; }
    /// <summary>Journal, conference, repository (e.g. "arXiv"), publisher for books, university for theses.</summary>
    public string? Source { get; set; }
    public string? Volume { get; set; }
    public string? Issue { get; set; }
    public string? Pages { get; set; }
    public string? Publisher { get; set; }
    /// <summary>Lowercased, without a resolver prefix.</summary>
    public string? Doi { get; set; }
    /// <summary>"2604.27326" or "hep-th/9901001", without a version suffix.</summary>
    public string? ArxivId { get; set; }
    public string? Isbn { get; set; }
    public string? Url { get; set; }
    public string? Abstract { get; set; }

    public Metadata Copy() => this with { Authors = [.. Authors] };

    public bool Equivalent(Metadata o) =>
        Type == o.Type && Title == o.Title && Authors.SequenceEqual(o.Authors) && Year == o.Year && Date == o.Date
        && Source == o.Source && Volume == o.Volume && Issue == o.Issue && Pages == o.Pages && Publisher == o.Publisher
        && Doi == o.Doi && ArxivId == o.ArxivId && Isbn == o.Isbn && Url == o.Url && Abstract == o.Abstract;
}

/// <summary>A top-level row in the library: either a regular item or a standalone file.</summary>
public sealed class Item
{
    public Item(ItemKind kind, string title, DateTime? dateAdded = null, string? id = null)
    {
        Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant();
        Kind = kind;
        Type = kind == ItemKind.Standalone ? ItemType.Other : ItemType.JournalArticle;
        Title = title;
        DateAdded = dateAdded ?? DateTime.UtcNow;
        DateModified = DateAdded;
    }

    public string Id { get; set; }
    public ItemKind Kind { get; set; }
    public ItemType Type { get; set; }
    public string Title { get; set; }
    public List<Author> Authors { get; set; } = [];
    public int? Year { get; set; }
    public string? Date { get; set; }
    public string? Source { get; set; }
    public string? Volume { get; set; }
    public string? Issue { get; set; }
    public string? Pages { get; set; }
    public string? Publisher { get; set; }
    public string? Doi { get; set; }
    public string? ArxivId { get; set; }
    public string? Isbn { get; set; }
    public string? Url { get; set; }
    public string? Abstract { get; set; }
    public string? CitationKey { get; set; }
    public int Rating { get; set; }
    public ReadStatus ReadStatus { get; set; }
    public string? DefaultFileId { get; set; }
    public MetadataState MetadataState { get; set; }
    public int RetryCount { get; set; }
    /// <summary>For a file deleted on its own: the item it belonged to, so restore can put it back.</summary>
    public string? OriginItemId { get; set; }
    public DateTime DateAdded { get; set; }
    public DateTime DateModified { get; set; }
    public DateTime? TrashedAt { get; set; }

    public bool IsTrashed => TrashedAt != null;

    public Metadata Metadata
    {
        get => new(Title)
        {
            Type = Type, Authors = [.. Authors], Year = Year, Date = Date, Source = Source, Volume = Volume, Issue = Issue,
            Pages = Pages, Publisher = Publisher, Doi = Doi, ArxivId = ArxivId, Isbn = Isbn, Url = Url, Abstract = Abstract,
        };
        set
        {
            Type = value.Type; Title = value.Title; Authors = [.. value.Authors]; Year = value.Year; Date = value.Date;
            Source = value.Source; Volume = value.Volume; Issue = value.Issue; Pages = value.Pages; Publisher = value.Publisher;
            Doi = value.Doi?.ToLowerInvariant(); ArxivId = value.ArxivId; Isbn = value.Isbn; Url = value.Url; Abstract = value.Abstract;
        }
    }

    public Item Clone() { var c = (Item)MemberwiseClone(); c.Authors = [.. Authors]; return c; }
}

/// <summary>What a translated file contains.</summary>
public enum TranslationKind
{
    /// <summary>Target language only.</summary>
    Mono = 0,
    /// <summary>Original and translation together.</summary>
    Dual = 1,
}

public enum FulltextState { Pending = 0, Indexed = 1, NotApplicable = 2 }

/// <summary>A file stored inside the library's Files/ folder and attached to an item.</summary>
public sealed class FileRecord
{
    public FileRecord(string itemId, string relativePath, string originalName, long size, string sha256, DateTime modifiedAt,
                      DateTime? dateAdded = null, FulltextState fulltextState = FulltextState.Pending, string? id = null)
    {
        Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant();
        ItemId = itemId;
        RelativePath = relativePath;
        OriginalName = originalName;
        Size = size;
        Sha256 = sha256;
        OriginalSha256 = sha256;
        ModifiedAt = modifiedAt;
        DateAdded = dateAdded ?? DateTime.UtcNow;
        FulltextState = fulltextState;
    }

    public string Id { get; set; }
    public string ItemId { get; set; }
    /// <summary>Path relative to the library root with forward slashes, e.g. "Files/Zhang_2026_Title.pdf".</summary>
    public string RelativePath { get; set; }
    public string OriginalName { get; set; }
    public long Size { get; set; }
    public string Sha256 { get; set; }
    /// <summary>Hash at import time; kept so re-importing the original is still detected after annotation edits.</summary>
    public string OriginalSha256 { get; set; }
    public DateTime ModifiedAt { get; set; }
    public DateTime DateAdded { get; set; }
    public FulltextState FulltextState { get; set; }
    public string? TranslationOf { get; set; }
    public TranslationKind? TranslationKind { get; set; }
    /// <summary>Who translated it: the service and model, e.g. "DeepSeek · deepseek-chat" or "Google".</summary>
    public string? TranslatedBy { get; set; }

    public string FileName => RelativePath.Split('/').Last();
    public bool IsPdf => Path.GetExtension(RelativePath).Equals(".pdf", StringComparison.OrdinalIgnoreCase);
    public FileRecord Clone() => (FileRecord)MemberwiseClone();
}

/// <summary>A user-created group. Groups nest at most two levels deep.</summary>
public sealed class LibraryGroup
{
    public LibraryGroup(string name, double position, string? parentId = null, DateTime? dateCreated = null, string? id = null)
    {
        Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant();
        Name = name;
        Position = position;
        ParentId = parentId;
        DateCreated = dateCreated ?? DateTime.UtcNow;
    }

    public string Id { get; set; }
    public string? ParentId { get; set; }
    public string Name { get; set; }
    public double Position { get; set; }
    public DateTime DateCreated { get; set; }
    /// <summary>Sidebar icon colour ("#RRGGBB"); null = the accent colour.</summary>
    public string? ColorHex { get; set; }
}

public sealed class Tag
{
    public Tag(string name, string colorHex, double position, string? id = null)
    {
        Id = id ?? Guid.NewGuid().ToString().ToUpperInvariant();
        Name = name;
        ColorHex = colorHex;
        Position = position;
    }

    public string Id { get; set; }
    public string Name { get; set; }
    /// <summary>"#RRGGBB"</summary>
    public string ColorHex { get; set; }
    public double Position { get; set; }
}

/// <summary>Where the reader left a file. Stored apart from the snapshot so scrolling never refreshes the list.</summary>
public sealed record ReadingState(string FileId, int PageIndex, double PointX, double PointY, double Scale, bool AutoScale,
                                  int DisplayMode, DateTime DateModified);

/// <summary>What the middle list shows.</summary>
public abstract record ViewScope
{
    public sealed record AllScope : ViewScope;
    public sealed record UnfiledScope : ViewScope;
    public sealed record TrashScope : ViewScope;
    public sealed record GroupScope(string Id) : ViewScope;
    public sealed record TagScope(string Id) : ViewScope;

    public static readonly ViewScope All = new AllScope();
    public static readonly ViewScope Unfiled = new UnfiledScope();
    public static readonly ViewScope Trash = new TrashScope();
    public static ViewScope Group(string id) => new GroupScope(id);
    public static ViewScope TagOf(string id) => new TagScope(id);

    /// <summary>Stable key used for per-view ordering and sort persistence.</summary>
    public string Key => this switch
    {
        AllScope => "all",
        UnfiledScope => "unfiled",
        TrashScope => "trash",
        GroupScope g => $"group:{g.Id}",
        TagScope t => $"tag:{t.Id}",
        _ => "all",
    };

    public string? GroupId => this is GroupScope g ? g.Id : null;
    public string? TagId => this is TagScope t ? t.Id : null;
}

public enum SortColumn
{
    Title, Authors, Year, Source, Type, DateAdded, DateModified, Doi, Publisher,
    Volume, Issue, Pages, ReadStatus, Rating, FileCount, CitationKey, Tags,
}

public static class SortColumns
{
    public static string Raw(this SortColumn c) => char.ToLowerInvariant(c.ToString()[0]) + c.ToString()[1..];
    public static SortColumn? Parse(string? raw) =>
        raw == null ? null : Enum.GetValues<SortColumn>().Cast<SortColumn?>().FirstOrDefault(c => c!.Value.Raw() == raw);
}

/// <summary>Column == null means the view's custom (drag-and-drop) order.</summary>
public sealed record SortState(SortColumn? Column = null, bool Ascending = true)
{
    public static readonly SortState Manual = new();
}

// Intermediate format for bulk imports (e.g. from Zotero).

public sealed record PreparedGroup(string Key, string Name, string? ParentKey, double Position);
public sealed record PreparedTag(string Name, string ColorHex);
public sealed record PreparedFile(string SourcePath, string OriginalName, DateTime DateAdded,
                                  TranslationKind? TranslationKind = null, string? TranslatedBy = null);

public sealed record PreparedEntry(Metadata? Metadata, List<PreparedFile> Files, List<string> GroupKeys, List<string> TagNames,
                                   DateTime DateAdded, DateTime DateModified)
{
    /// <summary>Null metadata = a standalone file.</summary>
    public bool IsRegular => Metadata != null;
}

public sealed record PreparedLibrary(List<PreparedGroup> Groups, List<PreparedTag> Tags, List<PreparedEntry> Entries);

public sealed class BulkImportSummary
{
    public int ItemsImported, FilesImported, GroupsCreated, TagsCreated, DuplicatesSkipped, MissingFiles, TranslationsRecognized;
}
