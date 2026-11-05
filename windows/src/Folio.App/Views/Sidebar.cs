using Folio.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Folio.App;

/// <summary>One row of the sidebar: a section header, a built-in view, a group or a tag.</summary>
public sealed record SidebarEntry
{
    public enum Kind { Header, Builtin, Group, Tag }
    public Kind EntryKind { get; init; }
    public string Title { get; init; } = "";
    public ViewScope? Scope { get; init; }
    public string Icon { get; init; } = "folder";
    public string? ColorHex { get; init; }
    public int Count { get; init; }
    public int Depth { get; init; }
    public bool HasChildren { get; init; }
    public bool Expanded { get; init; }
    public string? HeaderId { get; init; }
}

/// <summary>One row of the sidebar. All rows share one grid: disclosure, icon, title, count, so icons line up.</summary>
public sealed partial class SidebarRow : Grid
{
    readonly SidebarView _owner;
    bool _hover, _dropTarget;
    SidebarView.DropZone _zone;
    FontIcon? _sectionChevron;
    public SidebarEntry Entry { get; private set; }
    public bool IsCurrent { get; private set; }

    public SidebarRow(SidebarView owner, SidebarEntry entry, bool current)
    {
        _owner = owner;
        Entry = entry;
        IsCurrent = current;
        AllowDrop = true;
        CanDrag = entry.EntryKind == SidebarEntry.Kind.Group;
        CornerRadius = new CornerRadius(6);
        DragLeave += (_, _) => ShowDrop(SidebarView.DropZone.None);
        DragOver += (_, e) => ShowDrop(_owner.OnRowDragOver(Entry, this, e));
        Drop += (_, e) => { var zone = _zone; ShowDrop(SidebarView.DropZone.None); _owner.OnRowDrop(Entry, zone, e); };
        DragStarting += (_, e) =>
        {
            if (Entry is { EntryKind: SidebarEntry.Kind.Group, Scope: { GroupId: { } id } })
            {
                e.Data.Properties[SidebarView.GroupDragFormat] = id;
                e.Data.RequestedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Link;
            }
            else e.Cancel = true;
        };
        PointerEntered += (_, _) => { _hover = true; Paint(); };
        PointerExited += (_, _) => { _hover = false; Paint(); };
        PointerCanceled += (_, _) => { _hover = false; Paint(); };
        Tapped += (_, _) => _owner.RowTapped(Entry);
        RightTapped += (_, e) => _owner.ShowMenu(Entry, this, e);
        Render();
    }

    public void Update(SidebarEntry entry, bool current)
    {
        bool same = entry == Entry;
        Entry = entry;
        IsCurrent = current;
        CanDrag = entry.EntryKind == SidebarEntry.Kind.Group;
        if (same) Paint(); else Render();
    }

    /// <summary>On a row: filled; between rows: a line at its edge.</summary>
    void ShowDrop(SidebarView.DropZone zone)
    {
        if (zone == _zone) return;
        _zone = zone;
        _dropTarget = zone == SidebarView.DropZone.On;
        BorderBrush = UI.Brush("FolioAccentBrush");
        BorderThickness = new Thickness(0, zone == SidebarView.DropZone.Before ? 2 : 0, 0, zone == SidebarView.DropZone.After ? 2 : 0);
        Paint();
    }

    void Paint()
    {
        if (_sectionChevron != null) _sectionChevron.Opacity = Entry.Expanded && !_hover ? 0 : 1;
        Background = UI.Brush(Entry.EntryKind == SidebarEntry.Kind.Header ? "TransparentBrush"
            : _dropTarget ? "PressedBrush" : IsCurrent ? "RowSelectedBrush" : _hover ? "HoverBrush" : "TransparentBrush");
    }

    void Render()
    {
        var entry = Entry;
        Children.Clear();
        ColumnDefinitions.Clear();
        ColumnSpacing = 0;
        _sectionChevron = null;
        if (entry.EntryKind == SidebarEntry.Kind.Header) RenderHeader(entry);
        else RenderRow(entry);
        Paint();
    }

    void RenderHeader(SidebarEntry entry)
    {
        Height = 30;
        Margin = new Thickness(0, entry.HeaderId == "library" ? 2 : 10, 0, 0);
        Padding = new Thickness(8, 0, 2, 0);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(UI.Label(entry.Title, 11.5, secondary: true, bold: true));
        var chevron = UI.Icon(entry.Expanded ? "chevronDown" : "chevronRight", 8, UI.Brush("FolioSecondaryTextBrush"));
        chevron.VerticalAlignment = VerticalAlignment.Center;
        // Like macOS's Show/Hide: only when it can be noticed without cluttering the list.
        chevron.Opacity = entry.Expanded && !_hover ? 0 : 1;
        _sectionChevron = chevron;
        title.Children.Add(chevron);
        Children.Add(title);
        var add = _owner.HeaderAddButton(entry);
        if (add != null)
        {
            SetColumn(add, 1);
            Children.Add(add);
        }
    }

