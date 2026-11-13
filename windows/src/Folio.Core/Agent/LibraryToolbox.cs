using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Folio.Core.Citation;
using Folio.Core.Retrieval;

namespace Folio.Core.Agent;

// Port of macos/.../FolioAgent/AgentConfiguration.swift and LibraryToolbox.swift.

/// <summary>How folio-cli finds the user's library and what it may do, read from Folio's own settings so the
/// helper always follows the app.</summary>
public sealed record AgentConfiguration(string LibraryRoot, bool AllowWrites = true, bool AutoRenameFiles = true, string? CrossrefMailto = null,
                                        string? OpenAlexApiKey = null, bool UseZoteroRecognizer = true)
{
    /// <summary>--library &lt;dir&gt; &gt; FOLIO_LIBRARY &gt; Folio's setting &gt; Documents\Folio. Read afresh each time.</summary>
    public static AgentConfiguration Resolve(IReadOnlyList<string> arguments)
    {
        var settings = new AppSettings(Environment.GetEnvironmentVariable("FOLIO_SETTINGS"));
        int index = arguments.ToList().IndexOf("--library");
        var path = index >= 0 && index + 1 < arguments.Count ? arguments[index + 1] : settings.LibraryPath;
        bool readOnly = arguments.Contains("--read-only") || Environment.GetEnvironmentVariable("FOLIO_READ_ONLY") == "1";
        return new AgentConfiguration(Paths.Expand(path), !readOnly && settings.AiAllowWrites, settings.AutoRenameFiles,
            settings.CrossrefMailto is { Length: > 0 } m ? m : null, settings.OpenAlexApiKey is { Length: > 0 } k ? k : null, settings.UseZoteroRecognizer);
    }
}

static class Paths
{
    /// <summary>~ and environment variables expanded, made absolute.</summary>
    public static string Expand(string path)
    {
        path = Environment.ExpandEnvironmentVariables(path.Trim().Trim('"'));
        if (path == "~" || path.StartsWith("~/") || path.StartsWith("~\\"))
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path.Length > 2 ? path[2..] : "");
        return Path.GetFullPath(path);
    }
}

/// <summary>Runs the tools of ToolCatalog against one library. The running Folio app notices every change by
/// itself (SQLite's data_version).</summary>
public sealed class LibraryToolbox
{
    public AgentConfiguration Configuration { get; private set; }
    readonly Func<AgentConfiguration>? _source;
    Library? _library;
    MetadataEngine _engine;
    CslRenderer? _renderer;
    readonly SemaphoreSlim _gate = new(1, 1);

    /// <summary>For one-shot commands: opens the library now and fails when it cannot be opened.</summary>
    public LibraryToolbox(AgentConfiguration configuration)
    {
        Configuration = configuration;
        _engine = Engine(configuration);
        _library = Open(configuration.LibraryRoot);
    }

    /// <summary>For the MCP server: follows Folio's settings and opens the library on first use.</summary>
    public LibraryToolbox(Func<AgentConfiguration> source)
    {
        _source = source;
        Configuration = source();
        _engine = Engine(Configuration);
    }

    /// <summary>Test seam: an existing library.</summary>
    public LibraryToolbox(Library library, AgentConfiguration configuration)
    {
        Configuration = configuration;
        _library = library;
        _engine = new MetadataEngine();
    }

    static MetadataEngine Engine(AgentConfiguration c) => new(new MetadataEngineConfiguration
    {
        Mailto = c.CrossrefMailto, OpenAlexApiKey = c.OpenAlexApiKey, UseZoteroRecognizer = c.UseZoteroRecognizer,
    });

    /// <summary>Re-reads the configuration; a moved library is reopened on next use.</summary>
    public void Refresh()
    {
        if (_source == null) return;
        var fresh = _source();
        if (!string.Equals(Path.GetFullPath(fresh.LibraryRoot), Path.GetFullPath(Configuration.LibraryRoot), StringComparison.OrdinalIgnoreCase))
        {
            _library?.Dispose();
            _library = null;
        }
        if (fresh.CrossrefMailto != Configuration.CrossrefMailto || fresh.OpenAlexApiKey != Configuration.OpenAlexApiKey) _engine = Engine(fresh);
        Configuration = fresh;
    }

    public static Library Open(string root)
    {
        if (!File.Exists(Path.Combine(root, Library.DatabaseFileName)))
            throw new ToolError($"No Folio library at {root}. Open Folio once to create it, or check the library location in Folio ▸ 设置 ▸ 通用.");
        try { return new Library(root); }
        catch (Exception e) { throw new ToolError($"Cannot open the Folio library at {root}: {e.Message}"); }
    }

    Library Lib => _library ??= Open(Configuration.LibraryRoot);

    public List<ToolDefinition> Tools => ToolCatalog.Available(Configuration.AllowWrites);

    public async Task<JsonNode> Call(string name, JsonNode? arguments, CancellationToken cancel = default)
    {
        var tool = ToolCatalog.Tool(name) ?? throw new ToolError($"Unknown tool {name}.");
        if (tool.Writes && !Configuration.AllowWrites)
            throw new ToolError("The user has turned off changes by AI (Folio ▸ 设置 ▸ AI ▸ 允许 AI 修改文献库). Only reading tools are available.");
        var args = tool.Validated(arguments);
        // One call at a time against the library (the MCP server answers pings and cancellations meanwhile).
        await _gate.WaitAsync(cancel);
        try
        {
            return name switch
            {
                "search_library" => Search(args),
                "list_items" => ListItems(args),
                "list_collections" => ListCollections(),
                "get_item" => GetItem(args),
                "read_fulltext" => ReadFulltext(args),
                "get_annotations" => Annotations(args),
                "get_note" => Note(args),
                "format_citations" => FormatCitations(args),
                "export_references" => ExportReferences(args),
                "open_in_folio" => OpenInFolio(args),
                "add_item_by_identifier" => await AddByIdentifier(args, cancel),
                "add_pdf" => await AddPdf(args, cancel),
                "attach_file" => await AttachFile(args, cancel),
                "import_references" => ImportReferences(args),
                "update_item" => UpdateItem(args),
                "set_tags" => SetTags(args),
                "set_groups" => SetGroups(args),
                "create_group" => CreateGroup(args),
                "create_tag" => CreateTag(args),
                "update_tag" => UpdateTag(args),
                "delete_tag" => DeleteTag(args),
                "update_group" => UpdateGroup(args),
                "delete_group" => DeleteGroup(args),
                "move_to_trash" => Trash(args),
                "restore_from_trash" => Restore(args),
                "set_note" => SetNote(args),
                _ => throw new ToolError($"Unknown tool {name}."),
            };
        }
        catch (LibraryException e) { throw new ToolError(e.Message); }
        finally { _gate.Release(); }
    }

    // MARK: Lookups

    LibrarySnapshot Snap() => Lib.Snapshot();

