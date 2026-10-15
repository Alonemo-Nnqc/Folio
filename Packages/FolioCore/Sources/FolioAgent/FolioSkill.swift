import FolioCitation
import Foundation

/// The Folio skill (AI-03): a skill folder in the open Agent Skills format — a short `SKILL.md` the
/// agent loads when the user talks about their papers, and `references/` it reads when needed. It
/// works through Folio's MCP tools when connected and through folio-cli otherwise.
public enum FolioSkill {
    public static let name = "folio-library"

    /// Marker written into installed skills so Folio recognises (and updates) its own copy.
    public static let marker = "<!-- folio-skill -->"

    /// Read-only MCP tools Claude Code may run without asking while the skill is active.
    static let preapprovedTools = ["search_library", "list_items", "list_collections", "get_item", "read_fulltext",
                                   "get_annotations", "get_note", "format_citations"]

    /// Every file of the skill folder: relative path → contents.
    public static func files(cliPath: String) -> [(path: String, contents: String)] {
        [
            ("SKILL.md", markdown(cliPath: cliPath)),
            ("references/tools.md", toolReference()),
            ("references/cli.md", cliReference(cliPath: cliPath)),
            ("references/writing.md", writingGuide()),
        ]
    }

    /// Writes the skill folder, replacing an earlier copy completely (so removed files do not linger).
    public static func write(to folder: URL, cliPath: String) throws {
        let manager = FileManager.default
        let staging = folder.deletingLastPathComponent().appending(path: ".\(name)-\(UUID().uuidString)")
        try manager.createDirectory(at: staging.appending(path: "references"), withIntermediateDirectories: true)
        do {
            for file in files(cliPath: cliPath) {
                try file.contents.write(to: staging.appending(path: file.path), atomically: true, encoding: .utf8)
            }
            if manager.fileExists(atPath: folder.path) {
                _ = try manager.replaceItemAt(folder, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: folder)
            }
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Whether `folder` holds exactly this version of the skill for `cliPath`.
    public static func isCurrent(at folder: URL, cliPath: String) -> Bool {
        files(cliPath: cliPath).allSatisfy { file in
            (try? String(contentsOf: folder.appending(path: file.path), encoding: .utf8)) == file.contents
        }
    }

    static func quoted(_ cliPath: String) -> String {
        cliPath.contains(" ") ? "\"\(cliPath)\"" : cliPath
    }

    public static func markdown(cliPath: String) -> String {
        let cli = quoted(cliPath)
        return """
        ---
        name: \(name)
        description: Work with the user's Folio reference library (a Zotero-like app on this Mac) — find the paper the user means, read and summarise it, cite it (APA, GB/T 7714, IEEE, MLA, Chicago, Harvard, Vancouver, Nature, BibTeX) or export .bib / RIS / CSL JSON, add or organise papers by DOI, arXiv ID or PDF, and set up Folio's PDF translation (pdf2zh_next). Use whenever the user mentions their papers, literature, references, citations, bibliography, reading list or Folio, asks about "that paper about …", or writes something that needs references — also for 论文、文献、参考文献、引用、文献库、读过的文章.
        allowed-tools: \(preapprovedTools.map { "mcp__folio__\($0)" }.joined(separator: " "))
        ---
        \(marker)

        # Folio library

        Folio is the user's reference manager. Their papers, PDFs, highlights and notes live in it.
        **Never invent papers or citation details**: everything you state about the user's library comes from Folio.

        ## Reaching Folio

        1. **MCP tools** (preferred): tools such as `search_library`, `get_item`, `format_citations` from the server
           named `folio`.
        2. **Command line**, when those tools are not available: `\(cli) call <tool> '<JSON arguments>'` — the same
           tools and arguments, JSON output. Details: [references/cli.md](references/cli.md).
        3. If neither works, run `\(cli) status` and tell the user what it says. Folio ▸ 设置 ▸ AI adds the MCP server
           to their agents; "允许 AI 修改文献库" there controls whether changes are allowed.

        Every tool and parameter: [references/tools.md](references/tools.md).

        ## Finding the paper the user means

        Users describe papers loosely ("the Mamba one for retinal vessels", "the night-time segmentation dataset from 2021").
        1. `search_library` with 2–4 distinctive keywords: topic words, an acronym, an author's family name.
           Add filters when the user gives them: `author`, `year_from` / `year_to`, `item_type`, `read_status`, `tags`,
           `collection` ("group:<name>"). With filters only, the query may be empty ("my unread papers from 2024").
        2. Nothing convincing? Other wordings and synonyms, one rare word, or `include_fulltext: true` (searches inside
           the PDFs and returns the matching passage). "The paper I was reading yesterday": `list_items` with
           `sort: "last_read"`.
        3. Several candidates: show a short numbered list (title, first author, year) and ask. One clear match: name it
           in one line and continue.
        4. `get_item` for the full record (abstract, files, note) before answering detailed questions.

        ## Reading and answering questions about a paper

        - A specific question about a long paper: `read_fulltext` with `query` returns only the passages that mention
          the words, with page numbers. Otherwise read page ranges (`start_page` / `end_page`, follow `next_start_page`).
          Cite page numbers in your answer.
        - `get_annotations`: what the user highlighted and commented. `get_note`: their own note.
        - To save a summary for them: `set_note` with `mode: "append"` (never replace their note unless asked).
        - `open_in_folio` opens the paper in Folio's reader, optionally at a page.

        ## Citing and writing

        - `format_citations` with `style` (`apa`, `gbt7714`, `ieee`, `mla`, `chicago`, `harvard`, `vancouver`, `nature`,
          `bibtex`) and `mode` (`bibliography`, `in_text`, `both`). **Copy the returned text exactly** — do not reformat,
          translate, renumber or "fix" it.
        - Writing a LaTeX, Typst, Markdown / Pandoc or Word document: follow [references/writing.md](references/writing.md)
          (export the .bib / CSL JSON next to the document and cite with the returned citation keys).
        - Items without metadata ("standalone file") cannot be cited; offer to fix them with `update_item`
          or `add_item_by_identifier`.

        ## Adding and organising (only when the user asks)

        - By identifier: `add_item_by_identifier` with a DOI, arXiv ID or ISBN (exact metadata); `download_pdf: true`
          also fetches an open-access PDF.
        - A PDF on disk or at a URL: `add_pdf` (Folio retrieves the metadata). A PDF for an existing item: `attach_file`.
        - BibTeX / RIS / CSL JSON: `import_references` with `path` or `text`.
        - All of these report works already in the library instead of duplicating them. Put new papers in the group the
          user is working on (`group`, "Parent/Child" for a subgroup) and apply tags when asked.
        - Groups: `set_groups`, `create_group`, `update_group`. Tags: `set_tags`, `create_tag`, `update_tag`.
          Colours are names (red, orange, yellow, green, mint, cyan, blue, indigo, purple, pink, gray) or `#RRGGBB`.
        - Reading status (`unread` / `reading` / `read`), rating (0–5) and bibliographic fields: `update_item`.

        ## Setting up translation (pdf2zh_next)

        Folio translates PDFs with pdf2zh_next. When the user wants Folio to use their own copy, or Folio could not find it:
        1. `find_pdf2zh_next`. One working result: tell the user and call `set_pdf2zh_next_path`. Several: ask which.
        2. Nothing found: search with your shell, for example `mdfind "kMDItemFSName == 'pdf2zh_next'"`,
           `find ~ -path '*/bin/pdf2zh_next' -not -path '*/Library/*' 2>/dev/null | head`, `uv tool list`, `pipx list`,
           `conda env list` (then `<env>/bin/pdf2zh_next`). Check a candidate with `<path> --version`
           (it prints "pdf2zh-next version: …").
        3. `set_pdf2zh_next_path` with the absolute path; Folio checks it and uses it at once. Not installed at all:
           suggest `uv tool install pdf2zh-next`, or Folio's built-in engine (Folio ▸ 设置 ▸ 翻译 ▸ 下载并安装).

        ## Ask first

        - `delete_tag`, `delete_group` and `move_to_trash` need the user's confirmation: say exactly what will happen
          (which items, how many use the tag) and wait for a yes. Trashed items are restorable for 30 days
          (`restore_from_trash`); there is no permanent delete.
        - If a tool says changes by AI are turned off, explain that the user can allow them in Folio ▸ 设置 ▸ AI ▸
          允许 AI 修改文献库.

        ## Style

        - Answer in the user's language. Refer to papers by title (and first author, year), never by id.
        - After changing the library, summarise what changed in one or two lines; Folio updates on screen by itself.

        """
    }

    /// Every tool with its parameters, generated from `ToolCatalog` so it always matches the server.
    static func toolReference() -> String {
        var lines = [
            "# Folio tools",
            "",
            "The same tools are available as MCP tools (server `folio`) and through `folio-cli call <tool> '<JSON>'`.",
            "Item references can be an item id from a result, a DOI or a citation key. Tools marked **changes the library**",
            "are missing when the user turned off changes by AI; **ask first** tools need the user's confirmation.",
            "",
        ]
        for tool in ToolCatalog.all {
            var flags: [String] = []
            if tool.writes { flags.append("changes the library") }
            if tool.destructive { flags.append("ask first") }
            lines.append("## `\(tool.name)`\(flags.isEmpty ? "" : " — " + flags.map { "**\($0)**" }.joined(separator: ", "))")
            lines.append("")
            lines.append(tool.description.replacingOccurrences(of: "\n", with: " "))
            lines.append("")
            let required = Set(tool.inputSchema["required"]?.stringList ?? [])
            if case .object(let properties)? = tool.inputSchema["properties"], !properties.isEmpty {
                for key in properties.keys.sorted(by: { (required.contains($0) ? 0 : 1, $0) < (required.contains($1) ? 0 : 1, $1) }) {
                    let property = properties[key]!
                    var type = property["type"]?.stringValue ?? "value"
                    if type == "array" { type = "list of strings" }
                    let options = property["enum"]?.stringList ?? []
                    let detail = (property["description"]?.stringValue ?? "")
                        + (options.isEmpty ? "" : " One of: " + options.map { "`\($0)`" }.joined(separator: ", ") + ".")
                    lines.append("- `\(key)` (\(type)\(required.contains(key) ? ", required" : "")): \(detail)")
                }
            } else {
                lines.append("No parameters.")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func cliReference(cliPath: String) -> String {
        let cli = quoted(cliPath)
        return """
        # folio-cli

        `\(cli)` is Folio's command-line interface, for agents without the MCP tools. Output is JSON (citations and
        exports print their text). Exit status 0 means success; errors go to stderr.

        ```bash
        \(cli) status                                   # library location, item count, whether changes are allowed
        \(cli) tools                                    # every tool with its description (--json for the schemas)
        \(cli) call search_library '{"query": "mamba retinal vessel", "year_from": 2024}'
        \(cli) call get_item '{"item": "<id, DOI or citation key>"}'
        \(cli) call read_fulltext '{"item": "<id>", "query": "loss function"}'
        \(cli) call format_citations '{"items": ["<id>", "<id>"], "style": "ieee", "mode": "both"}'
        \(cli) call export_references '{"items": ["<id>"], "format": "bibtex", "path": "~/thesis/references.bib"}'
        ```

        Shortcuts:

        ```bash
        \(cli) search <words…> [--fulltext] [--limit N]
        \(cli) get <id | DOI | citation key>
        \(cli) cite <items…> [--style \(CitationStyle.allCases.map(\.rawValue).joined(separator: "|"))] [--in-text]
        \(cli) export [--format bibtex|ris|csljson] [--collection <group:name | tag:name>] [-o <file>]
        \(cli) add <DOI | arXiv ID | ISBN | PDF path> [--group <group>]
        \(cli) open <item> [--page N]
        ```

        Options: `--library <folder>` uses another library; `--read-only` refuses changes.

        Notes:

        - Pass JSON arguments in single quotes; inside them use double quotes.
        - Sandboxed agents may block folio-cli from reading `~/Folio` or from the network (needed for adding papers by
          DOI). If a command fails with a permission or network error, ask the user to allow it to run outside the
          sandbox, or to enable Folio's MCP server for this agent in Folio ▸ 设置 ▸ AI.
        - "No Folio library at …": Folio has not created its library yet, or the user keeps it elsewhere; ask them to
          open Folio once, or pass `--library`.

        """
    }

    static func writingGuide() -> String {
        """
        # Citing while writing

        Always take references from Folio — never type a citation from memory. Find each paper first
        (`search_library`, confirm with `get_item`), then:

        ## LaTeX (BibTeX / biblatex)

        1. Export the cited items: `export_references` with `format: "bibtex"` and `path` next to the document
           (e.g. `references.bib`). The result lists the `citation_keys`.
        2. **If the project already has a .bib file**, do not overwrite it: export to a separate file such as
           `folio.bib` and add it (`\\bibliography{references,folio}` or `\\addbibresource{folio.bib}`), or ask the user.
        3. Cite with the keys exactly as exported: `\\cite{key}`, `\\citep{key}` / `\\citet{key}` (natbib), `\\parencite{key}`
           (biblatex). `format_citations` with `style: "bibtex"`, `mode: "in_text"` gives `\\cite{…}` commands.
        4. Chinese theses usually require GB/T 7714: use the `gbt7714-numeric` biblatex style or the template's own.

        ## Typst

        Export BibTeX as above, add `#bibliography("folio.bib", style: "ieee")` (or `"apa"`, `"gb-7714-2015-numeric"`)
        and cite with `@key`.

        ## Markdown, Pandoc, Quarto, R Markdown

        Export CSL JSON (`format: "csljson"`, e.g. `references.json`), set `bibliography: references.json` in the
        front matter, cite with `[@key]` / `@key`, and render with `--citeproc` (add a `csl:` file for a specific style).

        ## Word, Pages, Google Docs, plain text, emails

        Call `format_citations` with all cited items **in the order they are first cited**, the style the user wants and
        `mode: "both"`. Paste the in-text citations where they belong and the reference list at the end, exactly as
        returned. Numeric styles (IEEE, Vancouver, Nature, GB/T 7714) number the items in the order you passed them.
        Tell the user that Folio's "拷贝引用" menu copies the same text with formatting (italics) for Word.

        ## Checking a draft

        To check citations in a draft: extract each cited work, find it with `search_library` (author + year + title
        words) and report anything not in the library, then offer `add_item_by_identifier` for missing papers whose DOI
        or arXiv ID the user can give.

        """
    }
}
