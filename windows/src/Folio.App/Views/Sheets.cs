using Folio.Core;
using Folio.Core.Retrieval;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Folio.App;

/// <summary>Creating and editing tags: a name and one of the preset colours.</summary>
static class TagEditor
{
    public static Task Create(AppModel model, IReadOnlyList<string>? applyTo = null) => Show(model, null, applyTo);
    public static Task Edit(AppModel model, Tag tag) => Show(model, tag, null);

    static async Task Show(AppModel model, Tag? tag, IReadOnlyList<string>? applyTo)
    {
        var name = new TextBox { Text = tag?.Name ?? "", PlaceholderText = Loc.S("标签名称"), Width = 300 };
        string color = tag?.ColorHex ?? TagPalette.Presets[model.Snapshot.Tags.Count % TagPalette.Presets.Length].Hex;
        var swatches = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        void Paint()
        {
            foreach (var child in swatches.Children.OfType<Button>())
                child.BorderThickness = new Thickness((string)child.Tag == color ? 2 : 0);
        }
        foreach (var (title, hex) in TagPalette.Presets)
        {
            var b = new Button { Width = 24, Height = 24, MinWidth = 0, Padding = new Thickness(0), CornerRadius = new CornerRadius(12), Background = UI.Hex(hex), BorderBrush = UI.Brush("TextFillColorPrimaryBrush"), Tag = hex };
            ToolTipService.SetToolTip(b, Loc.S(title));
            b.Click += (_, _) => { color = hex; Paint(); };
            swatches.Children.Add(b);
        }
        Paint();
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(name);
        panel.Children.Add(swatches);
        var dialog = new ContentDialog
        {
            Title = tag == null ? Loc.S("新建标签") : Loc.S("编辑标签"),
            Content = panel,
            PrimaryButtonText = tag == null ? Loc.S("创建") : Loc.S("存储"),
            CloseButtonText = Loc.S("取消"),
            DefaultButton = ContentDialogButton.Primary,
        };
        name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
        if (await Dialogs.Custom(dialog) != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(name.Text)) return;
        model.Perform(() =>
        {
            if (tag != null) model.Library.UpdateTag(tag.Id, name.Text, color);
            else
            {
                var created = model.Library.CreateTag(name.Text, color);
                if (applyTo is { Count: > 0 }) model.Library.SetTag(created.Id, applyTo, true);
            }
        });
    }
}

/// <summary>A new group: its name and a colour, or the default.</summary>
static class GroupEditor
{
    public static async Task<LibraryGroup?> Create(AppModel model, string? parentId)
    {
        var name = new TextBox { PlaceholderText = Loc.S("分组名称"), Width = 320 };
        string? color = null;
        var swatches = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        void Paint()
        {
            foreach (var b in swatches.Children.OfType<Button>()) b.BorderThickness = new Thickness((string?)b.Tag == color ? 2 : 0);
        }
        Button Swatch(string? hex, string title)
        {
            var b = new Button { Width = 24, Height = 24, MinWidth = 0, Padding = new Thickness(0), CornerRadius = new CornerRadius(12), Background = hex != null ? UI.Hex(hex) : UI.Brush("FolioAccentBrush"), BorderBrush = UI.Brush("TextFillColorPrimaryBrush"), Tag = hex };
            ToolTipService.SetToolTip(b, title);
            b.Click += (_, _) => { color = hex; Paint(); };
            return b;
        }
        swatches.Children.Add(Swatch(null, Loc.S("默认")));
        foreach (var (title, hex) in TagPalette.Presets) swatches.Children.Add(Swatch(hex, Loc.S(title)));
        Paint();
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(name);
        panel.Children.Add(swatches);
        var dialog = new ContentDialog
        {
            Title = parentId == null ? Loc.S("新建分组") : Loc.S("新建子分组"),
            Content = panel,
            PrimaryButtonText = Loc.S("创建"),
            CloseButtonText = Loc.S("取消"),
            DefaultButton = ContentDialogButton.Primary,
        };
        name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
        if (await Dialogs.Custom(dialog) != ContentDialogResult.Primary || string.IsNullOrWhiteSpace(name.Text)) return null;
        LibraryGroup? group = null;
        model.Perform(() =>
        {
            group = model.Library.CreateGroup(name.Text.Trim(), parentId);
            if (color != null) model.Library.SetGroupColor(group.Id, color);
        });
        return group;
    }
}

