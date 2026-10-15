import FolioCitation
import Foundation

/// One tool offered over MCP and `folio-cli call`.
public struct ToolDefinition: Sendable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: JSONValue
    /// Changes the library (hidden when 设置 ▸ AI ▸ 允许 AI 修改文献库 is off).
    public let writes: Bool
    /// Removes something (a tag, a group, items to the trash) — clients may ask the user first.
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
                "openWorldHint": .bool(["add_item_by_identifier", "add_pdf", "attach_file"].contains(name)),
            ],
        ]
    }

    /// Checks arguments against the schema so the model gets a precise, fixable error instead of a
    /// silently ignored misspelt parameter. Returns the arguments as an object.
    func validated(_ arguments: JSONValue) throws -> JSONValue {
        let object: [String: JSONValue]
        switch arguments {
        case .null: object = [:]
        case .object(let value): object = value
        default: throw ToolError("Arguments of \(name) must be a JSON object.")
        }
        var properties: [String: JSONValue] = [:]
        if case .object(let declared)? = inputSchema["properties"] { properties = declared }
        let accepted = properties.keys.sorted().joined(separator: ", ")
        var problems: [String] = []
        for key in object.keys.sorted() where properties[key] == nil {
            problems.append("unknown parameter \"\(key)\"")
        }
        for key in inputSchema["required"]?.stringList ?? [] {
            let value = object[key]
            if value == nil || value == .null || value?.stringValue?.isEmpty == true || value?.arrayValue?.isEmpty == true {
                problems.append("missing \"\(key)\"")
            }
        }
        for (key, value) in object.sorted(by: { $0.key < $1.key }) where value != .null {
            guard let type = properties[key]?["type"]?.stringValue else { continue }
            let fits = switch type {
            case "integer": value.intValue != nil
            case "boolean": value.boolValue != nil
            case "string": value.stringValue != nil
            case "array": value.arrayValue != nil || value.stringValue != nil
            default: true
            }
            if !fits { problems.append("\"\(key)\" must be \(["array", "integer"].contains(type) ? "an" : "a") \(type)") }
            if let allowed = properties[key]?["enum"]?.stringList, let text = value.stringValue,
               !allowed.contains(text.lowercased()), !allowed.contains(text), key != "style" {
                problems.append("\"\(key)\" must be one of \(allowed.joined(separator: ", "))")
            }
        }
        guard problems.isEmpty else {
            throw ToolError("Invalid arguments for \(name): \(problems.joined(separator: "; ")). Accepted parameters: \(accepted).")
        }
        return .object(object)
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
    static let colorHelp = "Colour: red, orange, yellow, green, mint, cyan, blue, indigo, purple, pink, gray, or a hex value like #34C759."
    static let collection = "Where to look: \"all\" (default), \"unfiled\", \"trash\", \"group:<name or id>\" (a parent group includes its subgroups), or \"tag:<name or id>\"."
    static let itemTypes = ["journalArticle", "conferencePaper", "preprint", "book", "bookChapter", "thesis", "report", "webpage", "dataset", "other"]
    static let readStatuses = ["unread", "reading", "read"]

    /// Filters shared by search_library and list_items.
    static let filters: [String: JSONValue] = [
        "collection": string(collection),
        "author": string("Only items with an author whose name contains this (e.g. a family name)."),
        "year_from": integer("Only items published in or after this year."),
        "year_to": integer("Only items published in or before this year."),
        "item_type": string("Only items of this type.", enumValues: itemTypes),
        "read_status": string("Only items with this reading status.", enumValues: readStatuses),
        "tags": strings("Only items that have all of these tags."),
        "limit": integer("Maximum results (default 20, max 200)."),
        "offset": integer("Skip this many results (paging)."),
    ]

    public static let all: [ToolDefinition] = [
        // MARK: Reading
        ToolDefinition(
            name: "search_library", title: "Search the library",
            description: """
            Find papers in the user's Folio library. Matches title, authors, venue, year, tags, DOI, arXiv ID, \
            abstract, the user's notes and file names; include_fulltext also searches inside the PDFs and returns \
            the matching passage. Results are ranked (`matched` = how many query words matched). For a vaguely \
            described paper, run several short keyword queries (topic words, an acronym, an author's family name) \
            and combine with filters; the query may be empty when filters are given (e.g. all unread 2024 papers). \
            Confirm the pick with get_item.
            """,
            inputSchema: schema(filters.merging([
                "query": string("Keywords, e.g. \"mamba retinal vessel\" or \"Zhang hyperspectral\". Optional when filters are given."),
                "include_fulltext": boolean("Also search the full text of PDFs and return matching passages (finds papers by content)."),
                "include_abstract": boolean("Add the first 300 characters of each abstract (helps judge relevance without get_item)."),
                "sort": string("Order: relevance (default), added (newest first), year (newest first), title.",
                               enumValues: ["relevance", "added", "year", "title"]),
            ]) { $1 }),
            writes: false, destructive: false),
        ToolDefinition(
            name: "list_items", title: "List items",
            description: "List items of the whole library, a group, a tag, unfiled items or the trash, with optional filters. Sort by date added (default), year, title, rating, or last_read (papers the user read most recently in Folio).",
            inputSchema: schema(filters.merging([
                "sort": string("Order of the results.", enumValues: ["added", "year", "title", "rating", "last_read"]),
            ]) { $1 }),
            writes: false, destructive: false),
        ToolDefinition(
            name: "list_collections", title: "List groups and tags",
            description: "Return the user's groups (two levels, with item counts and colours) and tags, plus the counts of all items, unfiled items and the trash.",
            inputSchema: schema([:]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "get_item", title: "Get one item",
            description: "Full record of one item: bibliographic fields, abstract, tags, groups, files (with absolute paths), reading status, rating, when it was last read, the user's note and a folio:// link.",
            inputSchema: schema(["item": string(itemRef)], required: ["item"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "read_fulltext", title: "Read a paper's text",
            description: """
            Text of an item's PDF with "[Page n]" markers. Read long papers in page ranges (follow next_start_page). \
            With `query`, returns only the passages that mention the query words, with their page numbers — use it to \
            answer a specific question about a long paper ("where do they define the loss?"). Scanned PDFs without a \
            text layer return nothing.
            """,
            inputSchema: schema([
                "item": string(itemRef),
                "query": string("Optional words to look for; returns matching passages instead of whole pages."),
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
            description: """
            Format references ready to paste, in APA 7th, GB/T 7714-2015 (Chinese national standard), IEEE, MLA 9th, \
            Chicago 18th (author-date), Harvard (Cite Them Right), Vancouver (NLM), Nature or BibTeX. `mode` \
            "bibliography" (default) gives the reference list, "in_text" the in-text citations (e.g. "(Wang et al., \
            2025)" or "[1]"; BibTeX gives \\cite{key}), "both" gives both. Numeric styles number items in the order \
            given. Present the returned text exactly as given.
            """,
            inputSchema: schema([
                "items": strings("Item references, in the order to cite them."),
                "style": string("Citation style.", enumValues: CitationStyle.allCases.map(\.rawValue)),
                "mode": string("What to return.", enumValues: ["bibliography", "in_text", "both"]),
            ], required: ["items", "style"]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "export_references", title: "Export references",
            description: "Export items as BibTeX, RIS or CSL JSON — given items, or a whole collection. Returns the text, or writes it to `path` when given (absolute path or ~/...), e.g. the .bib file of the user's LaTeX project.",
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
            description: "Look up a DOI, arXiv ID or ISBN online and add the work to the library. With download_pdf, also fetches an open-access PDF (arXiv, or the best open-access copy OpenAlex knows for a DOI). If the work is already there, the existing item is returned (and still gets the group, tags and PDF).",
            inputSchema: schema([
                "identifier": string("DOI (10.xxxx/...), arXiv ID (2401.01234) or ISBN, bare or as a URL."),
                "group": string("Optional group to add it to (name, \"Parent/Child\" or id; created when missing)."),
                "tags": strings("Optional tags to apply (created when missing)."),
                "download_pdf": boolean("Also download an open-access PDF when one exists (default false)."),
            ], required: ["identifier"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "add_pdf", title: "Add a PDF file",
            description: "Add a PDF (or any file) from disk or from a URL to the library and, for PDFs, retrieve its metadata online so it becomes a full item. Identical files already in the library are reported, not duplicated.",
            inputSchema: schema([
                "path": string("Absolute path of the file (or ~/...)."),
                "url": string("Or a URL to download the PDF from."),
                "group": string("Optional group to add it to (name or id; created when missing)."),
                "tags": strings("Optional tags to apply."),
                "retrieve_metadata": boolean("Look up metadata online (default true)."),
            ]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "attach_file", title: "Attach a file to an item",
            description: "Attach a file from disk or a PDF from a URL to an existing item (e.g. the PDF of an item added by DOI). The same file is not attached twice.",
            inputSchema: schema([
                "item": string(itemRef),
                "path": string("Absolute path of the file (or ~/...)."),
                "url": string("Or a URL to download a PDF from."),
                "make_default": boolean("Open this file by default for the item (default: only when it is the item's first PDF)."),
            ], required: ["item"]),
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
                "type": string("Item type.", enumValues: itemTypes),
                "read_status": string("Reading status.", enumValues: readStatuses),
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
            name: "create_tag", title: "Create a tag",
            description: "Create a tag (without applying it). To tag items use set_tags, which also creates missing tags.",
            inputSchema: schema([
                "name": string("Tag name."),
                "color": string(colorHelp),
            ], required: ["name"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "update_tag", title: "Rename or recolour a tag",
            description: "Rename a tag and/or change its colour. Items keep the tag.",
            inputSchema: schema([
                "tag": string("The tag (name or id)."),
                "name": string("New name."),
                "color": string(colorHelp),
            ], required: ["tag"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "delete_tag", title: "Delete a tag",
            description: "Delete a tag: it disappears from every item that has it (the items themselves stay). Tell the user how many items use it and confirm first.",
            inputSchema: schema(["tag": string("The tag (name or id).")], required: ["tag"]),
            writes: true, destructive: true),
        ToolDefinition(
            name: "update_group", title: "Rename, recolour or move a group",
            description: "Rename a group, change its folder colour, or move it under another top-level group (\"parent\": \"\" makes it top-level). Groups are at most two levels deep.",
            inputSchema: schema([
                "group": string("The group (name, \"Parent/Child\" or id)."),
                "name": string("New name."),
                "color": string(colorHelp + " \"default\" restores the accent colour."),
                "parent": string("New parent group, or \"\" for top level."),
            ], required: ["group"]),
            writes: true, destructive: false),
        ToolDefinition(
            name: "delete_group", title: "Delete a group",
            description: "Delete a group and its subgroups. Its items stay in the library unless trash_items is true (then they go to the trash). Confirm with the user first.",
            inputSchema: schema([
                "group": string("The group (name, \"Parent/Child\" or id)."),
                "trash_items": boolean("Also move the group's items to the trash (default false)."),
            ], required: ["group"]),
            writes: true, destructive: true),
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

        // Folio's translation engine (设置 ▸ 翻译): finding the user's own pdf2zh_next.
        ToolDefinition(
            name: "find_pdf2zh_next", title: "Find pdf2zh_next on this Mac",
            description: "Search this Mac for the user's own pdf2zh_next (the PDF translation engine Folio can use instead of its built-in copy) the way Folio does: shell PATH, uv / pipx / conda / pyenv / Homebrew / virtualenv locations, the zotero-pdf2zh plugin, Spotlight and virtual environments in the home folder. Runs each with --version. Returns the one Folio uses now, the working ones and those that fail. If none is found, look further with your own shell (see the skill), then call set_pdf2zh_next_path.",
            inputSchema: schema([:]),
            writes: false, destructive: false),
        ToolDefinition(
            name: "set_pdf2zh_next_path", title: "Use a pdf2zh_next for translation",
            description: "Make Folio translate with this pdf2zh_next executable (设置 ▸ 翻译 ▸ 使用自己安装的 pdf2zh_next). Folio first runs it with --version and refuses a file that does not report a pdf2zh-next version. Takes effect immediately in the running app.",
            inputSchema: schema(["path": string("Absolute path of the pdf2zh_next executable, e.g. ~/envs/translate/bin/pdf2zh_next.")],
                                required: ["path"]),
            writes: false, destructive: false),
    ]

    public static func tool(named name: String) -> ToolDefinition? { all.first { $0.name == name } }

    public static func available(allowWrites: Bool) -> [ToolDefinition] { all.filter { allowWrites || !$0.writes } }
}
