using System.Text.Json;
using System.Text.Json.Nodes;
using Folio.Core.Citation;

namespace Folio.Core.Agent;

// Port of macos/.../FolioAgent/ToolCatalog.swift and the helpers of JSONValue.swift.

/// <summary>A tool failure explained for the AI (and, through it, the user).</summary>
public sealed class ToolError(string message) : Exception(message);

/// <summary>JSON helpers for MCP messages and tool results.</summary>
public static class Json
{
    static readonly JsonSerializerOptions Compact = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    static readonly JsonSerializerOptions Pretty = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping, WriteIndented = true };

    public static string Encode(JsonNode? node, bool pretty = false) => node?.ToJsonString(pretty ? Pretty : Compact) ?? "null";

    /// <summary>One line of JSON for a newline-delimited stream (U+2028 / U+2029 escaped too).</summary>
    public static string WireLine(JsonNode node) => Encode(node).Replace("\u2028", "\\u2028").Replace("\u2029", "\\u2029");

    public static string? Str(this JsonNode? node) => node switch
    {
        JsonValue v when v.TryGetValue<string>(out var s) => s,
        JsonValue v when v.GetValueKind() == JsonValueKind.Number => v.ToJsonString(),
        _ => null,
    };

    public static int? Int(this JsonNode? node)
    {
        if (node is JsonValue v)
        {
            if (v.GetValueKind() == JsonValueKind.Number)
            {
                if (v.TryGetValue<int>(out var n)) return n;
                if (v.TryGetValue<long>(out var l)) return (int)l;
                if (v.TryGetValue<double>(out var d)) return (int)d;
                return (int)double.Parse(v.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture);
            }
            if (v.TryGetValue<string>(out var s) && int.TryParse(s, out var i)) return i;
        }
        return null;
    }

    public static bool? Bool(this JsonNode? node)
    {
        if (node is not JsonValue v) return null;
        if (v.GetValueKind() is JsonValueKind.True or JsonValueKind.False) return v.GetValue<bool>();
        if (v.TryGetValue<string>(out var s)) return s.ToLowerInvariant() is "true" or "1" or "yes";
        return null;
    }

    /// <summary>Strings of an array, or a single string as a one-element list.</summary>
    public static List<string> StringList(this JsonNode? node) => node switch
    {
        JsonArray a => a.Select(x => x.Str()).OfType<string>().ToList(),
        _ when node.Str() is { } s => [s],
        _ => [],
    };

    /// <summary>The value without nulls and empty strings, and without empty arrays or objects below the top level.</summary>
    public static JsonNode Pruned(JsonNode? node) => Prune(node, true) ?? new JsonObject();

    static JsonNode? Prune(JsonNode? node, bool isTop)
    {
        switch (node)
        {
            case null: return null;
            case JsonValue v when v.GetValueKind() == JsonValueKind.Null: return null;
            case JsonValue v when v.TryGetValue<string>(out var s): return s.Length == 0 ? null : JsonValue.Create(s);
            case JsonArray a:
            {
                var kept = new JsonArray();
                foreach (var x in a) if (Prune(x, false) is { } p) kept.Add(p);
                return kept.Count == 0 && !isTop ? null : kept;
            }
            case JsonObject o:
            {
                var kept = new JsonObject();
                foreach (var (key, value) in o)
                {
                    if (Prune(value, false) is { } p) kept[key] = p;
                    else if (isTop && value is JsonArray) kept[key] = new JsonArray();
                }
                return kept.Count == 0 && !isTop ? null : kept;
            }
            default: return node.DeepClone();
        }
    }

    public static JsonNode? From(string? s) => s == null ? null : JsonValue.Create(s);
    public static JsonNode? From(int? i) => i == null ? null : JsonValue.Create(i.Value);
    public static JsonArray Array(IEnumerable<JsonNode?> items) => new([.. items]);
    public static JsonArray Strings(IEnumerable<string> items) => new([.. items.Select(s => (JsonNode)JsonValue.Create(s))]);
}

/// <summary>One tool offered over MCP and folio-cli call.</summary>
public sealed record ToolDefinition(string Name, string Title, string Description, JsonObject InputSchema, bool Writes, bool Destructive)
{
    static readonly HashSet<string> OpenWorld = ["add_item_by_identifier", "add_pdf", "attach_file"];

