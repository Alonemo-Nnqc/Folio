using System.Globalization;
using System.Text.Json;
using Folio.Core;
using Folio.Core.Citation;
using Folio.Core.Retrieval;

namespace Folio.App;

public static partial class Api
{
    // MARK: What the page mirrors

    static readonly Dictionary<string, string> SentItems = [], SentFiles = [];

    static object ItemDto(Item i, LibrarySnapshot s) => new
    {
        id = i.Id, kind = i.Kind == ItemKind.Standalone ? "standalone" : "regular", type = i.Type.Raw(), typeName = i.Type.DisplayName(), title = i.Title,
        authors = i.Authors.Select(a => new { family = a.Family, given = a.Given, full = AuthorFormatter.Full(a) }),
        authorsList = AuthorFormatter.ListDisplay(i.Authors),
        year = i.Year, source = i.Source, volume = i.Volume, issue = i.Issue, pages = i.Pages, publisher = i.Publisher, doi = i.Doi, arxivId = i.ArxivId, isbn = i.Isbn, url = i.Url,
        @abstract = i.Abstract, citationKey = i.CitationKey, rating = i.Rating, readStatus = (int)i.ReadStatus, readStatusName = i.ReadStatus.DisplayName(),
        defaultFileId = i.DefaultFileId, metadataState = i.MetadataState.ToString(), dateAdded = Ms(i.DateAdded), dateModified = Ms(i.DateModified), trashed = i.IsTrashed,
        retrieving = M.Importer.IsRetrieving(i.Id),
    };

    static object FileDto(FileRecord f, Item? item, IReadOnlyList<FileRecord> siblings) => new
    {
        id = f.Id, itemId = f.ItemId, fileName = f.FileName, path = f.RelativePath, isPdf = f.IsPdf, translationOf = f.TranslationOf, translationKind = f.TranslationKind?.ToString().ToLowerInvariant(), translatedBy = f.TranslatedBy,
        sha = f.Sha256, dateAdded = Ms(f.DateAdded),
        title = FileLabel.Title(f, siblings, item?.DefaultFileId),
        tabTitle = FileLabel.TabTitle(f, item, siblings),
        tabTip = FileLabel.TabToolTip(f, item, siblings),
    };

    /// <summary>The library for the page. After the first time only items and files that changed travel: thousands of papers stay cheap.</summary>
    static object LibraryState(bool full)
    {
        var s = M.Snapshot;
        if (full) { SentItems.Clear(); SentFiles.Clear(); }
        var items = new List<JsonElement>();
        var seen = new HashSet<string>();
        foreach (var (id, item) in s.Items)
        {
            seen.Add(id);
            var json = JsonSerializer.Serialize(ItemDto(item, s), Bridge.Json);
            if (SentItems.GetValueOrDefault(id) == json) continue;
            SentItems[id] = json;
            items.Add(JsonDocument.Parse(json).RootElement);
        }
        var removedItems = SentItems.Keys.Where(k => !seen.Contains(k)).ToList();
        foreach (var k in removedItems) SentItems.Remove(k);

        var files = new List<JsonElement>();
        seen.Clear();
        foreach (var (id, file) in s.Files)
        {
            seen.Add(id);
            var json = JsonSerializer.Serialize(FileDto(file, s.Items.GetValueOrDefault(file.ItemId), s.FilesOf(file.ItemId)), Bridge.Json);
            if (SentFiles.GetValueOrDefault(id) == json) continue;
            SentFiles[id] = json;
            files.Add(JsonDocument.Parse(json).RootElement);
        }
        var removedFiles = SentFiles.Keys.Where(k => !seen.Contains(k)).ToList();
        foreach (var k in removedFiles) SentFiles.Remove(k);

        return new
        {
            full, items, removedItems, files, removedFiles,
            root = M.Library.Root,
            filesByItem = s.FilesByItem,
            groups = s.GroupsById.Values.Select(g => new { id = g.Id, parentId = g.ParentId, name = g.Name, color = g.ColorHex }),
            topGroups = s.TopLevelGroups,
            childGroups = s.ChildGroups,
            tags = s.Tags.Select(t => new { id = t.Id, name = t.Name, color = t.ColorHex }),
            itemTags = s.ItemTags,
            itemGroups = s.ItemGroups.ToDictionary(p => p.Key, p => p.Value.ToList()),
            noted = s.NotedItems,
            counts = M.Counts,
        };
    }