    /// <summary>An item by id, DOI, citation key or arXiv ID.</summary>
    Item ResolveItem(string? reference, LibrarySnapshot s)
    {
        var raw = reference?.Trim();
        if (string.IsNullOrEmpty(raw)) throw new ToolError("Missing item reference.");
        if (s.Items.TryGetValue(raw, out var direct)) return direct;
        var doi = raw.ToLowerInvariant().Replace("https://doi.org/", "").Replace("doi:", "");
        var arxiv = Regex.Replace(raw, "arXiv:", "", RegexOptions.IgnoreCase);
        var candidates = s.Items.Values.OrderBy(i => i.IsTrashed).ToList();
        return candidates.FirstOrDefault(i => i.Doi == doi) ?? candidates.FirstOrDefault(i => i.CitationKey == raw)
               ?? candidates.FirstOrDefault(i => i.ArxivId != null && i.ArxivId == arxiv)
               ?? throw new ToolError($"No item matches \"{raw}\". Use search_library to find the item's id.");
    }

    List<Item> Items(List<string> refs, LibrarySnapshot s)
    {
        if (refs.Count == 0) throw new ToolError("No items given.");
        return refs.Select(r => ResolveItem(r, s)).ToList();
    }

    ViewScope Scope(string? value, LibrarySnapshot s)
    {
        var text = (value ?? "all").Trim();
        switch (text.ToLowerInvariant())
        {
            case "" or "all" or "library": return ViewScope.All;
            case "unfiled": return ViewScope.Unfiled;
            case "trash": return ViewScope.Trash;
        }
        if (text.StartsWith("group:", StringComparison.OrdinalIgnoreCase))
            return ViewScope.Group((FindGroup(text[6..], s) ?? throw new ToolError($"No group \"{text[6..]}\". Use list_collections.")).Id);
        if (text.StartsWith("tag:", StringComparison.OrdinalIgnoreCase))
            return ViewScope.TagOf((FindTag(text[4..], s) ?? throw new ToolError($"No tag \"{text[4..]}\". Use list_collections.")).Id);
        if (FindGroup(text, s) is { } g) return ViewScope.Group(g.Id);
        if (FindTag(text, s) is { } t) return ViewScope.TagOf(t.Id);
        throw new ToolError($"Unknown collection \"{text}\". Use \"all\", \"unfiled\", \"trash\", \"group:<name>\" or \"tag:<name>\".");
    }

    static LibraryGroup? FindGroup(string reference, LibrarySnapshot s)
    {
        var r = reference.Trim();
        if (s.GroupsById.TryGetValue(r, out var g)) return g;
        var parts = r.Split('/').Select(p => p.Trim()).ToArray();
        if (parts.Length >= 2)
        {
            // "Parent/Child" or a longer path; it may start below the top level. A full path wins.
            bool Matches(List<string> path) => path.Count >= parts.Length
                && path.Skip(path.Count - parts.Length).Zip(parts).All(x => string.Equals(x.First, x.Second, StringComparison.OrdinalIgnoreCase));
            var candidates = s.GroupsForMenus().Select(x => x.Group).Where(x => Matches(s.GroupPath(x.Id))).ToList();
            return candidates.FirstOrDefault(x => s.GroupDepth(x.Id) == parts.Length) ?? candidates.FirstOrDefault();
        }
        var matches = s.GroupsById.Values.Where(x => string.Equals(x.Name, r, StringComparison.OrdinalIgnoreCase)).ToList();
        return matches.FirstOrDefault(x => x.ParentId == null) ?? matches.FirstOrDefault();
    }

    static Tag? FindTag(string reference, LibrarySnapshot s)
    {
        var r = reference.Trim();
        return s.TagsById.GetValueOrDefault(r) ?? s.Tags.FirstOrDefault(t => string.Equals(t.Name, r, StringComparison.OrdinalIgnoreCase));
    }

    // MARK: Filters

    sealed class ItemFilter
    {
        public string? Author;
        public int? YearFrom, YearTo;
        public ItemType? Type;
        public ReadStatus? Status;
        public List<string> TagIds = [];
        public bool IsActive => Author != null || YearFrom != null || YearTo != null || Type != null || Status != null || TagIds.Count > 0;

        public bool Accepts(Item item, LibrarySnapshot s)
        {
            if (Author != null)
            {
                var wanted = Author.ToLowerInvariant();
                if (!item.Authors.Any(a => $"{a.Given} {a.Family}".ToLowerInvariant().Contains(wanted) || $"{a.Family}, {a.Given}".ToLowerInvariant().Contains(wanted))) return false;
            }
            if (YearFrom is { } from && (item.Year ?? int.MinValue) < from) return false;
            if (YearTo is { } to && (item.Year ?? int.MaxValue) > to) return false;
            if (Type is { } type && (item.Type != type || item.Kind == ItemKind.Standalone)) return false;
            if (Status is { } status && item.ReadStatus != status) return false;
            if (TagIds.Count > 0)
            {
                var has = (s.ItemTags.GetValueOrDefault(item.Id) ?? []).ToHashSet();
                if (!TagIds.All(has.Contains)) return false;
            }
            return true;
        }
    }

    ItemFilter Filter(JsonObject args, LibrarySnapshot s)
    {
        var f = new ItemFilter
        {
            Author = args["author"].Str()?.Trim() is { Length: > 0 } a ? a : null,
            YearFrom = args["year_from"].Int(), YearTo = args["year_to"].Int(),
        };
        if (args["item_type"].Str() is { Length: > 0 } type)
        {
            if (!ToolCatalog.ItemTypes.Contains(type)) throw new ToolError($"Unknown item_type \"{type}\". Use one of {string.Join(", ", ToolCatalog.ItemTypes)}.");
            f.Type = ItemTypes.Parse(type);
        }
        if (args["read_status"].Str() is { Length: > 0 } status) f.Status = ParseStatus(status);
        f.TagIds = args["tags"].StringList().Select(n => (FindTag(n, s) ?? throw new ToolError($"No tag \"{n}\". Use list_collections.")).Id).ToList();
        return f;
    }

    static ReadStatus ParseStatus(string text) => text.ToLowerInvariant() switch
    {
        "unread" or "未读" => ReadStatus.Unread,
        "reading" or "在读" => ReadStatus.Reading,
        "read" or "已读" => ReadStatus.Read,
        _ => throw new ToolError($"Unknown read_status \"{text}\". Use unread, reading or read."),
    };

    List<Item> Candidates(JsonObject args, LibrarySnapshot s)
    {
        var scope = Scope(args["collection"].Str(), s);
        var filter = Filter(args, s);
        return ViewResolver.Members(scope, s, true).Select(id => s.Items.GetValueOrDefault(id)).OfType<Item>().Where(i => filter.Accepts(i, s)).ToList();
    }

    // MARK: Item JSON

    static string StatusName(ReadStatus status) => status switch { ReadStatus.Unread => "unread", ReadStatus.Reading => "reading", _ => "read" };

    static List<string> GroupNames(string itemId, LibrarySnapshot s) =>
        (s.ItemGroups.GetValueOrDefault(itemId) ?? []).Select(id => s.GroupsById.GetValueOrDefault(id)).OfType<LibraryGroup>()
            .Select(g => string.Join('/', s.GroupPath(g.Id)))
            .OrderBy(n => n, StringComparer.Ordinal).ToList();

