using System.Collections.ObjectModel;
using System.Globalization;
using Folio.Core;
using Folio.Core.Citation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace Folio.App;

/// <summary>A list row: an item, or (indented under an expanded item) one of its files.</summary>
public sealed record ItemRowModel(string ItemId, string? FileId, bool Expanded);

/// <summary>The list's columns, their widths and order (shared by the header and every row).</summary>
public sealed class ColumnLayout
{
    public static readonly (string Key, string Title, SortColumn Sort, double Width)[] Available =
    [
        ("title", "标题", SortColumn.Title, 300), ("source", "来源", SortColumn.Source, 140), ("authors", "作者", SortColumn.Authors, 150),
        ("year", "年份", SortColumn.Year, 56), ("tags", "标签", SortColumn.Tags, 130), ("dateAdded", "添加日期", SortColumn.DateAdded, 96),
        ("type", "类型", SortColumn.Type, 80), ("dateModified", "修改日期", SortColumn.DateModified, 96), ("doi", "DOI", SortColumn.Doi, 140), ("publisher", "出版社", SortColumn.Publisher, 140),
        ("volume", "卷", SortColumn.Volume, 56), ("issue", "期", SortColumn.Issue, 56), ("pages", "页码", SortColumn.Pages, 80),
        ("readStatus", "阅读状态", SortColumn.ReadStatus, 64), ("rating", "评分", SortColumn.Rating, 78), ("fileCount", "文件数", SortColumn.FileCount, 56),
        ("citationKey", "引用键", SortColumn.CitationKey, 140),
    ];

    readonly AppSettings _settings;
    public ColumnLayout(AppSettings settings) { _settings = settings; }

    public List<string> Visible => _settings.VisibleColumns.Where(k => Available.Any(a => a.Key == k)).ToList();
    public double Width(string key) => _settings.ColumnWidths.TryGetValue(key, out var w) ? w : Available.First(a => a.Key == key).Width;

    public event Action? Changed;

    public void SetWidth(string key, double width)
    {
        var widths = _settings.ColumnWidths;
        widths[key] = Math.Max(40, width);
        _settings.ColumnWidths = widths;
        Changed?.Invoke();
    }

    public void Toggle(string key)
    {
        var visible = Visible;
        if (visible.Contains(key)) { if (key != "title") visible.Remove(key); }
        else visible.Add(key);
        _settings.VisibleColumns = visible;
        Changed?.Invoke();
    }

    /// <summary>Changes with anything that moves the columns.</summary>
    public string Signature => string.Join(',', Visible.Select(k => $"{k}:{Width(k)}"));

    /// <summary>What the columns need at least; a narrower list scrolls sideways.</summary>
    public double MinimumWidth => 26 + Visible.Sum(k => k == "title" ? 160 : Width(k));

    public void Apply(Grid grid)
    {
        grid.ColumnDefinitions.Clear();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        // The title takes what the other columns leave, so the columns always fill the list.
        foreach (var key in Visible)
            grid.ColumnDefinitions.Add(key == "title"
                ? new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 160 }
                : new ColumnDefinition { Width = new GridLength(Width(key)) });
    }
}

/// <summary>Renders an ItemRowModel (bound as DataContext), column by column.</summary>
public sealed partial class ItemRow : Grid
{
    public static ItemList? Owner;

    string? _shown;

    public ItemRow()
    {
        MinHeight = 30;
        DataContextChanged += (_, _) => Render();
        DoubleTapped += (_, _) => { if (DataContext is ItemRowModel row) Owner?.Open(row); };
    }

    static string Signature(ItemRowModel row, Item item, LibrarySnapshot s, ItemList owner)
    {
        var text = new System.Text.StringBuilder();
        text.Append(row.FileId).Append('|').Append(row.Expanded).Append('|').Append(item.Title).Append('|').Append(item.Kind).Append('|').Append(owner.Columns.Signature).Append('|');
        if (row.FileId != null)
        {
            if (s.Files.TryGetValue(row.FileId, out var file)) text.Append(FileLabel.Title(file, s.FilesOf(item.Id), item.DefaultFileId));
            return text.ToString();
        }
        text.Append(s.FilesByItem.GetValueOrDefault(item.Id)?.Count ?? 0).Append('|').Append(item.Rating).Append('|');
        text.Append(owner.Model.Importer.IsRetrieving(item.Id)).Append('|').Append(owner.Model.Translations.JobOf(item.Id) != null).Append('|');
        foreach (var tag in s.TagsOf(item.Id)) text.Append(tag.Name).Append(tag.ColorHex).Append(',');
        foreach (var key in owner.Columns.Visible) text.Append('|').Append(Text(key, item, s));
        return text.ToString();
    }

