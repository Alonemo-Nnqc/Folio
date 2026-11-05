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
        ("title", "标题", SortColumn.Title, 320), ("source", "来源", SortColumn.Source, 150), ("authors", "作者", SortColumn.Authors, 150),
        ("year", "年份", SortColumn.Year, 60), ("tags", "标签", SortColumn.Tags, 130), ("dateAdded", "添加日期", SortColumn.DateAdded, 110),
        ("dateModified", "修改日期", SortColumn.DateModified, 110), ("type", "类型", SortColumn.Type, 90), ("publisher", "出版社", SortColumn.Publisher, 130),
        ("doi", "DOI", SortColumn.Doi, 160), ("volume", "卷", SortColumn.Volume, 50), ("issue", "期", SortColumn.Issue, 50), ("pages", "页码", SortColumn.Pages, 70),
        ("readStatus", "状态", SortColumn.ReadStatus, 60), ("rating", "评分", SortColumn.Rating, 80), ("fileCount", "附件", SortColumn.FileCount, 50),
        ("citationKey", "引用键", SortColumn.CitationKey, 110),
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

    public void Apply(Grid grid)
    {
        grid.ColumnDefinitions.Clear();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        foreach (var key in Visible) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Width(key)) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
    }
}

/// <summary>Renders an ItemRowModel (bound as DataContext), column by column.</summary>
public sealed partial class ItemRow : Grid
{
    public static ItemList? Owner;

    public ItemRow()
    {
        MinHeight = 30;
        DataContextChanged += (_, _) => Render();
        DoubleTapped += (_, _) => { if (DataContext is ItemRowModel row) Owner?.Open(row); };
    }

    public void Render()
    {
        Children.Clear();
        if (DataContext is not ItemRowModel row || Owner is not { } owner) return;
        var model = owner.Model;
        var s = model.Snapshot;
        if (!s.Items.TryGetValue(row.ItemId, out var item)) return;
        owner.Columns.Apply(this);
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
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(18, 0, 0, 0) };
        panel.Children.Add(UI.Icon(file.IsPdf ? "pdf" : "document", 13, UI.Brush("FolioSecondaryTextBrush")));
        panel.Children.Add(UI.Label(FileLabel.Title(file, s.FilesOf(item.Id), item.DefaultFileId), 12));
        SetColumn(panel, 1);
        SetColumnSpan(panel, Math.Max(1, owner.Columns.Visible.Count));
        Children.Add(panel);
    }

    static FrameworkElement Cell(string key, Item item, LibrarySnapshot s, ItemList owner)
    {
        switch (key)
        {
            case "title":
                var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                var files = s.FilesOf(item.Id);
                string icon = item.Kind == ItemKind.Standalone ? (files.FirstOrDefault()?.IsPdf == true ? "pdf" : "document") : "document";
                panel.Children.Add(UI.Icon(icon, 14, UI.Brush("FolioSecondaryTextBrush")));
                var title = UI.Label(item.Title);
                if (item.Kind == ItemKind.Standalone && owner.Model.Importer.IsRetrieving(item.Id))
                    panel.Children.Add(new ProgressRing { Width = 12, Height = 12, IsActive = true });
                panel.Children.Add(title);
                if (owner.Model.Translations.JobOf(item.Id) != null) panel.Children.Add(new TranslationProgressView(owner.Model, item.Id));
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
        bool standalone = item.Kind == ItemKind.Standalone;
        string Dash(string? v) => string.IsNullOrEmpty(v) ? (standalone ? "—" : "") : v;
        return key switch
        {
            "source" => standalone ? "—" : item.Source ?? "",
            "authors" => standalone ? "—" : AuthorFormatter.ListDisplay(item.Authors),
            "year" => standalone ? "—" : item.Year?.ToString(CultureInfo.InvariantCulture) ?? "",
            "dateAdded" => item.DateAdded.ToLocalTime().ToString("yyyy/M/d", CultureInfo.InvariantCulture),
            "dateModified" => item.DateModified.ToLocalTime().ToString("yyyy/M/d", CultureInfo.InvariantCulture),
            "type" => standalone ? "" : item.Type.DisplayName(),
            "publisher" => Dash(item.Publisher),
            "doi" => Dash(item.Doi),
            "volume" => Dash(item.Volume),
            "issue" => Dash(item.Issue),
            "pages" => Dash(item.Pages),
            "readStatus" => standalone ? "" : item.ReadStatus.DisplayName(),
            "fileCount" => (s.FilesByItem.GetValueOrDefault(item.Id)?.Count ?? 0).ToString(),
            "citationKey" => item.CitationKey ?? "",
            _ => "",
        };
    }
}

