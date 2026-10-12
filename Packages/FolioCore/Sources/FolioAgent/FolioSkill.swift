import Foundation

/// The Folio skill (AI-03): a SKILL.md that teaches an agent to work with the user's Folio library,
/// through the MCP tools when they are connected and through folio-cli otherwise.
public enum FolioSkill {
    public static let name = "folio-library"

    /// Marker written into installed skills so Folio recognises (and updates) its own copy.
    public static let marker = "<!-- folio-skill -->"

    public static func markdown(cliPath: String) -> String {
        let cli = cliPath.contains(" ") ? "\"\(cliPath)\"" : cliPath
        return """
        ---
        name: \(name)
        description: Work with the user's Folio reference library on this Mac — find the paper the user means, read it, cite it in APA / GB/T 7714 / BibTeX, export or import BibTeX / RIS, add papers by DOI, arXiv ID or PDF, and organise them with groups, tags and notes. Use whenever the user mentions their papers, literature, references, citations, bibliography, reading list, Folio, or asks about "that paper about …".
        ---
        \(marker)

        # Folio library

        Folio is the user's reference manager (like Zotero). Their papers, PDFs, highlights and notes live in it.
        Never invent papers or citation details: everything you state about the user's library must come from
        Folio's tools.

        ## How to reach Folio

        1. **MCP tools** (preferred): if tools such as `search_library`, `get_item`, `format_citations` are
           available (server name `folio`), use them.
        2. **Command line** (when no Folio MCP tools are available): run
           `\(cli) call <tool> '<JSON arguments>'` — same tools, same arguments, JSON output. Examples:
           ```bash
           \(cli) call search_library '{"query": "mamba retinal vessel"}'
           \(cli) call get_item '{"item": "<id>"}'
           \(cli) call format_citations '{"items": ["<id>"], "style": "apa"}'
           ```
           `\(cli) tools` lists every tool with its description.

        ## Finding the paper the user means

        Users describe papers loosely ("the Mamba one for retinal vessels", "that 2021 night-time segmentation dataset").
        1. Call `search_library` with 2–4 distinctive keywords: topic words, an acronym, an author's family name, a year.
           Results are ranked; `matched` tells how many of your words matched.
        2. Nothing convincing? Try other wordings and synonyms, a single rare word, or `include_fulltext: true`
           to search inside the PDFs. Use `list_collections` / `list_items` when the user names a group or tag.
        3. Several plausible candidates? Show a short numbered list (title, first author, year) and ask which one.
           One clear match? Say which paper you picked in one line, then continue.
        4. Use `get_item` for the full record (abstract, files, the user's note) before answering detailed questions.

        ## Reading and answering questions about a paper

        - `read_fulltext` returns the PDF text with `[Page n]` markers. Read long papers in ranges
          (`start_page` / `end_page`; follow `next_start_page`). Cite page numbers in your answer.
        - `get_annotations` returns what the user highlighted and commented — useful for "what did I mark as important".
        - `get_note` reads the user's own note. To save a summary for them, use `set_note` with `mode: "append"`
          (never replace their note unless they ask).
        - `open_in_folio` opens the paper in Folio's reader, optionally at a page, when the user wants to look at it.

        ## Citing and exporting

        - `format_citations` with `style` `apa` (APA 7th), `gbt7714` (GB/T 7714-2015, the Chinese standard) or `bibtex`.
          Copy the returned text exactly — do not reformat, translate or "fix" it.
        - `export_references` writes BibTeX, RIS or CSL JSON for given items or a whole collection
          (`"group:<name>"`, `"tag:<name>"`); pass `path` (e.g. `~/Desktop/references.bib`) to save a file.
        - Items without metadata (standalone files) cannot be cited; offer to fix them with `update_item`
          or `add_item_by_identifier`.

        ## Adding and importing

        - By identifier: `add_item_by_identifier` with a DOI, arXiv ID or ISBN (preferred: exact metadata).
        - From a PDF on disk: `add_pdf` with its path; Folio copies it in and retrieves metadata online.
        - From BibTeX / RIS / CSL JSON: `import_references` with a file `path` or the `text`.
        - All of these report works already in the library instead of duplicating them. Put new papers into the group
          the user is working on (`group`) and apply tags when asked.

        ## Organising

        - Groups (two levels, `"Parent/Child"`): `set_groups` puts items in / takes them out (creates missing groups),
          `create_group`, `update_group` (rename, folder colour, move under another group or to the top level),
          `delete_group` (items stay unless `trash_items`; ask first).
        - Tags: `set_tags` adds / removes tags on items (creates missing ones), `create_tag`, `update_tag`
          (rename, colour), `delete_tag` (removes it from every item; say how many items use it and ask first).
        - Colours are names (red, orange, yellow, green, mint, cyan, blue, indigo, purple, pink, gray) or `#RRGGBB`.
        - To merge two tags: `set_tags` to add the kept tag to the other tag's items, then `delete_tag` the other.
        - Details, reading status (`unread` / `reading` / `read`) and rating (0–5): `update_item`.

        ## Deleting — ask first

        - Deleting a tag or a group never deletes papers (unless `delete_group` with `trash_items`), but it cannot be
          undone from the AI side — confirm with the user before `delete_tag` / `delete_group`.
        - `move_to_trash` moves items to Folio's trash (restorable with `restore_from_trash` for 30 days).
          Always list exactly what will be trashed and get the user's confirmation first.
        - There is no permanent delete; tell the user to empty the trash in Folio if they want that.
        - If a tool says changes by AI are turned off, explain that the user can allow them in
          Folio ▸ 设置 ▸ AI ▸ 允许 AI 修改文献库.

        ## Style

        - Answer in the user's language. Refer to papers by title (and first author, year), not by id.
        - After changing the library, summarise what changed in one or two lines. Folio updates on screen by itself.
        """
    }
}
