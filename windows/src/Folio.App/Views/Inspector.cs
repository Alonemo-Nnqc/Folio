using System.Globalization;
using Folio.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Folio.App;

/// <summary>The right column: 信息 / 标注 / 笔记 for the selected item (the macOS InspectorView).</summary>
public sealed class Inspector : Grid
{
    readonly AppModel _model;
    readonly StackPanel _segments;
    readonly ScrollViewer _scroll;
    readonly StackPanel _content;
    readonly NoteEditor _notes;
    string _page = "info";
    string? _shownItem;

    public Inspector(AppModel model)
    {
        _model = model;
        Background = UI.Brush("FolioInspectorBrush");
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _segments = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 8), Spacing = 2 };
        foreach (var (key, title) in new[] { ("info", "信息"), ("annotations", "标注"), ("notes", "笔记") })
        {
            var b = new ToggleButton { Content = Loc.S(title), Tag = key, Padding = new Thickness(12, 3, 12, 3), MinWidth = 0 };
            b.Click += (_, _) => { _page = key; Render(force: true); };
            _segments.Children.Add(b);
        }
        Children.Add(_segments);
        _content = new StackPanel { Padding = new Thickness(16, 4, 16, 24), Spacing = 6 };
        _scroll = new ScrollViewer { Content = _content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        SetRow(_scroll, 1);
        Children.Add(_scroll);
        _notes = new NoteEditor(model);
        SetRow(_notes, 1);
        Children.Add(_notes);
        model.SelectionChanged += () => Render(force: true);
        model.SnapshotChanged += () => Render(force: false);
        Render(force: true);
    }

    public void ShowNotes() { _page = "notes"; Render(force: true); }

    void Render(bool force)
    {
        foreach (var b in _segments.Children.OfType<ToggleButton>()) b.IsChecked = (string)b.Tag == _page;
        var item = _model.SelectedItem;
        _notes.Visibility = _page == "notes" ? Visibility.Visible : Visibility.Collapsed;
        _scroll.Visibility = _page == "notes" ? Visibility.Collapsed : Visibility.Visible;
        _notes.Show(item?.Id);
        // While the user edits a field, a refresh caused by that edit must not rebuild the form.
        if (!force && _shownItem == item?.Id && XamlRoot != null && FocusManager.GetFocusedElement(XamlRoot) is TextBox { Parent: not null } focused && IsChild(focused)) return;
        _shownItem = item?.Id;
        _content.Children.Clear();
        if (item == null)
        {
            var count = _model.SelectedItemIds.Count;
            var empty = UI.Label(count > 1 ? Loc.S("已选择 %lld 项", count) : Loc.S("未选择文献"), 13, secondary: true);
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Margin = new Thickness(0, 40, 0, 0);
            _content.Children.Add(empty);
            return;
        }
        if (_page == "annotations") AnnotationsPage(item);
        else InfoPage(item);
    }

    bool IsChild(DependencyObject element)
    {
        for (var e = element; e != null; e = VisualTreeHelper.GetParent(e)) if (e == this) return true;
        return false;
    }

    void InfoPage(Item item)
    {
        var s = _model.Snapshot;
        if (item.Kind == ItemKind.Standalone)
        {
            _content.Children.Add(new TextBlock { Text = item.Title, TextWrapping = TextWrapping.Wrap, FontSize = 18, FontWeight = FontWeights.SemiBold });
            var state = item.MetadataState switch
            {
                MetadataState.Pending => Loc.S("正在检索元数据…"),
                MetadataState.Failed => Loc.S("未检索到元数据"),
                MetadataState.NetworkFailed => Loc.S("网络不可用，稍后自动重试"),
                _ => Loc.S("独立文件"),
            };
            _content.Children.Add(UI.Label(state, 12, secondary: true));
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 8) };
            var retrieve = new Button { Content = Loc.S("重新检索元数据") };
            retrieve.Click += (_, _) => _model.Retrieve([item.Id]);
            var match = new Button { Content = Loc.S("手动匹配…") };
            match.Click += (_, _) => _ = ManualMatchSheet.Show(_model, item.Id);
            buttons.Children.Add(retrieve);
            buttons.Children.Add(match);
            _content.Children.Add(buttons);
            FilesSection(item);
            LibrarySection(item, regular: false);
            return;
        }
        // Type menu, title, authors, citation key — like the macOS header.
        var type = new DropDownButton { Content = item.Type.DisplayName(), FontSize = 11, Padding = new Thickness(6, 2, 6, 2), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        var typeMenu = new MenuFlyout();
        foreach (var t in ItemTypes.All) typeMenu.Items.Add(UI.Item(t.DisplayName(), () => Update(item.Id, i => i.Type = t)));
        type.Flyout = typeMenu;
        _content.Children.Add(type);
        _content.Children.Add(EditableText(item.Title, v => Update(item.Id, i => i.Title = v), 18, FontWeights.SemiBold, serif: true));
        _content.Children.Add(EditableText(string.Join("; ", item.Authors.Select(AuthorFormatter.Full)), v => Update(item.Id, i => i.Authors = ParseAuthors(v)), 12, FontWeights.Normal, secondary: true));
        _content.Children.Add(UI.Label(item.CitationKey ?? "", 11, secondary: true));

        Section(Loc.S("引用"));
        Field(Loc.S("年份"), item.Year?.ToString(CultureInfo.InvariantCulture), v => Update(item.Id, i => i.Year = int.TryParse(v, out var y) ? y : null));
        Field(Loc.S("来源"), item.Source, v => Update(item.Id, i => i.Source = Text.NonEmpty(v)));
        Field(Loc.S("卷"), item.Volume, v => Update(item.Id, i => i.Volume = Text.NonEmpty(v)));
        Field(Loc.S("期"), item.Issue, v => Update(item.Id, i => i.Issue = Text.NonEmpty(v)));
        Field(Loc.S("页码"), item.Pages, v => Update(item.Id, i => i.Pages = Text.NonEmpty(v)));
        Field(Loc.S("出版社"), item.Publisher, v => Update(item.Id, i => i.Publisher = Text.NonEmpty(v)));
        Field("DOI", item.Doi, v => Update(item.Id, i => i.Doi = Text.NonEmpty(v)), link: item.Doi is { Length: > 0 } d ? $"https://doi.org/{d}" : null);
        Field("arXiv", item.ArxivId, v => Update(item.Id, i => i.ArxivId = Text.NonEmpty(v)), link: item.ArxivId is { Length: > 0 } a ? $"https://arxiv.org/abs/{a}" : null);
        Field("ISBN", item.Isbn, v => Update(item.Id, i => i.Isbn = Text.NonEmpty(v)));
        Field("URL", item.Url, v => Update(item.Id, i => i.Url = Text.NonEmpty(v)), link: item.Url);
        Field(Loc.S("引用键"), item.CitationKey, v => Update(item.Id, i => i.CitationKey = Text.NonEmpty(v)));

        LibrarySection(item, regular: true);
        FilesSection(item);

        Section(Loc.S("摘要"));
        _content.Children.Add(EditableText(item.Abstract ?? "", v => Update(item.Id, i => i.Abstract = Text.NonEmpty(v)), 12, FontWeights.Normal, multiline: true));
    }

    void LibrarySection(Item item, bool regular)
    {
        var s = _model.Snapshot;
        Section(Loc.S("文库"));
        if (regular)
        {
            var stars = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            for (int i = 1; i <= 5; i++)
            {
                int value = i;
                var star = new Button { Content = UI.Icon(i <= item.Rating ? "starFill" : "star", 14, UI.Hex("#FF9500")), Padding = new Thickness(2), MinWidth = 0, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
                star.Click += (_, _) => Update(item.Id, it => it.Rating = it.Rating == value ? 0 : value);
                stars.Children.Add(star);
            }
            if (item.Rating > 0) stars.Children.Add(UI.Label(Loc.S("%lld 星", item.Rating), 11, secondary: true));
            Row(Loc.S("评分"), stars);
            var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            foreach (var st in Enum.GetValues<ReadStatus>())
            {
                var b = new ToggleButton { Content = st.DisplayName(), IsChecked = item.ReadStatus == st, Padding = new Thickness(10, 2, 10, 2), MinWidth = 0, FontSize = 12 };
                b.Click += (_, _) => Update(item.Id, it => it.ReadStatus = st);
                status.Children.Add(b);
            }
            Row(Loc.S("状态"), status);
        }
        var groups = new VariableWrap();
        foreach (var gid in s.ItemGroups.GetValueOrDefault(item.Id) ?? [])
            if (s.GroupsById.TryGetValue(gid, out var g))
                groups.Add(UI.Chip(g.Name, g.ColorHex ?? "#007AFF", false, () => _model.Perform(() => _model.Library.RemoveItems([item.Id], g.Id, false))));
        var addGroup = new Button { Content = UI.Icon("add", 11), Padding = new Thickness(4), MinWidth = 0, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        var groupMenu = new MenuFlyout();
        groupMenu.Opening += (_, _) =>
        {
            groupMenu.Items.Clear();
            foreach (var (group, depth) in _model.Snapshot.GroupsForMenus())
                groupMenu.Items.Add(UI.Item(new string(' ', depth * 4) + group.Name, () => _model.Perform(() => _model.Library.AddItems([item.Id], group.Id, false))));
        };
        addGroup.Flyout = groupMenu;
        groups.Add(addGroup);
        Row(Loc.S("分组"), groups.Panel);
        var tags = new VariableWrap();
        foreach (var tag in s.TagsOf(item.Id))
            tags.Add(UI.Chip(tag.Name, tag.ColorHex, false, () => _model.Perform(() => _model.Library.SetTag(tag.Id, [item.Id], false))));
        var addTag = new Button { Content = UI.Icon("add", 11), Padding = new Thickness(4), MinWidth = 0, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        var tagMenu = new MenuFlyout();
        tagMenu.Opening += (_, _) =>
        {
            tagMenu.Items.Clear();
            var have = _model.Snapshot.ItemTags.GetValueOrDefault(item.Id) ?? [];
            foreach (var tag in _model.Snapshot.Tags.Where(t => !have.Contains(t.Id)))
                tagMenu.Items.Add(new MenuFlyoutItem { Text = tag.Name, Icon = new FontIcon { Glyph = "", FontFamily = UI.IconFont, Foreground = UI.Hex(tag.ColorHex) } }.With(m => m.Click += (_, _) => _model.Perform(() => _model.Library.SetTag(tag.Id, [item.Id], true))));
            tagMenu.Items.Add(new MenuFlyoutSeparator());
            tagMenu.Items.Add(UI.Item(Loc.S("新建标签…"), () => _ = TagEditor.Create(_model, [item.Id]), "add"));
        };
        addTag.Flyout = tagMenu;
        tags.Add(addTag);
        Row(Loc.S("标签"), tags.Panel);
    }

    void FilesSection(Item item)
    {
        var files = _model.Snapshot.FilesOf(item.Id);
        if (files.Count == 0) return;
        Section(Loc.S("文件"));
        foreach (var file in files)
        {
            var row = new Button { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0, 4, 0, 4) };
            var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            panel.Children.Add(UI.Icon(file.IsPdf ? "pdf" : "document", 14, UI.Brush("FolioSecondaryTextBrush")));
            var label = UI.Label(FileLabel.Title(file, files, item.DefaultFileId), 12);
            if (file.Id == item.DefaultFileId && files.Count > 1) label.FontWeight = FontWeights.SemiBold;
            panel.Children.Add(label);
            row.Content = panel;
            ToolTipService.SetToolTip(row, file.FileName);
            row.Click += (_, _) => _model.OpenFile(file);
            var menu = new MenuFlyout();
            Commands.FillFileMenu(menu.Items, _model, file);
            row.ContextFlyout = menu;
            _content.Children.Add(row);
        }
    }

    void AnnotationsPage(Item item)
    {
        var pdfs = _model.Snapshot.FilesOf(item.Id).Where(f => f.IsPdf).ToList();
        int total = 0;
        foreach (var file in pdfs)
        {
            var annotations = PdfAnnotations.Read(_model.Library.FilePath(file));
            if (annotations.Count == 0) continue;
            if (pdfs.Count > 1) Section(FileLabel.Title(file, pdfs, item.DefaultFileId));
            foreach (var a in annotations)
            {
                total++;
                var card = new Border { Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(6), Background = UI.Brush("FolioContentBrush"), BorderBrush = UI.Hex(a.ColorHex), BorderThickness = new Thickness(3, 0, 0, 0) };
                var stack = new StackPanel { Spacing = 4 };
                if (a.Text is { Length: > 0 } text) stack.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 12 });
                if (a.Comment is { Length: > 0 } comment) stack.Children.Add(new TextBlock { Text = comment, TextWrapping = TextWrapping.Wrap, FontSize = 12, FontStyle = Windows.UI.Text.FontStyle.Italic });
                stack.Children.Add(UI.Label(Loc.S("第 %lld 页", a.Page) + (a.Author is { Length: > 0 } author ? " · " + author : ""), 11, secondary: true));
                card.Child = stack;
                var open = new Button { Content = card, Padding = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
                var page = a.Page;
                open.Click += (_, _) => App.Current?.Window?.OpenReader(file, page);
                _content.Children.Add(open);
            }
        }
        if (total == 0)
        {
            var empty = UI.Label(Loc.S("没有标注"), 13, secondary: true);
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            empty.Margin = new Thickness(0, 40, 0, 0);
            _content.Children.Add(empty);
        }
    }

    void Update(string id, Action<Item> change) => _model.Perform(() =>
    {
        _model.Library.UpdateItem(id, change);
        if (_model.Settings.AutoRenameFiles) _model.Library.RenameFiles(id);
    });

    static List<Author> ParseAuthors(string text) => text.Split(';').Select(p => p.Trim()).Where(p => p.Length > 0).Select(p =>
    {
        int comma = p.IndexOf(',');
        if (comma >= 0) return new Author(p[..comma].Trim(), p[(comma + 1)..].Trim());
        var parts = p.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 1 ? new Author(parts[^1], string.Join(' ', parts[..^1])) : new Author(p);
    }).ToList();

    void Section(string title)
    {
        var label = UI.Label(title, 11, secondary: true, bold: true);
        label.Margin = new Thickness(0, 14, 0, 2);
        _content.Children.Add(label);
    }

    void Row(string label, FrameworkElement value)
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var l = UI.Label(label, 12, secondary: true);
        l.VerticalAlignment = VerticalAlignment.Top;
        l.Margin = new Thickness(0, 5, 0, 0);
        grid.Children.Add(l);
        SetColumn(value, 1);
        grid.Children.Add(value);
        _content.Children.Add(grid);
    }

    void Field(string label, string? value, Action<string> commit, string? link = null)
    {
        var box = PlainBox(value ?? "", commit, 12);
        box.PlaceholderText = "—";
        if (link == null) { Row(label, box); return; }
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(box);
        var open = UI.IconButton("open", Loc.S("在浏览器中打开"), (_, _) => Shell.Open(link), 12);
        SetColumn(open, 1);
        grid.Children.Add(open);
        Row(label, grid);
    }

    FrameworkElement EditableText(string value, Action<string> commit, double size, Windows.UI.Text.FontWeight weight, bool secondary = false, bool serif = false, bool multiline = false)
    {
        var box = PlainBox(value, commit, size, multiline || size >= 16);
        box.FontWeight = weight;
        if (serif) box.FontFamily = new FontFamily("Georgia, Cambria, Times New Roman, SimSun");
        if (secondary) box.Foreground = UI.Brush("FolioSecondaryTextBrush");
        return box;
    }

    /// <summary>A borderless text box that looks like a label until focused; commits on Enter or focus loss.</summary>
    static TextBox PlainBox(string value, Action<string> commit, double size, bool wrap = false)
    {
        var box = new TextBox
        {
            Text = value, FontSize = size, BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Padding = new Thickness(0, 4, 0, 4), MinHeight = 0, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, AcceptsReturn = wrap && size < 16,
        };
        void Commit()
        {
            if (box.Text != value) { value = box.Text; commit(box.Text.Trim()); }
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter && !box.AcceptsReturn) { Commit(); e.Handled = true; }
            if (e.Key == Windows.System.VirtualKey.Escape) { box.Text = value; e.Handled = true; }
        };
        return box;
    }

    /// <summary>Chips that wrap onto further lines.</summary>
    sealed class VariableWrap
    {
        public readonly VariableSizedWrapGrid Grid = new() { Orientation = Orientation.Horizontal, ItemHeight = 28, ItemWidth = double.NaN };
        public readonly StackPanel Panel;
        readonly StackPanel _line = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
        public VariableWrap() { Panel = new StackPanel { Spacing = 4 }; Panel.Children.Add(_line); }
        int _count;
        public void Add(FrameworkElement e)
        {
            if (_count > 0 && _count % 3 == 0) { var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 }; Panel.Children.Add(line); }
            ((StackPanel)Panel.Children[^1]).Children.Add(e);
            _count++;
        }
    }
}

