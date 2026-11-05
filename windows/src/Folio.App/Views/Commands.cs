using Folio.Core;
using Folio.Core.Citation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Folio.App;

/// <summary>Actions shared by menus, toolbar buttons and keyboard shortcuts (the macOS AppModel+Actions).</summary>
static class Commands
{
    static nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(App.Current!.Window!);

    /// <summary>The + of the toolbar and of the sidebar's 文献库 section.</summary>
    public static MenuFlyout AddMenu(AppModel model)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(UI.Item(Loc.S("添加文件…"), () => AddFiles(model).Fire(), "add"));
        menu.Items.Add(UI.Item(Loc.S("通过标识符添加…"), () => IdentifierSheet.Show(model).Fire(), "link"));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(UI.Item(Loc.S("新建分组"), () => App.Current?.Window?.NewGroup().Fire(), "folder"));
        menu.Items.Add(UI.Item(Loc.S("新建标签…"), () => TagEditor.Create(model).Fire(), "tag"));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(UI.Item(Loc.S("导入 BibTeX / RIS…"), () => ImportReferences(model).Fire(), "download"));
        menu.Items.Add(UI.Item(Loc.S("从 Zotero 导入…"), () => ZoteroImportSheet.Show(model).Fire(), "library"));
        return menu;
    }

    public static async Task AddFiles(AppModel model)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".pdf");
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count > 0) await model.Importer.ImportFiles(files.Select(f => f.Path), model.Scope.GroupId);
    }

    public static async Task AttachFiles(AppModel model, string itemId)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count > 0) await model.Importer.AttachFiles(files.Select(f => f.Path), itemId);
    }

    public static async Task ImportReferences(AppModel model)
    {
        var picker = new FileOpenPicker();
        foreach (var ext in new[] { ".bib", ".ris", ".json", ".txt" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var file = await picker.PickSingleFileAsync();
        if (file == null) return;
        var text = await File.ReadAllTextAsync(file.Path);
        var records = ReferenceFormats.Parse(text);
        if (records.Count == 0)
        {
            model.Toasts.Show(Loc.S("没有在文件中找到文献"), "question");
            return;
        }
        model.Perform(() =>
        {
            var result = model.Library.ImportReferences(records.Select(r => (r.Metadata, r.CitationKey)), model.Scope.GroupId);
            foreach (var (record, index) in records.Select((r, i) => (r, i)))
                foreach (var keyword in record.Keywords.Take(20))
                    if (index < result.Created.Count) model.Library.SetTag(model.Library.EnsureTag(keyword), [result.Created[index]], true);
            model.Toasts.Show(result.Duplicates.Count > 0
                ? Loc.S("已导入 %lld 篇文献，%lld 篇已在文献库中", result.Created.Count, result.Duplicates.Count)
                : Loc.S("已导入 %lld 篇文献", result.Created.Count), "download");
        });
    }

    public static async Task Export(AppModel model, IReadOnlyList<string> ids, ReferenceFormat format)
    {
        var entries = model.Entries(ids);
        if (entries.Count == 0) return;
        var picker = new FileSavePicker { SuggestedFileName = entries.Count == 1 ? entries[0].CitationKey : "Folio" };
        picker.FileTypeChoices.Add(format.DisplayName(), [$".{format.FileExtension()}"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var file = await picker.PickSaveFileAsync();
        if (file == null) return;
        await File.WriteAllTextAsync(file.Path, format.Render(entries));
        model.Toasts.Show(Loc.S("已导出 %lld 篇文献", entries.Count), "export", Loc.S("在资源管理器中显示"), () => Shell.Reveal(file.Path));
    }

    public static void CopyCitation(AppModel model, IReadOnlyList<string> ids, CitationStyle style)
    {
        try
        {
            var output = model.Cite(ids, style);
            if (output.PlainText.Length == 0)
            {
                model.Toasts.Show(Loc.S("所选文献没有可引用的元数据"), "question");
                return;
            }
            Shell.CopyText(output.PlainText, output.Html);
            model.Toasts.Show(Loc.S("已复制 %@ 引用", style.DisplayName()), "copy");
        }
        catch (Exception e) { model.Toasts.Show(e.Message, "warning"); }
    }

    public static void CopyInText(AppModel model, IReadOnlyList<string> ids, CitationStyle style)
    {
        try
        {
            var (_, combined) = model.InText(ids, style);
            Shell.CopyText(combined);
            model.Toasts.Show(Loc.S("已复制文内引用"), "copy");
        }
        catch (Exception e) { model.Toasts.Show(e.Message, "warning"); }
    }

    public static void FillCiteMenu(IList<MenuFlyoutItemBase> items, AppModel model, IReadOnlyList<string> ids)
    {
        items.Clear();
        bool any = model.Entries(ids).Count > 0;
        var copy = new MenuFlyoutSubItem { Text = Loc.S("复制引用"), Icon = UI.Icon("copy", 14), IsEnabled = any };
        foreach (var style in CitationStyles.All)
            copy.Items.Add(UI.Item(style.DisplayName(), () => { model.Settings.CitationStyle = style.Raw(); CopyCitation(model, ids, style); }));
        items.Add(UI.Item(Loc.S("复制 %@ 引用", model.DefaultStyle.DisplayName()), () => CopyCitation(model, ids, model.DefaultStyle), "copy", any));
        items.Add(copy);
        items.Add(UI.Item(Loc.S("复制文内引用"), () => CopyInText(model, ids, model.DefaultStyle), "cite", any));
        items.Add(new MenuFlyoutSeparator());
        foreach (var format in Enum.GetValues<ReferenceFormat>())
            items.Add(UI.Item(Loc.S("导出 %@…", format.DisplayName()), () => Export(model, ids, format).Fire(), "export", any));
    }

    /// <summary>The list's context menu (the macOS ItemMenuBuilder).</summary>
    public static void FillItemMenu(IList<MenuFlyoutItemBase> items, AppModel model, IReadOnlyList<string> ids)
    {
        var s = model.Snapshot;
        var selected = ids.Select(id => s.Items.GetValueOrDefault(id)).OfType<Item>().ToList();
        if (selected.Count == 0) return;
        if (model.Scope is ViewScope.TrashScope)
        {
            items.Add(UI.Item(Loc.S("恢复"), () => model.RestoreItems(ids.ToList()), "restore"));
            items.Add(UI.Item(Loc.S("彻底删除"), () => PurgeItems(model, ids).Fire(), "delete"));
            return;
        }
        var single = selected.Count == 1 ? selected[0] : null;
        bool allRegular = selected.All(i => i.Kind == ItemKind.Regular);
        items.Add(UI.Item(Loc.S("打开"), () => { foreach (var id in ids.Take(10)) model.OpenItem(id); }, "open"));
        if (single != null && DefaultFile(model, single) is { } openFile) items.Add(OpenWithMenu(model, openFile));
        items.Add(new MenuFlyoutSeparator());
        items.Add(GroupMenu(model, selected));
        items.Add(TagMenu(model, ids));
        if (allRegular)
        {
            var status = new MenuFlyoutSubItem { Text = Loc.S("阅读状态"), Icon = UI.Icon("reader", 14) };
            foreach (var st in Enum.GetValues<ReadStatus>())
                status.Items.Add(Check(st.DisplayName(), selected.All(i => i.ReadStatus == st), () => model.Perform(() => model.Library.UpdateItems(ids, i => i.ReadStatus = st))));
            items.Add(status);
            var rating = new MenuFlyoutSubItem { Text = Loc.S("评分"), Icon = UI.Icon("star", 14) };
            for (int value = 0; value <= 5; value++)
            {
                int stars = value;
                rating.Items.Add(Check(stars == 0 ? Loc.S("无评分") : new string('★', stars), selected.All(i => i.Rating == stars), () => model.Perform(() => model.Library.UpdateItems(ids, i => i.Rating = stars))));
            }
            items.Add(rating);
            var cite = new MenuFlyoutSubItem { Text = Loc.S("复制引用"), Icon = UI.Icon("cite", 14) };
            foreach (var style in CitationStyles.All)
                cite.Items.Add(UI.Item(style.DisplayName(), () => { model.Settings.CitationStyle = style.Raw(); CopyCitation(model, ids, style); }));
            items.Add(cite);
            var export = new MenuFlyoutSubItem { Text = Loc.S("引用与导出"), Icon = UI.Icon("share", 14) };
            FillCiteMenu(export.Items, model, ids);
            items.Add(export);
        }
        items.Add(new MenuFlyoutSeparator());
        if (single != null)
        {
            items.Add(UI.Item(Loc.S("编辑笔记"), () => App.Current?.Window?.ShowNotes(), "note"));
            if (s.NotedItems.Contains(single.Id)) items.Add(UI.Item(Loc.S("导出笔记…"), () => ExportNote(model, single).Fire(), "export"));
            if (DefaultFile(model, single) is { IsPdf: true }) items.Add(TranslateItem(model, single.Id, () => Translate(model, [single.Id])));
            items.Add(new MenuFlyoutSeparator());
            if (single.Kind == ItemKind.Regular)
            {
                items.Add(UI.Item(Loc.S("添加文件…"), () => AttachFiles(model, single.Id).Fire(), "attach"));
                items.Add(UI.Item(Loc.S("重新检索元数据"), () => model.Retrieve(ids), "refresh"));
            }
            else
            {
                items.Add(UI.Item(Loc.S("重新检索元数据"), () => model.Retrieve(ids), "refresh", single.MetadataState != MetadataState.Pending && s.FilesOf(single.Id).FirstOrDefault()?.IsPdf == true));
                items.Add(UI.Item(Loc.S("手动匹配…"), () => ManualMatchSheet.Show(model, single.Id).Fire(), "search"));
            }
        }
        else if (ids.Any(id => DefaultFile(model, s.Items[id]) is { IsPdf: true })) items.Add(UI.Item(Loc.S("翻译全文…"), () => Translate(model, ids), "translate"));
        if (selected.Select(i => DefaultFile(model, i)).FirstOrDefault(f => f != null) is { } first)
            items.Add(UI.Item(Loc.S("在资源管理器中显示"), () => Shell.Reveal(model.Library.FilePath(first)), "folder"));
        items.Add(new MenuFlyoutSeparator());
        if (model.Scope is ViewScope.GroupScope g)
            items.Add(UI.Item(Loc.S("从当前分组移除"), () => model.Perform(() => model.Library.RemoveItems(ids, g.Id, model.Settings.IncludeSubgroupItems)), "close"));
        items.Add(UI.Item(Loc.S("删除"), () => model.TrashItems(ids.ToList()), "delete"));
    }

    static MenuFlyoutItem TranslateItem(AppModel model, string itemId, Action translate) => model.Translations.JobOf(itemId) != null
        ? UI.Item(Loc.S("取消翻译"), () => model.Translations.Cancel(itemId), "close")
        : UI.Item(Loc.S("翻译全文…"), translate, "translate");

    static FileRecord? DefaultFile(AppModel model, Item item)
    {
        var files = model.Snapshot.FilesOf(item.Id);
        return files.FirstOrDefault(f => f.Id == item.DefaultFileId) ?? files.FirstOrDefault();
    }

    /// <summary>A menu row with a check mark when it applies to all that is selected.</summary>
    static ToggleMenuFlyoutItem Check(string text, bool on, Action action)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = on };
        item.Click += (_, _) => action();
        return item;
    }

    /// <summary>"打开方式 ▸": Folio's reader and the system's default app for PDFs, then any other program.</summary>
    static MenuFlyoutSubItem OpenWithMenu(AppModel model, FileRecord file)
    {
        var sub = new MenuFlyoutSubItem { Text = Loc.S("打开方式"), Icon = UI.Icon("open", 14) };
        var path = model.Library.FilePath(file);
        if (file.IsPdf) sub.Items.Add(UI.Item(Loc.S("在 Folio 中阅读"), () => App.Current?.Window?.OpenReader(file), "reader"));
        sub.Items.Add(UI.Item(Loc.S("系统默认应用"), () => Shell.Open(path)));
        sub.Items.Add(new MenuFlyoutSeparator());
        sub.Items.Add(UI.Item(Loc.S("其他应用…"), () => Shell.OpenWithDialog(path)));
        return sub;
    }

    public static async Task ExportNote(AppModel model, Item item)
    {
        var picker = new FileSavePicker { SuggestedFileName = Text.PrefixGraphemes(item.CitationKey ?? item.Title, 60) };
        picker.FileTypeChoices.Add("Markdown", [".md"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        var file = await picker.PickSaveFileAsync();
        if (file == null) return;
        await File.WriteAllTextAsync(file.Path, model.Library.Note(item.Id));
        model.Toasts.Show(Loc.S("笔记已导出"), "export", Loc.S("在资源管理器中显示"), () => Shell.Reveal(file.Path));
    }

    public static void FillFileMenu(IList<MenuFlyoutItemBase> items, AppModel model, FileRecord file)
    {
        var item = model.Snapshot.Items.GetValueOrDefault(file.ItemId);
        items.Add(UI.Item(Loc.S("打开"), () => model.OpenFile(file), "open"));
        items.Add(OpenWithMenu(model, file));
        items.Add(new MenuFlyoutSeparator());
        bool isDefault = item?.DefaultFileId == file.Id;
        items.Add(UI.Item(Loc.S("设为默认打开文件"), () => model.Perform(() => model.Library.SetDefaultFile(file.Id)), "star", !isDefault));
        items.Add(UI.Item(Loc.S("重命名…"), async () =>
        {
            var name = await Dialogs.Ask(Loc.S("重命名文件"), Loc.S("文件名"), Path.GetFileNameWithoutExtension(file.FileName), Loc.S("重命名"));
            if (!string.IsNullOrWhiteSpace(name)) model.Perform(() => model.Library.RenameFile(file.Id, name));
        }, "edit"));
        if (file.IsPdf && file.TranslationKind == null) items.Add(TranslateItem(model, file.ItemId, () => Translate(model, [file.ItemId], file)));
        items.Add(UI.Item(Loc.S("在资源管理器中显示"), () => Shell.Reveal(model.Library.FilePath(file)), "folder"));
        items.Add(new MenuFlyoutSeparator());
        items.Add(UI.Item(Loc.S("删除"), () => model.Perform(() => model.Library.TrashFiles([file.Id])), "delete"));
    }

    static MenuFlyoutSubItem GroupMenu(AppModel model, List<Item> items)
    {
        var sub = new MenuFlyoutSubItem { Text = Loc.S("添加到"), Icon = UI.Icon("folder", 14) };
        var ids = items.Select(i => i.Id).ToList();
        var groups = model.Snapshot.GroupsForMenus().Where(g => g.Group.Id != model.Scope.GroupId).ToList();
        foreach (var (group, depth) in groups)
        {
            bool all = model.Snapshot.GroupItems.GetValueOrDefault(group.Id) is { } members && ids.All(members.Contains);
            var entry = Check(new string(' ', depth * 4) + group.Name, all, () => model.Perform(() =>
            {
                var result = model.Library.AddItems(ids, group.Id, model.Settings.IncludeSubgroupItems);
                model.Toasts.Show(result.Added.Count > 0 ? Loc.S("已将 %lld 篇文献加入「%@」", result.Added.Count, group.Name) : Loc.S("所选文献已在「%@」中", group.Name), "folder");
            }));
            sub.Items.Add(entry);
        }
        if (groups.Count == 0) sub.Items.Add(UI.Item(Loc.S("没有其他分组"), () => { }, null, false));
        sub.Items.Add(new MenuFlyoutSeparator());
        sub.Items.Add(UI.Item(Loc.S("新建分组…"), async () =>
        {
            if (await GroupEditor.Create(model, null) is { } group) model.Perform(() => model.Library.AddItems(ids, group.Id, false));
        }, "add"));
        return sub;
    }

    static MenuFlyoutSubItem TagMenu(AppModel model, IReadOnlyList<string> ids)
    {
        var sub = new MenuFlyoutSubItem { Text = Loc.S("标签"), Icon = UI.Icon("tag", 14) };
        var s = model.Snapshot;
        foreach (var tag in s.Tags)
        {
            bool all = ids.All(id => s.ItemTags.GetValueOrDefault(id)?.Contains(tag.Id) == true);
            var toggle = new ToggleMenuFlyoutItem { Text = tag.Name, IsChecked = all, Icon = new FontIcon { Glyph = "", FontFamily = UI.IconFont, Foreground = UI.Hex(tag.ColorHex) } };
            toggle.Click += (_, _) => model.Perform(() => model.Library.SetTag(tag.Id, ids, !all));
            sub.Items.Add(toggle);
        }
        if (sub.Items.Count > 0) sub.Items.Add(new MenuFlyoutSeparator());
        sub.Items.Add(UI.Item(Loc.S("新建标签…"), () => TagEditor.Create(model, ids).Fire(), "add"));
        return sub;
    }

    public static async Task PurgeItems(AppModel model, IReadOnlyList<string> ids)
    {
        if (await Dialogs.Confirm(ids.Count == 1 ? Loc.S("彻底删除这一项？") : Loc.S("彻底删除 %lld 项？", ids.Count), Loc.S("文献和文件将被永久删除，无法恢复。"), Loc.S("彻底删除"), Loc.S("取消"), destructive: true))
            model.Perform(() => model.Library.PurgeItems(ids.ToList()));
    }

    public static void Translate(AppModel model, IReadOnlyList<string> ids, FileRecord? file = null)
    {
        var files = file != null ? [file] : ids.Select(id => model.Snapshot.FilesOf(id).FirstOrDefault(f => f.IsPdf && f.TranslationKind == null)).OfType<FileRecord>().ToList();
        if (files.Count == 0)
        {
            model.Toasts.Show(Loc.S("所选文献没有可翻译的 PDF"), "question");
            return;
        }
        App.Current?.Window?.ShowTranslationSheet(files);
    }
}
