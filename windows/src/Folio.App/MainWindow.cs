using Folio.Core;
using Folio.Core.Citation;
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
    readonly TabStrip _tabs;
    readonly TabButton _libraryTab;
    readonly Grid _titleBar;
    readonly Border _leftSplitter, _rightSplitter;
    readonly ColumnDefinition _captionInset;
    readonly FrameworkElement _titleBarLeft, _titleBarRight;
    readonly double _titleBarHeight;
    readonly Grid _libraryPage;
    readonly SidebarView _sidebar;
    readonly ItemList _list;
    readonly Inspector _inspector;
    readonly ColumnDefinition _sidebarColumn, _inspectorColumn;
    readonly Grid _toastLayer;
    readonly Grid _root;
    readonly TranslucentBackdrop _backdrop;
    readonly FrameworkElement _dropOverlay;
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _dropWatchdog;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _toastTimer;
    Button _sidebarButton = null!, _inspectorButton = null!;
    bool _sidebarShown, _inspectorShown;
    ReaderView? _spareReader;
    readonly Dictionary<TabButton, ReaderTab> _readers = [];
    Windows.Graphics.RectInt32? _normalBounds;

    /// <summary>A paper's tab: its reader is only created when the tab is first shown.</summary>
    sealed class ReaderTab(FileRecord file, int? page)
    {
        public FileRecord File = file;
        public int? Page = page;
        public ReaderView? View;
    }

    public MainWindow(AppModel model)
    {
        _model = model;
        UI.SetDark(UI.ResolveDark(model.Settings.Appearance));
        Title = "Folio";
        SystemBackdrop = _backdrop = new TranslucentBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Folio.ico"));
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        RestoreBounds();

        // Accelerators live on the root: without this WinUI shows "Ctrl+F" as a tooltip wherever the pointer rests.
        _root = new Grid { KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden, Background = UI.Brush("WindowBackgroundBrush") };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // Title bar: icon and sidebar button, the tabs, a free part to drag the window by, then settings and inspector
        // right beside Windows' own buttons, the same height and width as those.
        _titleBarHeight = Math.Max(AppWindow.TitleBar.Height / UI.Scale(this), 48);
        _titleBar = new Grid { Height = _titleBarHeight, BorderBrush = UI.Brush("FolioSeparatorBrush"), BorderThickness = new Thickness(0, 0, 0, 1) };
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _titleBar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _captionInset = new ColumnDefinition { Width = new GridLength(140) };
        _titleBar.ColumnDefinitions.Add(_captionInset);
        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(UI.TitleBarButton("settings", Loc.S("设置…"), (_, _) => SettingsWindow.Open(_model), _titleBarHeight - 1));
        _sidebarButton = UI.TitleBarButton("sidebarHide", Loc.S("显示/隐藏边栏"), (_, _) => ToggleSidebar(), _titleBarHeight - 1);
        left.Children.Add(_sidebarButton);
        _titleBarLeft = left;
        _titleBar.Children.Add(left);
        _tabs = new TabStrip { Margin = new Thickness(4, 0, 4, 0) };
        _libraryTab = _tabs.Add(Loc.S("文献库"), "library", closable: false);
        _tabs.CloseRequested += CloseTab;
        Grid.SetColumn(_tabs, 1);
        _titleBar.Children.Add(_tabs);
        var drag = new Grid { Background = new SolidColorBrush(Colors.Transparent) };
        Grid.SetColumn(drag, 2);
        _titleBar.Children.Add(drag);
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        _inspectorButton = UI.TitleBarButton("inspectorHide", Loc.S("显示/隐藏检查器"), (_, _) => ToggleInspector(), _titleBarHeight - 1);
        right.Children.Add(_inspectorButton);
        _titleBarRight = right;
        Grid.SetColumn(right, 3);
        _titleBar.Children.Add(right);
        _root.Children.Add(_titleBar);
        SetTitleBar(drag);
        _titleBar.SizeChanged += (_, _) => LayoutTitleBar();
        left.SizeChanged += (_, _) => LayoutTitleBar();
        right.SizeChanged += (_, _) => LayoutTitleBar();

        // Library page.
        _sidebar = new SidebarView(model);
        _list = new ItemList(model);
        _inspector = new Inspector(model);
        _libraryPage = new Grid();
        _sidebarShown = model.Settings.SidebarVisible;
        _inspectorShown = model.Settings.InspectorVisible;
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
        _leftSplitter = AddSplitter(1, HorizontalAlignment.Left, w => _sidebarColumn.Width = new GridLength(Math.Clamp(w, 160, 420)), () => _sidebarColumn.ActualWidth, w => model.Settings.SidebarWidth = w, +1);
        _rightSplitter = AddSplitter(1, HorizontalAlignment.Right, w => _inspectorColumn.Width = new GridLength(Math.Clamp(w, 240, 560)), () => _inspectorColumn.ActualWidth, w => model.Settings.InspectorWidth = w, -1);
        Grid.SetRow(_libraryPage, 1);
        _root.Children.Add(_libraryPage);

        // Toasts float above everything at the bottom centre.
        _toastLayer = new Grid { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 24), IsHitTestVisible = true };
        Grid.SetRowSpan(_toastLayer, 2);
        _root.Children.Add(_toastLayer);
        model.Toasts.Shown += ShowToast;

        // Files dropped anywhere on the library page are imported (the macOS DropOverlay).
        _dropOverlay = DropOverlay();
        Grid.SetRow(_dropOverlay, 1);
        _root.Children.Add(_dropOverlay);
        // Children take drops over them for themselves, so these listen to handled events as well: whatever happens to
        // the drag, the overlay goes.
        _libraryPage.AllowDrop = true;
        _libraryPage.AddHandler(UIElement.DragEnterEvent, new DragEventHandler(OnLibraryDragOver), true);
        _libraryPage.AddHandler(UIElement.DragOverEvent, new DragEventHandler(OnLibraryDragOver), true);
        _libraryPage.AddHandler(UIElement.DragLeaveEvent, new DragEventHandler((_, _) => HideDropOverlay()), true);
        _libraryPage.AddHandler(UIElement.DropEvent, new DragEventHandler(OnLibraryDrop), true);
        _dropWatchdog = DispatcherQueue.CreateTimer();
        _dropWatchdog.Interval = TimeSpan.FromMilliseconds(500);
        _dropWatchdog.IsRepeating = false;
        _dropWatchdog.Tick += (_, _) => HideDropOverlay();

        _tabs.Select(_libraryTab);
        _tabs.SelectionChanged += ShowSelectedTab;

        InstallAccelerators();

        Content = _root;
        _root.ActualThemeChanged += (_, _) => ThemeChanged();
        _root.Loaded += (_, _) =>
        {
            LayoutTitleBar();
            Content.XamlRoot.Changed += (_, _) => LayoutTitleBar();
        };
        ApplyTheme();
        UI.ApplyTitleBarTheme(this, UI.ResolveDark(model.Settings.Appearance));
        UI.SetTransparency(model.Settings.WindowTransparency);
        _backdrop.Refresh();
        UI.SurfacesChanged += _backdrop.Refresh;
        model.Settings.Changed += key =>
        {
            if (key == "appearance") DispatcherQueue.TryEnqueue(ApplyTheme);
            if (key == "windowTransparency") DispatcherQueue.TryEnqueue(() => UI.SetTransparency(model.Settings.WindowTransparency));
        };
        model.OpenInReaderRequested += (file, page) => OpenReader(file, page);
        Activated += (_, e) => { if (e.WindowActivationState != WindowActivationState.Deactivated) CurrentReader?.CheckForChanges(); };
        model.SnapshotChanged += CloseMissingTabs;
        model.LibraryWillChange += () =>
        {
            foreach (var tab in _readers.Keys.ToList()) CloseTab(tab);
            // Its page is tied to the old folder.
            if (_spareReader is { } spare) { spare.Close(); _root.Children.Remove(spare); _spareReader = null; }
            PrepareSpareReader();
        };
        AppWindow.Changed += (_, e) =>
        {
            if (e.DidPresenterChange || e.DidSizeChange) LayoutTitleBar();
            if ((e.DidPositionChange || e.DidSizeChange) && AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
                _normalBounds = new Windows.Graphics.RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        };
        Closed += (_, _) =>
        {
            _closing = true;
            SaveBounds();
            _inspector.Flush();
            foreach (var reader in _readers.Values) reader.View?.Close();
            _spareReader?.Close();
            _model.Translations.CancelAll();
            SettingsWindow.Current?.Close();
        };
        if (model.Settings.ReopenReaderTabs) DispatcherQueue.TryEnqueue(ReopenTabs);
        // Keys work in the list from the start (and no focus ring appears on the first button of the title bar).
        _root.Loaded += (_, _) =>
        {
            _list.FocusList();
            UpdatePanelButtons();
            PrepareSpareReader();
            if (_model.StartupProblem is { } problem) Dialogs.Message(Loc.S("无法打开文献库"), problem).Fire();
        };
    }

    /// <summary>Room for Windows' buttons, and for the tabs what is left beside a part to drag the window by.</summary>
    void LayoutTitleBar()
    {
        double scale = Content?.XamlRoot?.RasterizationScale ?? UI.Scale(this);
        double inset = AppWindow.TitleBar.RightInset / scale;
        _captionInset.Width = new GridLength(inset);
        double free = _titleBar.ActualWidth - _titleBarLeft.ActualWidth - _titleBarRight.ActualWidth - inset - _tabs.Margin.Left - _tabs.Margin.Right - 72;
        if (free > 0) _tabs.SetAvailableWidth(free);
    }

    // MARK: Keys

    /// <summary>Accelerators for keys pressed while focus is in native controls; in the reader's page the same keys
    /// come as messages. Both end in <see cref="HandleGlobalKey"/> and <see cref="ReaderView.HandleKey"/>.</summary>
    void InstallAccelerators()
    {
        const VirtualKeyModifiers C = VirtualKeyModifiers.Control, S = VirtualKeyModifiers.Shift, A = VirtualKeyModifiers.Menu;
        var plus = (VirtualKey)187;
        var minus = (VirtualKey)189;
        var comma = (VirtualKey)188;
        (VirtualKey Key, VirtualKeyModifiers Mods)[] keys =
        [
            (VirtualKey.F, C), (VirtualKey.O, C), (VirtualKey.O, C | S), (VirtualKey.N, C | S), (VirtualKey.I, C | S), (VirtualKey.E, C | S), (VirtualKey.C, C | S),
            (VirtualKey.R, C | S), (VirtualKey.W, C), (VirtualKey.Number1, C), (VirtualKey.L, C | S), (VirtualKey.Tab, C), (VirtualKey.Tab, C | S), (comma, C),
            (VirtualKey.S, C | A), (VirtualKey.I, C | A), (VirtualKey.N, C | A), (VirtualKey.R, C | A), (VirtualKey.T, C | A), (VirtualKey.F11, VirtualKeyModifiers.None),
            // The reader's.
            (plus, C), (minus, C), (VirtualKey.Number0, C), (VirtualKey.Number9, C), (VirtualKey.Z, C), (VirtualKey.Y, C), (VirtualKey.Z, C | S), (VirtualKey.P, C), (VirtualKey.G, C), (VirtualKey.G, C | S),
            (VirtualKey.F3, VirtualKeyModifiers.None), (VirtualKey.F3, S), (VirtualKey.Left, A), (VirtualKey.Right, A), ((VirtualKey)219, C), ((VirtualKey)221, C),
            (VirtualKey.Up, C | A), (VirtualKey.Down, C | A), (VirtualKey.G, C | A), (VirtualKey.M, C | A), (VirtualKey.Number0, C | A), (VirtualKey.H, C | A), (VirtualKey.U, C | A), (VirtualKey.K, C | A), (VirtualKey.D, C | A),
            (VirtualKey.Number2, C | A), (VirtualKey.Number3, C | A), (VirtualKey.Number4, C | A), (VirtualKey.Number5, C | A),
        ];
        foreach (var (key, mods) in keys)
        {
            var accelerator = new KeyboardAccelerator { Key = key, Modifiers = mods };
            accelerator.Invoked += (_, e) =>
            {
                bool ctrl = mods.HasFlag(C), alt = mods.HasFlag(A), shift = mods.HasFlag(S);
                // Text boxes keep their own undo.
                if (key is VirtualKey.Z or VirtualKey.Y && Content.XamlRoot != null && FocusManager.GetFocusedElement(Content.XamlRoot) is TextBox) return;
                e.Handled = HandleGlobalKey(key, ctrl, alt, shift) || (CurrentReader?.HandleKey(key, ctrl, alt, shift) ?? false);
            };
            _root.KeyboardAccelerators.Add(accelerator);
        }
    }

    ReaderView? CurrentReader => _tabs.Selected is { } tab && _readers.TryGetValue(tab, out var reader) ? reader.View : null;

    /// <summary>The window's keys, the same as the macOS menu bar's where Windows has them free. True when used.</summary>
    public bool HandleGlobalKey(VirtualKey key, bool ctrl, bool alt, bool shift)
    {
        var ids = _model.SelectedItemIds;
        bool library = _tabs.Selected == _libraryTab;
        switch (key)
        {
            case VirtualKey.F11: ToggleFullScreen(); return true;
            case VirtualKey.O when ctrl && !alt && !shift: Commands.AddFiles(_model).Fire(); return true;
            case VirtualKey.O when ctrl && shift: IdentifierSheet.Show(_model).Fire(); return true;
            case VirtualKey.N when ctrl && shift: _sidebar.NewGroup(null).Fire(); return true;
            case VirtualKey.I when ctrl && shift: Commands.ImportReferences(_model).Fire(); return true;
            case VirtualKey.E when ctrl && shift && ids.Count > 0: Commands.Export(_model, ids, ReferenceFormat.Bibtex).Fire(); return true;
            case VirtualKey.C when ctrl && shift && ids.Count > 0: Commands.CopyCitation(_model, ids, _model.DefaultStyle); return true;
            case VirtualKey.R when ctrl && shift && ids.Count == 1 && _model.Snapshot.FilesOf(ids[0]).FirstOrDefault() is { } first: Shell.Reveal(_model.Library.FilePath(first)); return true;
            case VirtualKey.R when ctrl && alt && ids.Count > 0: _model.Retrieve(ids); return true;
            case VirtualKey.W when ctrl: if (_tabs.Selected is { } t && t != _libraryTab) CloseTab(t); return true;
            case VirtualKey.Number1 when ctrl && !alt: _tabs.Select(_libraryTab); return true;
            case VirtualKey.L when ctrl && shift: _tabs.Select(_libraryTab); return true;
            case VirtualKey.Tab when ctrl:
                _tabs.SelectNext(shift);
                return true;
            case (VirtualKey)188 when ctrl: SettingsWindow.Open(_model); return true;
            case VirtualKey.S when ctrl && alt: ToggleSidebar(); return true;
            case VirtualKey.I when ctrl && alt: ToggleInspector(); return true;
            case VirtualKey.F when ctrl && library: _list.FocusSearch(); return true;
            case VirtualKey.N when ctrl && alt && library:
                if (_inspectorColumn.ActualWidth < 1) ToggleInspector();
                _inspector.ShowNotes();
                return true;
            case VirtualKey.T when ctrl && alt && library && ids.Count > 0: Commands.Translate(_model, ids); return true;
        }
        return false;
    }

    void ToggleFullScreen()
    {
        bool full = AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;
        AppWindow.SetPresenter(full ? AppWindowPresenterKind.Default : AppWindowPresenterKind.FullScreen);
    }

    // MARK: Dropped files

    FrameworkElement DropOverlay()
    {
        var text = new StackPanel { Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        text.Children.Add(new FontIcon { Glyph = UI.Glyph("add"), FontFamily = UI.IconFont, FontSize = 40, Foreground = UI.Brush("FolioAccentBrush") });
        text.Children.Add(new TextBlock { Text = Loc.S("松开以添加文件"), FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
        text.Children.Add(UI.Label(Loc.S("PDF 会自动检索元数据并创建条目"), 13, secondary: true).With(l => l.HorizontalAlignment = HorizontalAlignment.Center));
        return new Border
        {
            Child = text,
            Padding = new Thickness(48, 36, 48, 36),
            CornerRadius = new CornerRadius(24),
            Background = UI.Brush("ToastBackgroundBrush"),
            BorderBrush = UI.Brush("FolioAccentBrush"),
            BorderThickness = new Thickness(1.5),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
    }

    void OnLibraryDragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems) || ItemList.IsInternalDrag(e.DataView)) return;
        if (_model.Scope is ViewScope.TrashScope) return; // Nothing is imported into the trash.
        if (e.AcceptedOperation == Windows.ApplicationModel.DataTransfer.DataPackageOperation.None)
            e.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
        _dropOverlay.Visibility = Visibility.Visible;
        // A drag cancelled outside the window sends nothing: no news for a moment means it is over.
        _dropWatchdog.Stop();
        _dropWatchdog.Start();
    }

    void HideDropOverlay()
    {
        _dropWatchdog.Stop();
        _dropOverlay.Visibility = Visibility.Collapsed;
    }

    async void OnLibraryDrop(object sender, DragEventArgs e)
    {
        HideDropOverlay();
        if (e.Handled || _model.Scope is ViewScope.TrashScope || !e.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems) || ItemList.IsInternalDrag(e.DataView)) return;
        e.Handled = true;
        var deferral = e.GetDeferral();
        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            deferral.Complete();
            await _model.Importer.ImportFiles(items.Select(i => i.Path).ToList(), _model.Scope.GroupId);
        }
        catch (Exception ex) { deferral.Complete(); _model.Toasts.Show(ex.Message, "warning"); }
    }

    void ApplyTheme()
    {
        _root.RequestedTheme = UI.ThemeOf(_model.Settings.Appearance);
        ThemeChanged();
    }

    void ThemeChanged()
    {
        bool dark = _root.ActualTheme == ElementTheme.Dark;
        UI.SetDark(dark);
        UI.ApplyTitleBarTheme(this, dark);
        _backdrop.Apply(dark);
    }

    Border AddSplitter(int column, HorizontalAlignment edge, Action<double> resize, Func<double> current, Action<double> save, int direction)
    {
        var splitter = new Border { Width = 6, HorizontalAlignment = edge, Background = new SolidColorBrush(Colors.Transparent), Margin = new Thickness(edge == HorizontalAlignment.Left ? -3 : 0, 0, edge == HorizontalAlignment.Right ? -3 : 0, 0) };
        var line = new Border { Width = 1, HorizontalAlignment = edge, Background = UI.Brush("FolioSeparatorBrush") };
        Grid.SetColumn(line, column);
        Grid.SetColumn(splitter, column);
        _libraryPage.Children.Add(line);
        _libraryPage.Children.Add(splitter);
        double start = 0, startX = 0;
        bool dragging = false;
        UI.ResizeCursor(splitter);
        splitter.PointerPressed += (_, e) => { dragging = true; start = current(); startX = e.GetCurrentPoint(_root).Position.X; splitter.CapturePointer(e.Pointer); };
        splitter.PointerMoved += (_, e) => { if (dragging) resize(start + direction * (e.GetCurrentPoint(_root).Position.X - startX)); };
        splitter.PointerReleased += (_, _) => { dragging = false; splitter.ReleasePointerCaptures(); save(current()); };
        return splitter;
    }

    void ToggleSidebar()
    {
        if (CurrentReader is { } reader) reader.ToggleSidebar();
        else
        {
            _sidebarShown = !_sidebarShown;
            _sidebarColumn.Width = new GridLength(_sidebarShown ? _model.Settings.SidebarWidth : 0);
            _model.Settings.SidebarVisible = _sidebarShown;
        }
        UpdatePanelButtons();
    }

    void ToggleInspector()
    {
        if (CurrentReader is { } reader) reader.ToggleNotes();
        else
        {
            _inspectorShown = !_inspectorShown;
            _inspectorColumn.Width = new GridLength(_inspectorShown ? _model.Settings.InspectorWidth : 0);
            _model.Settings.InspectorVisible = _inspectorShown;
        }
        UpdatePanelButtons();
    }

    /// <summary>Each panel's button points where the panel will go: a shown left panel leaves to the left, a hidden one comes
    /// back to the right, and the other way round on the right.</summary>
    void UpdatePanelButtons()
    {
        bool left = CurrentReader?.SidebarVisible ?? _sidebarShown;
        bool right = CurrentReader?.NotesVisible ?? _inspectorShown;
        // A hidden panel's divider cannot be dragged open past its state.
        _leftSplitter.IsHitTestVisible = _sidebarShown;
        _rightSplitter.IsHitTestVisible = _inspectorShown;
        _sidebarButton.Content = UI.Icon(left ? "sidebarHide" : "sidebarShow", 14);
        _inspectorButton.Content = UI.Icon(right ? "inspectorHide" : "inspectorShow", 14);
    }

    public void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        Activate();
        // A window activated from another process's request only flashes without this.
        SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool SetForegroundWindow(nint hwnd);

    // MARK: Tabs

    void ShowSelectedTab()
    {
        ShowReaders();
        RememberTabs();
        UpdatePanelButtons();
        if (CurrentReader is { } reader)
        {
            reader.CheckForChanges();
            // The arrow keys and Page Down scroll the paper right away.
            reader.FocusPage();
        }
        else _list.FocusList();
    }

    public void OpenReader(FileRecord file, int? page = null)
    {
        foreach (var (existing, open) in _readers)
        {
            if (open.File.Id != file.Id) continue;
            _tabs.Select(existing);
            if (page != null)
            {
                if (open.View != null) open.View.GoToPage(page.Value);
                else open.Page = page;
            }
            return;
        }
        var tab = AddTab(file, page);
        _tabs.Select(tab);
        ShowReaders();
    }

    TabButton AddTab(FileRecord file, int? page)
    {
        var item = _model.Snapshot.Items.GetValueOrDefault(file.ItemId);
        var files = _model.Snapshot.FilesOf(file.ItemId);
        // The tab's content lives in the page grid, not inside the strip.
        var tab = _tabs.Add(FileLabel.TabTitle(file, item, files), file.TranslationKind != null ? "translate" : "pdf", closable: true);
        ToolTipService.SetToolTip(tab, FileLabel.TabToolTip(file, item, files));
        _readers[tab] = new ReaderTab(file, page);
        var menu = new MenuFlyout();
        menu.Items.Add(UI.Item(Loc.S("关闭标签页"), () => CloseTab(tab), "close"));
        menu.Items.Add(UI.Item(Loc.S("关闭其他标签页"), () => { foreach (var other in _readers.Keys.Where(t => t != tab).ToList()) CloseTab(other); }));
        tab.ContextFlyout = menu;
        return tab;
    }

    void ShowReaders()
    {
        foreach (var (tab, reader) in _readers)
        {
            bool selected = tab == _tabs.Selected;
            if (selected && reader.View == null)
            {
                reader.View = TakeReader();
                reader.View.Load(reader.File, reader.Page);
                reader.View.PanelsChanged += UpdatePanelButtons;
                reader.Page = null;
                PrepareSpareReader();
            }
            if (reader.View != null) reader.View.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
        }
        _libraryPage.Visibility = _tabs.Selected == _libraryTab ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>A reader whose page is already up, so a paper opens at once; a new one if none is ready.</summary>
    ReaderView TakeReader()
    {
        if (_spareReader is { } spare)
        {
            _spareReader = null;
            return spare;
        }
        return NewReader();
    }

    ReaderView NewReader()
    {
        var view = new ReaderView(_model) { Visibility = Visibility.Collapsed };
        Grid.SetRow(view, 1);
        _root.Children.Insert(_root.Children.IndexOf(_toastLayer), view);
        return view;
    }

    Microsoft.UI.Dispatching.DispatcherQueueTimer? _spareTimer;

    /// <summary>Starts the next reader in the background, a moment after the window has settled.</summary>
    void PrepareSpareReader()
    {
        if (_spareReader != null || _model.Settings.OpenWith != OpenWith.Folio) return;
        _spareTimer?.Stop();
        _spareTimer = DispatcherQueue.CreateTimer();
        _spareTimer.Interval = TimeSpan.FromSeconds(1.5);
        _spareTimer.IsRepeating = false;
        _spareTimer.Tick += (_, _) => { if (_spareReader == null && !_closing) _spareReader = NewReader(); };
        _spareTimer.Start();
    }

    bool _closing;

    void CloseTab(TabButton tab)
    {
        if (tab == _libraryTab || !_readers.Remove(tab, out var reader)) return;
        if (reader.View != null)
        {
            reader.View.Close();
            _root.Children.Remove(reader.View);
        }
        _tabs.Remove(tab);
        ShowReaders();
        RememberTabs();
    }

    void RememberTabs()
    {
        var open = _tabs.Tabs.Where(_readers.ContainsKey).Select(t => _readers[t].File.Id).ToList();
        if (!open.SequenceEqual(_model.Settings.OpenReaderTabs)) _model.Settings.OpenReaderTabs = open;
    }

    void ReopenTabs()
    {
        foreach (var id in _model.Settings.OpenReaderTabs)
            if (_model.Snapshot.Files.TryGetValue(id, out var file) && File.Exists(_model.Library.FilePath(file))) AddTab(file, null);
        _tabs.Select(_libraryTab);
    }

    /// <summary>Tabs of files that were deleted, or of another library, close; the others follow renames.</summary>
    void CloseMissingTabs()
    {
        foreach (var (tab, reader) in _readers.ToList())
        {
            if (!_model.Snapshot.Files.TryGetValue(reader.File.Id, out var file)) { CloseTab(tab); continue; }
            reader.File = file;
            var item = _model.Snapshot.Items.GetValueOrDefault(file.ItemId);
            var files = _model.Snapshot.FilesOf(file.ItemId);
            var title = FileLabel.TabTitle(file, item, files);
            if (tab.Title != title) tab.Title = title;
            ToolTipService.SetToolTip(tab, FileLabel.TabToolTip(file, item, files));
        }
    }

    public Task NewGroup() => _sidebar.NewGroup(null);

    /// <summary>Focus back on what the current tab reads or lists.</summary>
    public void RestoreFocus()
    {
        if (CurrentReader is { } reader) reader.FocusPage();
        else _list.FocusList();
    }

    /// <summary>The translation queue sheet (Translation/TranslationSheet).</summary>
    public void ShowTranslationSheet(List<FileRecord> files) => TranslationSheet.Show(_model, files).Fire();

    public void ShowNotes()
    {
        _tabs.Select(_libraryTab);
        if (_inspectorColumn.ActualWidth < 1) ToggleInspector();
        _inspector.ShowNotes();
    }

    // MARK: Toasts

    void ShowToast(ToastCenter.Toast toast)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        panel.Children.Add(UI.Icon(toast.Icon, 15));
        panel.Children.Add(new TextBlock { Text = toast.Message, TextWrapping = TextWrapping.Wrap, MaxWidth = 520, VerticalAlignment = VerticalAlignment.Center });
        var card = new Border
        {
            Child = panel,
            Padding = new Thickness(16, 6, 6, 6),
            MinHeight = 36,
            CornerRadius = new CornerRadius(18),
            Background = UI.Brush("ToastBackgroundBrush"),
            BorderBrush = UI.Brush("FolioSeparatorBrush"),
            BorderThickness = new Thickness(1),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 16),
            Opacity = 0,
        };
        if (toast.ActionTitle != null && toast.Action != null)
        {
            var action = new HyperlinkButton { Content = toast.ActionTitle, Padding = new Thickness(6, 2, 6, 2) };
            action.Click += (_, _) => { toast.Action(); Dismiss(card); };
            panel.Children.Add(action);
        }
        var close = UI.IconButton("close", Loc.S("关闭"), (_, _) => Dismiss(card), 9);
        close.Width = close.Height = 24;
        close.CornerRadius = new CornerRadius(12);
        panel.Children.Add(close);
        _toastLayer.Children.Clear();
        _toastLayer.Children.Add(card);
        Fade(card, 1);
        // Kept in a field: a timer nothing refers to is collected before it fires, and the toast would stay for good.
        _toastTimer?.Stop();
        _toastTimer = DispatcherQueue.CreateTimer();
        _toastTimer.Interval = TimeSpan.FromSeconds(toast.ActionTitle != null || toast.Message.Length > 30 ? 6 : 3.5);
        _toastTimer.IsRepeating = false;
        _toastTimer.Tick += (_, _) => Dismiss(card);
        _toastTimer.Start();
    }

    void Dismiss(Border card)
    {
        if (!_toastLayer.Children.Contains(card)) return;
        Fade(card, 0, () => _toastLayer.Children.Remove(card));
    }

    readonly List<Storyboard> _fading = [];

    void Fade(UIElement element, double to, Action? completed = null)
    {
        var animation = new DoubleAnimation { To = to, Duration = TimeSpan.FromMilliseconds(180) };
        Storyboard.SetTarget(animation, element);
        Storyboard.SetTargetProperty(animation, "Opacity");
        var board = new Storyboard();
        board.Children.Add(animation);
        // Referred to until done, for the same reason as the timer.
        _fading.Add(board);
        board.Completed += (_, _) => { _fading.Remove(board); completed?.Invoke(); };
        board.Begin();
    }

    // MARK: Window position

    void RestoreBounds()
    {
        double scale = UI.Scale(this);
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(900 * scale);
            presenter.PreferredMinimumHeight = (int)(540 * scale);
        }
        var parts = _model.Settings.Raw("windowBounds")?.ToString()?.Split(',').Select(p => int.TryParse(p, out var v) ? v : int.MinValue).ToArray();
        if (parts is { Length: >= 4 } && parts.All(p => p != int.MinValue) && parts[2] > 400 && parts[3] > 300)
        {
            // Only where a screen still is.
            var rect = new Windows.Graphics.RectInt32(parts[0], parts[1], parts[2], parts[3]);
            var display = DisplayArea.GetFromRect(rect, DisplayAreaFallback.None);
            if (display != null)
            {
                AppWindow.MoveAndResize(rect);
                _normalBounds = rect;
                if (parts.Length > 4 && parts[4] == 1 && AppWindow.Presenter is OverlappedPresenter p) p.Maximize();
                return;
            }
        }
        // First launch: 85% of the screen's work area, centred (sizes are in physical pixels).
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        int width = (int)(area.Width * 0.85), height = (int)(area.Height * 0.85);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
    }

    void SaveBounds()
    {
        var presenter = AppWindow.Presenter as OverlappedPresenter;
        bool maximized = presenter?.State == OverlappedPresenterState.Maximized;
        var b = _normalBounds ?? new Windows.Graphics.RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        if (presenter?.State == OverlappedPresenterState.Minimized && _normalBounds == null) return;
        _model.Settings.SetRaw("windowBounds", $"{b.X},{b.Y},{b.Width},{b.Height},{(maximized ? 1 : 0)}");
    }
}