    public void Render()
    {
        if (DataContext is not ItemRowModel row || Owner is not { } owner) { Children.Clear(); _shown = null; return; }
        var model = owner.Model;
        var s = model.Snapshot;
        if (!s.Items.TryGetValue(row.ItemId, out var item)) { Children.Clear(); _shown = null; return; }
        // Rebuilt only when what it shows changed: refreshes of the library never touch rows that stayed the same.
        var signature = Signature(row, item, s, owner);
        if (signature == _shown) return;
        _shown = signature;
        owner.Columns.Apply(this);
        Children.Clear();
        if (row.FileId != null)
        {
            RenderFile(owner, s, item, row.FileId);
            return;
        }
        var files = s.FilesOf(item.Id);
        if (files.Count > 0 && item.Kind == ItemKind.Regular)
        {
            var chevron = new Button
            {
                Content = UI.Icon(row.Expanded ? "chevronDown" : "chevronRight", 9),
                Padding = new Thickness(2), MinWidth = 18, MinHeight = 18, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
            };
            chevron.Click += (_, _) => owner.ToggleExpanded(item.Id);
            // Clicking it twice quickly is not opening the paper.
            chevron.DoubleTapped += (_, e) => e.Handled = true;
            Children.Add(chevron);
        }
        int column = 1;
        foreach (var key in owner.Columns.Visible)
        {
            var cell = Cell(key, item, s, owner);
            cell.Margin = new Thickness(column == 1 ? 0 : 8, 0, 4, 0);
            SetColumn(cell, column++);
            Children.Add(cell);
        }
    }

    void RenderFile(ItemList owner, LibrarySnapshot s, Item item, string fileId)
    {
        if (!s.Files.TryGetValue(fileId, out var file)) return;
        var panel = new Grid { ColumnSpacing = 6, Margin = new Thickness(18, 0, 0, 0) };
        panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        panel.Children.Add(UI.Icon(file.IsPdf ? "pdf" : "document", 13, UI.Brush("FolioSecondaryTextBrush")));
        var label = UI.Label(FileLabel.Title(file, s.FilesOf(item.Id), item.DefaultFileId), 12);
        Grid.SetColumn(label, 1);
        panel.Children.Add(label);
        SetColumn(panel, 1);
        SetColumnSpan(panel, Math.Max(1, owner.Columns.Visible.Count));
        Children.Add(panel);
    }

    static FrameworkElement Cell(string key, Item item, LibrarySnapshot s, ItemList owner)
    {
        switch (key)
        {
            case "title":
                // A grid, so the title is cut off with an ellipsis instead of being clipped.
                var panel = new Grid { ColumnSpacing = 8 };
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var files = s.FilesOf(item.Id);
                string icon = item.Kind == ItemKind.Standalone ? (files.FirstOrDefault()?.IsPdf == true ? "pdf" : "document") : "document";
                panel.Children.Add(UI.Icon(icon, 14, UI.Brush("FolioSecondaryTextBrush")));
                var title = UI.Label(item.Title);
                if (item.Kind == ItemKind.Standalone && owner.Model.Importer.IsRetrieving(item.Id))
                {
                    var ring = new ProgressRing { Width = 12, Height = 12, IsActive = true };
                    Grid.SetColumn(ring, 1);
                    panel.Children.Add(ring);
                }
                Grid.SetColumn(title, 2);
                panel.Children.Add(title);
                if (owner.Model.Translations.JobOf(item.Id) != null)
                {
                    var progress = new TranslationProgressView(owner.Model, item.Id);
                    Grid.SetColumn(progress, 3);
                    panel.Children.Add(progress);
                }
                return panel;
            case "tags":
                var tags = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
                var list = s.TagsOf(item.Id);
                foreach (var tag in list.Take(1)) tags.Children.Add(UI.Chip(tag.Name, tag.ColorHex));
                if (list.Count > 1) tags.Children.Add(UI.Chip($"+{list.Count - 1}", "#8E8E93"));
                return tags;
            case "rating":
                var stars = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 1 };
                for (int i = 1; i <= item.Rating; i++) stars.Children.Add(UI.Icon("starFill", 11, UI.Hex("#FF9500")));
                return stars;
            default:
                return UI.Label(Text(key, item, s), 13, secondary: key is "dateAdded" or "dateModified" or "fileCount" or "readStatus");
        }
    }

    public static string Text(string key, Item item, LibrarySnapshot s)
    {
        string Dash(string? v) => string.IsNullOrWhiteSpace(v) ? "—" : v;
        return key switch
        {
            "source" => Dash(item.Source),
            "authors" => Dash(AuthorFormatter.ListDisplay(item.Authors)),
            "year" => Dash(item.Year?.ToString(CultureInfo.InvariantCulture)),
            "dateAdded" => item.DateAdded.ToLocalTime().ToString("yyyy/MM/dd", CultureInfo.InvariantCulture),
            "dateModified" => item.DateModified.ToLocalTime().ToString("yyyy/MM/dd", CultureInfo.InvariantCulture),
            "type" => item.Kind == ItemKind.Standalone ? "—" : item.Type.DisplayName(),
            "publisher" => Dash(item.Publisher),
            "doi" => Dash(item.Doi),
            "volume" => Dash(item.Volume),
            "issue" => Dash(item.Issue),
            "pages" => Dash(item.Pages),
            "readStatus" => item.Kind == ItemKind.Standalone ? "—" : item.ReadStatus.DisplayName(),
            "fileCount" => (s.FilesByItem.GetValueOrDefault(item.Id)?.Count ?? 0).ToString(CultureInfo.InvariantCulture),
            "citationKey" => Dash(item.CitationKey),
            _ => "",
        };
    }
}