    static JsonObject Summary(Item item, LibrarySnapshot s)
    {
        var o = new JsonObject
        {
            ["id"] = item.Id, ["title"] = item.Title,
            ["authors"] = Json.Strings(item.Authors.Take(6).Select(AuthorFormatter.Full)),
            ["year"] = Json.From(item.Year), ["venue"] = Json.From(item.Source),
            ["type"] = item.Kind == ItemKind.Standalone ? "standalone file (no metadata yet)" : item.Type.Raw(),
            ["doi"] = Json.From(item.Doi), ["arxiv"] = Json.From(item.ArxivId), ["citation_key"] = Json.From(item.CitationKey),
            ["tags"] = Json.Strings(s.TagsOf(item.Id).Select(t => t.Name)),
            ["groups"] = Json.Strings(GroupNames(item.Id, s)),
            ["has_pdf"] = s.FilesOf(item.Id).Any(f => f.IsPdf),
            ["read_status"] = StatusName(item.ReadStatus),
        };
        if (item.Authors.Count > 6) o["more_authors"] = item.Authors.Count - 6;
        if (item.Rating > 0) o["rating"] = item.Rating;
        if (item.IsTrashed) o["in_trash"] = true;
        return o;
    }

    static string Iso(DateTime date) => date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    JsonObject Detail(Item item, LibrarySnapshot s)
    {
        var o = Summary(item, s);
        o["authors"] = Json.Strings(item.Authors.Select(AuthorFormatter.Full));
        o.Remove("more_authors");
        foreach (var (key, value) in new[] { ("date", item.Date), ("volume", item.Volume), ("issue", item.Issue), ("pages", item.Pages),
                     ("publisher", item.Publisher), ("isbn", item.Isbn), ("url", item.Url), ("abstract", item.Abstract) })
            if (!string.IsNullOrEmpty(value)) o[key] = value;
        o["date_added"] = Iso(item.DateAdded);
        if (Lib.LastReadDates().TryGetValue(item.Id, out var lastRead)) o["last_read"] = Iso(lastRead);
        o["files"] = Json.Array(s.FilesOf(item.Id).Select(file =>
        {
            var entry = new JsonObject
            {
                ["id"] = file.Id, ["name"] = file.FileName, ["path"] = Lib.FilePath(file), ["is_pdf"] = file.IsPdf, ["is_default"] = item.DefaultFileId == file.Id,
            };
            if (file.TranslationKind is { } kind) entry["translation"] = kind == TranslationKind.Mono ? "translated text" : "bilingual";
            return (JsonNode)entry;
        }));
        var note = Lib.Note(item.Id);
        if (note.Length > 0) o["note"] = note;
        if (s.JournalMetricsOf(item) is { IsIndexed: true } metrics) o["journal_metrics"] = JournalMetricsJson(metrics);
        o["folio_link"] = $"folio://open?item={item.Id}";
        return o;
    }

    /// <summary>The venue's ranks cached from easyScholar (META-30), in the same shape on both platforms.</summary>
    static JsonObject JournalMetricsJson(JournalMetrics m)
    {
        var o = new JsonObject { ["summary"] = m.Summary };
        if (m.CasZone is { } zone) { o["cas_zone"] = zone; o["cas_top"] = m.CasTop; }
        if (m.CasCategory is { } category) o["cas_category"] = category;
        if (m.CasBaseZone is { } baseZone) o["cas_base_zone"] = baseZone;
        if (m.JcrQuartile is { } q) o["jcr_quartile"] = $"Q{q}";
        if (m.ImpactFactor is { } f) o["impact_factor"] = f;
        if (m.ImpactFactor5Year is { } f5) o["impact_factor_5_year"] = f5;
        if (m.Ccf is { } ccf) o["ccf"] = ccf;
        if (m.Warning is { } warning) o["cas_warning"] = warning;
        o["source"] = "easyScholar";
        o["fetched"] = Iso(m.FetchedAt);
        return o;
    }

    // MARK: Reading tools

    JsonNode Search(JsonObject args)
    {
        var query = args["query"].Str()?.Trim() ?? "";
        var tokens = SearchMatcher.Tokens(query);
        var s = Snap();
        var pool = Candidates(args, s);
        bool filtered = Filter(args, s).IsActive || (args["collection"].Str() is { Length: > 0 } c && c != "all");
        if (tokens.Length == 0 && !filtered) throw new ToolError("Give a query, or filters (author, year_from, year_to, item_type, read_status, tags, collection).");
        int limit = Math.Clamp(args["limit"].Int() ?? 20, 1, 200), offset = Math.Max(args["offset"].Int() ?? 0, 0);
        var perToken = new Dictionary<string, HashSet<string>>();
        var hits = new Dictionary<string, FulltextHit>();
        if (args["include_fulltext"].Bool() == true && tokens.Length > 0)
        {
            foreach (var token in tokens) { try { perToken[token] = Lib.FulltextItemIds(token); } catch { perToken[token] = []; } }
            try { foreach (var hit in Lib.FulltextHits(query)) hits.TryAdd(hit.ItemId, hit); } catch { }
        }
        var phrase = tokens.Length > 1 ? string.Join(" ", tokens) : null;
        var scored = new List<(Item Item, int Matched, double Score)>();
        foreach (var item in pool)
        {
            if (tokens.Length == 0) { scored.Add((item, 0, 0)); continue; }
            var haystack = s.SearchText.GetValueOrDefault(item.Id) ?? "";
            var title = item.Title.ToLowerInvariant();
            var families = item.Authors.Select(a => a.Family.ToLowerInvariant()).ToList();
            int matched = 0;
            double score = 0;
            foreach (var token in tokens)
            {
                if (families.Contains(token)) { matched++; score += 3.5; }
                else if (ContainsWord(token, title)) { matched++; score += 4; }
                else if (title.Contains(token)) { matched++; score += 2.5; }
                else if (ContainsWord(token, haystack)) { matched++; score += 1.5; }
                else if (haystack.Contains(token)) { matched++; score += 1; }
                else if (perToken.GetValueOrDefault(token)?.Contains(item.Id) == true) { matched++; score += 0.75; }
            }
            if (phrase != null && title.Contains(phrase)) score += 3;
            if (hits.TryGetValue(item.Id, out var h)) score += Math.Clamp(-h.Rank, 0, 20) * 0.05;
            if (matched > 0) scored.Add((item, matched, score));
        }
        scored = (args["sort"].Str()?.ToLowerInvariant() ?? "relevance") switch
        {
            "added" => scored.OrderByDescending(x => x.Item.DateAdded).ToList(),
            "year" => scored.OrderByDescending(x => x.Item.Year ?? 0).ThenByDescending(x => x.Matched).ThenByDescending(x => x.Score).ToList(),
            "title" => scored.OrderBy(x => x.Item.Title, NaturalComparer).ToList(),
            _ => scored.OrderByDescending(x => x.Matched).ThenByDescending(x => x.Score).ThenByDescending(x => x.Item.DateAdded).ToList(),
        };
        bool includeAbstract = args["include_abstract"].Bool() == true;
        var page = scored.Skip(offset).Take(limit).ToList();
        var result = new JsonObject
        {
            ["total_matches"] = scored.Count,
            ["results"] = Json.Array(page.Select(entry =>
            {
                var o = Summary(entry.Item, s);
                if (tokens.Length > 0) o["matched"] = $"{entry.Matched}/{tokens.Length} words";
                if (hits.TryGetValue(entry.Item.Id, out var hit) && hit.Snippet.Length > 0) o["fulltext_snippet"] = hit.Snippet;
                if (includeAbstract && entry.Item.Abstract is { Length: > 0 } abs) o["abstract"] = abs.Length > 300 ? abs[..300] + "…" : abs;
                return (JsonNode)o;
            })),
        };
        if (query.Length > 0) result["query"] = query;
        if (offset + page.Count < scored.Count) result["next_offset"] = offset + page.Count;
        if (scored.Count == 0)
            result["hint"] = args["include_fulltext"].Bool() == true
                ? "Nothing matched. Try fewer or different words (synonyms, an acronym, an author's family name)."
                : "Nothing matched. Try fewer or different words, or include_fulltext: true to search inside the PDFs.";
        return result;
    }

