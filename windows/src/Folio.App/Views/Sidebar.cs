using System.Collections.ObjectModel;
using Folio.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Folio.App;

/// <summary>One row of the sidebar: a section header, a built-in view, a group or a tag.</summary>
public sealed class SidebarEntry
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

/// <summary>Renders a SidebarEntry (bound as DataContext).</summary>
public sealed partial class SidebarRow : Grid
{
    public static SidebarView? Owner;

    public SidebarRow()
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        MinHeight = 30;
        DataContextChanged += (_, _) => Render();
        AllowDrop = true;
        DragOver += (_, e) => Owner?.OnRowDragOver(DataContext as SidebarEntry, e);
        Drop += (_, e) => Owner?.OnRowDrop(DataContext as SidebarEntry, e);
    }

    void Render()
    {
        Children.Clear();
        if (DataContext is not SidebarEntry entry) return;
        if (entry.EntryKind == SidebarEntry.Kind.Header)
        {
            var header = UI.Label(entry.Title, 11, secondary: true, bold: true);
            header.Margin = new Thickness(4, 10, 0, 2);
            SetColumnSpan(header, 3);
            Children.Add(header);
            return;
        }
        var lead = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(entry.Depth * 18, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        if (entry.EntryKind == SidebarEntry.Kind.Group)
        {
            var chevron = new Button
            {
                Content = UI.Icon(entry.Expanded ? "chevronDown" : "chevronRight", 9),
                Padding = new Thickness(2), MinWidth = 16, MinHeight = 16, Width = 16,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0),
                Visibility = entry.HasChildren ? Visibility.Visible : Visibility.Collapsed,
            };
            chevron.Click += (_, _) => Owner?.ToggleExpanded(entry);
            lead.Children.Add(entry.HasChildren ? chevron : new Border { Width = 16 });
        }
        if (entry.EntryKind == SidebarEntry.Kind.Tag) lead.Children.Add(UI.Dot(entry.ColorHex ?? TagPalette.ImportDefault, 13));
        else lead.Children.Add(UI.Icon(entry.Icon, 16, entry.ColorHex != null ? UI.Hex(entry.ColorHex) : UI.Brush("FolioAccentBrush")));
        Children.Add(lead);
        var title = UI.Label(entry.Title, 13);
        title.Margin = new Thickness(8, 0, 4, 0);
        SetColumn(title, 1);
        Children.Add(title);
        var count = UI.Label(entry.Count.ToString(), 12, secondary: true);
        count.Margin = new Thickness(4, 0, 4, 0);
        SetColumn(count, 2);
        Children.Add(count);
    }
}

/// <summary>The sidebar: library views, two-level groups and tags (the macOS SidebarController).</summary>
public sealed class SidebarView : Grid
{
    readonly AppModel _model;
    readonly ListView _list;
    readonly ObservableCollection<SidebarEntry> _entries = [];
    readonly HashSet<string> _collapsed = [];
    bool _updating;

    public SidebarView(AppModel model)
    {
        _model = model;
        SidebarRow.Owner = this;
        Background = UI.Brush("FolioSidebarBrush");
        _list = new ListView
        {
            ItemsSource = _entries,
            ItemTemplate = (DataTemplate)Application.Current.Resources["SidebarRowTemplate"],
            SelectionMode = ListViewSelectionMode.Single,
            Padding = new Thickness(6, 4, 6, 12),
            ItemContainerStyle = ContainerStyle(),
        };
        _list.SelectionChanged += (_, _) =>
        {
            if (_updating || _list.SelectedItem is not SidebarEntry { Scope: { } scope }) return;
            _model.SelectScope(scope);
        };
        _list.ContainerContentChanging += (_, e) =>
        {
            if (e.Item is SidebarEntry { EntryKind: SidebarEntry.Kind.Header }) e.ItemContainer.IsHitTestVisible = true;
        };
        _list.RightTapped += OnRightTapped;
        Children.Add(_list);
        model.SnapshotChanged += Rebuild;
        model.RowsChanged += SyncSelection;
        Rebuild();
    }