    void RenderRow(SidebarEntry entry)
    {
        Height = 30;
        Margin = new Thickness(0, 1, 0, 1);
        Padding = new Thickness(2, 0, 8, 0);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18 + entry.Depth * 16) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (entry.EntryKind == SidebarEntry.Kind.Group && entry.HasChildren)
        {
            var chevron = UI.IconButton(entry.Expanded ? "chevronDown" : "chevronRight", entry.Expanded ? Loc.S("折叠") : Loc.S("展开"), (_, _) => _owner.ToggleExpanded(entry), 8);
            chevron.Width = chevron.Height = 18;
            // Unfolds without choosing the group.
            chevron.Tapped += (_, e) => e.Handled = true;
            chevron.HorizontalAlignment = HorizontalAlignment.Left;
            Children.Add(chevron);
        }
        FrameworkElement icon = entry.EntryKind == SidebarEntry.Kind.Tag
            ? UI.Dot(entry.ColorHex ?? TagPalette.ImportDefault, 12)
            : UI.Icon(entry.Icon, 15, entry.ColorHex != null ? UI.Hex(entry.ColorHex) : UI.Brush("FolioAccentBrush"));
        icon.HorizontalAlignment = HorizontalAlignment.Left;
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(entry.EntryKind == SidebarEntry.Kind.Tag ? 1.5 : 0, 0, 0, 0);
        SetColumn(icon, 1);
        Children.Add(icon);
        var title = UI.Label(entry.Title, 13);
        title.Margin = new Thickness(2, 0, 4, 0);
        SetColumn(title, 2);
        Children.Add(title);
        var count = UI.Label(entry.Count > 0 ? entry.Count.ToString() : "", 12, secondary: true);
        SetColumn(count, 3);
        Children.Add(count);
    }
}

/// <summary>The sidebar: library views, two-level groups and tags (the macOS SidebarController). Each section header has
/// its + button; clicking a header folds its section.</summary>
public sealed class SidebarView : UserControl
{
    readonly AppModel _model;
    readonly StackPanel _rows = new() { Padding = new Thickness(8, 4, 8, 12) };
    readonly List<SidebarRow> _shown = [];
    readonly HashSet<string> _collapsed = [];
    readonly HashSet<string> _foldedSections = [];

