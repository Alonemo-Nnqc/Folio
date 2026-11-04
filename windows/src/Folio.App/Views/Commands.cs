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
            items.Add(UI.Item(Loc.S("导出 %@…", format.DisplayName()), () => _ = Export(model, ids, format), "export", any));
    }

    public static void FillItemMenu(IList<MenuFlyoutItemBase> items, AppModel model, IReadOnlyList<string> ids)
    {
        var s = model.Snapshot;
        var selected = ids.Select(id => s.Items.GetValueOrDefault(id)).OfType<Item>().ToList();
        if (selected.Count == 0) return;
        bool trash = model.Scope is ViewScope.TrashScope;
        if (trash)
        {
            items.Add(UI.Item(Loc.S("恢复"), () => model.RestoreItems(ids.ToList()), "restore"));
            items.Add(UI.Item(Loc.S("永久删除…"), () => _ = PurgeItems(model, ids), "delete"));
            return;
        }
        items.Add(UI.Item(Loc.S("打开"), () => { foreach (var id in ids.Take(10)) model.OpenItem(id); }, "reader"));
        if (selected.Count == 1 && s.FilesOf(selected[0].Id).FirstOrDefault() is { } first)
            items.Add(UI.Item(Loc.S("在资源管理器中显示"), () => Shell.Reveal(model.Library.FilePath(first)), "open"));
        items.Add(new MenuFlyoutSeparator());
        items.Add(UI.Item(Loc.S("重新检索元数据"), () => model.Retrieve(ids), "refresh"));
        if (selected.Count == 1 && selected[0].Kind == ItemKind.Standalone)
            items.Add(UI.Item(Loc.S("手动匹配元数据…"), () => _ = ManualMatchSheet.Show(model, selected[0].Id), "search"));
        if (selected.Count == 1 && selected[0].Kind == ItemKind.Regular)
            items.Add(UI.Item(Loc.S("添加附件…"), () => _ = AttachFiles(model, selected[0].Id), "attach"));
        items.Add(UI.Item(Loc.S("翻译…"), () => Translate(model, ids), "translate"));
        items.Add(new MenuFlyoutSeparator());
        var cite = new MenuFlyoutSubItem { Text = Loc.S("引用与导出"), Icon = UI.Icon("share", 14) };
        FillCiteMenu(cite.Items, model, ids);
        items.Add(cite);
        items.Add(GroupMenu(model, ids));
        items.Add(TagMenu(model, ids));
        if (selected.All(i => i.Kind == ItemKind.Regular))
        {
            var status = new MenuFlyoutSubItem { Text = Loc.S("阅读状态") };
            foreach (var st in Enum.GetValues<ReadStatus>())
                status.Items.Add(UI.Item(st.DisplayName(), () => model.Perform(() => model.Library.UpdateItems(ids, i => i.ReadStatus = st))));
            items.Add(status);
        }
        items.Add(new MenuFlyoutSeparator());
        if (model.Scope is ViewScope.GroupScope g)
            items.Add(UI.Item(Loc.S("从分组中移除"), () => model.Perform(() => model.Library.RemoveItems(ids, g.Id, model.Settings.IncludeSubgroupItems)), "close"));
        items.Add(UI.Item(Loc.S("移到回收站"), () => model.TrashItems(ids.ToList()), "delete"));
    }

    public static void FillFileMenu(IList<MenuFlyoutItemBase> items, AppModel model, FileRecord file)
    {
        items.Add(UI.Item(Loc.S("打开"), () => model.OpenFile(file), "reader"));
        items.Add(UI.Item(Loc.S("用系统默认应用打开"), () => Shell.Open(model.Library.FilePath(file)), "open"));
        items.Add(UI.Item(Loc.S("在资源管理器中显示"), () => Shell.Reveal(model.Library.FilePath(file)), "open"));
        items.Add(new MenuFlyoutSeparator());
        if (model.Snapshot.Items.GetValueOrDefault(file.ItemId)?.DefaultFileId != file.Id)
            items.Add(UI.Item(Loc.S("设为默认文件"), () => model.Perform(() => model.Library.SetDefaultFile(file.Id)), "check"));
        items.Add(UI.Item(Loc.S("重命名…"), async () =>
        {
            var name = await Dialogs.Ask(Loc.S("重命名文件"), Loc.S("文件名"), Path.GetFileNameWithoutExtension(file.FileName), Loc.S("重命名"));
            if (!string.IsNullOrWhiteSpace(name)) model.Perform(() => model.Library.RenameFile(file.Id, name));
        }, "edit"));
        if (file.IsPdf && file.TranslationKind == null) items.Add(UI.Item(Loc.S("翻译…"), () => Translate(model, [file.ItemId], file), "translate"));
        items.Add(new MenuFlyoutSeparator());
        items.Add(UI.Item(Loc.S("移到回收站"), () => model.Perform(() => model.Library.TrashFiles([file.Id])), "delete"));
    }

    static MenuFlyoutSubItem GroupMenu(AppModel model, IReadOnlyList<string> ids)
    {
        var sub = new MenuFlyoutSubItem { Text = Loc.S("添加到分组"), Icon = UI.Icon("folder", 14) };
        foreach (var (group, depth) in model.Snapshot.GroupsForMenus())
            sub.Items.Add(UI.Item(new string(' ', depth * 4) + group.Name, () => model.Perform(() =>
            {
                var result = model.Library.AddItems(ids, group.Id, model.Settings.IncludeSubgroupItems);
                model.Toasts.Show(result.Added.Count > 0 ? Loc.S("已将 %lld 篇文献加入「%@」", result.Added.Count, group.Name) : Loc.S("所选文献已在「%@」中", group.Name), "folder");
            })));
        if (sub.Items.Count > 0) sub.Items.Add(new MenuFlyoutSeparator());
        sub.Items.Add(UI.Item(Loc.S("新建分组…"), async () =>
        {
            var name = await Dialogs.Ask(Loc.S("新建分组"), Loc.S("分组名称"), primary: Loc.S("创建"));
            if (!string.IsNullOrWhiteSpace(name)) model.Perform(() => model.Library.AddItems(ids, model.Library.CreateGroup(name).Id, false));
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
        sub.Items.Add(UI.Item(Loc.S("新建标签…"), () => _ = TagEditor.Create(model, ids), "add"));
        return sub;
    }

    public static async Task PurgeItems(AppModel model, IReadOnlyList<string> ids)
    {
        if (await Dialogs.Confirm(Loc.S("永久删除 %lld 项？", ids.Count), Loc.S("文献和文件将被永久删除，无法恢复。"), Loc.S("永久删除"), Loc.S("取消"), destructive: true))
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