    static readonly IComparer<string> NaturalComparer = Comparer<string>.Create((a, b) =>
        CultureInfo.InvariantCulture.CompareInfo.Compare(a, b, CompareOptions.IgnoreCase | CompareOptions.NumericOrdering));

    /// <summary>Whether token occurs at the start of a word in text (both lowercased).</summary>
    public static bool ContainsWord(string token, string text)
    {
        int from = 0;
        while (from <= text.Length && text.IndexOf(token, from, StringComparison.Ordinal) is var at && at >= 0)
        {
            if (at == 0) return true;
            if (!char.IsLetterOrDigit(text[at - 1])) return true;
            if (token.Length > 0 && token[0] is >= '㐀' and <= '鿿') return true;
            from = at + Math.Max(token.Length, 1);
        }
        return false;
    }

    JsonNode ListItems(JsonObject args)
    {
        var s = Snap();
        var items = Candidates(args, s);
        switch (args["sort"].Str()?.ToLowerInvariant())
        {
            case "year": items = items.OrderByDescending(i => i.Year ?? 0).ThenByDescending(i => i.DateAdded).ToList(); break;
            case "title": items = items.OrderBy(i => i.Title, NaturalComparer).ToList(); break;
            case "rating": items = items.OrderByDescending(i => i.Rating).ThenByDescending(i => i.DateAdded).ToList(); break;
            case "last_read":
                var dates = Lib.LastReadDates();
                items = items.Where(i => dates.ContainsKey(i.Id)).OrderByDescending(i => dates[i.Id]).ToList();
                break;
            default: items = items.OrderByDescending(i => i.DateAdded).ToList(); break;
        }
        int offset = Math.Max(args["offset"].Int() ?? 0, 0), limit = Math.Clamp(args["limit"].Int() ?? 20, 1, 200);
        var page = items.Skip(offset).Take(limit).ToList();
        var result = new JsonObject { ["total"] = items.Count, ["items"] = Json.Array(page.Select(i => (JsonNode)Summary(i, s))) };
        if (offset + page.Count < items.Count) result["next_offset"] = offset + page.Count;
        return result;
    }

    JsonNode ListCollections()
    {
        var s = Snap();
        var counts = SidebarCounts.Compute(s, true);
        JsonNode Node(string id)
        {
            var g = s.GroupsById[id];
            var o = new JsonObject { ["id"] = id, ["name"] = g.Name, ["item_count"] = counts.GetValueOrDefault(ViewScope.Group(id).Key) };
            if (g.ColorHex != null) o["color"] = g.ColorHex;
            var children = s.ChildGroups.GetValueOrDefault(id) ?? [];
            if (children.Count > 0) o["subgroups"] = Json.Array(children.Select(Node));
            return o;
        }
        return new JsonObject
        {
            ["all_items"] = counts.GetValueOrDefault(ViewScope.All.Key), ["unfiled"] = counts.GetValueOrDefault(ViewScope.Unfiled.Key),
            ["trash"] = counts.GetValueOrDefault(ViewScope.Trash.Key),
            ["groups"] = Json.Array(s.TopLevelGroups.Select(Node)),
            ["tags"] = Json.Array(s.Tags.Select(t => (JsonNode)new JsonObject
            {
                ["id"] = t.Id, ["name"] = t.Name, ["color"] = t.ColorHex, ["item_count"] = counts.GetValueOrDefault(ViewScope.TagOf(t.Id).Key),
            })),
        };
    }

    JsonNode GetItem(JsonObject args)
    {
        var s = Snap();
        return Detail(ResolveItem(args["item"].Str(), s), s);
    }

    FileRecord Pdf(Item item, LibrarySnapshot s)
    {
        var files = s.FilesOf(item.Id).Where(f => f.IsPdf).ToList();
        return files.FirstOrDefault(f => f.Id == item.DefaultFileId && f.TranslationOf == null) ?? files.FirstOrDefault(f => f.TranslationOf == null) ?? files.FirstOrDefault()
               ?? throw new ToolError($"\"{item.Title}\" has no PDF. Attach one with attach_file, or add_item_by_identifier with download_pdf.");
    }

    JsonNode ReadFulltext(JsonObject args)
    {
        var s = Snap();
        var item = ResolveItem(args["item"].Str(), s);
        var file = Pdf(item, s);
        var path = Lib.FilePath(file);
        int maxChars = Math.Clamp(args["max_chars"].Int() ?? 30_000, 1000, 200_000);
        var query = args["query"].Str()?.Trim() ?? "";
        UglyToad.PdfPig.PdfDocument document;
        try { document = UglyToad.PdfPig.PdfDocument.Open(path); }
        catch { throw new ToolError($"Cannot open {file.FileName}."); }
        using (document)
        {
            int count = document.NumberOfPages;
            if (count == 0) throw new ToolError($"{file.FileName} has no pages.");
            int start = Math.Clamp(args["start_page"].Int() ?? 1, 1, count);
            int end = Math.Max(Math.Min(args["end_page"].Int() ?? count, count), start);
            string PageString(int n)
            {
                try { return PdfLines.PlainText(document.GetPage(n)); } catch { return ""; }
            }
            if (query.Length > 0) return Passages(PageString, start, end, count, query, maxChars, item.Title);
            var text = new StringBuilder();
            int last = start - 1;
            bool truncated = false;
            for (int n = start; n <= end; n++)
            {
                var page = $"[Page {n}]\n{PageString(n)}\n\n";
                if (text.Length + page.Length > maxChars && text.Length > 0) { truncated = true; break; }
                text.Append(page);
                last = n;
            }
            if (Regex.Replace(text.ToString(), @"\[Page \d+\]", "").Trim().Length == 0)
                return new JsonObject { ["title"] = item.Title, ["page_count"] = count, ["pages"] = $"{start}-{last}", ["note"] = "These pages have no text layer (probably scanned)." };
            var result = new JsonObject { ["title"] = item.Title, ["page_count"] = count, ["pages"] = $"{start}-{last}", ["text"] = text.ToString() };
            if (truncated || last < end) result["next_start_page"] = last + 1;
            return result;
        }
    }

