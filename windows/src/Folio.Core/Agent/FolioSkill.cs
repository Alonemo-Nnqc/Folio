using Folio.Core.Citation;

namespace Folio.Core.Agent;

// Port of macos/.../FolioAgent/FolioSkill.swift (worded for Windows: PowerShell quoting, folio-cli.exe).

/// <summary>The Folio skill: a folder in the open Agent Skills format — a short SKILL.md the agent loads when the user
/// talks about their papers, and references/ it reads when needed.</summary>
public static class FolioSkill
{
    public const string Name = "folio-library";
    /// <summary>Marker written into installed skills so Folio recognises (and updates) its own copy.</summary>
    public const string Marker = "<!-- folio-skill -->";

    static readonly string[] PreapprovedTools = ["search_library", "list_items", "list_collections", "get_item", "read_fulltext", "get_annotations", "get_note", "format_citations"];

    public static List<(string Path, string Contents)> Files(string cliPath) =>
    [
        ("SKILL.md", Markdown(cliPath)),
        ("references/tools.md", ToolReference()),
        ("references/cli.md", CliReference(cliPath)),
        ("references/writing.md", WritingGuide()),
    ];

    /// <summary>Writes the skill folder, replacing an earlier copy completely.</summary>
    public static void Write(string folder, string cliPath)
    {
        var staging = Path.Combine(Path.GetDirectoryName(folder)!, $".{Name}-{Guid.NewGuid()}");
        Directory.CreateDirectory(Path.Combine(staging, "references"));
        try
        {
            foreach (var (path, contents) in Files(cliPath)) File.WriteAllText(Path.Combine(staging, path), contents);
            if (Directory.Exists(folder)) Directory.Delete(folder, true);
            Directory.Move(staging, folder);
        }
        catch
        {
            try { Directory.Delete(staging, true); } catch { }
            throw;
        }
    }

    public static bool IsCurrent(string folder, string cliPath) =>
        Files(cliPath).All(f => File.Exists(Path.Combine(folder, f.Path)) && File.ReadAllText(Path.Combine(folder, f.Path)) == f.Contents);

    static string Quoted(string cliPath) => cliPath.Contains(' ') ? $"& \"{cliPath}\"" : cliPath;

    public static string Markdown(string cliPath)
    {
        var cli = Quoted(cliPath);
        return $$"""
        ---
        name: {{Name}}
        description: Work with the user's Folio reference library (a Zotero-like app on this computer) — find the paper the user means, read and summarise it, cite it (APA, GB/T 7714, IEEE, MLA, Chicago, Harvard, Vancouver, Nature, BibTeX) or export .bib / RIS / CSL JSON, add or organise papers by DOI, arXiv ID or PDF, and translate papers with Folio. Use whenever the user mentions their papers, literature, references, citations, bibliography, reading list or Folio, asks about "that paper about …", or writes something that needs references — also for 论文、文献、参考文献、引用、文献库、读过的文章.
        allowed-tools: {{string.Join(" ", PreapprovedTools.Select(t => "mcp__folio__" + t))}}
        ---
        {{Marker}}

        # Folio library

        Folio is the user's reference manager. Their papers, PDFs, highlights and notes live in it.
        **Never invent papers or citation details**: everything you state about the user's library comes from Folio.

        ## Reaching Folio

        1. **MCP tools** (preferred): tools such as `search_library`, `get_item`, `format_citations` from the server
           named `folio`.
        2. **Command line**, when those tools are not available: `{{cli}} call <tool> '<JSON arguments>'` — the same
           tools and arguments, JSON output. Details (quoting in PowerShell): [references/cli.md](references/cli.md).
        3. If neither works, run `{{cli}} status` and tell the user what it says. Folio ▸ 设置 ▸ AI adds the MCP server
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

        ## Translation

        Folio translates whole PDFs itself, keeping the layout (item ▸ 翻译…); nothing needs installing. It can
        translate with free services, API keys the user configured, or a coding agent on this computer such as Claude
        Code or Codex (设置 ▸ 翻译). Translations are filed under the item as "<file>（简体中文译文 · …）.pdf".

        ## Ask first

        - `delete_tag`, `delete_group` and `move_to_trash` need the user's confirmation: say exactly what will happen
          (which items, how many use the tag) and wait for a yes. Trashed items are restorable for 30 days
          (`restore_from_trash`); there is no permanent delete.
        - If a tool says changes by AI are turned off, explain that the user can allow them in Folio ▸ 设置 ▸ AI ▸
          允许 AI 修改文献库.

        ## Style

        - Answer in the user's language. Refer to papers by title (and first author, year), never by id.
        - After changing the library, summarise what changed in one or two lines; Folio updates on screen by itself.

        """.Replace("\r\n", "\n");
    }