    public SidebarView(AppModel model)
    {
        _model = model;
        Background = UI.Brush("FolioSidebarBrush");
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        Content = new ScrollViewer { Content = _rows, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        KeyDown += OnKeyDown;
        // A right click on the free part below the rows.
        RightTapped += (_, e) => { if (!e.Handled) ShowMenu(null, this, e); };
        model.SnapshotChanged += Rebuild;
        model.RowsChanged += SyncSelection;
        Rebuild();
    }

    /// <summary>The + of a section header.</summary>
    public Button? HeaderAddButton(SidebarEntry header)
    {
        Button Make(string tip, RoutedEventHandler click)
        {
            var b = UI.IconButton("add", tip, click, 11);
            b.Width = b.Height = 24;
            b.CornerRadius = new CornerRadius(5);
            b.Foreground = UI.Brush("FolioSecondaryTextBrush");
            // The click is the button's, not the header's (which folds the section).
            b.Tapped += (_, e) => e.Handled = true;
            return b;
        }
        switch (header.HeaderId)
        {
            case "library":
                var add = Make(Loc.S("添加文献"), (_, _) => { });
                add.Flyout = Commands.AddMenu(_model);
                return add;
            case "groups":
                return Make(Loc.S("新建分组"), (_, _) => NewGroup(null).Fire());
            case "tags":
                return Make(Loc.S("新建标签"), (_, _) => TagEditor.Create(_model).Fire());
            default:
                return null;
        }
    }

    public void ToggleExpanded(SidebarEntry entry)
    {
        if (entry.Scope?.GroupId is not { } id) return;
        if (!_collapsed.Remove(id)) _collapsed.Add(id);
        Rebuild();
    }

    public void RowTapped(SidebarEntry entry)
    {
        Focus(FocusState.Programmatic);
        if (entry.EntryKind == SidebarEntry.Kind.Header)
        {
            if (!_foldedSections.Remove(entry.HeaderId!)) _foldedSections.Add(entry.HeaderId!);
            Rebuild();
        }
        else if (entry.Scope is { } scope) _model.SelectScope(scope);
    }

    void Rebuild()
    {
        var s = _model.Snapshot;
        var c = _model.Counts;
        var entries = new List<SidebarEntry>();
        void Section(string id, string title, Action rows)
        {
            bool open = !_foldedSections.Contains(id);
            entries.Add(new() { EntryKind = SidebarEntry.Kind.Header, Title = title, HeaderId = id, Expanded = open });
            if (open) rows();
        }
        Section("library", Loc.S("文献库"), () =>
        {
            entries.Add(new() { EntryKind = SidebarEntry.Kind.Builtin, Title = Loc.S("所有文献"), Scope = ViewScope.All, Icon = "all", Count = c.GetValueOrDefault("all") });
            entries.Add(new() { EntryKind = SidebarEntry.Kind.Builtin, Title = Loc.S("未分组"), Scope = ViewScope.Unfiled, Icon = "unfiled", Count = c.GetValueOrDefault("unfiled") });
            entries.Add(new() { EntryKind = SidebarEntry.Kind.Builtin, Title = Loc.S("回收站"), Scope = ViewScope.Trash, Icon = "trash", Count = c.GetValueOrDefault("trash") });
        });
        Section("groups", Loc.S("分组"), () =>
        {
            foreach (var id in s.TopLevelGroups)
            {
                var g = s.GroupsById[id];
                var children = s.ChildGroups.GetValueOrDefault(id) ?? [];
                bool expanded = !_collapsed.Contains(id);
                entries.Add(new() { EntryKind = SidebarEntry.Kind.Group, Title = g.Name, Scope = ViewScope.Group(id), ColorHex = g.ColorHex, Count = c.GetValueOrDefault($"group:{id}"), HasChildren = children.Count > 0, Expanded = expanded, Icon = "folder" });
                if (!expanded) continue;
                foreach (var child in children)
                {
                    var cg = s.GroupsById[child];
                    entries.Add(new() { EntryKind = SidebarEntry.Kind.Group, Title = cg.Name, Scope = ViewScope.Group(child), ColorHex = cg.ColorHex, Count = c.GetValueOrDefault($"group:{child}"), Depth = 1, Icon = "folder" });
                }
            }
        });
        Section("tags", Loc.S("标签"), () =>
        {
            foreach (var tag in s.Tags)
                entries.Add(new() { EntryKind = SidebarEntry.Kind.Tag, Title = tag.Name, Scope = ViewScope.TagOf(tag.Id), ColorHex = tag.ColorHex, Count = c.GetValueOrDefault($"tag:{tag.Id}") });
        });
        // Only what changed is touched: the scroll position stays and nothing flickers.
        for (int i = 0; i < entries.Count; i++)
        {
            bool current = entries[i].Scope is { } scope && scope == _model.Scope;
            if (i < _shown.Count) _shown[i].Update(entries[i], current);
            else
            {
                var row = new SidebarRow(this, entries[i], current);
                _shown.Add(row);
                _rows.Children.Add(row);
            }
        }
        while (_shown.Count > entries.Count)
        {
            _rows.Children.RemoveAt(_rows.Children.Count - 1);
            _shown.RemoveAt(_shown.Count - 1);
        }
    }

    void SyncSelection()
    {
        foreach (var row in _shown) row.Update(row.Entry, row.Entry.Scope is { } scope && scope == _model.Scope);
    }

    void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key is not (Windows.System.VirtualKey.Up or Windows.System.VirtualKey.Down)) return;
        var selectable = _shown.Where(r => r.Entry.Scope != null).ToList();
        int index = selectable.FindIndex(r => r.IsCurrent);
        int next = Math.Clamp(index + (e.Key == Windows.System.VirtualKey.Down ? 1 : -1), 0, selectable.Count - 1);
        if (selectable.Count > 0 && next != index)
        {
            _model.SelectScope(selectable[next].Entry.Scope!);
            selectable[next].StartBringIntoView();
        }
        e.Handled = true;
    }

    // MARK: Context menus

    public void ShowMenu(SidebarEntry? entry, FrameworkElement anchor, RightTappedRoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        switch (entry)
        {
            case { EntryKind: SidebarEntry.Kind.Group, Scope: { GroupId: { } groupId } }:
                var group = _model.Snapshot.GroupsById[groupId];
                if (group.ParentId == null) menu.Items.Add(UI.Item(Loc.S("新建子分组…"), () => NewGroup(groupId).Fire(), "add"));
                menu.Items.Add(UI.Item(Loc.S("重命名…"), () => RenameGroup(group).Fire(), "edit"));
                menu.Items.Add(ColorMenu(group));
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(UI.Item(Loc.S("删除分组…"), () => DeleteGroup(group).Fire(), "delete"));
                break;
            case { EntryKind: SidebarEntry.Kind.Tag, Scope: { TagId: { } tagId } }:
                var tag = _model.Snapshot.TagsById[tagId];
                menu.Items.Add(UI.Item(Loc.S("编辑标签…"), () => TagEditor.Edit(_model, tag).Fire(), "edit"));
                menu.Items.Add(UI.Item(Loc.S("删除标签…"), () => DeleteTag(tag).Fire(), "delete"));
                break;
            case { EntryKind: SidebarEntry.Kind.Builtin, Scope: ViewScope.TrashScope }:
                menu.Items.Add(UI.Item(Loc.S("清空回收站…"), () => EmptyTrash().Fire(), "delete", _model.Counts.GetValueOrDefault("trash") > 0));
                break;
            default:
                menu.Items.Add(UI.Item(Loc.S("新建分组…"), () => NewGroup(null).Fire(), "add"));
                menu.Items.Add(UI.Item(Loc.S("新建标签…"), () => TagEditor.Create(_model).Fire(), "tag"));
                break;
        }
        menu.ShowAt(anchor, e.GetPosition(anchor));
        e.Handled = true;
    }

    MenuFlyoutSubItem ColorMenu(LibraryGroup group)
    {
        var sub = new MenuFlyoutSubItem { Text = Loc.S("颜色"), Icon = UI.Icon("folder", 14) };
        sub.Items.Add(UI.Item(Loc.S("默认"), () => _model.Perform(() => _model.Library.SetGroupColor(group.Id, null))));
        foreach (var (name, hex) in TagPalette.Presets)
        {
            var item = new MenuFlyoutItem { Text = Loc.S(name), Icon = new FontIcon { Glyph = "", FontFamily = UI.IconFont, Foreground = UI.Hex(hex) } };
            item.Click += (_, _) => _model.Perform(() => _model.Library.SetGroupColor(group.Id, hex));
            sub.Items.Add(item);
        }
        return sub;
    }

    public async Task NewGroup(string? parentId)
    {
        if (await GroupEditor.Create(_model, parentId) is { } group) _model.SelectScope(ViewScope.Group(group.Id));
    }

    async Task RenameGroup(LibraryGroup group)
    {
        var name = await Dialogs.Ask(Loc.S("重命名分组"), Loc.S("分组名称"), group.Name, Loc.S("重命名"));
        if (!string.IsNullOrWhiteSpace(name) && name != group.Name) _model.Perform(() => _model.Library.RenameGroup(group.Id, name));
    }

    async Task DeleteGroup(LibraryGroup group)
    {
        var choice = await Dialogs.Choose(Loc.S("删除分组「%@」？", group.Name), Loc.S("分组中的文献会保留在文献库中，也可以一并移到回收站。"),
                                          Loc.S("删除分组"), Loc.S("删除分组并将文献移到回收站"), Loc.S("取消"));
        if (choice == ContentDialogResult.None) return;
        _model.Perform(() => _model.Library.DeleteGroup(group.Id, trashItems: choice == ContentDialogResult.Secondary));
    }

    async Task DeleteTag(Tag tag)
    {
        int count = _model.Library.ItemCount(tag.Id);
        if (await Dialogs.Confirm(Loc.S("删除标签「%@」？", tag.Name), Loc.S("%lld 篇文献会失去这个标签，文献本身不受影响。", count), Loc.S("删除"), Loc.S("取消"), destructive: true))
            _model.Perform(() => _model.Library.DeleteTag(tag.Id));
    }

    async Task EmptyTrash()
    {
        if (await Dialogs.Confirm(Loc.S("清空回收站？"), Loc.S("回收站中的文献和文件将被永久删除，无法恢复。"), Loc.S("清空回收站"), Loc.S("取消"), destructive: true))
            _model.Perform(_model.Library.EmptyTrash);
    }

    // MARK: Drag and drop: items onto groups, tags and the trash; files onto groups or the library.

    public const string GroupDragFormat = "FolioGroupId";

    public enum DropZone { None, Before, On, After }

    /// <summary>A group dragged here: where it would go (the macOS SidebarDragRules). Null when it cannot.</summary>
    (string? Parent, int Index, bool Nest)? GroupDrop(string id, SidebarEntry entry, DropZone zone)
    {
        var s = _model.Snapshot;
        if (!s.GroupsById.ContainsKey(id)) return null;
        bool hasChildren = (s.ChildGroups.GetValueOrDefault(id) ?? []).Count > 0;
        if (entry is { EntryKind: SidebarEntry.Kind.Header, HeaderId: "groups" }) return (null, s.TopLevelGroups.Count(g => g != id), false);
        if (entry is not { EntryKind: SidebarEntry.Kind.Group, Scope: { GroupId: { } target } } || target == id) return null;
        var parent = s.GroupsById[target].ParentId;
        if (zone == DropZone.On)
            return parent == null && !hasChildren ? (target, (s.ChildGroups.GetValueOrDefault(target) ?? []).Count(g => g != id), true) : null;
        if (parent != null && (hasChildren || parent == id)) return null;
        var siblings = (parent == null ? s.TopLevelGroups : s.ChildGroups.GetValueOrDefault(parent) ?? []).Where(g => g != id).ToList();
        return (parent, siblings.IndexOf(target) + (zone == DropZone.After ? 1 : 0), false);
    }

    public DropZone OnRowDragOver(SidebarEntry entry, FrameworkElement row, DragEventArgs e)
    {
        e.Handled = true;
        if (e.DataView.Properties.TryGetValue(GroupDragFormat, out var dragged) && dragged is string groupId)
        {
            double y = e.GetPosition(row).Y, h = row.ActualHeight;
            var zone = entry.EntryKind == SidebarEntry.Kind.Header ? DropZone.On : y < h * 0.28 ? DropZone.Before : y > h * 0.72 ? DropZone.After : DropZone.On;
            if (GroupDrop(groupId, entry, zone) == null) return DropZone.None;
            e.AcceptedOperation = DataPackageOperation.Link;
            e.DragUIOverride.IsCaptionVisible = false;
            return zone;
        }
        if (entry.Scope is not { } scope) return DropZone.None;
        bool items = e.DataView.Properties.ContainsKey(ItemList.DragFormat);
        bool files = e.DataView.Contains(StandardDataFormats.StorageItems);
        if (items && _model.Scope is not ViewScope.TrashScope && scope != _model.Scope && scope is ViewScope.GroupScope or ViewScope.TagScope or ViewScope.TrashScope)
        {
            e.AcceptedOperation = DataPackageOperation.Link;
            e.DragUIOverride.IsCaptionVisible = false;
        }
        else if (!items && files && scope is ViewScope.GroupScope or ViewScope.AllScope or ViewScope.UnfiledScope)
            e.AcceptedOperation = DataPackageOperation.Copy;
        else return DropZone.None;
        return DropZone.On;
    }

    public async void OnRowDrop(SidebarEntry entry, DropZone zone, DragEventArgs e)
    {
        e.Handled = true;
        if (e.DataView.Properties.TryGetValue(GroupDragFormat, out var dragged) && dragged is string groupId)
        {
            if (GroupDrop(groupId, entry, zone) is { } move) _model.Perform(() => _model.Library.MoveGroup(groupId, move.Parent, move.Index));
            return;
        }
        if (entry.Scope is not { } scope) return;
        if (e.DataView.Properties.TryGetValue(ItemList.DragFormat, out var raw) && raw is string joined)
        {
            var ids = joined.Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();
            switch (scope)
            {
                case ViewScope.GroupScope g:
                    _model.Perform(() =>
                    {
                        var result = _model.Library.AddItems(ids, g.Id, _model.Settings.IncludeSubgroupItems);
                        var name = _model.Snapshot.GroupsById[g.Id].Name;
                        if (result.Added.Count > 0) _model.Toasts.Show(Loc.S("已将 %lld 篇文献加入「%@」", result.Added.Count, name), "folder");
                        else _model.Toasts.Show(Loc.S("所选文献已在「%@」中", name), "folder");
                    });
                    break;
                case ViewScope.TagScope t:
                    _model.Perform(() => _model.Library.SetTag(t.Id, ids, true));
                    break;
                case ViewScope.TrashScope:
                    _model.TrashItems(ids);
                    break;
            }
        }
        else if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            var deferral = e.GetDeferral();
            try
            {
                var items = await e.DataView.GetStorageItemsAsync();
                deferral.Complete();
                await _model.Importer.ImportFiles(items.Select(i => i.Path).ToList(), scope.GroupId);
            }
            catch (Exception ex) { deferral.Complete(); _model.Toasts.Show(ex.Message, "warning"); }
        }
    }
}