/// <summary>The middle column: header with the view's name, toolbar and search; sortable columns; the rows.</summary>
public sealed partial class ItemList : Grid
{
    public const string DragFormat = "FolioItemIds";

    public AppModel Model { get; }
    public ColumnLayout Columns { get; }
    readonly ListView _list;
    readonly Grid _header;
    readonly TextBlock _scopeTitle;
    readonly TextBlock _scopeCount;
    readonly AutoSuggestBox _search;
    readonly ObservableCollection<ItemRowModel> _rows = [];
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
        var bar = new Grid { Padding = new Thickness(16, 8, 12, 8), ColumnSpacing = 4 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _scopeTitle = UI.Label("", 14, bold: true);
        _scopeCount = UI.Label("", 11, secondary: true);
        titles.Children.Add(_scopeTitle);
        titles.Children.Add(_scopeCount);
        bar.Children.Add(titles);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        var add = UI.IconButton("add", Loc.S("添加"), (_, _) => { });
        add.Flyout = AddMenu();
        actions.Children.Add(add);
        actions.Children.Add(UI.IconButton("reader", Loc.S("打开"), (_, _) => OpenSelection()));
        actions.Children.Add(UI.IconButton("translate", Loc.S("翻译"), (_, _) => Commands.Translate(model, Model.SelectedItemIds)));
        var share = UI.IconButton("share", Loc.S("引用与导出"), (_, _) => { });
        share.Flyout = new MenuFlyout();
        ((MenuFlyout)share.Flyout).Opening += (f, _) => Commands.FillCiteMenu(((MenuFlyout)f!).Items, model, Model.SelectedItemIds);
        actions.Children.Add(share);
        SetColumn(actions, 1);
        bar.Children.Add(actions);
        _search = new AutoSuggestBox { PlaceholderText = Loc.S("搜索文献"), QueryIcon = new SymbolIcon(Symbol.Find), Width = 260, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
        _search.TextChanged += (_, e) => { if (e.Reason == AutoSuggestionBoxTextChangeReason.UserInput) model.Search(_search.Text); };
        SetColumn(_search, 2);
        bar.Children.Add(_search);
        Children.Add(bar);

        _header = new Grid { Height = 28, Padding = new Thickness(12, 0, 12, 0), BorderBrush = UI.Brush("FolioSeparatorBrush"), BorderThickness = new Thickness(0, 0, 0, 1) };
        SetRow(_header, 1);
        Children.Add(_header);

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
        };
        _list.SelectionChanged += (_, _) =>
        {
            if (_syncing) return;
            Model.SetSelection(_list.SelectedItems.OfType<ItemRowModel>().Select(r => r.ItemId).Distinct().ToList());
        };
        _list.DragItemsStarting += (_, e) =>
        {
            var ids = e.Items.OfType<ItemRowModel>().Select(r => r.ItemId).Distinct().ToList();
            e.Data.Properties[DragFormat] = string.Join('\n', ids);
            e.Data.RequestedOperation = DataPackageOperation.Link | DataPackageOperation.Move;
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
        _list.DragOver += (_, e) =>
        {
            if (e.DataView.Contains(StandardDataFormats.StorageItems) && !e.DataView.Properties.ContainsKey(DragFormat))
            {
                e.AcceptedOperation = DataPackageOperation.Copy;
                e.DragUIOverride.Caption = Loc.S("添加到文献库");
            }
        };
        _list.Drop += async (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems) || e.DataView.Properties.ContainsKey(DragFormat)) return;
            var items = await e.DataView.GetStorageItemsAsync();
            var paths = items.Select(i => i.Path).ToList();
            // Files dropped onto an item's row attach to it; elsewhere they are imported into the current group.
            var target = (e.OriginalSource as FrameworkElement)?.DataContext as ItemRowModel;
            if (target != null && Model.Snapshot.Items.TryGetValue(target.ItemId, out var item) && item.Kind == ItemKind.Regular)
                await Model.Importer.AttachFiles(paths, target.ItemId);
            else await Model.Importer.ImportFiles(paths, Model.Scope.GroupId);
        };
        _list.RightTapped += OnRightTapped;
        _list.KeyDown += OnKeyDown;
        SetRow(_list, 2);
        Children.Add(_list);