    static Style ContainerStyle()
    {
        var style = new Style(typeof(ListViewItem));
        style.Setters.Add(new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch));
        style.Setters.Add(new Setter(FrameworkElement.MinHeightProperty, 28.0));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(6, 0, 6, 0)));
        return style;
    }

    public void ToggleExpanded(SidebarEntry entry)
    {
        if (entry.Scope?.GroupId is not { } id) return;
        if (!_collapsed.Remove(id)) _collapsed.Add(id);
        Rebuild();
    }

    void Rebuild()
    {
        var s = _model.Snapshot;
        var c = _model.Counts;
        var entries = new List<SidebarEntry>
        {
            new() { EntryKind = SidebarEntry.Kind.Header, Title = Loc.S("文献库"), HeaderId = "library" },
            new() { EntryKind = SidebarEntry.Kind.Builtin, Title = Loc.S("所有文献"), Scope = ViewScope.All, Icon = "all", Count = c.GetValueOrDefault("all") },
            new() { EntryKind = SidebarEntry.Kind.Builtin, Title = Loc.S("未分组"), Scope = ViewScope.Unfiled, Icon = "unfiled", Count = c.GetValueOrDefault("unfiled") },
            new() { EntryKind = SidebarEntry.Kind.Builtin, Title = Loc.S("回收站"), Scope = ViewScope.Trash, Icon = "trash", Count = c.GetValueOrDefault("trash") },
            new() { EntryKind = SidebarEntry.Kind.Header, Title = Loc.S("分组"), HeaderId = "groups" },
        };
        foreach (var id in s.TopLevelGroups)
        {
            var g = s.GroupsById[id];
            var children = s.ChildGroups.GetValueOrDefault(id) ?? [];
            bool expanded = !_collapsed.Contains(id);
            entries.Add(new() { EntryKind = SidebarEntry.Kind.Group, Title = g.Name, Scope = ViewScope.Group(id), ColorHex = g.ColorHex, Count = c.GetValueOrDefault($"group:{id}"), HasChildren = children.Count > 0, Expanded = expanded });
            if (!expanded) continue;
            foreach (var child in children)
            {
                var cg = s.GroupsById[child];
                entries.Add(new() { EntryKind = SidebarEntry.Kind.Group, Title = cg.Name, Scope = ViewScope.Group(child), ColorHex = cg.ColorHex, Count = c.GetValueOrDefault($"group:{child}"), Depth = 1 });
            }
        }
        if (s.Tags.Count > 0) entries.Add(new() { EntryKind = SidebarEntry.Kind.Header, Title = Loc.S("标签"), HeaderId = "tags" });
        foreach (var tag in s.Tags)
            entries.Add(new() { EntryKind = SidebarEntry.Kind.Tag, Title = tag.Name, Scope = ViewScope.TagOf(tag.Id), ColorHex = tag.ColorHex, Count = c.GetValueOrDefault($"tag:{tag.Id}") });
        _updating = true;
        _entries.Clear();
        foreach (var e in entries) _entries.Add(e);
        _updating = false;
        SyncSelection();
    }

    void SyncSelection()
    {
        _updating = true;
        _list.SelectedItem = _entries.FirstOrDefault(e => e.Scope == _model.Scope);
        _updating = false;
    }

    // MARK: Context menus

    void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var entry = (e.OriginalSource as FrameworkElement)?.DataContext as SidebarEntry;
        var menu = new MenuFlyout();
        switch (entry)
        {
            case { EntryKind: SidebarEntry.Kind.Group, Scope: { GroupId: { } groupId } }:
                var group = _model.Snapshot.GroupsById[groupId];
                if (group.ParentId == null) menu.Items.Add(UI.Item(Loc.S("新建子分组…"), () => _ = NewGroup(groupId), "add"));
                menu.Items.Add(UI.Item(Loc.S("重命名…"), () => _ = RenameGroup(group), "edit"));
                menu.Items.Add(ColorMenu(group));
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(UI.Item(Loc.S("删除分组…"), () => _ = DeleteGroup(group), "delete"));
                break;
            case { EntryKind: SidebarEntry.Kind.Tag, Scope: { TagId: { } tagId } }:
                var tag = _model.Snapshot.TagsById[tagId];
                menu.Items.Add(UI.Item(Loc.S("编辑标签…"), () => _ = TagEditor.Edit(_model, tag), "edit"));
                menu.Items.Add(UI.Item(Loc.S("删除标签…"), () => _ = DeleteTag(tag), "delete"));
                break;
            case { EntryKind: SidebarEntry.Kind.Builtin, Scope: ViewScope.TrashScope }:
                menu.Items.Add(UI.Item(Loc.S("清空回收站…"), () => _ = EmptyTrash(), "delete", _model.Counts.GetValueOrDefault("trash") > 0));
                break;
            default:
                menu.Items.Add(UI.Item(Loc.S("新建分组…"), () => _ = NewGroup(null), "add"));
                menu.Items.Add(UI.Item(Loc.S("新建标签…"), () => _ = TagEditor.Create(_model), "tag"));
                break;
        }
        menu.ShowAt(this, e.GetPosition(this));
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
        var name = await Dialogs.Ask(parentId == null ? Loc.S("新建分组") : Loc.S("新建子分组"), Loc.S("分组名称"), primary: Loc.S("创建"));
        if (string.IsNullOrWhiteSpace(name)) return;
        _model.Perform(() =>
        {
            var g = _model.Library.CreateGroup(name, parentId);
            _model.SelectScope(ViewScope.Group(g.Id));
        });
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

    public void OnRowDragOver(SidebarEntry? entry, DragEventArgs e)
    {
        if (entry?.Scope is not { } scope) return;
        bool items = e.DataView.Properties.ContainsKey(ItemList.DragFormat);
        bool files = e.DataView.Contains(StandardDataFormats.StorageItems);
        if (items && scope is ViewScope.GroupScope or ViewScope.TagScope or ViewScope.TrashScope)
            e.AcceptedOperation = scope is ViewScope.TrashScope ? DataPackageOperation.Move : DataPackageOperation.Link;
        else if (files && scope is ViewScope.GroupScope or ViewScope.AllScope or ViewScope.UnfiledScope)
            e.AcceptedOperation = DataPackageOperation.Copy;
        e.Handled = true;
    }

    public async void OnRowDrop(SidebarEntry? entry, DragEventArgs e)
    {
        if (entry?.Scope is not { } scope) return;
        e.Handled = true;
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
            var items = await e.DataView.GetStorageItemsAsync();
            await _model.Importer.ImportFiles(items.Select(i => i.Path), scope.GroupId);
        }
    }
}