    static JsonNode Passages(Func<int, string> pageText, int start, int end, int count, string query, int maxChars, string title)
    {
        var tokens = SearchMatcher.Tokens(query).Where(t => t.Length > 1 || (t.Length == 1 && t[0] is >= '㐀' and <= '鿿')).ToList();
        const int radius = 280;
        var found = new List<(int Page, int Hits, string Text)>();
        for (int n = start; n <= end; n++)
        {
            var raw = pageText(n);
            if (raw.Length == 0) continue;
            var text = Regex.Replace(raw, @"\s+", " ");
            var windows = new List<(int From, int To)>();
            int hitCount = 0;
            foreach (var token in tokens)
            {
                int from = 0;
                while (from < text.Length && CultureInfo.InvariantCulture.CompareInfo.IndexOf(text, token, from, CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) is var at && at >= 0)
                {
                    hitCount++;
                    windows.Add((Math.Max(0, at - radius), Math.Min(text.Length, at + token.Length + radius)));
                    from = at + token.Length;
                }
            }
            if (hitCount == 0) continue;
            windows.Sort();
            var merged = new List<(int From, int To)>();
            foreach (var w in windows)
            {
                if (merged.Count > 0 && w.From <= merged[^1].To) merged[^1] = (merged[^1].From, Math.Max(merged[^1].To, w.To));
                else merged.Add(w);
            }
            var excerpt = string.Join(" ", merged.Select(r => (r.From > 0 ? "…" : "") + text[r.From..r.To] + (r.To < text.Length ? "…" : "")));
            found.Add((n, hitCount, excerpt));
        }
        found = found.OrderByDescending(f => f.Hits).ThenBy(f => f.Page).ToList();
        int used = 0;
        var kept = new JsonArray();
        foreach (var entry in found)
        {
            if (used >= maxChars) break;
            var text = entry.Text.Length + used > maxChars ? entry.Text[..(maxChars - used)] + "…" : entry.Text;
            used += text.Length;
            kept.Add(new JsonObject { ["page"] = entry.Page, ["mentions"] = entry.Hits, ["text"] = text });
        }
        var result = new JsonObject
        {
            ["title"] = title, ["query"] = query, ["page_count"] = count, ["pages_with_matches"] = found.Count, ["passages"] = kept,
        };
        if (found.Count == 0) result["hint"] = "No page mentions these words. Try other words, or read pages without a query.";
        return result;
    }

    JsonNode Annotations(JsonObject args)
    {
        var s = Snap();
        var item = ResolveItem(args["item"].Str(), s);
        var entries = new JsonArray();
        foreach (var file in s.FilesOf(item.Id).Where(f => f.IsPdf))
            foreach (var a in PdfAnnotations.Read(Lib.FilePath(file)))
            {
                var o = new JsonObject { ["kind"] = a.Kind, ["page"] = a.Page, ["color"] = a.ColorHex, ["file"] = file.FileName };
                if (!string.IsNullOrEmpty(a.Text)) o["text"] = a.Text;
                if (!string.IsNullOrEmpty(a.Comment)) o["comment"] = a.Comment;
                entries.Add(o);
            }
        return new JsonObject { ["title"] = item.Title, ["count"] = entries.Count, ["annotations"] = entries };
    }

    JsonNode Note(JsonObject args)
    {
        var s = Snap();
        var item = ResolveItem(args["item"].Str(), s);
        return new JsonObject { ["title"] = item.Title, ["note"] = Lib.Note(item.Id) };
    }

    static List<CitationEntry> Entries(IEnumerable<Item> items) => items.Where(i => i.Kind == ItemKind.Regular)
        .Select(i => new CitationEntry(i.Id, i.CitationKey ?? CitationKeyGenerator.BaseKey(i.Metadata), i.Metadata)).ToList();

    JsonNode FormatCitations(JsonObject args)
    {
        var s = Snap();
        var chosen = Items(args["items"].StringList(), s);
        var list = Entries(chosen);
        if (list.Count == 0) throw new ToolError("None of these items has bibliographic metadata yet.");
        var styleName = args["style"].Str() ?? "apa";
        var style = CitationStyles.Named(styleName)
                    ?? throw new ToolError($"Unknown style \"{styleName}\". Use one of {string.Join(", ", CitationStyles.All.Select(x => x.Raw()))}.");
        var mode = args["mode"].Str()?.ToLowerInvariant() ?? "bibliography";
        _renderer ??= new CslRenderer();
        var result = new JsonObject { ["style"] = style.DisplayName() };
        if (mode is "bibliography" or "both") result["text"] = _renderer.Render(list, style).PlainText;
        if (mode is "in_text" or "both")
        {
            var (each, combined) = _renderer.InTextCitations(list, style);
            result["in_text"] = Json.Array(list.Zip(each).Select(p => (JsonNode)new JsonObject { ["item"] = p.First.Id, ["title"] = p.First.Metadata.Title, ["citation"] = p.Second }));
            if (list.Count > 1) result["in_text_combined"] = combined;
        }
        var skipped = chosen.Where(i => i.Kind != ItemKind.Regular).Select(i => i.Title).ToList();
        if (skipped.Count > 0)
        {
            result["skipped"] = Json.Strings(skipped);
            result["note"] = "Skipped items have no bibliographic metadata yet; fix them with update_item or add_item_by_identifier.";
        }
        return result;
    }