    /// <summary>MCP tools/list entry.</summary>
    public JsonObject McpDescription => new()
    {
        ["name"] = Name, ["title"] = Title, ["description"] = Description, ["inputSchema"] = InputSchema.DeepClone(),
        ["annotations"] = new JsonObject
        {
            ["title"] = Title, ["readOnlyHint"] = !Writes, ["destructiveHint"] = Destructive, ["idempotentHint"] = !Writes,
            ["openWorldHint"] = OpenWorld.Contains(Name),
        },
    };

    /// <summary>Checks arguments against the schema so the model gets a precise, fixable error.</summary>
    public JsonObject Validated(JsonNode? arguments)
    {
        JsonObject obj = arguments switch
        {
            null => [],
            JsonValue v when v.GetValueKind() == JsonValueKind.Null => [],
            JsonObject o => o,
            _ => throw new ToolError($"Arguments of {Name} must be a JSON object."),
        };
        var properties = InputSchema["properties"] as JsonObject ?? [];
        var accepted = string.Join(", ", properties.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal));
        var problems = new List<string>();
        foreach (var key in obj.Select(p => p.Key).OrderBy(k => k, StringComparer.Ordinal))
            if (!properties.ContainsKey(key)) problems.Add($"unknown parameter \"{key}\"");
        foreach (var key in InputSchema["required"].StringList())
        {
            var value = obj[key];
            if (value == null || value.GetValueKind() == JsonValueKind.Null || value.Str() is "" || value is JsonArray { Count: 0 })
                problems.Add($"missing \"{key}\"");
        }
        foreach (var (key, value) in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
        {
            if (value == null || value.GetValueKind() == JsonValueKind.Null) continue;
            if (properties[key]?["type"].Str() is not { } type) continue;
            bool fits = type switch
            {
                "integer" => value.Int() != null,
                "boolean" => value.Bool() != null,
                "string" => value.Str() != null,
                "array" => value is JsonArray || value.Str() != null,
                _ => true,
            };
            if (!fits) problems.Add($"\"{key}\" must be {(type is "array" or "integer" ? "an" : "a")} {type}");
            var allowed = properties[key]?["enum"].StringList() ?? [];
            if (allowed.Count > 0 && value.Str() is { } text && !allowed.Contains(text.ToLowerInvariant()) && !allowed.Contains(text) && key != "style")
                problems.Add($"\"{key}\" must be one of {string.Join(", ", allowed)}");
        }
        if (problems.Count > 0)
            throw new ToolError($"Invalid arguments for {Name}: {string.Join("; ", problems)}. Accepted parameters: {accepted}.");
        return obj;
    }
}

public static class ToolCatalog
{
    static JsonObject Schema(Dictionary<string, JsonNode> properties, params string[] required) => new()
    {
        ["type"] = "object", ["properties"] = new JsonObject(properties.Select(p => KeyValuePair.Create(p.Key, (JsonNode?)p.Value.DeepClone()))),
        ["required"] = Json.Strings(required), ["additionalProperties"] = false,
    };

    static JsonNode String(string description, string[]? values = null)
    {
        var o = new JsonObject { ["type"] = "string", ["description"] = description };
        if (values != null) o["enum"] = Json.Strings(values);
        return o;
    }

    static JsonNode Strings(string description) => new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" }, ["description"] = description };
    static JsonNode Integer(string description) => new JsonObject { ["type"] = "integer", ["description"] = description };
    static JsonNode Boolean(string description) => new JsonObject { ["type"] = "boolean", ["description"] = description };

    public const string ItemRef = "Item reference: the item's id, its DOI, or its citation key (as returned by search_library / get_item).";
    public const string ColorHelp = "Colour: red, orange, yellow, green, mint, cyan, blue, indigo, purple, pink, gray, or a hex value like #34C759.";
    public const string Collection = "Where to look: \"all\" (default), \"unfiled\", \"trash\", \"group:<name or id>\" (a parent group includes its subgroups), or \"tag:<name or id>\".";
    public static readonly string[] ItemTypes = ["journalArticle", "conferencePaper", "preprint", "book", "bookChapter", "thesis", "report", "webpage", "dataset", "other"];
    public static readonly string[] ReadStatuses = ["unread", "reading", "read"];