/// <summary>The middle column: header with the view's name, toolbar and search; sortable columns; the rows.</summary>
public sealed partial class ItemList : Grid
{
    public const string DragFormat = "FolioItemIds";

    /// <summary>A drag of the list's own rows (they also carry their files, for dropping into Explorer).</summary>
    public static bool IsInternalDrag(Windows.ApplicationModel.DataTransfer.DataPackageView view) => view.Properties.ContainsKey(DragFormat);

    public AppModel Model { get; }
    public ColumnLayout Columns { get; }
    readonly ListView _list;
    readonly Grid _header, _table;
    readonly ScrollViewer _tableScroller;
    readonly Border _insertionLine;
    readonly TextBlock _scopeTitle;
    readonly TextBlock _scopeCount;
    readonly AutoSuggestBox _search;
    readonly StackPanel _scopeBar;
    readonly SegmentedControl _scopeChoice;
    readonly TextBlock _scopeOnly;
    readonly TextBlock _emptyLabel;
    ObservableCollection<ItemRowModel> _rows = [];
    readonly HashSet<string> _expanded = [];
    bool _syncing;

    public ItemList(AppModel model)
    {
        Model = model;
        Columns = new ColumnLayout(model.Settings);
        ItemRow.Owner = this;
        Background = UI.Brush("FolioContentBrush");
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // Toolbar row: "所有文献 / 12 项" on the left, actions and search on the right (as in the macOS window).
        var bar = new Grid { Padding = new Thickness(16, 8, 12, 8), ColumnSpacing = 4, MinHeight = 48, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _scopeTitle = UI.Label("", 14, bold: true);
        _scopeCount = UI.Label("", 11, secondary: true);
        titles.Children.Add(_scopeTitle);
        titles.Children.Add(_scopeCount);
        bar.Children.Add(titles);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var add = UI.IconButton("add", Loc.S("添加"), (_, _) => { });
        add.Flyout = Commands.AddMenu(model);
        actions.Children.Add(add);
        actions.Children.Add(UI.IconButton("reader", Loc.S("打开"), (_, _) => OpenSelection()));
        actions.Children.Add(UI.IconButton("translate", Loc.S("翻译"), (_, _) => Commands.Translate(model, Model.SelectedItemIds)));
        var share = UI.IconButton("share", Loc.S("引用与导出"), (_, _) => { });
        share.Flyout = new MenuFlyout();
        ((MenuFlyout)share.Flyout).Opening += (f, _) => Commands.FillCiteMenu(((MenuFlyout)f!).Items, model, Model.SelectedItemIds);
        actions.Children.Add(share);
        SetColumn(actions, 1);
        bar.Children.Add(actions);
        _search = new AutoSuggestBox { PlaceholderText = Loc.S("搜索文献"), QueryIcon = new SymbolIcon(Symbol.Find), Width = 240, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        _search.TextChanged += (_, e) => { if (e.Reason != AutoSuggestionBoxTextChangeReason.ProgrammaticChange && _search.Text != model.SearchText) model.Search(_search.Text); };
        _search.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Escape && _search.Text.Length > 0)
            {
                _search.Text = "";
                model.Search("");
                e.Handled = true;
            }
        };
        SetColumn(_search, 2);
        bar.Children.Add(_search);
        Children.Add(bar);
        // The search box gives way first when the column is narrow, then the view's name.
        bar.SizeChanged += (_, e) => _search.Width = Math.Clamp(e.NewSize.Width - actions.ActualWidth - 120, 110, 240);

        // While searching: where to look (the macOS SearchScopeBar).
        _scopeBar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(16, 0, 12, 6), Visibility = Visibility.Collapsed };
        _scopeBar.Children.Add(UI.Label(Loc.S("搜索："), 12, secondary: true));
        _scopeOnly = UI.Label(Loc.S("所有文献"), 12);
        _scopeBar.Children.Add(_scopeOnly);
        _scopeChoice = new SegmentedControl([("current", ""), ("all", Loc.S("全部文献"))], "current", height: 22, padding: 10);
        _scopeChoice.Changed += key => { model.SearchWholeLibrary = key == "all"; model.ResolveRows(); };
        _scopeBar.Children.Add(_scopeChoice);
        var fulltext = new CheckBox { Content = Loc.S("包含 PDF 全文"), FontSize = 12, MinWidth = 0, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        fulltext.Click += (_, _) => model.SetFulltextSearch(fulltext.IsChecked == true);
        _scopeBar.Children.Add(fulltext);
        SetRow(_scopeBar, 1);
        Children.Add(_scopeBar);

        // The columns and rows scroll sideways together when they do not fit.
        _table = new Grid();
        _table.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _table.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _tableScroller = new ScrollViewer
        {
            Content = _table, HorizontalScrollMode = ScrollMode.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, ZoomMode = ZoomMode.Disabled,
            BringIntoViewOnFocusChange = false, // Focusing a row must not nudge the columns sideways.
        };
        SetRow(_tableScroller, 2);
        Children.Add(_tableScroller);
        _tableScroller.SizeChanged += (_, _) => FitTable();

        _header = new Grid { Height = 28, Padding = new Thickness(12, 0, 12, 0), BorderBrush = UI.Brush("FolioSeparatorBrush"), BorderThickness = new Thickness(0, 0, 0, 1) };
        _table.Children.Add(_header);
        _header.RightTapped += (_, e) => ShowColumnsMenu(e.GetPosition(_header));

        _list = new ListView
        {
            ItemsSource = _rows,
            ItemTemplate = (DataTemplate)Application.Current.Resources["ItemRowTemplate"],
            SelectionMode = ListViewSelectionMode.Extended,
            CanDragItems = true,
            AllowDrop = true,
            CanReorderItems = false,
            Padding = new Thickness(4, 2, 4, 8),
            ItemContainerStyle = RowStyle(),
            IsMultiSelectCheckBoxEnabled = false,
            // No entrance, add and reorder animations: rows are simply there.
            ItemContainerTransitions = [],
        };
        // The macOS list's grey selection; on the list itself so it holds in both themes.
        _list.Resources["ListViewItemBackgroundSelected"] = UI.Brush("RowSelectedBrush");
        _list.Resources["ListViewItemBackgroundSelectedPointerOver"] = UI.Brush("RowSelectedBrush");
        _list.Resources["ListViewItemBackgroundSelectedPressed"] = UI.Brush("PressedBrush");
        _list.Resources["ListViewItemBackgroundPointerOver"] = UI.Brush("HoverBrush");
        _list.Resources["ListViewItemBackgroundPressed"] = UI.Brush("PressedBrush");
        _list.SelectionChanged += (_, _) =>
        {
            if (_syncing) return;
            Model.SetSelection(_list.SelectedItems.OfType<ItemRowModel>().Select(r => r.ItemId).Distinct().ToList());
        };
        _list.DragItemsStarting += (_, e) =>
        {
            var ids = e.Items.OfType<ItemRowModel>().Select(r => r.ItemId).Distinct().ToList();
            e.Data.Properties[DragFormat] = string.Join('\n', ids);
            // Never Move: dragging into Explorer must copy, not take the file out of the library.
            e.Data.RequestedOperation = DataPackageOperation.Link | DataPackageOperation.Copy;
            // Dragging out to Explorer or another app carries the files.
            var paths = ids.SelectMany(id => Model.Snapshot.FilesOf(id)).Select(f => Model.Library.FilePath(f)).Where(File.Exists).ToList();
            if (paths.Count > 0)
                e.Data.SetDataProvider(StandardDataFormats.StorageItems, async request =>
                {
                    var deferral = request.GetDeferral();
                    var files = new List<Windows.Storage.IStorageItem>();
                    foreach (var p in paths) files.Add(await Windows.Storage.StorageFile.GetFileFromPathAsync(p));
                    request.SetData(files);
                    deferral.Complete();
                });
        };
        // Rows dragged within the list change the custom order; files from elsewhere are imported, wherever they land.
        _list.DragOver += (_, e) =>
        {
            if (e.DataView.Properties.ContainsKey(DragFormat))
            {
                bool canReorder = Model.SearchText.Trim().Length == 0 && Model.Scope is not ViewScope.TrashScope;
                e.AcceptedOperation = canReorder ? DataPackageOperation.Link : DataPackageOperation.None;
                if (canReorder)
                {
                    e.DragUIOverride.IsCaptionVisible = false;
                    ShowInsertion(e.GetPosition(_list));
                }
                e.Handled = true;
            }
            else if (e.DataView.Contains(StandardDataFormats.StorageItems) && Model.Scope is not ViewScope.TrashScope)
            {
                e.AcceptedOperation = DataPackageOperation.Copy;
                e.DragUIOverride.Caption = Loc.S("添加到文献库");
            }
        };
        _list.DragLeave += (_, _) => _insertionLine.Visibility = Visibility.Collapsed;
        _list.Drop += async (_, e) =>
        {
            _insertionLine.Visibility = Visibility.Collapsed;
            if (e.DataView.Properties.TryGetValue(DragFormat, out var raw) && raw is string joined)
            {
                e.Handled = true;
                if (Model.SearchText.Trim().Length > 0 || Model.Scope is ViewScope.TrashScope) return;
                var ids = joined.Split('\n', StringSplitOptions.RemoveEmptyEntries);
                int index = InsertionIndex(e.GetPosition(_list), out double unused);
                Model.Perform(() => Model.Library.MoveItems(ids, Model.Scope, Model.Rows, index));
                return;
            }
            if (!e.DataView.Contains(StandardDataFormats.StorageItems) || Model.Scope is ViewScope.TrashScope) return;
            e.Handled = true;
            var deferral = e.GetDeferral();
            try
            {
                var items = await e.DataView.GetStorageItemsAsync();
                deferral.Complete();
                await Model.Importer.ImportFiles(items.Select(i => i.Path).ToList(), Model.Scope.GroupId);
            }
            catch (Exception ex) { deferral.Complete(); Model.Toasts.Show(ex.Message, "warning"); }
        };
        _list.RightTapped += OnRightTapped;
        _list.KeyDown += OnKeyDown;
        _emptyLabel = UI.Label("", 14, secondary: true);
        _emptyLabel.HorizontalAlignment = HorizontalAlignment.Center;
        _emptyLabel.VerticalAlignment = VerticalAlignment.Center;
        _emptyLabel.TextAlignment = TextAlignment.Center;
        _emptyLabel.TextWrapping = TextWrapping.Wrap;
        _emptyLabel.IsHitTestVisible = false;
        SetRow(_emptyLabel, 2);
        SetRow(_list, 1);
        _table.Children.Add(_list);
        Children.Add(_emptyLabel);
        _insertionLine = new Border { Height = 2, Background = UI.Brush("FolioAccentBrush"), VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false, Visibility = Visibility.Collapsed };
        SetRow(_insertionLine, 1);
        _table.Children.Add(_insertionLine);

        Columns.Changed += () => { BuildHeader(); FitTable(); RefreshRows(); };
        model.RowsChanged += Reload;
        model.SnapshotChanged += RefreshRows;
        model.Translations.JobsChanged += RefreshRows;
        model.RevealRequested += Reveal;
        BuildHeader();
        Reload();
    }

