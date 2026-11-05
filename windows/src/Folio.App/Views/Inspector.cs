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
    readonly SegmentedControl _segments;
    readonly ScrollViewer _scroll;
    readonly StackPanel _content;
    readonly NoteEditor _notes;
    string _page = "info";
    string? _shownItem;
    string _annotationQuery = "";
    string _annotationKey = "";
    string _formKey = "";
    bool _renderQueued, _skipped, _renderWhenShown;

    public Inspector(AppModel model)
    {
        _model = model;
        Background = UI.Brush("FolioInspectorBrush");
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _segments = new SegmentedControl([("info", Loc.S("信息")), ("annotations", Loc.S("标注")), ("notes", Loc.S("笔记"))], "info", height: 26, padding: 16)
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 10, 0, 8),
        };
        _segments.Changed += key => { _page = key; Render(force: true); };
        Children.Add(_segments);
        _content = new StackPanel { Padding = new Thickness(16, 4, 16, 24), Spacing = 6 };
        _scroll = new ScrollViewer { Content = _content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        SetRow(_scroll, 1);
        Children.Add(_scroll);
        _notes = new NoteEditor(model);
        SetRow(_notes, 1);
        Children.Add(_notes);
        // Selecting stays quick: the form follows once the list has answered, and only for the last of several quick selections.
        model.SelectionChanged += () =>
        {
            _annotationQuery = "";
            if (_renderQueued) return;
            _renderQueued = true;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                _renderQueued = false;
                Render(force: true);
            });
        };
        model.SnapshotChanged += () => Render(force: false);
        SizeChanged += (_, e) =>
        {
            if (e.NewSize.Width >= 1 && _renderWhenShown)
            {
                _renderWhenShown = false;
                Render(force: true);
            }
        };
        // A refresh skipped while typing catches up when focus leaves the form.
        LostFocus += (_, _) => DispatcherQueue.TryEnqueue(() => { if (_skipped) Render(force: false); });
        Render(force: true);
    }

    public void ShowNotes() { _page = "notes"; Render(force: true); }

    void Render(bool force)
    {
        // Hidden, it does no work: it catches up when it is shown.
        if (IsLoaded && ActualWidth < 1) { _renderWhenShown = true; return; }
        _segments.Select(_page);
        var item = _model.SelectedItem;
        _notes.Visibility = _page == "notes" ? Visibility.Visible : Visibility.Collapsed;
        _scroll.Visibility = _page == "notes" ? Visibility.Collapsed : Visibility.Visible;
        _notes.Show(item?.Id);
        if (_page == "notes" && !force) return;
        // Other papers changing leave this form alone: same text, same scroll position, same open sections.
        var formKey = FormKey(item);
        if (!force && _shownItem == item?.Id && formKey == _formKey) { _skipped = false; return; }
        // While the user edits a field, a refresh caused by that edit must not rebuild the form.
        if (!force && _shownItem == item?.Id && XamlRoot != null && FocusManager.GetFocusedElement(XamlRoot) is TextBox { Parent: not null } focused && IsChild(focused)) { _skipped = true; return; }
        _skipped = false;
        _formKey = formKey;
        // The annotation list only changes with the files it was read from.
        var annotationKey = item == null ? "" : string.Join(",", _model.Snapshot.FilesOf(item.Id).Select(f => f.Id + f.Sha256));
        if (!force && _page == "annotations" && _shownItem == item?.Id && annotationKey == _annotationKey) return;
        _annotationKey = annotationKey;
        _shownItem = item?.Id;
        double scroll = _scroll.VerticalOffset;
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
        if (_page == "annotations") AnnotationsPage(item).Fire();
        else InfoPage(item);
        // A refresh keeps the place; only another item starts from the top.
        if (!force) DispatcherQueue.TryEnqueue(() => _scroll.ChangeView(null, scroll, null, disableAnimation: true));
        else _scroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    /// <summary>Everything the form shows of an item.</summary>
    string FormKey(Item? item)
    {
        if (item == null) return $"none:{_model.SelectedItemIds.Count}";
        var s = _model.Snapshot;
        var text = new System.Text.StringBuilder(JsonOf(item));
        foreach (var f in s.FilesOf(item.Id)) text.Append('|').Append(f.Id).Append(f.FileName).Append(f.Sha256).Append(f.TranslationKind);
        foreach (var t in s.TagsOf(item.Id)) text.Append('|').Append(t.Id).Append(t.Name).Append(t.ColorHex);
        foreach (var g in s.ItemGroups.GetValueOrDefault(item.Id) ?? []) if (s.GroupsById.TryGetValue(g, out var group)) text.Append('|').Append(g).Append(group.Name).Append(group.ColorHex);
        return text.ToString();
    }

    static string JsonOf(Item i) => string.Join('\u0001', i.Title, i.Type, i.Kind, i.Year, i.Source, i.Volume, i.Issue, i.Pages, i.Publisher, i.Doi, i.ArxivId, i.Isbn, i.Url, i.CitationKey,
        i.Abstract, i.Rating, i.ReadStatus, i.MetadataState, i.DateModified.Ticks, i.DefaultFileId, string.Join(';', i.Authors.Select(AuthorFormatter.Full)));

    public void Flush() => _notes.Flush();

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
            var buttons = new WrapPanel { HorizontalSpacing = 8, VerticalSpacing = 8, Margin = new Thickness(0, 8, 0, 8) };
            var retrieve = new Button { Content = Loc.S("重新检索元数据") };
            retrieve.Click += (_, _) => _model.Retrieve([item.Id]);
            var match = new Button { Content = Loc.S("手动匹配…") };
            match.Click += (_, _) => ManualMatchSheet.Show(_model, item.Id).Fire();
            buttons.Children.Add(retrieve);
            buttons.Children.Add(match);
            _content.Children.Add(buttons);
            FilesSection(item);
            LibrarySection(item, regular: false);
            return;
        }
        // Type menu, title, authors, citation key — like the macOS header.
        var type = new DropDownButton { Content = item.Type.DisplayName(), FontSize = 11, Padding = new Thickness(6, 2, 6, 2), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Margin = new Thickness(-6, 0, 0, 0) };
        UI.FlatResources(type);
        var typeMenu = new MenuFlyout();
        foreach (var t in ItemTypes.All) typeMenu.Items.Add(UI.Item(t.DisplayName(), () => Update(item.Id, i => i.Type = t)));
        type.Flyout = typeMenu;
        _content.Children.Add(type);
        _content.Children.Add(EditableText(item.Title, v => Update(item.Id, i => i.Title = v), 18, FontWeights.SemiBold, serif: true));
        var authors = (TextBox)EditableText(string.Join("; ", item.Authors.Select(AuthorFormatter.Full)), v => Update(item.Id, i => i.Authors = ParseAuthors(v)), 12, FontWeights.Normal, secondary: true, wrap: true);
        authors.PlaceholderText = Loc.S("无作者");
        ToolTipService.SetToolTip(authors, Loc.S("编辑作者"));
        _content.Children.Add(authors);
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

        if (item.Abstract is { Length: > 0 })
        {
            Section(Loc.S("内容"));
            _content.Children.Add(new Expander
            {
                Header = Loc.S("摘要"), IsExpanded = _abstractExpanded, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new Thickness(0, 4, 0, 4),
                Content = EditableText(item.Abstract, v => Update(item.Id, i => i.Abstract = Text.NonEmpty(v)), 12, FontWeights.Normal, multiline: true),
            }.With(e => { e.Expanding += (_, _) => _abstractExpanded = true; e.Collapsed += (_, _) => _abstractExpanded = false; }));
        }
        FilesSection(item);
        var stamps = UI.Label(Loc.S("添加于 %@ · 修改于 %@", item.DateAdded.ToLocalTime().ToString("g"), item.DateModified.ToLocalTime().ToString("g")), 11, secondary: true);
        stamps.TextWrapping = TextWrapping.Wrap;
        stamps.Margin = new Thickness(0, 8, 0, 0);
        _content.Children.Add(stamps);
    }

    bool _abstractExpanded = true;

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
            var status = new SegmentedControl(Enum.GetValues<ReadStatus>().Select(st => (st.ToString(), st.DisplayName())).ToArray(), item.ReadStatus.ToString(), accent: true, height: 22, padding: 9);
            status.Changed += key => Update(item.Id, it => it.ReadStatus = Enum.Parse<ReadStatus>(key));
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
            tagMenu.Items.Add(UI.Item(Loc.S("新建标签…"), () => TagEditor.Create(_model, [item.Id]).Fire(), "add"));
        };
        addTag.Flyout = tagMenu;
        tags.Add(addTag);
        Row(Loc.S("标签"), tags.Panel);
    }

    void FilesSection(Item item)
    {
        var files = _model.Snapshot.FilesOf(item.Id);
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
        if (item.Kind == ItemKind.Regular)
        {
            var attach = new Button { Content = Loc.S("添加文件…"), Margin = new Thickness(0, 4, 0, 0) };
            attach.Click += (_, _) => Commands.AttachFiles(_model, item.Id).Fire();
            _content.Children.Add(attach);
        }
    }

    /// <summary>Highlights and notes in the item's PDFs (read off the UI thread: big files take a moment).</summary>
    async Task AnnotationsPage(Item item)
    {
        var search = new AutoSuggestBox { PlaceholderText = Loc.S("搜索标注"), QueryIcon = new SymbolIcon(Symbol.Find), Text = _annotationQuery, Margin = new Thickness(0, 0, 0, 8) };
        var list = new StackPanel { Spacing = 6 };
        _content.Children.Add(search);
        _content.Children.Add(list);
        list.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20, Margin = new Thickness(0, 30, 0, 0) });
        var pdfs = _model.Snapshot.FilesOf(item.Id).Where(f => f.IsPdf).ToList();
        var paths = pdfs.Select(f => _model.Library.FilePath(f)).ToList();
        var results = await Task.Run(() => paths.Select(PdfAnnotations.Read).ToList());
        if (_shownItem != item.Id || _page != "annotations" || !_content.Children.Contains(list)) return;
        void Fill()
        {
            list.Children.Clear();
            var query = search.Text.Trim();
            _annotationQuery = search.Text;
            int total = 0;
            for (int f = 0; f < pdfs.Count; f++)
            {
                var file = pdfs[f];
                var matching = results[f].Where(a => query.Length == 0 || (a.Text ?? "").Contains(query, StringComparison.OrdinalIgnoreCase) || (a.Comment ?? "").Contains(query, StringComparison.OrdinalIgnoreCase)).ToList();
                if (matching.Count == 0) continue;
                var header = new Grid { Margin = new Thickness(0, 6, 0, 2) };
                header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                header.Children.Add(UI.Label(FileLabel.Title(file, pdfs, item.DefaultFileId), 11, secondary: true, bold: true));
                var read = new HyperlinkButton { Content = Loc.S("阅读"), Padding = new Thickness(4, 0, 4, 0), FontSize = 11 };
                read.Click += (_, _) => _model.OpenFile(file);
                SetColumn(read, 1);
                header.Children.Add(read);
                list.Children.Add(header);
                foreach (var a in matching)
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
                    list.Children.Add(open);
                }
            }
            if (total == 0)
            {
                var empty = new TextBlock { Text = query.Length == 0 ? Loc.S("没有标注") : Loc.S("没有匹配的标注"), FontSize = 13, Foreground = UI.Brush("FolioSecondaryTextBrush"), HorizontalAlignment = HorizontalAlignment.Center, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 40, 0, 0) };
                list.Children.Add(empty);
                if (query.Length == 0) list.Children.Add(new TextBlock { Text = Loc.S("在 Folio 阅读器或\"预览\"中添加的高亮和批注会显示在这里"), FontSize = 11, Foreground = UI.Brush("FolioSecondaryTextBrush"), TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap });
            }
        }
        search.TextChanged += (_, _) => Fill();
        Fill();
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
        var box = PlainBox(value ?? "", commit, 12, wrap: true);
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

    FrameworkElement EditableText(string value, Action<string> commit, double size, Windows.UI.Text.FontWeight weight, bool secondary = false, bool serif = false, bool multiline = false, bool wrap = false)
    {
        var box = PlainBox(value, commit, size, multiline || wrap || size >= 16, multiline);
        box.FontWeight = weight;
        if (serif) box.FontFamily = new FontFamily("Georgia, Cambria, Times New Roman, SimSun");
        if (secondary) box.Foreground = UI.Brush("FolioSecondaryTextBrush");
        return box;
    }

    /// <summary>A borderless text box that looks like a label until focused; commits on Enter or focus loss.</summary>
    static TextBox PlainBox(string value, Action<string> commit, double size, bool wrap = false, bool multiline = false)
    {
        var box = new TextBox
        {
            Text = value, FontSize = size, BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Padding = new Thickness(0, 4, 0, 4), MinHeight = 0, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, AcceptsReturn = multiline,
        };
        void Commit()
        {
            // Compared as stored: merely clicking through a multi-line field must not change the item.
            if (UI.Lf(box.Text) != UI.Lf(value)) { value = box.Text; commit(UI.Lf(box.Text).Trim()); }
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
        public readonly WrapPanel Panel = new() { HorizontalSpacing = 4, VerticalSpacing = 4 };
        public void Add(FrameworkElement e) => Panel.Children.Add(e);
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

    /// <summary>Another editor (a reader tab, an agent) changed the note; what is being typed here is not overwritten.</summary>
    public void Reload()
    {
        if (_itemId == null || _box.FocusState != FocusState.Unfocused || UI.Lf(_box.Text) != _saved) return;
        var current = _model.Library.Note(_itemId);
        if (current != _saved) { _saved = current; _box.Text = current; }
    }

    public void Show(string? itemId)
    {
        if (itemId == _itemId) { Reload(); return; }
        Save();
        _itemId = itemId;
        _box.IsEnabled = itemId != null;
        _saved = itemId == null ? "" : UI.Lf(_model.Library.Note(itemId));
        _box.Text = _saved;
        _title.Text = itemId != null && _model.Snapshot.Items.TryGetValue(itemId, out var item) ? item.Title : "";
    }

    public void Flush() => Save();

    public void FocusEditor() => _box.Focus(FocusState.Programmatic);

    /// <summary>Appends text (selected in the reader) as a quote.</summary>
    public void AppendQuote(string itemId, string quote, int page)
    {
        Show(itemId);
        var addition = Loc.S("%@\n> —— 第 %lld 页", "> " + quote.Replace("\n", "\n> "), page);
        var current = UI.Lf(_box.Text);
        _box.Text = (string.IsNullOrWhiteSpace(current) ? addition : current.TrimEnd() + "\n\n" + addition) + "\n";
        Save();
        _model.Toasts.Show(Loc.S("已添加到笔记"), "note");
    }

    void Save()
    {
        _save.Stop();
        var text = UI.Lf(_box.Text);
        if (_itemId == null || text == _saved) return;
        _saved = text;
        var id = _itemId;
        _model.Perform(() => _model.Library.SetNote(text, id));
    }
}
