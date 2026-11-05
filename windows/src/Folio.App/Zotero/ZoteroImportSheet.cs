using Folio.Core;
using Folio.Core.Zotero;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace Folio.App;

/// <summary>"从 Zotero 导入…": probe → options → import with progress → summary (the macOS ZoteroImportSheet).</summary>
static class ZoteroImportSheet
{
    public static async Task Show(AppModel model)
    {
        string? directory = ZoteroLocator.DefaultDataDirectory();
        ZoteroReadReport? report = null;
        bool importing = false, finished = false;

        var path = new TextBlock
        {
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono,Consolas"), FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center, MaxWidth = 300,
        };
        var choose = new Button { Content = Loc.S("选择…") };
        var directoryRow = new Grid { ColumnSpacing = 8 };
        directoryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        directoryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        directoryRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        directoryRow.Children.Add(new TextBlock { Text = Loc.S("数据目录"), Foreground = UI.Brush("FolioSecondaryTextBrush"), VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(path, 1);
        directoryRow.Children.Add(path);
        Grid.SetColumn(choose, 2);
        directoryRow.Children.Add(choose);

        var content = new StackPanel { Spacing = 6 };
        var automatic = new CheckBox();
        var root = new StackPanel { Spacing = 16, Width = 460 };
        root.Children.Add(directoryRow);
        root.Children.Add(content);

        var dialog = new ContentDialog
        {
            Title = Loc.S("从 Zotero 导入"), Content = root, PrimaryButtonText = Loc.S("导入"), CloseButtonText = Loc.S("取消"),
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false,
        };

        TextBlock Text(string text, bool secondary = false, double size = 13) => new()
        {
            Text = text, TextWrapping = TextWrapping.Wrap, FontSize = size, Foreground = secondary ? UI.Brush("FolioSecondaryTextBrush") : null,
        };
        void Busy(string text)
        {
            content.Children.Clear();
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true });
            row.Children.Add(Text(text));
            content.Children.Add(row);
        }
        void Failed(string text)
        {
            content.Children.Clear();
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            row.Children.Add(UI.Icon("warning", 14, UI.Hex("#FF3B30")));
            row.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, MaxWidth = 420, Foreground = UI.Hex("#FF3B30") });
            content.Children.Add(row);
            dialog.IsPrimaryButtonEnabled = false;
        }

        async Task Probe()
        {
            path.Text = directory ?? Loc.S("未找到 Zotero 数据目录");
            ToolTipService.SetToolTip(path, directory);
            if (directory == null)
            {
                Failed(Loc.S("未找到 Zotero 数据目录，请点击「选择…」手动指定"));
                return;
            }
            Busy(Loc.S("正在读取 Zotero 数据库…"));
            dialog.IsPrimaryButtonEnabled = false;
            var dir = directory;
            try
            {
                report = await Task.Run(() => { using var reader = new ZoteroReader(dir); return reader.Probe(); });
            }
            catch (Exception e)
            {
                Failed(Loc.S("无法读取 Zotero 数据库：%@", e.Message));
                return;
            }
            content.Children.Clear();
            content.Children.Add(Text(Loc.S("将导入 %lld 个条目、%lld 个独立文件、%lld 个分组、%lld 个标签。", report.RegularItems, report.StandaloneFiles, report.Collections, report.Tags)));
            content.Children.Add(Text(Loc.S("跳过：%lld 条笔记、%lld 条 Zotero 批注、%lld 个网页快照、%lld 个回收站条目。超过两级的分组会并入第二级。",
                report.SkippedNotes, report.SkippedAnnotations, report.SkippedSnapshots, report.SkippedTrashed), true, 12));
            automatic.Content = Loc.S("同时导入自动标签（%lld 个，来自出版商关键词和 arXiv 分类）", report.AutomaticTagsAvailable);
            automatic.IsEnabled = report.AutomaticTagsAvailable > 0;
            automatic.Margin = new Thickness(0, 4, 0, 0);
            content.Children.Add(automatic);
            content.Children.Add(Text(Loc.S("只读取 Zotero 数据库的副本，不会修改 Zotero；PDF 会复制进 Folio 文献库，与已有文献重复的会跳过。"), true, 11));
            dialog.IsPrimaryButtonEnabled = true;
        }

        choose.Click += async (_, _) =>
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            if (App.Current?.Window is { } window) WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window));
            if (await picker.PickSingleFolderAsync() is not { } folder) return;
            directory = folder.Path;
            await Probe();
        };

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            if (finished) return;
            args.Cancel = true;
            if (importing || directory == null) return;
            importing = true;
            dialog.IsPrimaryButtonEnabled = false;
            dialog.IsSecondaryButtonEnabled = false;
            choose.IsEnabled = false;
            var options = new ZoteroReadOptions { IncludeAutomaticTags = automatic.IsChecked == true };
            int total = report != null ? report.RegularItems + report.StandaloneFiles : 0;
            content.Children.Clear();
            var bar = new ProgressBar { Maximum = Math.Max(total, 1), Value = 0 };
            var label = Text(Loc.S("正在导入 %lld / %lld…", 0, total), true, 12);
            content.Children.Add(bar);
            content.Children.Add(label);
            var library = model.Library;
            var autoRename = model.Settings.AutoRenameFiles;
            var dir = directory;
            try
            {
                var summary = await Task.Run(() =>
                {
                    using var reader = new ZoteroReader(dir);
                    var (prepared, _) = reader.Read(options);
                    return library.ImportPrepared(prepared, autoRename, (done, all) => model.RunOnUi(() =>
                    {
                        bar.Maximum = Math.Max(all, 1);
                        bar.Value = done;
                        label.Text = Loc.S("正在导入 %lld / %lld…", done, all);
                    }));
                });
                model.Importer.IndexFulltext();
                content.Children.Clear();
                var done = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                done.Children.Add(UI.Icon("check", 14, UI.Hex("#34C759")));
                done.Children.Add(new TextBlock { Text = Loc.S("导入完成"), Foreground = UI.Hex("#34C759") });
                content.Children.Add(done);
                content.Children.Add(Text(Loc.S("导入 %lld 个条目、%lld 个文件，新建 %lld 个分组、%lld 个标签。", summary.ItemsImported, summary.FilesImported, summary.GroupsCreated, summary.TagsCreated)));
                if (summary.TranslationsRecognized > 0)
                    content.Children.Add(Text(Loc.S("识别出之前导入的 %lld 个翻译文件，已按翻译服务重新命名。", summary.TranslationsRecognized)));
                if (summary.DuplicatesSkipped > 0 || summary.MissingFiles > 0)
                    content.Children.Add(Text(Loc.S("跳过 %lld 个重复条目；%lld 个附件在 Zotero 中已找不到文件。", summary.DuplicatesSkipped, summary.MissingFiles), true));
                finished = true;
                dialog.PrimaryButtonText = Loc.S("完成");
                dialog.CloseButtonText = "";
                dialog.IsPrimaryButtonEnabled = true;
            }
            catch (Exception e)
            {
                Failed(Loc.S("导入失败：%@", e.Message));
                choose.IsEnabled = true;
            }
            importing = false;
        };
        dialog.Closing += (_, args) => { if (importing) args.Cancel = true; };
        dialog.Opened += async (_, _) => await Probe();
        await Dialogs.Custom(dialog);
    }
}