    static Style RowStyle()
    {
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 30.0));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(8, 0, 8, 0)));
        // The selected row already shows where the keyboard is, as in the macOS list.
        style.Setters.Add(new Setter(Control.UseSystemFocusVisualsProperty, false));
        return style;
    }

    public void FocusSearch() => _search.Focus(FocusState.Keyboard);

    /// <summary>The table is as wide as the view, or as its columns need.</summary>
    void FitTable()
    {
        double width = _tableScroller.ActualWidth;
        if (width > 0) _table.Width = Math.Max(width, Columns.MinimumWidth + 32);
    }

    /// <summary>Where rows dropped at this point go, as a position among the items (attachments rows do not count).</summary>
    int InsertionIndex(Windows.Foundation.Point at, out double lineY)
    {
        lineY = 0;
        int row = _rows.Count;
        if (_list.ItemsPanelRoot is ItemsStackPanel panel && panel.FirstVisibleIndex >= 0)
        {
            for (int i = panel.FirstVisibleIndex; i <= panel.LastVisibleIndex && i < _rows.Count; i++)
            {
                if (_list.ContainerFromIndex(i) is not ListViewItem container) continue;
                double top = container.TransformToVisual(_list).TransformPoint(default).Y;
                lineY = top + container.ActualHeight;
                if (_rows[i].FileId != null) continue;
                if (at.Y < top + container.ActualHeight / 2) { row = i; lineY = top; break; }
            }
        }
        return _rows.Take(row).Count(r => r.FileId == null);
    }

    void ShowInsertion(Windows.Foundation.Point at)
    {
        InsertionIndex(at, out double y);
        _insertionLine.Margin = new Thickness(12, Math.Max(0, y - 1), 12, 0);
        _insertionLine.Visibility = Visibility.Visible;
    }

    // As if clicked: Programmatic would draw the keyboard ring whenever the last input happened to be a key.
    public void FocusList() => _list.Focus(FocusState.Pointer);

    void BuildHeader()
    {
        _header.Children.Clear();
        Columns.Apply(_header);
        var sort = Model.Snapshot.Sort(Model.Scope);
        int column = 1;
        foreach (var key in Columns.Visible)
        {
            var spec = ColumnLayout.Available.First(a => a.Key == key);
            var cell = new Grid();
            var label = new Button
            {
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
                Padding = new Thickness(column == 1 ? 0 : 8, 0, 4, 0), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            content.Children.Add(UI.Label(spec.Title == "DOI" ? "DOI" : Loc.S(spec.Title), 12, secondary: true));
            if (sort.Column == spec.Sort) content.Children.Add(UI.Icon(sort.Ascending ? "chevronUp" : "chevronDown", 8, UI.Brush("FolioSecondaryTextBrush")));
            label.Content = content;
            label.Click += (_, _) => Model.Sort(spec.Sort, sort.Column == spec.Sort ? !sort.Ascending : true);
            cell.Children.Add(label);
            // Drag the right edge to resize (the title takes whatever the others leave).
            if (key == "title") { SetColumn(cell, column++); _header.Children.Add(cell); continue; }
            var grip = new Border { Width = 8, HorizontalAlignment = HorizontalAlignment.Right, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
            UI.ResizeCursor(grip);
            var line = new Border { Width = 1, Margin = new Thickness(0, 6, 2, 6), HorizontalAlignment = HorizontalAlignment.Right, Background = UI.Brush("FolioSeparatorBrush") };
            cell.Children.Add(line);
            cell.Children.Add(grip);
            double startWidth = 0, startX = 0;
            bool dragging = false;
            grip.PointerPressed += (_, e) => { dragging = true; startWidth = Columns.Width(key); startX = e.GetCurrentPoint(this).Position.X; grip.CapturePointer(e.Pointer); e.Handled = true; };
            grip.PointerMoved += (_, e) =>
            {
                if (!dragging) return;
                var w = Math.Max(40, startWidth + e.GetCurrentPoint(this).Position.X - startX);
                _header.ColumnDefinitions[Grid.GetColumn(cell)].Width = new GridLength(w);
            };
            grip.PointerReleased += (_, e) =>
            {
                if (!dragging) return;
                dragging = false;
                grip.ReleasePointerCaptures();
                Columns.SetWidth(key, Math.Max(40, startWidth + e.GetCurrentPoint(this).Position.X - startX));
            };
            SetColumn(cell, column++);
            _header.Children.Add(cell);
        }
    }

    void ShowColumnsMenu(Windows.Foundation.Point at)
    {
        var menu = new MenuFlyout();
        foreach (var spec in ColumnLayout.Available)
        {
            var toggle = new ToggleMenuFlyoutItem { Text = spec.Title == "DOI" ? "DOI" : Loc.S(spec.Title), IsChecked = Columns.Visible.Contains(spec.Key), IsEnabled = spec.Key != "title" };
            toggle.Click += (_, _) => Columns.Toggle(spec.Key);
            menu.Items.Add(toggle);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(UI.Item(Loc.S("按自定义顺序排列"), () => Model.Sort(null, true)));
        menu.ShowAt(_header, at);
    }

    void UpdateScopeBar()
    {
        bool searching = Model.SearchText.Trim().Length > 0;
        _scopeBar.Visibility = searching ? Visibility.Visible : Visibility.Collapsed;
        // Searching 所有文献 already covers the whole library: nothing to choose.
        bool all = Model.Scope is ViewScope.AllScope;
        _scopeOnly.Visibility = all ? Visibility.Visible : Visibility.Collapsed;
        _scopeChoice.Visibility = all ? Visibility.Collapsed : Visibility.Visible;
        _scopeChoice.SetTitle("current", $"「{_scopeTitle.Text}」");
        _scopeChoice.Select(Model.SearchWholeLibrary ? "all" : "current");
    }

    void UpdateTitle()
    {
        var s = Model.Snapshot;
        _scopeTitle.Text = Model.Scope switch
        {
            ViewScope.AllScope => Loc.S("所有文献"),
            ViewScope.UnfiledScope => Loc.S("未分组"),
            ViewScope.TrashScope => Loc.S("回收站"),
            ViewScope.GroupScope g => s.GroupsById.GetValueOrDefault(g.Id)?.Name ?? "",
            ViewScope.TagScope t => s.TagsById.GetValueOrDefault(t.Id)?.Name ?? "",
            _ => "",
        };
        _scopeCount.Text = Loc.S("%lld 项", Model.Rows.Count);
    }

    string? _headerShown;

    /// <summary>New rows (scope, search, sort or contents changed). Only what changed is touched, so the list keeps its
    /// scroll position and selection when, say, a rating changes.</summary>
    void Reload()
    {
        UpdateTitle();
        UpdateScopeBar();
        // Search cleared from elsewhere (revealing an item).
        if (_search.Text != Model.SearchText) _search.Text = Model.SearchText;
        var sort = Model.Snapshot.Sort(Model.Scope);
        var headerKey = $"{sort.Column}|{sort.Ascending}|{string.Join(',', Columns.Visible)}";
        if (headerKey != _headerShown) { _headerShown = headerKey; BuildHeader(); }

        var wanted = new List<ItemRowModel>(Model.Rows.Count);
        foreach (var id in Model.Rows)
        {
            bool expanded = _expanded.Contains(id);
            wanted.Add(new ItemRowModel(id, null, expanded));
            if (expanded)
                foreach (var file in Model.Snapshot.FilesOf(id)) wanted.Add(new ItemRowModel(id, file.Id, false));
        }
        _syncing = true;
        var selected = Model.SelectedItemIds.ToHashSet();
        int prefix = 0, oldEnd = _rows.Count, newEnd = wanted.Count;
        while (prefix < oldEnd && prefix < newEnd && _rows[prefix] == wanted[prefix]) prefix++;
        while (oldEnd > prefix && newEnd > prefix && _rows[oldEnd - 1] == wanted[newEnd - 1]) { oldEnd--; newEnd--; }
        if (oldEnd - prefix + newEnd - prefix > 12)
        {
            // Another view: everything at once, not row by row.
            _rows = new ObservableCollection<ItemRowModel>(wanted);
            _list.ItemsSource = _rows;
            foreach (var row in wanted.Where(r => r.FileId == null && selected.Contains(r.ItemId))) _list.SelectedItems.Add(row);
        }
        else
        {
            for (int i = oldEnd - 1; i >= prefix; i--) _rows.RemoveAt(i);
            for (int i = prefix; i < newEnd; i++) _rows.Insert(i, wanted[i]);
            for (int i = prefix; i < newEnd; i++)
                if (wanted[i].FileId == null && selected.Contains(wanted[i].ItemId)) _list.SelectedItems.Add(wanted[i]);
        }
        _syncing = false;
        var still = _list.SelectedItems.OfType<ItemRowModel>().Select(r => r.ItemId).Distinct().ToList();
        if (!still.ToHashSet().SetEquals(Model.SelectedItemIds)) Model.SetSelection(still);
        UpdateEmptyLabel();
        if (_pendingReveal is { } pending && _rows.Any(r => r.ItemId == pending)) Reveal(pending);
    }

    void UpdateEmptyLabel()
    {
        if (_rows.Count > 0) { _emptyLabel.Visibility = Visibility.Collapsed; return; }
        _emptyLabel.Visibility = Visibility.Visible;
        _emptyLabel.Text = Model.SearchText.Trim().Length > 0 ? Loc.S("没有匹配的文献")
            : Model.Scope is ViewScope.TrashScope ? Loc.S("回收站是空的")
            : Model.Scope is ViewScope.AllScope ? Loc.S("把 PDF 拖到这里，或点击工具栏上的 + 添加文献")
            : Loc.S("这里还没有文献");
    }

    /// <summary>Same rows, new data (a title changed, a tag was added): re-render the realized rows.</summary>
    void RefreshRows()
    {
        UpdateTitle();
        // Only the rows that exist as controls: the list virtualizes the rest, and they render when they appear.
        if (_list.ItemsPanelRoot is ItemsStackPanel panel && panel.FirstCacheIndex >= 0)
        {
            for (int i = panel.FirstCacheIndex; i <= panel.LastCacheIndex && i < _rows.Count; i++)
                if (_list.ContainerFromIndex(i) is ListViewItem { ContentTemplateRoot: ItemRow row }) row.Render();
        }
    }

    public void ToggleExpanded(string itemId)
    {
        if (!_expanded.Remove(itemId)) _expanded.Add(itemId);
        Reload();
    }

    string? _pendingReveal;

    void Reveal(string itemId)
    {
        var row = _rows.FirstOrDefault(r => r.ItemId == itemId && r.FileId == null);
        // A new item's row appears with the next refresh.
        if (row == null) { _pendingReveal = itemId; return; }
        _pendingReveal = null;
        _list.SelectedItems.Clear();
        _list.SelectedItem = row;
        _list.ScrollIntoView(row, ScrollIntoViewAlignment.Default);
    }

    public void Open(ItemRowModel row)
    {
        if (row.FileId != null && Model.Snapshot.Files.TryGetValue(row.FileId, out var file)) Model.OpenFile(file);
        else Model.OpenItem(row.ItemId);
    }

    void OpenSelection()
    {
        foreach (var id in Model.SelectedItemIds.Take(10)) Model.OpenItem(id);
    }

    void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ids = Model.SelectedItemIds;
        switch (e.Key)
        {
            case VirtualKey.Delete when ids.Count > 0:
                // A selected attachment row removes that file only, as in the macOS list.
                if (_list.SelectedItems.Count == 1 && _list.SelectedItem is ItemRowModel { FileId: { } fileId } && Model.Scope is not ViewScope.TrashScope)
                    Model.Perform(() => Model.Library.TrashFiles([fileId]));
                else if (Model.Scope is ViewScope.TrashScope) Commands.PurgeItems(Model, ids).Fire();
                else if (Model.Scope is ViewScope.GroupScope g && !KeyboardState.Shift) Model.Perform(() => Model.Library.RemoveItems(ids, g.Id, Model.Settings.IncludeSubgroupItems));
                else Model.TrashItems(ids);
                e.Handled = true;
                break;
            case VirtualKey.Enter:
                OpenSelection();
                e.Handled = true;
                break;
            case VirtualKey.Right:
                foreach (var id in ids) _expanded.Add(id);
                Reload();
                e.Handled = true;
                break;
            case VirtualKey.Left:
                foreach (var id in ids) _expanded.Remove(id);
                Reload();
                e.Handled = true;
                break;
        }
    }

    void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is ItemRowModel row)
        {
            if (!_list.SelectedItems.Contains(row))
            {
                _list.SelectedItems.Clear();
                _list.SelectedItem = row;
            }
            var menu = new MenuFlyout();
            if (row.FileId != null && Model.Scope is not ViewScope.TrashScope && Model.Snapshot.Files.TryGetValue(row.FileId, out var file)) Commands.FillFileMenu(menu.Items, Model, file);
            else Commands.FillItemMenu(menu.Items, Model, Model.SelectedItemIds);
            if (menu.Items.Count > 0) menu.ShowAt(_list, e.GetPosition(_list));
            e.Handled = true;
        }
    }
}

static class KeyboardState
{
    public static bool Shift => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
    public static bool Ctrl => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
}