        Columns.Changed += () => { BuildHeader(); RefreshRows(); };
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
        return style;
    }

    public void FocusSearch() => _search.Focus(FocusState.Keyboard);

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
            if (sort.Column == spec.Sort) content.Children.Add(UI.Icon(sort.Ascending ? "chevronDown" : "chevronDown", 8, UI.Brush("FolioSecondaryTextBrush")));
            if (sort.Column == spec.Sort && !sort.Ascending) content.Children[^1].RenderTransform = new RotateTransform { Angle = 180, CenterX = 4, CenterY = 4 };
            label.Content = content;
            label.Click += (_, _) => Model.Sort(spec.Sort, sort.Column == spec.Sort ? !sort.Ascending : true);
            cell.Children.Add(label);
            // Drag the right edge to resize.
            var grip = new Border { Width = 6, HorizontalAlignment = HorizontalAlignment.Right, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
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
        _header.RightTapped += (_, e) =>
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
            menu.ShowAt(_header, e.GetPosition(_header));
        };
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

    /// <summary>New rows (scope, search, sort or contents changed).</summary>
    void Reload()
    {
        UpdateTitle();
        BuildHeader();
        var selected = Model.SelectedItemIds.ToHashSet();
        _syncing = true;
        _rows.Clear();
        foreach (var id in Model.Rows)
        {
            bool expanded = _expanded.Contains(id);
            _rows.Add(new ItemRowModel(id, null, expanded));
            if (expanded)
                foreach (var file in Model.Snapshot.FilesOf(id)) _rows.Add(new ItemRowModel(id, file.Id, false));
        }
        foreach (var row in _rows.Where(r => r.FileId == null && selected.Contains(r.ItemId))) _list.SelectedItems.Add(row);
        _syncing = false;
        var still = _list.SelectedItems.OfType<ItemRowModel>().Select(r => r.ItemId).Distinct().ToList();
        if (!still.SequenceEqual(Model.SelectedItemIds)) Model.SetSelection(still);
    }

    /// <summary>Same rows, new data (a title changed, a tag was added): re-render the realized rows.</summary>
    void RefreshRows()
    {
        UpdateTitle();
        for (int i = 0; i < _rows.Count; i++)
            if (_list.ContainerFromIndex(i) is ListViewItem { ContentTemplateRoot: ItemRow row }) row.Render();
    }

    public void ToggleExpanded(string itemId)
    {
        if (!_expanded.Remove(itemId)) _expanded.Add(itemId);
        Reload();
    }

    void Reveal(string itemId)
    {
        var row = _rows.FirstOrDefault(r => r.ItemId == itemId && r.FileId == null);
        if (row == null) return;
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

    MenuFlyout AddMenu()
    {
        var menu = new MenuFlyout();
        menu.Items.Add(UI.Item(Loc.S("添加文件…"), () => _ = Commands.AddFiles(Model), "add"));
        menu.Items.Add(UI.Item(Loc.S("通过标识符添加…"), () => _ = IdentifierSheet.Show(Model), "link"));
        menu.Items.Add(UI.Item(Loc.S("导入 BibTeX / RIS…"), () => _ = Commands.ImportReferences(Model), "download"));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(UI.Item(Loc.S("从 Zotero 导入…"), () => _ = ZoteroImportSheet.Show(Model), "library"));
        return menu;
    }

    void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ids = Model.SelectedItemIds;
        switch (e.Key)
        {
            case VirtualKey.Delete when ids.Count > 0:
                if (Model.Scope is ViewScope.TrashScope) _ = Commands.PurgeItems(Model, ids);
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
            if (row.FileId != null && Model.Snapshot.Files.TryGetValue(row.FileId, out var file)) Commands.FillFileMenu(menu.Items, Model, file);
            else Commands.FillItemMenu(menu.Items, Model, Model.SelectedItemIds);
            menu.ShowAt(_list, e.GetPosition(_list));
            e.Handled = true;
        }
    }
}

static class KeyboardState
{
    public static bool Shift => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
    public static bool Ctrl => Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
}