    /// <summary>Every tool with its parameters, generated from ToolCatalog so it always matches the server.</summary>
    public static string ToolReference()
    {
        var lines = new List<string>
        {
            "# Folio tools", "",
            "The same tools are available as MCP tools (server `folio`) and through `folio-cli call <tool> '<JSON>'`.",
            "Item references can be an item id from a result, a DOI or a citation key. Tools marked **changes the library**",
            "are missing when the user turned off changes by AI; **ask first** tools need the user's confirmation.", "",
        };
        foreach (var tool in ToolCatalog.All)
        {
            var flags = new List<string>();
            if (tool.Writes) flags.Add("changes the library");
            if (tool.Destructive) flags.Add("ask first");
            lines.Add($"## `{tool.Name}`" + (flags.Count == 0 ? "" : " — " + string.Join(", ", flags.Select(f => $"**{f}**"))));
            lines.Add("");
            lines.Add(tool.Description.Replace("\n", " "));
            lines.Add("");
            var required = tool.InputSchema["required"].StringList().ToHashSet();
            if (tool.InputSchema["properties"] is System.Text.Json.Nodes.JsonObject { Count: > 0 } properties)
            {
                foreach (var key in properties.Select(p => p.Key).OrderBy(k => required.Contains(k) ? 0 : 1).ThenBy(k => k, StringComparer.Ordinal))
                {
                    var property = properties[key]!;
                    var type = property["type"].Str() ?? "value";
                    if (type == "array") type = "list of strings";
                    var options = property["enum"].StringList();
                    var detail = (property["description"].Str() ?? "") + (options.Count == 0 ? "" : " One of: " + string.Join(", ", options.Select(o => $"`{o}`")) + ".");
                    lines.Add($"- `{key}` ({type}{(required.Contains(key) ? ", required" : "")}): {detail}");
                }
            }
            else lines.Add("No parameters.");
            lines.Add("");
        }
        return string.Join("\n", lines);
    }

    public static string CliReference(string cliPath)
    {
        var cli = Quoted(cliPath);
        var styles = string.Join("|", CitationStyles.All.Select(s => s.Raw()));
        return $$"""
        # folio-cli

        `{{cli}}` is Folio's command-line interface, for agents without the MCP tools. Output is JSON (citations and
        exports print their text). Exit status 0 means success; errors go to stderr.

        ```powershell
        {{cli}} status                                   # library location, item count, whether changes are allowed
        {{cli}} tools                                    # every tool with its description (--json for the schemas)
        '{"query": "mamba retinal vessel", "year_from": 2024}' | {{cli}} call search_library -
        '{"item": "<id, DOI or citation key>"}' | {{cli}} call get_item -
        '{"item": "<id>", "query": "loss function"}' | {{cli}} call read_fulltext -
        '{"items": ["<id>", "<id>"], "style": "ieee", "mode": "both"}' | {{cli}} call format_citations -
        '{"items": ["<id>"], "format": "bibtex", "path": "~/thesis/references.bib"}' | {{cli}} call export_references -
        ```

        `-` reads the JSON arguments from standard input, which avoids PowerShell and cmd.exe stripping the double quotes
        of a JSON argument. In bash (Git Bash, WSL) the arguments can also follow the tool name in single quotes.

        Shortcuts:

        ```powershell
        {{cli}} search <words…> [--fulltext] [--limit N]
        {{cli}} get <id | DOI | citation key>
        {{cli}} cite <items…> [--style {{styles}}] [--in-text]
        {{cli}} export [--format bibtex|ris|csljson] [--collection <group:name | tag:name>] [-o <file>]
        {{cli}} add <DOI | arXiv ID | ISBN | PDF path> [--group <group>]
        {{cli}} open <item> [--page N]
        ```

        Options: `--library <folder>` uses another library; `--read-only` refuses changes.

        Notes:

        - Sandboxed agents may block folio-cli from reading the library folder or from the network (needed for adding
          papers by DOI). If a command fails with a permission or network error, ask the user to allow it to run outside
          the sandbox, or to enable Folio's MCP server for this agent in Folio ▸ 设置 ▸ AI.
        - "No Folio library at …": Folio has not created its library yet, or the user keeps it elsewhere; ask them to
          open Folio once, or pass `--library`.

        """.Replace("\r\n", "\n");
    }

    public static string WritingGuide() => """
        # Citing while writing

        Always take references from Folio — never type a citation from memory. Find each paper first
        (`search_library`, confirm with `get_item`), then:

        ## LaTeX (BibTeX / biblatex)

        1. Export the cited items: `export_references` with `format: "bibtex"` and `path` next to the document
           (e.g. `references.bib`). The result lists the `citation_keys`.
        2. **If the project already has a .bib file**, do not overwrite it: export to a separate file such as
           `folio.bib` and add it (`\bibliography{references,folio}` or `\addbibresource{folio.bib}`), or ask the user.
        3. Cite with the keys exactly as exported: `\cite{key}`, `\citep{key}` / `\citet{key}` (natbib), `\parencite{key}`
           (biblatex). `format_citations` with `style: "bibtex"`, `mode: "in_text"` gives `\cite{…}` commands.
        4. Chinese theses usually require GB/T 7714: use the `gbt7714-numeric` biblatex style or the template's own.

        ## Typst

        Export BibTeX as above, add `#bibliography("folio.bib", style: "ieee")` (or `"apa"`, `"gb-7714-2015-numeric"`)
        and cite with `@key`.

        ## Markdown, Pandoc, Quarto, R Markdown

        Export CSL JSON (`format: "csljson"`, e.g. `references.json`), set `bibliography: references.json` in the
        front matter, cite with `[@key]` / `@key`, and render with `--citeproc` (add a `csl:` file for a specific style).

        ## Word, Google Docs, plain text, emails

        Call `format_citations` with all cited items **in the order they are first cited**, the style the user wants and
        `mode: "both"`. Paste the in-text citations where they belong and the reference list at the end, exactly as
        returned. Numeric styles (IEEE, Vancouver, Nature, GB/T 7714) number the items in the order you passed them.
        Tell the user that Folio's "引用与导出" menu copies the same text with formatting (italics) for Word.

        ## Checking a draft

        To check citations in a draft: extract each cited work, find it with `search_library` (author + year + title
        words) and report anything not in the library, then offer `add_item_by_identifier` for missing papers whose DOI
        or arXiv ID the user can give.

        """.Replace("\r\n", "\n");
}
