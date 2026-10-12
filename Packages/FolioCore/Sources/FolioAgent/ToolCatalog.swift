import Foundation

/// One tool offered over MCP and `folio-cli call`.
public struct ToolDefinition: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    /// Changes the library (hidden when 设置 ▸ AI ▸ 允许 AI 修改文献库 is off).
    public let writes: Bool
    /// Removes something from view (moves to the trash) — clients may ask the user first.
    public let destructive: Bool

    /// MCP `tools/list` entry.
    public var mcpDescription: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(!writes),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(!writes),
                "openWorldHint": .bool(name == "add_item_by_identifier" || name == "add_pdf"),
            ],
        ]
    }
}

public enum ToolCatalog {
    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)),
         "additionalProperties": false]
    }

    private static func string(_ description: String, enumValues: [String]? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let enumValues { object["enum"] = .array(enumValues.map(JSONValue.string)) }
        return .object(object)
    }

    private static func strings(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    private static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    private static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    static let itemRef = "Item reference: the item's id, its DOI, or its citation key (as returned by search_library / get_item)."
    static let collection = "Where to look: \"all\" (default), \"unfiled\", \"trash\", \"group:<name or id>\" (a parent group includes its subgroups), or \"tag:<name or id>\"."

    public static let all: [ToolDefinition] = [
        // MARK: Reading
        ToolDefinition(
            name: "search_library", title: "Search the library",
            description: """
            Find papers in the user's Folio library. Matches title, authors, venue, year, tags, DOI, arXiv ID, \
            abstract, the user's notes and file names; set include_fulltext to also search inside the PDFs. \
            Results are ranked: items matching more of the words come first, and `matched` says how many \
            words matched. Use several short keyword queries (topic words, an author's family name, a year, \
            an acronym) when the user describes a paper vaguely, then confirm with get_item.
            """,
            inputSchema: schema([
                "query": string("Keywords, e.g. \"mamba retinal vessel\" or \"Zhang 2026 hyperspectral\"."),
                "collection": string(collection),
                "include_fulltext": boolean("Also search the full text of PDFs (slower, finds papers by content)."),
                "limit": integer("Maximum results (default 20, max 100)."),
            ], required: ["query"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "list_items", title: "List items in a collection",
            description: "List items of the whole library, a group, a tag, unfiled items or the trash, newest first by default.",
            inputSchema: schema([
                "collection": string(collection),
                "sort": string("Order of the results.", enumValues: ["added", "year", "title"]),
                "limit": integer("Maximum results (default 50, max 200)."),
                "offset": integer("Skip this many results (paging)."),
            ]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "list_collections", title: "List groups and tags",
            description: "Return the user's groups (two levels, with item counts and colours) and tags, plus the counts of all items, unfiled items and the trash.",
            inputSchema: schema([:]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "get_item", title: "Get one item",
            description: "Full record of one item: bibliographic fields, abstract, tags, groups, files (with absolute paths), reading status, rating, the user's note and a folio:// link.",
            inputSchema: schema(["item": string(itemRef)], required: ["item"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "read_fulltext", title: "Read a paper's text",
            description: "Extract the text of an item's PDF, page by page (\"[Page n]\" markers). Read long papers in page ranges. Scanned PDFs without a text layer return nothing.",
            inputSchema: schema([
                "item": string(itemRef),
                "start_page": integer("First page, 1-based (default 1)."),
                "end_page": integer("Last page (default: as many as fit in max_chars)."),
                "max_chars": integer("Maximum characters to return (default 30000)."),
            ], required: ["item"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "get_annotations", title: "Get highlights and notes in the PDF",
            description: "The user's highlights, underlines, strike-throughs, sticky notes and text boxes in an item's PDFs, with page numbers, quoted text and comments.",
            inputSchema: schema(["item": string(itemRef)], required: ["item"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "get_note", title: "Get the item's note",
            description: "The user's Markdown note for an item (empty when there is none).",
            inputSchema: schema(["item": string(itemRef)], required: ["item"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "format_citations", title: "Format citations",
            description: "Format references in a citation style, ready to paste: APA 7th, GB/T 7714-2015 (Chinese national standard, numeric) or BibTeX. Present the returned text exactly as given.",
            inputSchema: schema([
                "items": strings("Item references, in the order to cite them."),
                "style": string("Citation style.", enumValues: ["apa", "gbt7714", "bibtex"]),
            ], required: ["items", "style"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "export_references", title: "Export references",
            description: "Export items as BibTeX, RIS or CSL JSON — given items, or a whole collection. Returns the text, or writes it to `path` when given (absolute path or ~/...).",
            inputSchema: schema([
                "items": strings("Item references. Leave out to export `collection`."),
                "collection": string(collection),
                "format": string("File format.", enumValues: ["bibtex", "ris", "csljson"]),
                "path": string("Optional file to write, e.g. ~/Desktop/refs.bib."),
            ], required: ["format"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "open_in_folio", title: "Open in Folio",
            description: "Show an item in the Folio app: opens its PDF in Folio's reader (optionally at a page) or selects it in the library.",
            inputSchema: schema([
                "item": string(itemRef),
                "page": integer("1-based page to open the PDF at."),
                "select_only": boolean("Only select the item in the library list instead of opening the PDF."),
            ], required: ["item"]),
            writes: false, destructive: false),

        // MARK: Changing the library
        ToolDefinition(
            name: "add_item_by_identifier", title: "Add a paper by DOI / arXiv / ISBN",
            description: "Look up a DOI, arXiv ID or ISBN online and add the work to the library (no PDF). If it is already there, the existing item is returned instead.",
            inputSchema: schema([
                "identifier": string("DOI (10.xxxx/...), arXiv ID (2401.01234) or ISBN, bare or as a URL."),
                "group": string("Optional group to add it to (name or id; created when missing)."),
                "tags": strings("Optional tags to apply (created when missing)."),
            ], required: ["identifier"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "add_pdf", title: "Add a PDF file",
            description: "Copy a PDF (or any file) from disk into the library and, for PDFs, retrieve its metadata online so it becomes a full item. Identical files already in the library are reported, not duplicated.",
            inputSchema: schema([
                "path": string("Absolute path of the file (or ~/...)."),
                "group": string("Optional group to add it to (name or id; created when missing)."),
                "tags": strings("Optional tags to apply."),
                "retrieve_metadata": boolean("Look up metadata online (default true)."),
            ], required: ["path"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "import_references", title: "Import BibTeX / RIS",
            description: "Create items from BibTeX, RIS or CSL JSON — from a file path or pasted text. Works already in the library are skipped (and still added to `group`).",
            inputSchema: schema([
                "path": string("A .bib / .ris / .json file (absolute or ~/...)."),
                "text": string("Or the references as text."),
                "group": string("Optional group to put them in (name or id; created when missing)."),
            ]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "update_item", title: "Edit an item's details",
            description: "Change bibliographic fields, reading status or rating of one item. Only the fields given are changed.",
            inputSchema: schema([
                "item": string(itemRef),
                "title": string("Title."),
                "authors": strings("Authors as \"Family, Given\" (replaces the list)."),
                "year": integer("Year."),
                "venue": string("Journal, conference or publisher series."),
                "volume": string("Volume."), "issue": string("Issue."), "pages": string("Pages, e.g. 120-131."),
                "publisher": string("Publisher."), "doi": string("DOI."), "url": string("URL."),
                "abstract": string("Abstract."), "citation_key": string("BibTeX citation key."),
                "type": string("Item type.", enumValues: ["journalArticle", "conferencePaper", "preprint", "book", "bookChapter",
                                                          "thesis", "report", "webpage", "dataset", "other"]),
                "read_status": string("Reading status.", enumValues: ["unread", "reading", "read"]),
                "rating": integer("0 (none) to 5 stars."),
            ], required: ["item"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "set_tags", title: "Add or remove tags",
            description: "Add tags to and/or remove tags from items. Missing tags are created.",
            inputSchema: schema([
                "items": strings("Item references."),
                "add": strings("Tag names to add."),
                "remove": strings("Tag names to remove."),
            ], required: ["items"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "set_groups", title: "Add to / remove from groups",
            description: "Put items into groups and/or take them out of groups (they stay in the library). Groups are given by name, id or \"Parent/Child\"; missing groups are created when create_missing is true.",
            inputSchema: schema([
                "items": strings("Item references."),
                "add": strings("Groups to add the items to."),
                "remove": strings("Groups to remove the items from."),
                "create_missing": boolean("Create groups that do not exist (default true)."),
            ], required: ["items"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "create_group", title: "Create a group",
            description: "Create a group, optionally inside a top-level parent group (groups are at most two levels deep).",
            inputSchema: schema([
                "name": string("Group name."),
                "parent": string("Optional parent group (name or id)."),
            ], required: ["name"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "move_to_trash", title: "Move items to the trash",
            description: "Delete items by moving them to Folio's trash (with their files). They can be restored with restore_from_trash; Folio empties the trash after 30 days. Confirm with the user before using this.",
            inputSchema: schema(["items": strings("Item references.")], required: ["items"]),
            writes: true, destructive: true),
        ToolDefinition(
            name: "restore_from_trash", title: "Restore items from the trash",
            description: "Bring trashed items back to the groups they were in.",
            inputSchema: schema(["items": strings("Item ids (see list_items with collection \"trash\").")], required: ["items"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "set_note", title: "Write the item's note",
            description: "Replace or append to the user's Markdown note of an item. Prefer append so the user's own text is kept.",
            inputSchema: schema([
                "item": string(itemRef),
                "content": string("Markdown text."),
                "mode": string("append (default) or replace.", enumValues: ["append", "replace"]),
            ], required: ["item", "content"]),
            writes: true, destructive: false),
    ]

    public static func tool(named name: String) -> ToolDefinition? { all.first { $0.name == name } }

    public static func available(allowWrites: Bool) -> [ToolDefinition] { all.filter { allowWrites || !$0.writes } }
}