static class FluentExtensions
{
    public static T With<T>(this T value, Action<T> configure) { configure(value); return value; }
}

/// <summary>An item's Markdown note: plain text editing with a live preview toggle (the macOS NoteEditor).</summary>
public sealed class NoteEditor : Grid
{
    readonly AppModel _model;
    readonly TextBox _box;
    readonly TextBlock _title;
    string? _itemId;
    string _saved = "";
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _save;

    public NoteEditor(AppModel model)
    {
        _model = model;
        Padding = new Thickness(16, 4, 16, 16);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _title = UI.Label("", 11, secondary: true);
        _title.TextWrapping = TextWrapping.Wrap;
        _title.Margin = new Thickness(0, 0, 0, 8);
        Children.Add(_title);
        _box = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, PlaceholderText = Loc.S("记下想法、摘录与待办… 支持 Markdown"), FontSize = 13 };
        ScrollViewer.SetVerticalScrollBarVisibility(_box, ScrollBarVisibility.Auto);
        SetRow(_box, 1);
        Children.Add(_box);
        _save = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();
        _save.Interval = TimeSpan.FromMilliseconds(600);
        _save.IsRepeating = false;
        _save.Tick += (_, _) => Save();
        _box.TextChanged += (_, _) => { if (_itemId != null) { _save.Stop(); _save.Start(); } };
        _box.LostFocus += (_, _) => Save();
    }

    public void Show(string? itemId)
    {
        if (itemId == _itemId) return;
        Save();
        _itemId = itemId;
        _box.IsEnabled = itemId != null;
        _saved = itemId == null ? "" : _model.Library.Note(itemId);
        _box.Text = _saved;
        _title.Text = itemId != null && _model.Snapshot.Items.TryGetValue(itemId, out var item) ? item.Title : "";
    }

    /// <summary>Appends text (selected in the reader) as a quote.</summary>
    public void AppendQuote(string itemId, string quote, int page)
    {
        Show(itemId);
        var addition = Loc.S("%@\n> —— 第 %lld 页", "> " + quote.Replace("\n", "\n> "), page);
        _box.Text = string.IsNullOrWhiteSpace(_box.Text) ? addition : _box.Text.TrimEnd() + "\n\n" + addition;
        Save();
    }

    void Save()
    {
        _save.Stop();
        if (_itemId == null || _box.Text == _saved) return;
        _saved = _box.Text;
        var id = _itemId;
        var text = _box.Text;
        _model.Perform(() => _model.Library.SetNote(text, id));
    }
}