    JsonNode ExportReferences(JsonObject args)
    {
        var s = Snap();
        var refs = args["items"].StringList();
        var chosen = refs.Count == 0
            ? ViewResolver.Members(Scope(args["collection"].Str(), s), s, true).Select(id => s.Items.GetValueOrDefault(id)).OfType<Item>().OrderBy(i => i.DateAdded).ToList()
            : Items(refs, s);
        var list = Entries(chosen);
        if (list.Count == 0) throw new ToolError("Nothing to export.");
        var format = (args["format"].Str()?.ToLowerInvariant()) switch { "ris" => ReferenceFormat.Ris, "csljson" => ReferenceFormat.Csljson, _ => ReferenceFormat.Bibtex };
        var formatName = format.ToString().ToLowerInvariant();
        var text = format.Render(list);
        if (args["path"].Str() is { Length: > 0 } p)
        {
            var path = Paths.Expand(p);
            if (Path.GetExtension(path).Length == 0) path += "." + format.FileExtension();
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, text, new UTF8Encoding(false));
            return new JsonObject { ["format"] = formatName, ["count"] = list.Count, ["path"] = path, ["citation_keys"] = Json.Strings(list.Select(e => e.CitationKey)) };
        }
        return new JsonObject { ["format"] = formatName, ["count"] = list.Count, ["text"] = text };
    }

    /// <summary>The Folio app next to this program (folio-cli ships beside Folio.exe).</summary>
    public static string? FolioExecutable()
    {
        var here = Path.Combine(AppContext.BaseDirectory, OperatingSystem.IsWindows() ? "Folio.exe" : "Folio");
        return File.Exists(here) ? here : null;
    }

    JsonNode OpenInFolio(JsonObject args)
    {
        var s = Snap();
        var item = ResolveItem(args["item"].Str(), s);
        var link = $"folio://{(args["select_only"].Bool() == true ? "select" : "open")}?item={Uri.EscapeDataString(item.Id)}";
        if (args["page"].Int() is { } page) link += $"&page={page}";
        try
        {
            // Folio.exe passes the link on to the running Folio; the folio:// protocol does the same from elsewhere.
            var info = FolioExecutable() is { } exe ? new ProcessStartInfo(exe) { ArgumentList = { link }, UseShellExecute = false } : new ProcessStartInfo(link) { UseShellExecute = true };
            Process.Start(info);
        }
        catch { throw new ToolError("Could not open Folio."); }
        return new JsonObject { ["opened"] = item.Title, ["link"] = link };
    }

    // MARK: Writing tools

    async Task<JsonNode> AddByIdentifier(JsonObject args, CancellationToken cancel)
    {
        var identifier = args["identifier"].Str();
        if (string.IsNullOrEmpty(identifier)) throw new ToolError("Missing identifier.");
        switch (await _engine.Resolve(identifier, cancel))
        {
            case ResolveResult.Found found:
            {
                var groupId = args["group"].Str() is { } g ? EnsureGroup(g) : null;
                string id, status;
                switch (Lib.CreateItem(found.Metadata, groupId))
                {
                    case CreateOutcome.Created c: (id, status) = (c.ItemId, "created"); break;
                    case CreateOutcome.Duplicate d:
                        (id, status) = (d.ExistingItemId, "already in library");
                        if (groupId != null) Lib.AddItems([id], groupId, false);
                        break;
                    default: throw new ToolError("Could not add the item.");
                }
                ApplyTags(args["tags"].StringList(), [id]);
                var result = new JsonObject { ["status"] = status };
                if (args["download_pdf"].Bool() == true) result["pdf"] = await DownloadOpenAccessPdf(id, found.Metadata, cancel);
                var s = Snap();
                result["item"] = Detail(ResolveItem(id, s), s);
                return result;
            }
            case ResolveResult.NotFound: throw new ToolError($"Nothing found for {identifier}. Check the identifier.");
            default: throw new ToolError("Could not reach the metadata services (network). Try again later.");
        }
    }

    async Task<string> DownloadOpenAccessPdf(string itemId, Metadata metadata, CancellationToken cancel)
    {
        if (Snap().FilesOf(itemId).Any(f => f.IsPdf)) return "the item already has a PDF";
        var url = await OpenAccessPdf.Locate(metadata.Doi, metadata.ArxivId, Configuration.CrossrefMailto, cancel);
        if (url == null) return "no open-access PDF found (attach one with attach_file if the user has it)";
        try
        {
            var file = await OpenAccessPdf.Download(url, Configuration.CrossrefMailto, cancel);
            try
            {
                return Lib.AddFiles([file], itemId, Configuration.AutoRenameFiles).FirstOrDefault() switch
                {
                    AddFileOutcome.Added => $"attached ({url})",
                    AddFileOutcome.Duplicate => "this PDF is already in the library",
                    AddFileOutcome.Failed f => $"could not attach: {f.Reason}",
                    _ => "could not attach",
                };
            }
            finally { try { Directory.Delete(Path.GetDirectoryName(file)!, true); } catch { } }
        }
        catch (Exception e) { return $"{e.Message} ({url})"; }
    }

    async Task<(string Path, Action Cleanup)> SourceFile(JsonObject args, CancellationToken cancel)
    {
        if (args["path"].Str() is { Length: > 0 } p)
        {
            var path = Paths.Expand(p);
            if (!File.Exists(path)) throw new ToolError($"No file at {path}.");
            return (path, () => { });
        }
        if (args["url"].Str() is { Length: > 0 } link)
        {
            if (!Uri.TryCreate(link, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) throw new ToolError($"\"{link}\" is not an http(s) URL.");
            var file = await OpenAccessPdf.Download(link, Configuration.CrossrefMailto, cancel);
            return (file, () => { try { Directory.Delete(Path.GetDirectoryName(file)!, true); } catch { } });
        }
        throw new ToolError("Give `path` (a file on disk) or `url` (a PDF to download).");
    }

    async Task<JsonNode> AddPdf(JsonObject args, CancellationToken cancel)
    {
        var (path, cleanup) = await SourceFile(args, cancel);
        try
        {
            var groupId = args["group"].Str() is { } g ? EnsureGroup(g) : null;
            var outcome = Lib.ImportFiles([path], groupId).FirstOrDefault() ?? throw new ToolError("Import failed.");
            string itemId, status = "added";
            switch (outcome)
            {
                case ImportOutcome.Imported imported:
                    itemId = imported.ItemId;
                    if (imported.IsPdf)
                    {
                        if (args["retrieve_metadata"].Bool() ?? true)
                        {
                            switch (await _engine.ResolvePdf(Lib.FilePath(Lib.Files(itemId)[0]), cancel))
                            {
                                case ResolveResult.Found found:
                                    switch (Lib.ApplyMetadata(found.Metadata, itemId, Configuration.AutoRenameFiles))
                                    {
                                        case ApplyOutcome.Created: status = "added with metadata"; break;
                                        case ApplyOutcome.DuplicateItem dup:
                                            Lib.MergeStandalone(itemId, dup.ExistingItemId, Configuration.AutoRenameFiles);
                                            itemId = dup.ExistingItemId;
                                            status = "attached to the existing item for this work";
                                            break;
                                    }
                                    break;
                                case ResolveResult.NotFound:
                                    Lib.SetMetadataState(MetadataState.Failed, itemId);
                                    status = "added without metadata (no match found; it stays a standalone file — fix it with update_item)";
                                    break;
                                default:
                                    Lib.SetMetadataState(MetadataState.NetworkFailed, itemId, true);
                                    status = "added; metadata lookup failed (network) and Folio will retry";
                                    break;
                            }
                        }
                        else
                        {
                            Lib.SetMetadataState(MetadataState.None, itemId);
                            status = "added without looking up metadata";
                        }
                    }
                    break;
                case ImportOutcome.DuplicateFile dupFile:
                    itemId = dupFile.ExistingItemId;
                    status = "this exact file is already in the library";
                    break;
                case ImportOutcome.DuplicateInTrash trashed:
                    Lib.RestoreItems([trashed.ExistingItemId]);
                    itemId = trashed.ExistingItemId;
                    status = "this file was in the trash and has been restored";
                    break;
                case ImportOutcome.Failed failed:
                    throw new ToolError($"Could not add the file: {failed.Reason}");
                default:
                    throw new ToolError("Import failed.");
            }
            ApplyTags(args["tags"].StringList(), [itemId]);
            var s = Snap();
            return new JsonObject { ["status"] = status, ["item"] = Detail(ResolveItem(itemId, s), s) };
        }
        finally { cleanup(); }
    }

    async Task<JsonNode> AttachFile(JsonObject args, CancellationToken cancel)
    {
        var item = ResolveItem(args["item"].Str(), Snap());
        if (item.IsTrashed) throw new ToolError($"\"{item.Title}\" is in the trash; restore it first.");
        var (path, cleanup) = await SourceFile(args, cancel);
        try
        {
            string status;
            switch (Lib.AddFiles([path], item.Id, Configuration.AutoRenameFiles).FirstOrDefault())
            {
                case AddFileOutcome.Added added:
                    status = "attached";
                    if (args["make_default"].Bool() == true) Lib.SetDefaultFile(added.FileId);
                    break;
                case AddFileOutcome.Duplicate dup:
                    status = dup.ExistingItemId == item.Id ? "this file is already attached to the item" : $"this file already belongs to another item ({dup.ExistingItemId})";
                    break;
                case AddFileOutcome.Failed failed: throw new ToolError($"Could not attach the file: {failed.Reason}");
                default: throw new ToolError("Could not attach the file.");
            }
            var s = Snap();
            return new JsonObject { ["status"] = status, ["item"] = Detail(ResolveItem(item.Id, s), s) };
        }
        finally { cleanup(); }
    }

    JsonNode ImportReferences(JsonObject args)
    {
        var text = args["text"].Str() ?? "";
        if (args["path"].Str() is { Length: > 0 } p)
        {
            var path = Paths.Expand(p);
            try { text = File.ReadAllText(path); } catch { throw new ToolError($"Cannot read {path}."); }
        }
        if (text.Trim().Length == 0) throw new ToolError("Give `path` or `text`.");
        var records = ReferenceFormats.Parse(text);
        if (records.Count == 0) throw new ToolError("No BibTeX, RIS or CSL JSON references found.");
        var groupId = args["group"].Str() is { } g ? EnsureGroup(g) : null;
        var result = Lib.ImportReferences(records.Select(r => (r.Metadata, r.CitationKey)), groupId);
        var s = Snap();
        return new JsonObject
        {
            ["parsed"] = records.Count, ["created"] = result.Created.Count, ["already_in_library"] = result.Duplicates.Count,
            ["items"] = Json.Array(result.Created.Concat(result.Duplicates).Select(id => s.Items.GetValueOrDefault(id)).OfType<Item>().Select(i => (JsonNode)Summary(i, s))),
        };
    }

    JsonNode UpdateItem(JsonObject args)
    {
        var item = ResolveItem(args["item"].Str(), Snap());
        var problems = new List<string>();
        ReadStatus? status = args["read_status"].Str() is { } st ? ParseStatus(st) : null;
        Lib.UpdateItem(item.Id, i =>
        {
            bool Has(string key) => args.ContainsKey(key);
            string? Text(string key) => args[key].Str()?.Trim() is { Length: > 0 } v ? v : null;
            if (Has("title")) { if (Text("title") is { } t) i.Title = t; else problems.Add("title cannot be empty"); }
            if (Has("authors"))
                i.Authors = args["authors"].StringList().Select(name =>
                {
                    var parts = name.Split(',', 2).Select(x => x.Trim()).ToArray();
                    return parts.Length == 2 ? new Author(parts[0], parts[1]) : new Author(name);
                }).ToList();
            if (Has("year")) i.Year = args["year"].Int();
            if (Has("venue")) i.Source = Text("venue");
            if (Has("volume")) i.Volume = Text("volume");
            if (Has("issue")) i.Issue = Text("issue");
            if (Has("pages")) i.Pages = Text("pages");
            if (Has("publisher")) i.Publisher = Text("publisher");
            if (Has("doi")) i.Doi = Text("doi")?.ToLowerInvariant();
            if (Has("url")) i.Url = Text("url");
            if (Has("abstract")) i.Abstract = Text("abstract");
            if (Has("citation_key")) i.CitationKey = Text("citation_key");
            if (args["type"].Str() is { } type)
            {
                if (ToolCatalog.ItemTypes.Contains(type)) i.Type = ItemTypes.Parse(type); else problems.Add($"unknown type {type}");
            }
            if (status is { } s) i.ReadStatus = s;
            if (args["rating"].Int() is { } rating) i.Rating = Math.Clamp(rating, 0, 5);
            if (i.Kind == ItemKind.Standalone && Has("title")) { i.Kind = ItemKind.Regular; i.MetadataState = MetadataState.Resolved; }
        });
        var after = Snap();
        var result = new JsonObject { ["item"] = Detail(ResolveItem(item.Id, after), after) };
        if (problems.Count > 0) result["warnings"] = Json.Strings(problems);
        return result;
    }

    static readonly string[] Palette = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#32ADE6", "#007AFF", "#5856D6", "#AF52DE", "#FF2D55"];

    string EnsureTagId(string name)
    {
        var clean = name.Trim();
        var s = Snap();
        if (FindTag(clean, s) is { } t) return t.Id;
        return Lib.CreateTag(clean, Palette[s.Tags.Count % Palette.Length]).Id;
    }

    void ApplyTags(List<string> names, List<string> ids)
    {
        foreach (var name in names.Where(n => n.Trim().Length > 0)) Lib.SetTag(EnsureTagId(name), ids, true);
    }

    string EnsureGroup(string reference, bool create = true)
    {
        var s = Snap();
        if (FindGroup(reference, s) is { } g) return g.Id;
        if (!create) throw new ToolError($"No group \"{reference}\".");
        var parts = reference.Split('/').Select(p => p.Trim()).Where(p => p.Length > 0).ToList();
        if (parts.Count == 0) throw new ToolError("Empty group name.");
        // Walk the path, creating what is missing (four levels at most).
        string parentId = (parts.Count >= 2 ? FindGroup(parts[0], s)?.Id : null) ?? Lib.CreateGroup(parts[0]).Id;
        foreach (var name in parts.Skip(1))
        {
            var current = Snap();
            var existing = (current.ChildGroups.GetValueOrDefault(parentId) ?? [])
                .FirstOrDefault(id => string.Equals(current.GroupsById[id].Name, name, StringComparison.OrdinalIgnoreCase));
            if (existing == null && !current.CanAddSubgroup(parentId))
                throw new ToolError($"Groups are at most {LibraryGroup.MaximumDepth} levels deep; \"{reference}\" would go deeper.");
            parentId = existing ?? Lib.CreateGroup(name, parentId).Id;
        }
        return parentId;
    }

    JsonNode ItemsResult(List<string> ids)
    {
        var after = Snap();
        return new JsonObject { ["items"] = Json.Array(ids.Select(id => after.Items.GetValueOrDefault(id)).OfType<Item>().Select(i => (JsonNode)Summary(i, after))) };
    }

    JsonNode SetTags(JsonObject args)
    {
        var ids = Items(args["items"].StringList(), Snap()).Select(i => i.Id).ToList();
        ApplyTags(args["add"].StringList(), ids);
        foreach (var name in args["remove"].StringList())
            if (FindTag(name, Snap()) is { } tag) Lib.SetTag(tag.Id, ids, false);
        return ItemsResult(ids);
    }

    JsonNode SetGroups(JsonObject args)
    {
        var ids = Items(args["items"].StringList(), Snap()).Select(i => i.Id).ToList();
        bool create = args["create_missing"].Bool() ?? true;
        foreach (var name in args["add"].StringList()) Lib.AddItems(ids, EnsureGroup(name, create), false);
        foreach (var name in args["remove"].StringList())
        {
            var group = FindGroup(name, Snap()) ?? throw new ToolError($"No group \"{name}\".");
            Lib.RemoveItems(ids, group.Id, true);
        }
        return ItemsResult(ids);
    }

    JsonNode CreateGroup(JsonObject args)
    {
        var name = args["name"].Str();
        if (string.IsNullOrEmpty(name)) throw new ToolError("Missing name.");
        string? parentId = null;
        if (args["parent"].Str() is { Length: > 0 } parent)
        {
            var snap = Snap();
            var group = FindGroup(parent, snap) ?? throw new ToolError($"No parent group \"{parent}\".");
            if (!snap.CanAddSubgroup(group.Id))
                throw new ToolError($"Groups are at most {LibraryGroup.MaximumDepth} levels deep; \"{parent}\" is already on the last level.");
            parentId = group.Id;
        }
        try
        {
            var created = Lib.CreateGroup(name, parentId);
            return new JsonObject { ["id"] = created.Id, ["name"] = created.Name };
        }
        catch (LibraryException) { throw new ToolError($"A group named \"{name}\" already exists there."); }
    }

    static readonly Dictionary<string, string> NamedColors = new()
    {
        ["red"] = "#FF3B30", ["orange"] = "#FF9500", ["yellow"] = "#FFCC00", ["green"] = "#34C759", ["mint"] = "#00C7BE",
        ["cyan"] = "#32ADE6", ["teal"] = "#32ADE6", ["blue"] = "#007AFF", ["indigo"] = "#5856D6", ["purple"] = "#AF52DE",
        ["pink"] = "#FF2D55", ["gray"] = "#8E8E93", ["grey"] = "#8E8E93",
        ["红"] = "#FF3B30", ["橙"] = "#FF9500", ["黄"] = "#FFCC00", ["绿"] = "#34C759", ["青"] = "#32ADE6", ["蓝"] = "#007AFF",
        ["靛"] = "#5856D6", ["紫"] = "#AF52DE", ["粉"] = "#FF2D55", ["灰"] = "#8E8E93",
    };

    /// <summary>A colour name or #RRGGBB → "#RRGGBB".</summary>
    public static string? HexColor(string? value)
    {
        var raw = value?.Trim();
        if (string.IsNullOrEmpty(raw)) return null;
        if (NamedColors.TryGetValue(raw.ToLowerInvariant(), out var named) || NamedColors.TryGetValue(raw, out named)) return named;
        var hex = raw.TrimStart('#');
        if (hex.Length != 6 || !hex.All(Uri.IsHexDigit)) throw new ToolError($"Unknown colour \"{raw}\". Use a colour name (red, blue, …) or #RRGGBB.");
        return "#" + hex.ToUpperInvariant();
    }

    static JsonNode TagJson(Tag tag, LibrarySnapshot s) => new JsonObject
    {
        ["id"] = tag.Id, ["name"] = tag.Name, ["color"] = tag.ColorHex, ["item_count"] = s.TagItems.GetValueOrDefault(tag.Id)?.Count ?? 0,
    };

    static Tag RequireTag(JsonObject args, LibrarySnapshot s) =>
        args["tag"].Str() is { } r && FindTag(r, s) is { } t ? t : throw new ToolError($"No tag \"{args["tag"].Str() ?? ""}\". Use list_collections.");

    JsonNode CreateTag(JsonObject args)
    {
        var name = args["name"].Str()?.Trim();
        if (string.IsNullOrEmpty(name)) throw new ToolError("Missing name.");
        var s = Snap();
        if (FindTag(name, s) is { } existing) return new JsonObject { ["status"] = "already exists", ["tag"] = TagJson(existing, s) };
        var color = HexColor(args["color"].Str());
        var id = EnsureTagId(name);
        if (color != null) Lib.UpdateTag(id, name, color);
        var after = Snap();
        return new JsonObject { ["status"] = "created", ["tag"] = TagJson(after.TagsById[id], after) };
    }

    JsonNode UpdateTag(JsonObject args)
    {
        var s = Snap();
        var tag = RequireTag(args, s);
        var name = args["name"].Str()?.Trim() is { Length: > 0 } n ? n : tag.Name;
        var color = HexColor(args["color"].Str()) ?? tag.ColorHex;
        try { Lib.UpdateTag(tag.Id, name, color); }
        catch (LibraryException) { throw new ToolError($"A tag named \"{name}\" already exists. Use set_tags to move items to it, then delete_tag the old one."); }
        var after = Snap();
        return new JsonObject { ["tag"] = TagJson(after.TagsById[tag.Id], after) };
    }

    JsonNode DeleteTag(JsonObject args)
    {
        var s = Snap();
        var tag = RequireTag(args, s);
        int count = s.TagItems.GetValueOrDefault(tag.Id)?.Count ?? 0;
        Lib.DeleteTag(tag.Id);
        return new JsonObject { ["deleted_tag"] = tag.Name, ["removed_from_items"] = count };
    }

    static LibraryGroup RequireGroup(JsonObject args, LibrarySnapshot s) =>
        args["group"].Str() is { } r && FindGroup(r, s) is { } g ? g : throw new ToolError($"No group \"{args["group"].Str() ?? ""}\". Use list_collections.");

    JsonNode UpdateGroup(JsonObject args)
    {
        var s = Snap();
        var group = RequireGroup(args, s);
        if (args["name"].Str()?.Trim() is { Length: > 0 } name && name != group.Name)
        {
            try { Lib.RenameGroup(group.Id, name); }
            catch (LibraryException) { throw new ToolError($"A sibling group named \"{name}\" already exists."); }
        }
        if (args["color"].Str() is { } color) Lib.SetGroupColor(group.Id, color.ToLowerInvariant() == "default" ? null : HexColor(color));
        if (args["parent"].Str() is { } parent)
        {
            string? parentId = parent.Trim().Length == 0 ? null : (FindGroup(parent, s) ?? throw new ToolError($"No group \"{parent}\".")).Id;
            if (!Lib.CanMoveGroup(group.Id, parentId))
                throw new ToolError($"Cannot move \"{group.Name}\" there: groups are at most {LibraryGroup.MaximumDepth} levels deep (its subgroups included), and a group cannot go inside itself or its own subgroups.");
            var siblings = parentId != null ? s.ChildGroups.GetValueOrDefault(parentId) ?? [] : s.TopLevelGroups;
            Lib.MoveGroup(group.Id, parentId, siblings.Count);
        }
        var after = Snap();
        var updated = after.GroupsById[group.Id];
        var result = new JsonObject
        {
            ["id"] = updated.Id, ["name"] = updated.Name,
            ["parent"] = updated.ParentId != null && after.GroupsById.TryGetValue(updated.ParentId, out var p) ? p.Name : null,
        };
        if (updated.ColorHex != null) result["color"] = updated.ColorHex;
        return result;
    }

    JsonNode DeleteGroup(JsonObject args)
    {
        var s = Snap();
        var group = RequireGroup(args, s);
        bool trashItems = args["trash_items"].Bool() ?? false;
        var members = ViewResolver.Members(ViewScope.Group(group.Id), s, true);
        Lib.DeleteGroup(group.Id, trashItems);
        return new JsonObject
        {
            ["deleted_group"] = group.Name, ["subgroups_deleted"] = s.GroupDescendants(group.Id).Count,
            [trashItems ? "items_moved_to_trash" : "items_kept_in_library"] = members.Count,
        };
    }

    JsonNode Trash(JsonObject args)
    {
        var chosen = Items(args["items"].StringList(), Snap()).Where(i => !i.IsTrashed).ToList();
        Lib.TrashItems(chosen.Select(i => i.Id));
        return new JsonObject { ["moved_to_trash"] = Json.Strings(chosen.Select(i => i.Title)), ["note"] = "Restorable with restore_from_trash for 30 days." };
    }

    JsonNode Restore(JsonObject args)
    {
        var chosen = Items(args["items"].StringList(), Snap()).Where(i => i.IsTrashed).ToList();
        Lib.RestoreItems(chosen.Select(i => i.Id));
        return new JsonObject { ["restored"] = Json.Strings(chosen.Select(i => i.Title)) };
    }

    JsonNode SetNote(JsonObject args)
    {
        var item = ResolveItem(args["item"].Str(), Snap());
        var content = args["content"].Str() ?? "";
        var note = content;
        if (args["mode"].Str() != "replace")
        {
            var current = Lib.Note(item.Id);
            note = current.Length == 0 ? content : current + (current.EndsWith('\n') ? "\n" : "\n\n") + content;
        }
        Lib.SetNote(note, item.Id);
        return new JsonObject { ["title"] = item.Title, ["note"] = Lib.Note(item.Id) };
    }
}