    static object RowsState()
    {
        var sort = M.Snapshot.Sort(M.Scope);
        return new
        {
            rows = M.Rows, scope = M.Scope.Key, searchText = M.SearchText, searchWholeLibrary = M.SearchWholeLibrary, includeFulltext = M.IncludeFulltext,
            sortColumn = sort.Column?.Raw(), sortAscending = sort.Ascending,
        };
    }

    static ViewScope ParseScope(string key)
    {
        if (key == ViewScope.Unfiled.Key) return ViewScope.Unfiled;
        if (key == ViewScope.Trash.Key) return ViewScope.Trash;
        if (key == ViewScope.All.Key) return ViewScope.All;
        int colon = key.IndexOf(':');
        if (colon > 0)
        {
            var kind = key[..colon];
            var id = key[(colon + 1)..];
            if (kind == "group") return ViewScope.Group(id);
            if (kind == "tag") return ViewScope.TagOf(id);
        }
        return ViewScope.All;
    }

    static void ApplyPatch(Item i, JsonElement patch)
    {
        foreach (var p in patch.EnumerateObject())
        {
            string? text = p.Value.ValueKind == JsonValueKind.String ? Text.NonEmpty(p.Value.GetString()) : null;
            switch (p.Name)
            {
                case "title": if (text != null) i.Title = text; break;
                case "type": i.Type = ItemTypes.Parse(text); break;
                case "year": i.Year = int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var y) ? y : p.Value.ValueKind == JsonValueKind.Number ? p.Value.GetInt32() : null; break;
                case "source": i.Source = text; break;
                case "volume": i.Volume = text; break;
                case "issue": i.Issue = text; break;
                case "pages": i.Pages = text; break;
                case "publisher": i.Publisher = text; break;
                case "doi": i.Doi = text; break;
                case "arxivId": i.ArxivId = text; break;
                case "isbn": i.Isbn = text; break;
                case "url": i.Url = text; break;
                case "abstract": i.Abstract = text; break;
                case "citationKey": i.CitationKey = text; break;
                case "rating": i.Rating = p.Value.GetInt32(); break;
                case "readStatus": i.ReadStatus = (ReadStatus)p.Value.GetInt32(); break;
                case "authors": i.Authors = ParseAuthors(p.Value.GetString() ?? ""); break;
            }
        }
    }

    static List<Author> ParseAuthors(string text) => text.Split(';').Select(p => p.Trim()).Where(p => p.Length > 0).Select(p =>
    {
        int comma = p.IndexOf(',');
        if (comma >= 0) return new Author(p[..comma].Trim(), p[(comma + 1)..].Trim());
        var parts = p.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 1 ? new Author(parts[^1], string.Join(' ', parts[..^1])) : new Author(p);
    }).ToList();

    static void InstallLibrary()
    {
        // Views.
        Bridge.On("library.scope", a => { M.SelectScope(ParseScope(a.Str("scope"))); return null; });
        Bridge.On("library.search", a => { M.Search(a.Str("text")); return null; });
        Bridge.On("library.searchWhole", a => { M.SearchWholeLibrary = a.Bool("on"); M.ResolveRows(); return null; });
        Bridge.On("library.fulltext", a => { M.SetFulltextSearch(a.Bool("on")); return null; });
        Bridge.On("library.sort", a => { M.Sort(SortColumns.Parse(a.OptStr("column")), a.Bool("ascending", true)); return null; });
        Bridge.On("library.select", a => { M.SetSelection(a.Strs("ids")); return null; });
        Bridge.On("library.moveItems", a => { M.Perform(() => M.Library.MoveItems(a.Strs("ids"), M.Scope, M.Rows, a.Int("index"))); return null; });

        // Opening.
        Bridge.On("item.open", a => { M.OpenItem(a.Str("id"), a.OptInt("page")); return null; });
        Bridge.On("file.open", a => { if (M.Snapshot.Files.TryGetValue(a.Str("id"), out var f)) M.OpenFile(f, a.OptInt("page")); return null; });
        Bridge.On("file.reveal", a => { if (M.Snapshot.Files.TryGetValue(a.Str("id"), out var f)) Shell.Reveal(M.Library.FilePath(f)); return null; });
        Bridge.On("file.openSystem", a => { if (M.Snapshot.Files.TryGetValue(a.Str("id"), out var f)) Shell.OpenPath(M.Library.FilePath(f)); return null; });
        Bridge.On("file.openWithDialog", a => { if (M.Snapshot.Files.TryGetValue(a.Str("id"), out var f)) Shell.OpenWithDialog(M.Library.FilePath(f)); return null; });
        Bridge.On("library.revealRoot", _ => { Shell.OpenPath(M.Library.Root); return null; });

        // Items.
        Bridge.On("item.update", a =>
        {
            var id = a.Str("id");
            var patch = a.Raw("patch").Clone();
            M.Perform(() =>
            {
                M.Library.UpdateItem(id, i => ApplyPatch(i, patch));
                if (M.Settings.AutoRenameFiles) M.Library.RenameFiles(id);
            });
            return null;
        });
        Bridge.On("items.update", a =>
        {
            var patch = a.Raw("patch").Clone();
            var ids = a.Strs("ids");
            M.Perform(() => M.Library.UpdateItems(ids, i => ApplyPatch(i, patch)));
            return null;
        });
        Bridge.On("items.trash", a => { M.TrashItems(a.Strs("ids")); return null; });
        Bridge.On("items.restore", a => { M.RestoreItems(a.Strs("ids")); return null; });
        Bridge.On("items.purge", a => { var ids = a.Strs("ids"); M.Perform(() => M.Library.PurgeItems(ids)); return null; });
        Bridge.On("trash.empty", _ => { M.Perform(M.Library.EmptyTrash); return null; });
        Bridge.On("items.retrieve", a => { M.Retrieve(a.Strs("ids")); return null; });
        Bridge.On("items.addToGroup", a =>
        {
            var ids = a.Strs("ids");
            var group = a.Str("group");
            M.Perform(() =>
            {
                var result = M.Library.AddItems(ids, group, a.Bool("includeSubgroups", M.Settings.IncludeSubgroupItems));
                var name = M.Snapshot.GroupsById.GetValueOrDefault(group)?.Name ?? "";
                if (a.Bool("quiet")) return;
                M.Toasts.Show(result.Added.Count > 0 ? Loc.S("已将 %lld 篇文献加入「%@」", result.Added.Count, name) : Loc.S("所选文献已在「%@」中", name), "folder");
            });
            return null;
        });
        Bridge.On("items.removeFromGroup", a => { var ids = a.Strs("ids"); M.Perform(() => M.Library.RemoveItems(ids, a.Str("group"), a.Bool("includeSubgroups", M.Settings.IncludeSubgroupItems))); return null; });
        Bridge.On("items.setTag", a => { var ids = a.Strs("ids"); M.Perform(() => M.Library.SetTag(a.Str("tag"), ids, a.Bool("on"))); return null; });

        // Files.
        Bridge.On("file.setDefault", a => { M.Perform(() => M.Library.SetDefaultFile(a.Str("id"))); return null; });
        Bridge.On("file.rename", a => { M.Perform(() => M.Library.RenameFile(a.Str("id"), a.Str("name"))); return null; });
        Bridge.On("files.trash", a => { var ids = a.Strs("ids"); M.Perform(() => M.Library.TrashFiles(ids)); return null; });
        Bridge.OnAsync("files.attachPick", async a =>
        {
            var paths = Pickers.OpenFiles();
            if (paths.Count > 0) await M.Importer.AttachFiles(paths, a.Str("item"));
        });
        Bridge.OnAsync("files.importPick", async _ =>
        {
            var paths = Pickers.OpenFiles("PDF|*.pdf|*|*.*");
            if (paths.Count > 0) await M.Importer.ImportFiles(paths, M.Scope.GroupId);
        });
        Bridge.OnAsync("files.import", a => M.Importer.ImportFiles(a.Strs("paths"), a.OptStr("group") ?? M.Scope.GroupId));
        Bridge.OnAsync("files.importTo", a => M.Importer.ImportFiles(a.Strs("paths"), a.OptStr("group")));
        Bridge.On("files.dragPaths", a => a.Strs("items").SelectMany(id => M.Snapshot.FilesOf(id)).Select(f => M.Library.FilePath(f)).Where(File.Exists).ToList());

        // Groups and tags.
        Bridge.On("group.create", a =>
        {
            LibraryGroup? group = null;
            M.Perform(() =>
            {
                group = M.Library.CreateGroup(a.Str("name").Trim(), a.OptStr("parent"));
                if (a.OptStr("color") is { } color) M.Library.SetGroupColor(group.Id, color);
                if (a.Strs("items") is { Count: > 0 } items) M.Library.AddItems(items, group.Id, false);
            });
            return group?.Id;
        });
        Bridge.On("group.rename", a => { M.Perform(() => M.Library.RenameGroup(a.Str("id"), a.Str("name"))); return null; });
        Bridge.On("group.color", a => { M.Perform(() => M.Library.SetGroupColor(a.Str("id"), a.OptStr("color"))); return null; });
        Bridge.On("group.delete", a => { M.Perform(() => M.Library.DeleteGroup(a.Str("id"), a.Bool("trashItems"))); return null; });
        Bridge.On("group.move", a => { M.Perform(() => M.Library.MoveGroup(a.Str("id"), a.OptStr("parent"), a.Int("index"))); return null; });
        Bridge.On("tag.create", a =>
        {
            M.Perform(() =>
            {
                var created = M.Library.CreateTag(a.Str("name"), a.Str("color"));
                if (a.Strs("items") is { Count: > 0 } items) M.Library.SetTag(created.Id, items, true);
            });
            return null;
        });
        Bridge.On("tag.update", a => { M.Perform(() => M.Library.UpdateTag(a.Str("id"), a.Str("name"), a.Str("color"))); return null; });
        Bridge.On("tag.delete", a => { M.Perform(() => M.Library.DeleteTag(a.Str("id"))); return null; });
        Bridge.On("tag.move", a => { M.Perform(() => M.Library.MoveTag(a.Str("id"), a.Int("index"))); return null; });
        Bridge.On("tag.itemCount", a => M.Library.ItemCount(a.Str("id")));

        // Notes and annotations.
        Bridge.On("note.get", a => M.Library.Note(a.Str("item")));
        Bridge.On("note.set", a => { M.Perform(() => M.Library.SetNote(a.Str("text"), a.Str("item"))); return null; });
        Bridge.OnAsync("note.export", async a =>
        {
            if (!M.Snapshot.Items.TryGetValue(a.Str("item"), out var item)) return;
            if (Pickers.SaveFile(Text.PrefixGraphemes(item.CitationKey ?? item.Title, 60), "Markdown|*.md") is not { } path) return;
            await File.WriteAllTextAsync(path, M.Library.Note(item.Id));
            M.Toasts.Show(Loc.S("笔记已导出"), "export", Loc.S("在资源管理器中显示"), () => Shell.Reveal(path));
        });
        Bridge.OnAsync("annotations.read", async a =>
        {
            var pdfs = M.Snapshot.FilesOf(a.Str("item")).Where(f => f.IsPdf).ToList();
            var paths = pdfs.Select(f => M.Library.FilePath(f)).ToList();
            var results = await Task.Run(() => paths.Select(PdfAnnotations.Read).ToList());
            return (object?)pdfs.Select((f, i) => new { fileId = f.Id, annotations = results[i].Select(x => new { page = x.Page, kind = x.Kind, color = x.ColorHex, text = x.Text, comment = x.Comment, author = x.Author }) }).ToList();
        });

        // Citations and references.
        Bridge.On("cite.copy", a =>
        {
            var ids = a.Strs("ids");
            var style = CitationStyles.Named(a.OptStr("style") ?? "") ?? M.DefaultStyle;
            if (a.OptStr("style") != null) M.Settings.CitationStyle = style.Raw();
            try
            {
                var output = M.Cite(ids, style);
                if (output.PlainText.Length == 0) { M.Toasts.Show(Loc.S("所选文献没有可引用的元数据"), "question"); return null; }
                Shell.CopyText(output.PlainText, output.Html);
                M.Toasts.Show(Loc.S("已复制 %@ 引用", style.DisplayName()), "copy");
            }
            catch (Exception e) { M.Toasts.Show(e.Message, "warning"); }
            return null;
        });
        Bridge.On("cite.inText", a =>
        {
            try
            {
                var (_, combined) = M.InText(a.Strs("ids"), M.DefaultStyle);
                Shell.CopyText(combined);
                M.Toasts.Show(Loc.S("已复制文内引用"), "copy");
            }
            catch (Exception e) { M.Toasts.Show(e.Message, "warning"); }
            return null;
        });
        Bridge.On("cite.hasEntries", a => M.Entries(a.Strs("ids")).Count > 0);
        Bridge.OnAsync("references.export", async a =>
        {
            var entries = M.Entries(a.Strs("ids"));
            if (entries.Count == 0) return;
            var format = Enum.TryParse<ReferenceFormat>(a.Str("format"), true, out var f) ? f : ReferenceFormat.Bibtex;
            if (Pickers.SaveFile(entries.Count == 1 ? entries[0].CitationKey : "Folio", $"{format.DisplayName()}|*.{format.FileExtension()}") is not { } path) return;
            await File.WriteAllTextAsync(path, format.Render(entries));
            M.Toasts.Show(Loc.S("已导出 %lld 篇文献", entries.Count), "export", Loc.S("在资源管理器中显示"), () => Shell.Reveal(path));
        });
        Bridge.OnAsync("references.import", async _ =>
        {
            if (Pickers.OpenFiles("BibTeX / RIS / CSL JSON|*.bib;*.ris;*.json;*.txt", false).FirstOrDefault() is not { } path) return;
            var records = ReferenceFormats.Parse(await File.ReadAllTextAsync(path));
            if (records.Count == 0) { M.Toasts.Show(Loc.S("没有在文件中找到文献"), "question"); return; }
            M.Perform(() =>
            {
                var result = M.Library.ImportReferences(records.Select(r => (r.Metadata, r.CitationKey)), M.Scope.GroupId);
                foreach (var (record, index) in records.Select((r, i) => (r, i)))
                    foreach (var keyword in record.Keywords.Take(20))
                        if (index < result.Created.Count) M.Library.SetTag(M.Library.EnsureTag(keyword), [result.Created[index]], true);
                M.Toasts.Show(result.Duplicates.Count > 0
                    ? Loc.S("已导入 %lld 篇文献，%lld 篇已在文献库中", result.Created.Count, result.Duplicates.Count)
                    : Loc.S("已导入 %lld 篇文献", result.Created.Count), "download");
            });
        });

        // Finding metadata.
        Bridge.OnAsync("identifiers.add", async a =>
        {
            var lines = a.Str("text").Split(['\r', '\n']).Select(l => l.Trim()).Where(l => l.Length > 0).Distinct().ToList();
            if (lines.Count == 0) return;
            M.Toasts.Show(Loc.S("正在检索…"), "search");
            int added = 0, existing = 0, failed = 0;
            string? last = null;
            foreach (var line in lines)
            {
                if (await M.Importer.Engine.Resolve(line) is ResolveResult.Found found)
                {
                    var outcome = M.Library.CreateItem(found.Metadata, M.Scope.GroupId);
                    if (outcome is CreateOutcome.Created) added++; else existing++;
                    if (outcome is CreateOutcome.Duplicate && M.Scope.GroupId is { } g) M.Library.AddItems([outcome.Id], g, false);
                    last = outcome.Id;
                }
                else failed++;
            }
            if (last != null) M.Reveal(last);
            if (failed > 0 && added + existing == 0) M.Toasts.Show(Loc.S("没有找到对应的文献"), "question");
            else if (existing > 0 && added == 0) M.Toasts.Show(Loc.S("已在文献库中"), "copy");
            else M.Toasts.Show(failed > 0 ? Loc.S("已添加 %lld 篇，%lld 个未找到", added, failed) : Loc.S("已添加 %lld 篇文献", added), "check");
        });
        var matches = new List<Metadata>();
        Bridge.OnAsync("match.search", async a =>
        {
            matches = await M.Importer.Engine.Search(a.Str("query"));
            return (object?)matches.Select((m, i) => new { index = i, title = m.Title, authors = AuthorFormatter.ListDisplay(m.Authors), year = m.Year, source = m.Source }).ToList();
        });
        Bridge.OnAsync("match.apply", async a =>
        {
            int i = a.Int("index");
            if (i >= 0 && i < matches.Count) await M.Importer.Apply(matches[i], a.Str("item"));
        });

        // Where the library lives.
        Bridge.OnAsync("library.relocate", async _ =>
        {
            if (Pickers.Folder() is not { } folder) return (object?)null;
            await M.RelocateLibrary(folder);
            App.Broadcast("settings", AllSettings());
            return M.Library.Root;
        });
        Bridge.On("library.pickOther", _ =>
        {
            if (Pickers.Folder() is not { } folder) return null;
            return new { folder, exists = File.Exists(Path.Combine(folder, Library.DatabaseFileName)) };
        });
        Bridge.On("library.switch", a =>
        {
            M.SwitchLibrary(a.Str("folder"));
            App.Broadcast("settings", AllSettings());
            return M.Library.Root;
        });
    }
}