    static Dictionary<string, JsonNode> Filters(Dictionary<string, JsonNode> more)
    {
        var d = new Dictionary<string, JsonNode>
        {
            ["collection"] = String(Collection),
            ["author"] = String("Only items with an author whose name contains this (e.g. a family name)."),
            ["year_from"] = Integer("Only items published in or after this year."),
            ["year_to"] = Integer("Only items published in or before this year."),
            ["item_type"] = String("Only items of this type.", ItemTypes),
            ["read_status"] = String("Only items with this reading status.", ReadStatuses),
            ["tags"] = Strings("Only items that have all of these tags."),
            ["limit"] = Integer("Maximum results (default 20, max 200)."),
            ["offset"] = Integer("Skip this many results (paging)."),
        };
        foreach (var (k, v) in more) d[k] = v;
        return d;
    }

    static string[] StyleNames => CitationStyles.All.Select(s => s.Raw()).ToArray();

    public static readonly List<ToolDefinition> All =
    [
        // Reading
        new("search_library", "Search the library",
            "Find papers in the user's Folio library. Matches title, authors, venue, year, tags, DOI, arXiv ID, abstract, the user's notes and file names; include_fulltext also searches inside the PDFs and returns the matching passage. Results are ranked (`matched` = how many query words matched). For a vaguely described paper, run several short keyword queries (topic words, an acronym, an author's family name) and combine with filters; the query may be empty when filters are given (e.g. all unread 2024 papers). Confirm the pick with get_item.",
            Schema(Filters(new()
            {
                ["query"] = String("Keywords, e.g. \"mamba retinal vessel\" or \"Zhang hyperspectral\". Optional when filters are given."),
                ["include_fulltext"] = Boolean("Also search the full text of PDFs and return matching passages (finds papers by content)."),
                ["include_abstract"] = Boolean("Add the first 300 characters of each abstract (helps judge relevance without get_item)."),
                ["sort"] = String("Order: relevance (default), added (newest first), year (newest first), title.", ["relevance", "added", "year", "title"]),
            })), false, false),
        new("list_items", "List items",
            "List items of the whole library, a group, a tag, unfiled items or the trash, with optional filters. Sort by date added (default), year, title, rating, or last_read (papers the user read most recently in Folio).",
            Schema(Filters(new() { ["sort"] = String("Order of the results.", ["added", "year", "title", "rating", "last_read"]) })), false, false),
        new("list_collections", "List groups and tags",
            "Return the user's groups (two levels, with item counts and colours) and tags, plus the counts of all items, unfiled items and the trash.",
            Schema([]), false, false),
        new("get_item", "Get one item",
            "Full record of one item: bibliographic fields, abstract, tags, groups, files (with absolute paths), reading status, rating, when it was last read, the user's note and a folio:// link.",
            Schema(new() { ["item"] = String(ItemRef) }, "item"), false, false),
        new("read_fulltext", "Read a paper's text",
            "Text of an item's PDF with \"[Page n]\" markers. Read long papers in page ranges (follow next_start_page). With `query`, returns only the passages that mention the query words, with their page numbers — use it to answer a specific question about a long paper (\"where do they define the loss?\"). Scanned PDFs without a text layer return nothing.",
            Schema(new()
            {
                ["item"] = String(ItemRef),
                ["query"] = String("Optional words to look for; returns matching passages instead of whole pages."),
                ["start_page"] = Integer("First page, 1-based (default 1)."),
                ["end_page"] = Integer("Last page (default: as many as fit in max_chars)."),
                ["max_chars"] = Integer("Maximum characters to return (default 30000)."),
            }, "item"), false, false),
        new("get_annotations", "Get highlights and notes in the PDF",
            "The user's highlights, underlines, strike-throughs, sticky notes and text boxes in an item's PDFs, with page numbers, quoted text and comments.",
            Schema(new() { ["item"] = String(ItemRef) }, "item"), false, false),
        new("get_note", "Get the item's note", "The user's Markdown note for an item (empty when there is none).",
            Schema(new() { ["item"] = String(ItemRef) }, "item"), false, false),
        new("format_citations", "Format citations",
            "Format references ready to paste, in APA 7th, GB/T 7714-2015 (Chinese national standard), IEEE, MLA 9th, Chicago 18th (author-date), Harvard (Cite Them Right), Vancouver (NLM), Nature or BibTeX. `mode` \"bibliography\" (default) gives the reference list, \"in_text\" the in-text citations (e.g. \"(Wang et al., 2025)\" or \"[1]\"; BibTeX gives \\cite{key}), \"both\" gives both. Numeric styles number items in the order given. Present the returned text exactly as given.",
            Schema(new()
            {
                ["items"] = Strings("Item references, in the order to cite them."),
                ["style"] = String("Citation style.", StyleNames),
                ["mode"] = String("What to return.", ["bibliography", "in_text", "both"]),
            }, "items", "style"), false, false),
        new("export_references", "Export references",
            "Export items as BibTeX, RIS or CSL JSON — given items, or a whole collection. Returns the text, or writes it to `path` when given (absolute path or ~/...), e.g. the .bib file of the user's LaTeX project.",
            Schema(new()
            {
                ["items"] = Strings("Item references. Leave out to export `collection`."),
                ["collection"] = String(Collection),
                ["format"] = String("File format.", ["bibtex", "ris", "csljson"]),
                ["path"] = String("Optional file to write, e.g. ~/Desktop/refs.bib."),
            }, "format"), false, false),
        new("open_in_folio", "Open in Folio",
            "Show an item in the Folio app: opens its PDF in Folio's reader (optionally at a page) or selects it in the library.",
            Schema(new()
            {
                ["item"] = String(ItemRef),
                ["page"] = Integer("1-based page to open the PDF at."),
                ["select_only"] = Boolean("Only select the item in the library list instead of opening the PDF."),
            }, "item"), false, false),

        // Changing the library
        new("add_item_by_identifier", "Add a paper by DOI / arXiv / ISBN",
            "Look up a DOI, arXiv ID or ISBN online and add the work to the library. With download_pdf, also fetches an open-access PDF (arXiv, or the best open-access copy OpenAlex knows for a DOI). If the work is already there, the existing item is returned (and still gets the group, tags and PDF).",
            Schema(new()
            {
                ["identifier"] = String("DOI (10.xxxx/...), arXiv ID (2401.01234) or ISBN, bare or as a URL."),
                ["group"] = String("Optional group to add it to (name, \"Parent/Child\" or id; created when missing)."),
                ["tags"] = Strings("Optional tags to apply (created when missing)."),
                ["download_pdf"] = Boolean("Also download an open-access PDF when one exists (default false)."),
            }, "identifier"), true, false),
        new("add_pdf", "Add a PDF file",
            "Add a PDF (or any file) from disk or from a URL to the library and, for PDFs, retrieve its metadata online so it becomes a full item. Identical files already in the library are reported, not duplicated.",
            Schema(new()
            {
                ["path"] = String("Absolute path of the file (or ~/...)."),
                ["url"] = String("Or a URL to download the PDF from."),
                ["group"] = String("Optional group to add it to (name or id; created when missing)."),
                ["tags"] = Strings("Optional tags to apply."),
                ["retrieve_metadata"] = Boolean("Look up metadata online (default true)."),
            }), true, false),
        new("attach_file", "Attach a file to an item",
            "Attach a file from disk or a PDF from a URL to an existing item (e.g. the PDF of an item added by DOI). The same file is not attached twice.",
            Schema(new()
            {
                ["item"] = String(ItemRef),
                ["path"] = String("Absolute path of the file (or ~/...)."),
                ["url"] = String("Or a URL to download a PDF from."),
                ["make_default"] = Boolean("Open this file by default for the item (default: only when it is the item's first PDF)."),
            }, "item"), true, false),
        new("import_references", "Import BibTeX / RIS",
            "Create items from BibTeX, RIS or CSL JSON — from a file path or pasted text. Works already in the library are skipped (and still added to `group`).",
            Schema(new()
            {
                ["path"] = String("A .bib / .ris / .json file (absolute or ~/...)."),
                ["text"] = String("Or the references as text."),
                ["group"] = String("Optional group to put them in (name or id; created when missing)."),
            }), true, false),
        new("update_item", "Edit an item's details",
            "Change bibliographic fields, reading status or rating of one item. Only the fields given are changed.",
            Schema(new()
            {
                ["item"] = String(ItemRef),
                ["title"] = String("Title."),
                ["authors"] = Strings("Authors as \"Family, Given\" (replaces the list)."),
                ["year"] = Integer("Year."),
                ["venue"] = String("Journal, conference or publisher series."),
                ["volume"] = String("Volume."), ["issue"] = String("Issue."), ["pages"] = String("Pages, e.g. 120-131."),
                ["publisher"] = String("Publisher."), ["doi"] = String("DOI."), ["url"] = String("URL."),
                ["abstract"] = String("Abstract."), ["citation_key"] = String("BibTeX citation key."),
                ["type"] = String("Item type.", ItemTypes),
                ["read_status"] = String("Reading status.", ReadStatuses),
                ["rating"] = Integer("0 (none) to 5 stars."),
            }, "item"), true, false),
        new("set_tags", "Add or remove tags", "Add tags to and/or remove tags from items. Missing tags are created.",
            Schema(new() { ["items"] = Strings("Item references."), ["add"] = Strings("Tag names to add."), ["remove"] = Strings("Tag names to remove.") }, "items"), true, false),
        new("set_groups", "Add to / remove from groups",
            "Put items into groups and/or take them out of groups (they stay in the library). Groups are given by name, id or \"Parent/Child\"; missing groups are created when create_missing is true.",
            Schema(new()
            {
                ["items"] = Strings("Item references."), ["add"] = Strings("Groups to add the items to."),
                ["remove"] = Strings("Groups to remove the items from."), ["create_missing"] = Boolean("Create groups that do not exist (default true)."),
            }, "items"), true, false),
        new("create_group", "Create a group", "Create a group, optionally inside a top-level parent group (groups are at most two levels deep).",
            Schema(new() { ["name"] = String("Group name."), ["parent"] = String("Optional parent group (name or id).") }, "name"), true, false),
        new("create_tag", "Create a tag", "Create a tag (without applying it). To tag items use set_tags, which also creates missing tags.",
            Schema(new() { ["name"] = String("Tag name."), ["color"] = String(ColorHelp) }, "name"), true, false),
        new("update_tag", "Rename or recolour a tag", "Rename a tag and/or change its colour. Items keep the tag.",
            Schema(new() { ["tag"] = String("The tag (name or id)."), ["name"] = String("New name."), ["color"] = String(ColorHelp) }, "tag"), true, false),
        new("delete_tag", "Delete a tag",
            "Delete a tag: it disappears from every item that has it (the items themselves stay). Tell the user how many items use it and confirm first.",
            Schema(new() { ["tag"] = String("The tag (name or id).") }, "tag"), true, true),
        new("update_group", "Rename, recolour or move a group",
            "Rename a group, change its folder colour, or move it under another top-level group (\"parent\": \"\" makes it top-level). Groups are at most two levels deep.",
            Schema(new()
            {
                ["group"] = String("The group (name, \"Parent/Child\" or id)."), ["name"] = String("New name."),
                ["color"] = String(ColorHelp + " \"default\" restores the accent colour."), ["parent"] = String("New parent group, or \"\" for top level."),
            }, "group"), true, false),
        new("delete_group", "Delete a group",
            "Delete a group and its subgroups. Its items stay in the library unless trash_items is true (then they go to the trash). Confirm with the user first.",
            Schema(new() { ["group"] = String("The group (name, \"Parent/Child\" or id)."), ["trash_items"] = Boolean("Also move the group's items to the trash (default false).") }, "group"), true, true),
        new("move_to_trash", "Move items to the trash",
            "Delete items by moving them to Folio's trash (with their files). They can be restored with restore_from_trash; Folio empties the trash after 30 days. Confirm with the user before using this.",
            Schema(new() { ["items"] = Strings("Item references.") }, "items"), true, true),
        new("restore_from_trash", "Restore items from the trash", "Bring trashed items back to the groups they were in.",
            Schema(new() { ["items"] = Strings("Item ids (see list_items with collection \"trash\").") }, "items"), true, false),
        new("set_note", "Write the item's note",
            "Replace or append to the user's Markdown note of an item. Prefer append so the user's own text is kept.",
            Schema(new() { ["item"] = String(ItemRef), ["content"] = String("Markdown text."), ["mode"] = String("append (default) or replace.", ["append", "replace"]) }, "item", "content"), true, false),
    ];

    public static ToolDefinition? Tool(string name) => All.FirstOrDefault(t => t.Name == name);

    public static List<ToolDefinition> Available(bool allowWrites) => All.Where(t => allowWrites || !t.Writes).ToList();
}
