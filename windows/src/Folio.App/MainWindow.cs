using Folio.Core;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.System;

namespace Folio.App;

/// <summary>
/// Folio's window: tabs in the title bar (文献库 first, then open papers, as the macOS window does), the library
/// page (sidebar | list | inspector), toasts at the bottom.
/// </summary>
public sealed class MainWindow : Window
{
    readonly AppModel _model;
    readonly TabView _tabs;
    readonly TabViewItem _libraryTab;
    readonly Grid _libraryPage;
    readonly SidebarView _sidebar;
    readonly ItemList _list;
    readonly Inspector _inspector;
    readonly ColumnDefinition _sidebarColumn, _inspectorColumn;
    readonly Grid _toastLayer;
    readonly Grid _root;

    public MainWindow(AppModel model)
    {
        _model = model;
        Title = "Folio";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Folio.ico"));
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        RestoreBounds();

        _root = new Grid();
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // Title bar: sidebar toggle, the tab strip, inspector toggle; the rest is draggable.
        _tabs = new TabView
        {
            IsAddTabButtonVisible = false,
            TabWidthMode = TabViewWidthMode.SizeToContent,
            CloseButtonOverlayMode = TabViewCloseButtonOverlayMode.OnPointerOver,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 6, 0, 0),
        };
        _libraryTab = new TabViewItem { Header = Loc.S("文献库"), IsClosable = false, IconSource = new FontIconSource { Glyph = UI.Glyph("library"), FontFamily = UI.IconFont } };
        _tabs.TabItems.Add(_libraryTab);
        _tabs.TabCloseRequested += (_, e) => CloseTab(e.Tab);
        _tabs.SelectionChanged += (_, _) => ShowSelectedTab();
        var leftHeader = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 4, 0), VerticalAlignment = VerticalAlignment.Center };
        leftHeader.Children.Add(new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Folio.png"))), Width = 18, Height = 18, Margin = new Thickness(4, 0, 8, 0) });
        leftHeader.Children.Add(UI.IconButton("sidebar", Loc.S("显示/隐藏侧栏"), (_, _) => ToggleSidebar()));
        _tabs.TabStripHeader = leftHeader;
        var drag = new Grid { Background = new SolidColorBrush(Colors.Transparent), MinWidth = 120 };
        var rightHeader = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 150, 0) };
        rightHeader.Children.Add(UI.IconButton("settings", Loc.S("设置…"), (_, _) => SettingsWindow.Open(_model)));
        rightHeader.Children.Add(UI.IconButton("inspector", Loc.S("显示/隐藏检查器"), (_, _) => ToggleInspector()));
        var footer = new Grid();
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.Children.Add(drag);
        Grid.SetColumn(rightHeader, 1);
        footer.Children.Add(rightHeader);
        _tabs.TabStripFooter = footer;
        _root.Children.Add(_tabs);
        SetTitleBar(drag);

        // Library page.
        _sidebar = new SidebarView(model);
        _list = new ItemList(model);
        _inspector = new Inspector(model);
        _libraryPage = new Grid();
        _sidebarColumn = new ColumnDefinition { Width = new GridLength(model.Settings.SidebarVisible ? model.Settings.SidebarWidth : 0), MinWidth = 0 };
        _inspectorColumn = new ColumnDefinition { Width = new GridLength(model.Settings.InspectorVisible ? model.Settings.InspectorWidth : 0), MinWidth = 0 };
        _libraryPage.ColumnDefinitions.Add(_sidebarColumn);
        _libraryPage.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _libraryPage.ColumnDefinitions.Add(_inspectorColumn);
        _libraryPage.Children.Add(_sidebar);
        Grid.SetColumn(_list, 1);
        _libraryPage.Children.Add(_list);
        Grid.SetColumn(_inspector, 2);
        _libraryPage.Children.Add(_inspector);
        AddSplitter(1, HorizontalAlignment.Left, w => _sidebarColumn.Width = new GridLength(Math.Clamp(w, 160, 420)), () => _sidebarColumn.ActualWidth, w => model.Settings.SidebarWidth = w, +1);
        AddSplitter(1, HorizontalAlignment.Right, w => _inspectorColumn.Width = new GridLength(Math.Clamp(w, 240, 560)), () => _inspectorColumn.ActualWidth, w => model.Settings.InspectorWidth = w, -1);
        Grid.SetRow(_libraryPage, 1);
        _root.Children.Add(_libraryPage);

        // Toasts float above everything at the bottom centre.
        _toastLayer = new Grid { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 24), IsHitTestVisible = true };
        Grid.SetRowSpan(_toastLayer, 2);
        _root.Children.Add(_toastLayer);
        model.Toasts.Shown += ShowToast;

        // Files dropped anywhere on the library page are imported (the macOS DropOverlay).
        _libraryPage.AllowDrop = true;

        _root.KeyboardAccelerators.Add(Accelerator(VirtualKey.F, VirtualKeyModifiers.Control, () => _list.FocusSearch()));
        _root.KeyboardAccelerators.Add(Accelerator(VirtualKey.O, VirtualKeyModifiers.Control, () => _ = Commands.AddFiles(model)));
        _root.KeyboardAccelerators.Add(Accelerator(VirtualKey.N, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => _ = _sidebar.NewGroup(null)));
        _root.KeyboardAccelerators.Add(Accelerator(VirtualKey.C, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => Commands.CopyCitation(model, model.SelectedItemIds, model.DefaultStyle)));
        _root.KeyboardAccelerators.Add(Accelerator(VirtualKey.W, VirtualKeyModifiers.Control, () => { if (_tabs.SelectedItem is TabViewItem t && t != _libraryTab) CloseTab(t); }));
        _root.KeyboardAccelerators.Add(Accelerator(VirtualKey.Number1, VirtualKeyModifiers.Control, () => _tabs.SelectedItem = _libraryTab));

        Content = _root;
        ApplyTheme();
        model.Settings.Changed += key => { if (key == "appearance") DispatcherQueue.TryEnqueue(ApplyTheme); };
        model.OpenInReaderRequested += file => OpenReader(file);
        Closed += (_, _) => SaveBounds();
        if (model.Settings.ReopenReaderTabs) DispatcherQueue.TryEnqueue(ReopenTabs);
    }

    static KeyboardAccelerator Accelerator(VirtualKey key, VirtualKeyModifiers modifiers, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += (_, e) => { action(); e.Handled = true; };
        return accelerator;
    }

    void ApplyTheme()
    {
        _root.RequestedTheme = _model.Settings.Appearance switch
        {
            Appearance.Light => ElementTheme.Light,
            Appearance.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
    }

    void AddSplitter(int column, HorizontalAlignment edge, Action<double> resize, Func<double> current, Action<double> save, int direction)
    {
        var splitter = new Border { Width = 6, HorizontalAlignment = edge, Background = new SolidColorBrush(Colors.Transparent), Margin = new Thickness(edge == HorizontalAlignment.Left ? -3 : 0, 0, edge == HorizontalAlignment.Right ? -3 : 0, 0) };
        var line = new Border { Width = 1, HorizontalAlignment = edge, Background = UI.Brush("FolioSeparatorBrush") };
        Grid.SetColumn(line, column);
        Grid.SetColumn(splitter, column);
        _libraryPage.Children.Add(line);
        _libraryPage.Children.Add(splitter);
        double start = 0, startX = 0;
        bool dragging = false;
        splitter.PointerEntered += (_, _) => ProtectedCursor(splitter, true);
        splitter.PointerExited += (_, _) => { if (!dragging) ProtectedCursor(splitter, false); };
        splitter.PointerPressed += (_, e) => { dragging = true; start = current(); startX = e.GetCurrentPoint(_root).Position.X; splitter.CapturePointer(e.Pointer); };
        splitter.PointerMoved += (_, e) => { if (dragging) resize(start + direction * (e.GetCurrentPoint(_root).Position.X - startX)); };
        splitter.PointerReleased += (_, _) => { dragging = false; splitter.ReleasePointerCaptures(); save(current()); };
    }

    static void ProtectedCursor(UIElement element, bool resize)
    {
        // UIElement.ProtectedCursor is protected; set it through reflection-free helper subclasses is overkill here.
        typeof(UIElement).GetProperty("ProtectedCursor", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
            ?.SetValue(element, resize ? Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.SizeWestEast) : null);
    }

    void ToggleSidebar()
    {
        bool show = _sidebarColumn.ActualWidth < 1;
        _sidebarColumn.Width = new GridLength(show ? _model.Settings.SidebarWidth : 0);
        _model.Settings.SidebarVisible = show;
        if (_tabs.SelectedItem is TabViewItem { Content: ReaderView reader }) reader.ToggleSidebar();
    }

    void ToggleInspector()
    {
        if (_tabs.SelectedItem is TabViewItem { Content: ReaderView reader }) { reader.ToggleNotes(); return; }
        bool show = _inspectorColumn.ActualWidth < 1;
        _inspectorColumn.Width = new GridLength(show ? _model.Settings.InspectorWidth : 0);
        _model.Settings.InspectorVisible = show;
    }

    public void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        Activate();
    }

    // MARK: Tabs

    void ShowSelectedTab()
    {
        bool library = _tabs.SelectedItem == _libraryTab;
        _libraryPage.Visibility = library ? Visibility.Visible : Visibility.Collapsed;
        foreach (var tab in _tabs.TabItems.OfType<TabViewItem>())
            if (tab.Content is UIElement content) content.Visibility = tab == _tabs.SelectedItem ? Visibility.Visible : Visibility.Collapsed;
        RememberTabs();
    }

    public void OpenReader(FileRecord file, int? page = null)
    {
        var existing = _tabs.TabItems.OfType<TabViewItem>().FirstOrDefault(t => t.Content is ReaderView r && r.FileId == file.Id);
        if (existing != null)
        {
            _tabs.SelectedItem = existing;
            if (page != null) ((ReaderView)existing.Content).GoToPage(page.Value);
            return;
        }
        var reader = new ReaderView(_model, file, page);
        Grid.SetRow(reader, 1);
        _root.Children.Insert(_root.Children.Count - 1, reader);
        var item = _model.Snapshot.Items.GetValueOrDefault(file.ItemId);
        var tab = new TabViewItem { Header = TabTitle(item, file), Content = reader, IconSource = new FontIconSource { Glyph = UI.Glyph("pdf"), FontFamily = UI.IconFont } };
        ToolTipService.SetToolTip(tab, item?.Title ?? file.FileName);
        // The tab's content lives in the page grid, not inside the strip.
        tab.Content = null;
        tab.Tag = reader;
        _readers[tab] = reader;
        _tabs.TabItems.Add(tab);
        _tabs.SelectedItem = tab;
        ShowReaders();
    }

    readonly Dictionary<TabViewItem, ReaderView> _readers = [];

    void ShowReaders()
    {
        foreach (var (tab, reader) in _readers) reader.Visibility = tab == _tabs.SelectedItem ? Visibility.Visible : Visibility.Collapsed;
        _libraryPage.Visibility = _tabs.SelectedItem == _libraryTab ? Visibility.Visible : Visibility.Collapsed;
    }

    static string TabTitle(Item? item, FileRecord file)
    {
        if (item is { Kind: ItemKind.Regular })
        {
            var author = item.Authors.FirstOrDefault()?.Family;
            var label = author != null && item.Year != null ? $"{author} {item.Year}" : item.Title;
            if (file.TranslationKind is { } kind) label += " · " + FileLabel.KindName(kind);
            return Text.PrefixGraphemes(label, 40);
        }
        return Text.PrefixGraphemes(Path.GetFileNameWithoutExtension(file.FileName), 40);
    }

    void CloseTab(TabViewItem tab)
    {
        if (tab == _libraryTab || !_readers.Remove(tab, out var reader)) return;
        reader.Close();
        _root.Children.Remove(reader);
        _tabs.TabItems.Remove(tab);
        if (_tabs.SelectedItem == null) _tabs.SelectedItem = _libraryTab;
        ShowReaders();
        RememberTabs();
    }

    void RememberTabs()
    {
        ShowReaders();
        _model.Settings.OpenReaderTabs = _readers.Values.Select(r => r.FileId).ToList();
    }

    void ReopenTabs()
    {
        foreach (var id in _model.Settings.OpenReaderTabs)
            if (_model.Snapshot.Files.TryGetValue(id, out var file) && File.Exists(_model.Library.FilePath(file))) OpenReader(file);
        _tabs.SelectedItem = _libraryTab;
    }

    /// <summary>The translation queue sheet (Translation/TranslationSheet).</summary>
    public void ShowTranslationSheet(List<FileRecord> files) => _ = TranslationSheet.Show(_model, files);

    public void ShowNotes() => _inspector.ShowNotes();

    // MARK: Toasts

    void ShowToast(ToastCenter.Toast toast)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(UI.Icon(toast.Icon, 15));
        panel.Children.Add(new TextBlock { Text = toast.Message, TextWrapping = TextWrapping.Wrap, MaxWidth = 520, VerticalAlignment = VerticalAlignment.Center });
        var card = new Border
        {
            Child = panel,
            Padding = new Thickness(16, 10, 16, 10),
            CornerRadius = new CornerRadius(18),
            Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"],
            BorderBrush = UI.Brush("FolioSeparatorBrush"),
            BorderThickness = new Thickness(1),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 16),
            Opacity = 0,
        };
        if (toast.ActionTitle != null && toast.Action != null)
        {
            var action = new HyperlinkButton { Content = toast.ActionTitle, Padding = new Thickness(6, 0, 0, 0) };
            action.Click += (_, _) => { toast.Action(); Dismiss(card); };
            panel.Children.Add(action);
        }
        _toastLayer.Children.Clear();
        _toastLayer.Children.Add(card);
        Fade(card, 1);
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(toast.ActionTitle != null ? 6 : 3.5);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => Dismiss(card);
        timer.Start();
    }

    void Dismiss(Border card)
    {
        if (!_toastLayer.Children.Contains(card)) return;
        Fade(card, 0, () => _toastLayer.Children.Remove(card));
    }

    static void Fade(UIElement element, double to, Action? completed = null)
    {
        var animation = new DoubleAnimation { To = to, Duration = TimeSpan.FromMilliseconds(180) };
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var board = new Storyboard();
        board.Children.Add(animation);
        if (completed != null) board.Completed += (_, _) => completed();
        board.Begin();
    }

    // MARK: Window position

    void RestoreBounds()
    {
        var raw = _model.Settings.Raw("windowBounds")?.ToString();
        var parts = raw?.Split(',').Select(p => int.TryParse(p, out var v) ? v : -1).ToArray();
        if (parts is { Length: 4 } && parts.All(p => p >= 0) && parts[2] > 600 && parts[3] > 400)
        {
            AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(parts[0], parts[1], parts[2], parts[3]));
            return;
        }
        // First launch: 85% of the screen's work area, centred (sizes are in physical pixels).
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        int width = (int)(area.Width * 0.85), height = (int)(area.Height * 0.85);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
    }

    void SaveBounds()
    {
        var p = AppWindow.Position;
        var s = AppWindow.Size;
        _model.Settings.SetRaw("windowBounds", $"{p.X},{p.Y},{s.Width},{s.Height}");
    }
}