/// <summary>Adding a paper by DOI, arXiv ID or ISBN (several, one per line).</summary>
static class IdentifierSheet
{
    public static async Task Show(AppModel model)
    {
        var box = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 120, Width = 420, PlaceholderText = Loc.S("DOI、arXiv ID 或 ISBN，每行一个") };
        var dialog = new ContentDialog { Title = Loc.S("通过标识符添加"), Content = box, PrimaryButtonText = Loc.S("添加"), CloseButtonText = Loc.S("取消"), DefaultButton = ContentDialogButton.Primary };
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
        if (await Dialogs.Custom(dialog) != ContentDialogResult.Primary) return;
        var lines = box.Text.Split(['\r', '\n']).Select(l => l.Trim()).Where(l => l.Length > 0).Distinct().ToList();
        if (lines.Count == 0) return;
        model.Toasts.Show(Loc.S("正在检索…"), "search");
        int added = 0, existing = 0, failed = 0;
        string? last = null;
        foreach (var line in lines)
        {
            switch (await model.Importer.Engine.Resolve(line))
            {
                case ResolveResult.Found found:
                    var outcome = model.Library.CreateItem(found.Metadata, model.Scope.GroupId);
                    if (outcome is CreateOutcome.Created) added++; else existing++;
                    if (outcome is CreateOutcome.Duplicate && model.Scope.GroupId is { } g) model.Library.AddItems([outcome.Id], g, false);
                    last = outcome.Id;
                    break;
                default:
                    failed++;
                    break;
            }
        }
        if (last != null) model.Reveal(last);
        if (failed > 0 && added + existing == 0) model.Toasts.Show(Loc.S("没有找到对应的文献"), "question");
        else if (existing > 0 && added == 0) model.Toasts.Show(Loc.S("已在文献库中"), "copy");
        else model.Toasts.Show(failed > 0 ? Loc.S("已添加 %lld 篇，%lld 个未找到", added, failed) : Loc.S("已添加 %lld 篇文献", added), "check");
    }
}

/// <summary>Matching a standalone file by hand: search by title or identifier, pick the right record.</summary>
static class ManualMatchSheet
{
    public static async Task Show(AppModel model, string itemId)
    {
        var item = model.Snapshot.Items.GetValueOrDefault(itemId);
        if (item == null) return;
        var query = new AutoSuggestBox { Text = Path.GetFileNameWithoutExtension(item.Title), PlaceholderText = Loc.S("标题、DOI、arXiv ID 或 ISBN"), QueryIcon = new SymbolIcon(Symbol.Find), Width = 520 };
        var results = new ListView { Height = 300, SelectionMode = ListViewSelectionMode.Single };
        var progress = new ProgressBar { IsIndeterminate = true, Visibility = Visibility.Collapsed };
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(query);
        panel.Children.Add(progress);
        panel.Children.Add(results);
        var found = new List<Metadata>();
        async Task Search()
        {
            progress.Visibility = Visibility.Visible;
            results.Items.Clear();
            found = await model.Importer.Engine.Search(query.Text);
            progress.Visibility = Visibility.Collapsed;
            foreach (var m in found)
            {
                var row = new StackPanel { Padding = new Thickness(0, 4, 0, 4) };
                row.Children.Add(new TextBlock { Text = m.Title, TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                row.Children.Add(UI.Label(string.Join(" · ", new[] { AuthorFormatter.ListDisplay(m.Authors), m.Year?.ToString(), m.Source }.Where(x => !string.IsNullOrEmpty(x))), 12, secondary: true));
                results.Items.Add(row);
            }
            if (found.Count == 0) results.Items.Add(UI.Label(Loc.S("没有找到匹配的文献"), 12, secondary: true));
        }
        query.QuerySubmitted += async (_, _) => await Search();
        var dialog = new ContentDialog { Title = Loc.S("手动匹配元数据"), Content = panel, PrimaryButtonText = Loc.S("使用所选"), CloseButtonText = Loc.S("取消"), DefaultButton = ContentDialogButton.Primary };
        dialog.Opened += async (_, _) => await Search();
        if (await Dialogs.Custom(dialog) != ContentDialogResult.Primary || results.SelectedIndex < 0 || results.SelectedIndex >= found.Count) return;
        await model.Importer.Apply(found[results.SelectedIndex], itemId);
    }
}
