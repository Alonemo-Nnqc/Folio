using System.Text.Json;
using System.Text.Json.Nodes;
using Folio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using Windows.Foundation;

namespace Folio.App;

/// <summary>One PDF shown with pdf.js in a WebView2 (Reader/Web/viewer.html).</summary>
sealed class PdfPane : Grid
{
    const string LibraryHost = "folio.library", PreviewHost = "folio.preview";
    readonly AppModel _model;
    public WebView2 Web { get; } = new();
    public FileRecord File { get; set; }
    /// <summary>A translation still being written: its preview file, outside the library.</summary>
    public string? PreviewPath { get; private set; }
    public event Action<JsonNode>? Message;
    bool _ready;
    readonly Queue<string> _pending = new();
    Task _writes = Task.CompletedTask;
    readonly Stack<(long Before, long After)> _undo = new();
    readonly Stack<(long Before, byte[] Tail)> _redo = new();

    static Task<CoreWebView2Environment>? _environment;

    /// <summary>One browser environment for all readers: only the first one pays for starting it.</summary>
    static Task<CoreWebView2Environment> Environment() =>
        _environment ??= CoreWebView2Environment.CreateWithOptionsAsync(null, Path.Combine(AppSettings.Folder, "WebView2"), new CoreWebView2EnvironmentOptions()).AsTask();

    public PdfPane(AppModel model, FileRecord? file, string? previewPath = null)
    {
        _model = model;
        File = file!;
        PreviewPath = previewPath;
        // See-through until the page paints; the page's own surfaces follow the window's transparency.
        Web.DefaultBackgroundColor = Microsoft.UI.Colors.Transparent;
        Children.Add(Web);
        Initialize().Fire();
    }

    async Task Initialize()
    {
        try
        {
            await Web.EnsureCoreWebView2Async(await Environment());
        }
        catch (Exception e)
        {
            // Windows 10 without the WebView2 runtime, or a broken one.
            CrashLog.Write(e);
            Children.Clear();
            var message = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Spacing = 8, MaxWidth = 420 };
            message.Children.Add(new TextBlock { Text = Loc.S("无法打开阅读器：这台电脑缺少 Microsoft Edge WebView2 运行时。"), TextWrapping = TextWrapping.Wrap });
            var link = new HyperlinkButton { Content = Loc.S("下载 WebView2 运行时"), NavigateUri = new Uri("https://developer.microsoft.com/microsoft-edge/webview2/") };
            message.Children.Add(link);
            Children.Add(message);
            return;
        }
        var core = Web.CoreWebView2;
#if DEBUG
        core.Settings.AreDevToolsEnabled = true;
#else
        core.Settings.AreDevToolsEnabled = false;
#endif
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = false;
        // Ctrl+P, Ctrl+F, F5 and the like are Folio's in the reader; the page forwards them.
        core.Settings.AreBrowserAcceleratorKeysEnabled = false;
        core.Settings.IsZoomControlEnabled = false;
        // Must stay on: without it a touchpad pinch never reaches the page. The page handles it itself, so nothing scales the interface (viewer.js).
        core.Settings.IsPinchZoomEnabled = true;
        core.Settings.IsSwipeNavigationEnabled = false;
        core.Settings.IsGeneralAutofillEnabled = false;
        core.Settings.IsPasswordAutosaveEnabled = false;
        core.SetVirtualHostNameToFolderMapping("folio.reader", AppContext.BaseDirectory, CoreWebView2HostResourceAccessKind.Allow);
        // The papers themselves come straight from the library folder: range requests work and nothing is copied into memory.
        core.SetVirtualHostNameToFolderMapping(LibraryHost, _model.Library.Root, CoreWebView2HostResourceAccessKind.Allow);
        if (PreviewPath != null && Path.GetDirectoryName(PreviewPath) is { } previews)
            core.SetVirtualHostNameToFolderMapping(PreviewHost, previews, CoreWebView2HostResourceAccessKind.Allow);
        core.NewWindowRequested += (_, e) => { e.Handled = true; Shell.Open(e.Uri); };
        // Anything that would leave the reader page (a dropped file, a link) opens outside instead.
        core.NavigationStarting += (_, e) =>
        {
            if (e.Uri.StartsWith("https://folio.reader/", StringComparison.OrdinalIgnoreCase)) return;
            e.Cancel = true;
            if (e.Uri.StartsWith("http", StringComparison.OrdinalIgnoreCase)) Shell.Open(e.Uri);
        };
        core.WebMessageReceived += (_, e) =>
        {
            JsonNode? node;
            try { node = JsonNode.Parse(e.WebMessageAsJson); } catch (JsonException) { return; }
            if (node?["type"]?.ToString() == "ready")
            {
                _ready = true;
                while (_pending.Count > 0) core.PostWebMessageAsJson(_pending.Dequeue());
            }
            if (node != null) Message?.Invoke(node);
        };
        core.Navigate("https://folio.reader/Reader/Web/viewer.html");
    }

    public string Path_ => PreviewPath ?? _model.Library.FilePath(File);

    /// <summary>The file's address; a new query each time so a reload never sees an old copy.</summary>
    public string Url
    {
        get
        {
            var version = $"?v={DateTime.UtcNow.Ticks}";
            if (PreviewPath != null) return $"https://{PreviewHost}/{Uri.EscapeDataString(Path.GetFileName(PreviewPath))}{version}";
            var relative = Path.GetRelativePath(_model.Library.Root, _model.Library.FilePath(File));
            return $"https://{LibraryHost}/{string.Join('/', relative.Split('\\', '/').Select(Uri.EscapeDataString))}{version}";
        }
    }

    DateTime _loadedStamp;
    long _loadedLength;

    void RememberFile()
    {
        try { var info = new FileInfo(Path_); _loadedStamp = info.LastWriteTimeUtc; _loadedLength = info.Length; }
        catch (IOException) { }
    }

    /// <summary>Opens the file (first load), remembering which version is on screen.</summary>
    public void Open(object command)
    {
        RememberFile();
        Send(command);
    }

    /// <summary>The file changed underneath the reader (another app, an AI agent, a sync client): show the new one.</summary>
    public void ReloadIfChanged()
    {
        try
        {
            var info = new FileInfo(Path_);
            if (!info.Exists || (info.LastWriteTimeUtc == _loadedStamp && info.Length == _loadedLength)) return;
        }
        catch (IOException) { return; }
        RememberFile();
        lock (_undo) { _undo.Clear(); _redo.Clear(); }
        Send(new { cmd = "reload", url = Url });
    }

    public void Send(object command)
    {
        var json = JsonSerializer.Serialize(command);
        if (_ready) Web.CoreWebView2.PostWebMessageAsJson(json); else _pending.Enqueue(json);
    }

    public void Close()
    {
        try { Web.Close(); } catch (Exception e) { CrashLog.Write(e); }
    }

    // MARK: Changing the file (one at a time, in order, off the UI thread)

    /// <summary>Runs a change to the PDF, remembers how to undo it (changes only append, so undoing is cutting the end
    /// off). What it returns is sent to the page afterwards; the page itself has already drawn the change.</summary>
    public void Change(Func<string, object?> change)
    {
        var path = Path_;
        Enqueue(() =>
        {
            long before = new FileInfo(path).Length;
            var message = change(path);
            long after = new FileInfo(path).Length;
            if (after != before) lock (_undo) { _undo.Push((before, after)); _redo.Clear(); }
            return message;
        });
    }

    public void Undo()
    {
        var path = Path_;
        Enqueue(() =>
        {
            lock (_undo)
            {
                if (_undo.Count == 0) return null;
                var (before, after) = _undo.Pop();
                if (new FileInfo(path).Length != after) { _undo.Clear(); _redo.Clear(); throw new IOException(Loc.S("文件已被其他程序修改")); }
                _redo.Push((before, AnnotationWriter.TruncateTo(path, before)));
                return new { cmd = "undone" };
            }
        });
    }

    public void Redo()
    {
        var path = Path_;
        Enqueue(() =>
        {
            lock (_undo)
            {
                if (_redo.Count == 0) return null;
                var (before, tail) = _redo.Pop();
                if (new FileInfo(path).Length != before) { _undo.Clear(); _redo.Clear(); throw new IOException(Loc.S("文件已被其他程序修改")); }
                AnnotationWriter.Append(path, tail);
                _undo.Push((before, before + tail.Length));
                return new { cmd = "redone" };
            }
        });
    }

    void Enqueue(Func<object?> work)
    {
        var queue = DispatcherQueue;
        _writes = _writes.ContinueWith(_ =>
        {
            try
            {
                var message = work();
                queue.TryEnqueue(() =>
                {
                    RememberFile();
                    if (message != null) Send(message);
                    _model.Importer.RefreshChangedFiles();
                });
            }
            catch (Exception e)
            {
                CrashLog.Write(e);
                _model.Toasts.Show(Loc.S("无法保存标注：%@", e.Message), "warning");
                // What the page shows may no longer be what the file holds.
                queue.TryEnqueue(() =>
                {
                    lock (_undo) { _undo.Clear(); _redo.Clear(); }
                    RememberFile();
                    Send(new { cmd = "reload", url = Url });
                });
            }
        }, TaskScheduler.Default);
    }
}

/// <summary>
/// A paper in a tab (the macOS ReaderWindowController): toolbar with zoom, markup tools and colour, translation, search;
/// pdf.js pages with a thumbnails / outline / annotations / search sidebar; the item's note on the right; the
/// translation side by side with synchronized scrolling.
/// </summary>
public sealed class ReaderView : Grid
{
    readonly AppModel _model;
    FileRecord _file = null!;
    readonly PdfPane _main;
    PdfPane? _parallel;
    readonly Grid _panes;
    readonly ColumnDefinition _notesColumn;
    readonly Grid _notesPanel;
    readonly NoteEditor _notes;
    readonly TextBlock _title, _pageLabel;
    readonly StackPanel _tools;
    readonly Button _colorButton;
    readonly AutoSuggestBox _search;
    readonly TextBlock _searchCount;
    string _tool = "select";
    string _color;
    JsonNode? _selection;
    bool _sidebarVisible = true;
    int _pageCount;
    string? _followingPreview;
    readonly Action<string> _settingsChanged;
    readonly Action<string> _progressChanged;
    readonly Action _jobsChanged, _snapshotChanged;
    readonly Border _translationHud;
    public string FileId => _file.Id;

    /// <summary>A reader with its page loading, not yet showing a paper: see <see cref="Load"/>.</summary>
    public ReaderView(AppModel model)
    {
        _model = model;
        _color = model.Settings.HighlightColor;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var bar = new Grid { Background = UI.Brush("FolioContentBrush"), Padding = new Thickness(16, 8, 12, 8), ColumnSpacing = 8, MinHeight = 48, BorderBrush = UI.Brush("FolioSeparatorBrush"), BorderThickness = new Thickness(0, 0, 0, 1) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 60 });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _title = UI.Label("", 13, bold: true);
        _pageLabel = UI.Label("", 11, secondary: true);
        titles.Children.Add(_title);
        titles.Children.Add(_pageLabel);
        bar.Children.Add(titles);

        _tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        _tools.Children.Add(UI.IconButton("zoomOut", Loc.S("缩小"), (_, _) => Zoom("out"), 15));
        _tools.Children.Add(UI.IconButton("zoomIn", Loc.S("放大"), (_, _) => Zoom("in"), 15));
        var view = new DropDownButton { Content = UI.Icon("thumbnails", 15), Height = 32, MinWidth = 0, Padding = new Thickness(8, 0, 6, 0), CornerRadius = new CornerRadius(6), Background = UI.Brush("TransparentBrush"), BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
        UI.FlatResources(view);
        ToolTipService.SetToolTip(view, Loc.S("显示"));
        view.Flyout = ViewMenu();
        _tools.Children.Add(view);
        _tools.Children.Add(UI.ToolbarSeparator());
        foreach (var (key, icon, tip, shortcut) in Tools)
        {
            var b = UI.ToolToggle(icon, $"{Loc.S(tip)}（Ctrl+Alt+{shortcut}）", key);
            b.IsChecked = key == "select";
            b.Click += (_, _) => SetTool(key);
            _tools.Children.Add(b);
        }
        _colorButton = UI.IconButton("add", Loc.S("批注颜色"), (_, _) => { }, 15);
        var colorMenu = new MenuFlyout();
        foreach (var (key, title, _, _, _) in AnnotationColors.All)
            colorMenu.Items.Add(new MenuFlyoutItem { Text = Loc.S(title), Icon = UI.ColorIcon(AnnotationColors.Hex(key)) }
                .With(m => m.Click += (_, _) => { _color = key; model.Settings.HighlightColor = key; PaintColor(); SetTool(_tool); }));
        _colorButton.Flyout = colorMenu;
        PaintColor();
        _tools.Children.Add(_colorButton);
        _tools.Children.Add(UI.ToolbarSeparator());
        var translate = UI.IconButton("translate", Loc.S("保留排版翻译全文、对照阅读"), (_, _) => { }, 15);
        var translateMenu = new MenuFlyout();
        translateMenu.Opening += (_, _) =>
        {
            translateMenu.Items.Clear();
            bool running = model.Translations.JobOf(_file.ItemId) != null;
            if (_file.IsPdf && _file.TranslationOf == null) translateMenu.Items.Add(UI.Item(Loc.S("翻译全文…"), () => Commands.Translate(model, [_file.ItemId], _file), "translate", !running));
            translateMenu.Items.Add(UI.Item(Loc.S("对照阅读"), ToggleParallel, "parallel"));
            translateMenu.Items.Add(UI.Item(Loc.S("取消翻译"), () => model.Translations.Cancel(_file.ItemId), "close", running));
        };
        translate.Flyout = translateMenu;
        _tools.Children.Add(translate);
        SetColumn(_tools, 1);
        bar.Children.Add(_tools);

        var searchArea = new Grid { VerticalAlignment = VerticalAlignment.Center };
        _search = new AutoSuggestBox { PlaceholderText = Loc.S("在文档中查找"), QueryIcon = new SymbolIcon(Symbol.Find), Width = 180, VerticalAlignment = VerticalAlignment.Center };
        _search.QuerySubmitted += (_, e) => _main!.Send(new { cmd = "find", query = e.QueryText, previous = KeyboardState.Shift });
        _search.TextChanged += (_, e) => { if (string.IsNullOrEmpty(_search.Text) && e.Reason == AutoSuggestionBoxTextChangeReason.UserInput) _main!.Send(new { cmd = "find", query = "" }); };
        searchArea.Children.Add(_search);
        _searchCount = UI.Label("", 11, secondary: true);
        _searchCount.HorizontalAlignment = HorizontalAlignment.Right;
        _searchCount.Margin = new Thickness(0, 0, 36, 0);
        _searchCount.IsHitTestVisible = false;
        searchArea.Children.Add(_searchCount);
        SetColumn(searchArea, 2);
        bar.Children.Add(searchArea);
        Children.Add(bar);

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _notesColumn = new ColumnDefinition { Width = new GridLength(0) };
        body.ColumnDefinitions.Add(_notesColumn);
        _panes = new Grid();
        _panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _main = new PdfPane(model, null);
        _main.Message += m => OnMessage(_main, m);
        _panes.Children.Add(_main);
        body.Children.Add(_panes);
        _notesPanel = new Grid { Background = UI.Brush("FolioInspectorBrush"), BorderBrush = UI.Brush("FolioSeparatorBrush"), BorderThickness = new Thickness(1, 0, 0, 0) };
        _notesPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _notesPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var notesHeader = UI.Label(Loc.S("笔记"), 13, bold: true);
        notesHeader.Margin = new Thickness(16, 14, 16, 6);
        _notesPanel.Children.Add(notesHeader);
        _notes = new NoteEditor(model);
        SetRow(_notes, 1);
        _notesPanel.Children.Add(_notes);
        SetColumn(_notesPanel, 1);
        body.Children.Add(_notesPanel);
        var notesGrip = new Border { Width = 6, HorizontalAlignment = HorizontalAlignment.Left, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        UI.ResizeCursor(notesGrip);
        SetColumn(notesGrip, 1);
        body.Children.Add(notesGrip);
        double gripStart = 0, gripWidth = 0;
        bool gripDragging = false;
        notesGrip.PointerPressed += (_, e) => { gripDragging = true; gripStart = e.GetCurrentPoint(this).Position.X; gripWidth = _notesColumn.ActualWidth; notesGrip.CapturePointer(e.Pointer); };
        notesGrip.PointerMoved += (_, e) =>
        {
            if (!gripDragging) return;
            _notesWidth = Math.Clamp(gripWidth - (e.GetCurrentPoint(this).Position.X - gripStart), 220, 560);
            _notesColumn.Width = new GridLength(_notesWidth);
        };
        notesGrip.PointerReleased += (_, _) => { gripDragging = false; notesGrip.ReleasePointerCaptures(); };
        SetRow(body, 1);
        Children.Add(body);
        _translationHud = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 20), Padding = new Thickness(12, 4, 6, 4),
            CornerRadius = new CornerRadius(14), Background = UI.Brush("ToastBackgroundBrush"), BorderBrush = UI.Brush("FolioSeparatorBrush"), BorderThickness = new Thickness(1), Visibility = Visibility.Collapsed,
        };
        SetRow(_translationHud, 1);
        Children.Add(_translationHud);

        SendTheme(_main);
        SendSurface();
        UI.SurfacesChanged += SendSurface;
        _main.Send(new { cmd = "shadows", on = model.Settings.ReaderPageShadows });
        ActualThemeChanged += (_, _) => { SendTheme(_main); if (_parallel != null) SendTheme(_parallel); };
        Loaded += (_, _) => SendTheme(_main);
        SetTool("select");

        _settingsChanged = key =>
        {
            if (key == "readerPageShadows") DispatcherQueue.TryEnqueue(() => _main.Send(new { cmd = "shadows", on = model.Settings.ReaderPageShadows }));
        };
        model.Settings.Changed += _settingsChanged;
        _progressChanged = id => { if (_file != null && id == _file.ItemId) FollowTranslation(); };
        _jobsChanged = () => { ShowTranslationProgress(); FollowTranslation(); };
        _snapshotChanged = FollowLibrary;
        model.SnapshotChanged += _snapshotChanged;
        model.Translations.ProgressChanged += _progressChanged;
        model.Translations.JobsChanged += _jobsChanged;
    }

    /// <summary>Shows a paper in this reader.</summary>
    public void Load(FileRecord file, int? page)
    {
        _file = file;
        _main.File = file;
        var item = _model.Snapshot.Items.GetValueOrDefault(file.ItemId);
        _title.Text = item?.Kind == ItemKind.Regular ? item.Title : file.FileName;
        _notes.Show(file.ItemId);
        ShowTranslationProgress();
        FocusPage();
        var state = _model.Library.ReadingState(file.Id);
        _main.Open(new
        {
            cmd = "open", url = _main.Url, page = page ?? (state?.PageIndex + 1),
            scale = page == null && state is { AutoScale: false } ? state.Scale : (double?)null,
            top = page == null ? state?.PointY : null, left = page == null ? state?.PointX : null,
            layout = _model.Settings.ReaderLayout == ReaderLayout.TwoUp ? "twoUp" : "single",
            zoom = _model.Settings.ReaderZoom == ReaderZoom.ActualSize ? "actualSize" : "fitWidth",
            labels = Labels(),
            author = Author ?? "",
        });
    }

    void SendSurface()
    {
        _main.Send(new { cmd = "surface", alpha = UI.ReaderSurfaceOpacity });
        _parallel?.Send(new { cmd = "surface", alpha = UI.ReaderSurfaceOpacity });
    }

    public event Action? PanelsChanged;
    public bool SidebarVisible => _sidebarVisible;
    public bool NotesVisible => _notesColumn.Width.Value > 0;

    static readonly (string Key, string Icon, string Tip, string Shortcut)[] Tools =
    [
        ("select", "select", "选择", "0"), ("highlight", "highlight", "高亮", "H"), ("underline", "underline", "下划线", "U"), ("strike", "strike", "删除线", "K"),
        ("note", "note", "便签", "N"), ("textbox", "textbox", "文本框", "T"), ("ink", "ink", "手绘", "D"),
    ];

    void SendTheme(PdfPane pane) => pane.Send(new { cmd = "theme", dark = ActualTheme == ElementTheme.Dark });

    static Dictionary<string, string> Labels() => new()
    {
        ["page"] = Loc.S("第 %lld 页", 0).Replace("0", "%d"),
        ["thumbnails"] = Loc.S("缩略图"), ["outline"] = Loc.S("目录"), ["annotations"] = Loc.S("批注"), ["hits"] = Loc.S("查找结果"),
        ["noAnnotations"] = Loc.S("没有批注"), ["noAnnotationsDetail"] = Loc.S("选中文字后用工具栏添加高亮"),
        ["noOutline"] = Loc.S("没有目录"), ["noOutlineDetail"] = Loc.S("这份 PDF 没有内置目录"),
        ["noMatches"] = Loc.S("未找到"), ["searchHint"] = Loc.S("在工具栏搜索框中输入，结果会列在这里"),
        ["openFailed"] = Loc.S("无法打开这个 PDF"), ["encrypted"] = Loc.S("这个 PDF 需要密码"),
        ["Highlight"] = Loc.S("高亮"), ["Underline"] = Loc.S("下划线"), ["StrikeOut"] = Loc.S("删除线"),
        ["Text"] = Loc.S("便签"), ["FreeText"] = Loc.S("文本框"), ["Ink"] = Loc.S("手绘"),
    };

    MenuFlyout ViewMenu()
    {
        var menu = new MenuFlyout();
        menu.Items.Add(UI.Item(Loc.S("适合页宽"), () => Zoom("page-width")));
        menu.Items.Add(UI.Item(Loc.S("实际大小"), () => Zoom("page-actual")));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(UI.Item(Loc.S("单页连续"), () => { Layout("single"); _model.Settings.ReaderLayout = ReaderLayout.Single; }));
        menu.Items.Add(UI.Item(Loc.S("双页连续"), () => { Layout("twoUp"); _model.Settings.ReaderLayout = ReaderLayout.TwoUp; }));
        menu.Items.Add(new MenuFlyoutSeparator());
        var sidebar = new MenuFlyoutSubItem { Text = Loc.S("阅读边栏") };
        sidebar.Items.Add(UI.Item(Loc.S("缩略图"), () => ShowSidebarTab("thumbnails")));
        sidebar.Items.Add(UI.Item(Loc.S("目录"), () => ShowSidebarTab("outline")));
        sidebar.Items.Add(UI.Item(Loc.S("批注"), () => ShowSidebarTab("annotations")));
        sidebar.Items.Add(UI.Item(Loc.S("查找结果"), () => ShowSidebarTab("hits")));
        menu.Items.Add(sidebar);
        var go = new MenuFlyoutSubItem { Text = Loc.S("前往") };
        go.Items.Add(UI.Item(Loc.S("上一页"), () => Step("previous")));
        go.Items.Add(UI.Item(Loc.S("下一页"), () => Step("next")));
        go.Items.Add(UI.Item(Loc.S("第一页"), () => Step("first")));
        go.Items.Add(UI.Item(Loc.S("最后一页"), () => Step("last")));
        go.Items.Add(new MenuFlyoutSeparator());
        go.Items.Add(UI.Item(Loc.S("后退"), () => _main.Send(new { cmd = "history", value = "back" })));
        go.Items.Add(UI.Item(Loc.S("前进"), () => _main.Send(new { cmd = "history", value = "forward" })));
        go.Items.Add(new MenuFlyoutSeparator());
        go.Items.Add(UI.Item(Loc.S("前往页面…"), () => AskPage().Fire()));
        menu.Items.Add(go);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(UI.Item(Loc.S("添加到笔记"), AddSelectionToNote, "note"));
        menu.Items.Add(UI.Item(Loc.S("打印…"), () => _main.Send(new { cmd = "print" }), "print"));
        menu.Items.Add(UI.Item(Loc.S("在资源管理器中显示"), () => Shell.Reveal(_model.Library.FilePath(_file)), "open"));
        return menu;
    }

    void PaintColor() => _colorButton.Content = UI.Dot(AnnotationColors.Hex(_color), 14);

    void SetTool(string tool)
    {
        _tool = tool;
        foreach (var b in _tools.Children.OfType<ToggleButton>()) b.IsChecked = (string)b.Tag == tool;
        _main.Send(new { cmd = "tool", tool, color = _color });
    }

    void Zoom(string value)
    {
        _main.Send(new { cmd = "zoom", value });
        _parallel?.Send(new { cmd = "zoom", value });
    }

    void Layout(string value)
    {
        _main.Send(new { cmd = "layout", value });
        _parallel?.Send(new { cmd = "layout", value });
    }

    void Step(string value) => _main.Send(new { cmd = "step", value });

    void ShowSidebarTab(string value)
    {
        if (!_sidebarVisible) ToggleSidebar();
        _main.Send(new { cmd = "sidebarTab", value });
    }

    async Task AskPage()
    {
        var text = await Dialogs.Ask(Loc.S("前往页面"), _pageCount > 0 ? Loc.S("页码（1–%lld）", _pageCount) : Loc.S("页码"), primary: Loc.S("前往"));
        if (int.TryParse(text?.Trim(), out var page) && page >= 1) GoToPage(_pageCount > 0 ? Math.Min(page, _pageCount) : page);
    }

    public void GoToPage(int page) => _main.Send(new { cmd = "goto", page });

    public void ToggleSidebar()
    {
        _sidebarVisible = !_sidebarVisible;
        _main.Send(new { cmd = "sidebar", visible = _sidebarVisible });
        PanelsChanged?.Invoke();
    }

    double _notesWidth = 300;

    public void FocusPage() => _main.Web.Focus(FocusState.Programmatic);

    public void ToggleNotes()
    {
        _notesColumn.Width = new GridLength(NotesVisible ? 0 : _notesWidth);
        PanelsChanged?.Invoke();
    }

    public void Close()
    {
        _model.Settings.Changed -= _settingsChanged;
        UI.SurfacesChanged -= SendSurface;
        _model.Translations.ProgressChanged -= _progressChanged;
        _model.Translations.JobsChanged -= _jobsChanged;
        _model.SnapshotChanged -= _snapshotChanged;
        _notes.Flush();
        if (_file != null) _main.Send(new { cmd = "flushPosition" });
        _main.Close();
        _parallel?.Close();
    }

    /// <summary>The paper's file may have been renamed (metadata arrived), its title changed, its note edited elsewhere.</summary>
    void FollowLibrary()
    {
        if (_file == null) return;
        var s = _model.Snapshot;
        if (s.Files.TryGetValue(_file.Id, out var file))
        {
            _file = file;
            _main.File = file;
        }
        if (_parallel is { PreviewPath: null } parallel && s.Files.TryGetValue(parallel.File.Id, out var other)) parallel.File = other;
        var item = s.Items.GetValueOrDefault(_file.ItemId);
        var title = item?.Kind == ItemKind.Regular ? item.Title : _file.FileName;
        if (_title.Text != title) _title.Text = title;
        _notes.Reload();
    }

    /// <summary>The window came forward or this tab was chosen.</summary>
    public void CheckForChanges()
    {
        _main.ReloadIfChanged();
        _parallel?.ReloadIfChanged();
    }

    /// <summary>Progress of this paper's translation, over the pages (the macOS TranslationProgressHUD).</summary>
    void ShowTranslationProgress()
    {
        bool running = _file != null && _model.Translations.JobOf(_file.ItemId) != null;
        if (running && _translationHud.Child == null) _translationHud.Child = new TranslationProgressView(_model, _file.ItemId);
        else if (!running) _translationHud.Child = null;
        _translationHud.Visibility = running ? Visibility.Visible : Visibility.Collapsed;
    }

    public void FocusSearch()
    {
        _search.Focus(FocusState.Keyboard);
        if (_search.FindDescendant<TextBox>() is { } box) box.SelectAll();
    }

    /// <summary>Keys of the reader (from the page or the toolbar). True when the key was used.</summary>
    public bool HandleKey(Windows.System.VirtualKey key, bool ctrl, bool alt, bool shift)
    {
        const Windows.System.VirtualKey Plus = (Windows.System.VirtualKey)187, Minus = (Windows.System.VirtualKey)189, LeftBracket = (Windows.System.VirtualKey)219, RightBracket = (Windows.System.VirtualKey)221;
        if (key == Windows.System.VirtualKey.F3) { Find(shift); return true; }
        if (ctrl && alt)
        {
            int number = key - Windows.System.VirtualKey.Number0;
            switch (key)
            {
                case >= Windows.System.VirtualKey.Number2 and <= Windows.System.VirtualKey.Number5:
                    ShowSidebarTab(new[] { "thumbnails", "outline", "annotations", "hits" }[number - 2]);
                    return true;
                case Windows.System.VirtualKey.Up: Step("previous"); return true;
                case Windows.System.VirtualKey.Down: Step("next"); return true;
                case Windows.System.VirtualKey.G: AskPage().Fire(); return true;
                case Windows.System.VirtualKey.M: AddSelectionToNote(); return true;
            }
            var letter = key == Windows.System.VirtualKey.Number0 ? "0" : key.ToString();
            var tool = Tools.FirstOrDefault(t => t.Shortcut == letter);
            if (tool.Key != null) { SetTool(tool.Key); return true; }
            return false;
        }
        if (alt && key == Windows.System.VirtualKey.Left) { _main.Send(new { cmd = "history", value = "back" }); return true; }
        if (alt && key == Windows.System.VirtualKey.Right) { _main.Send(new { cmd = "history", value = "forward" }); return true; }
        if (!ctrl) return false;
        switch (key)
        {
            case Plus or Windows.System.VirtualKey.Add: Zoom("in"); return true;
            case Minus or Windows.System.VirtualKey.Subtract: Zoom("out"); return true;
            case Windows.System.VirtualKey.Number0 or Windows.System.VirtualKey.NumberPad0: Zoom("page-actual"); return true;
            case Windows.System.VirtualKey.Number9: Zoom("page-width"); return true;
            case Windows.System.VirtualKey.Z when !shift: _main.Undo(); return true;
            case Windows.System.VirtualKey.Z or Windows.System.VirtualKey.Y: _main.Redo(); return true;
            case Windows.System.VirtualKey.P: _main.Send(new { cmd = "print" }); return true;
            case Windows.System.VirtualKey.F: FocusSearch(); return true;
            case Windows.System.VirtualKey.G: Find(shift); return true;
            case LeftBracket: _main.Send(new { cmd = "history", value = "back" }); return true;
            case RightBracket: _main.Send(new { cmd = "history", value = "forward" }); return true;
        }
        return false;
    }

    void Find(bool previous)
    {
        if (string.IsNullOrEmpty(_search.Text)) { FocusSearch(); return; }
        _main.Send(new { cmd = "find", query = _search.Text, previous });
    }

    // MARK: Parallel reading

    /// <summary>The newest translation, plain before side by side (as on macOS); from a translation, its original.</summary>
    FileRecord? TranslationFile()
    {
        var files = _model.Snapshot.FilesOf(_file.ItemId);
        if (_file.TranslationOf != null) return files.FirstOrDefault(f => f.Id == _file.TranslationOf);
        var translations = files.Where(f => f.TranslationOf == _file.Id).OrderByDescending(f => f.DateAdded).ToList();
        return translations.FirstOrDefault(f => f.TranslationKind == TranslationKind.Mono) ?? translations.FirstOrDefault();
    }

    void ToggleParallel()
    {
        if (_parallel != null)
        {
            CloseParallel();
            return;
        }
        var job = _model.Translations.JobOf(_file.ItemId);
        var translation = TranslationFile();
        if (translation == null && job?.Preview is { } preview && File.Exists(preview))
        {
            _followingPreview = preview;
            ShowParallel(_file, preview);
            return;
        }
        if (translation == null)
        {
            _model.Toasts.Show(Loc.S("这篇论文还没有译文。可以先\"翻译全文\""), "translate");
            return;
        }
        ShowParallel(translation, null);
    }

    void ShowParallel(FileRecord file, string? preview)
    {
        CloseParallel();
        _panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var pane = new PdfPane(_model, file, preview);
        _parallel = pane;
        pane.Message += m => OnMessage(pane, m);
        SetColumn(pane, 1);
        _panes.Children.Add(pane);
        pane.Open(new { cmd = "open", url = pane.Url, zoom = "fitWidth", labels = Labels(), layout = _model.Settings.ReaderLayout == ReaderLayout.TwoUp ? "twoUp" : "single" });
        pane.Send(new { cmd = "sidebar", visible = false });
        SendTheme(pane);
        pane.Send(new { cmd = "surface", alpha = UI.ReaderSurfaceOpacity });
    }

    void CloseParallel()
    {
        _followingPreview = null;
        if (_parallel == null) return;
        _panes.Children.Remove(_parallel);
        _parallel.Close();
        _parallel = null;
        _panes.ColumnDefinitions.RemoveAt(1);
    }

    /// <summary>边翻边看: while this paper is being translated, 对照阅读 shows the pages done so far; when the translation is
    /// filed it switches to it.</summary>
    void FollowTranslation()
    {
        if (_file == null || _followingPreview == null || _parallel == null) return;
        var job = _model.Translations.JobOf(_file.ItemId);
        if (job?.Preview is { } preview)
        {
            if (preview != _followingPreview) { _followingPreview = preview; ShowParallel(_file, preview); _followingPreview = preview; }
            else _parallel.Send(new { cmd = "reload", url = _parallel.Url });
        }
        else if (job == null)
        {
            var finished = TranslationFile();
            CloseParallel();
            if (finished != null) ShowParallel(finished, null);
        }
    }

    // MARK: Messages from the page

    void OnMessage(PdfPane pane, JsonNode m)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            try { Handle(pane, m); }
            catch (Exception e) { CrashLog.Write(e); }
        });
    }

    void Handle(PdfPane pane, JsonNode m)
    {
        switch (m["type"]?.ToString())
        {
            case "error":
                // A damaged or locked PDF is the user's news, not a crash.
                if ((bool?)m["fatal"] == true) _model.Toasts.Show(m["name"]?.ToString() == "PasswordException" ? Loc.S("这个 PDF 需要密码") : Loc.S("无法打开这个 PDF"), "warning");
                else CrashLog.Write(new InvalidOperationException($"Reader: {m["message"]} {m["detail"]}"));
                break;
            case "password":
                AskPassword(pane, (bool?)m["wrong"] == true).Fire();
                break;
            case "loaded" when pane == _main:
                _pageCount = (int)m["pages"]!;
                break;
            case "page" when pane == _main:
                if ((int)m["pages"]! > 0) _pageLabel.Text = Loc.S("第 %lld / %lld 页", (int)m["page"]!, (int)m["pages"]!);
                break;
            case "position" when pane == _main:
                _model.SaveReadingState(new ReadingState(pane.File.Id, (int)m["page"]! - 1, (double?)m["left"] ?? 0, (double?)m["top"] ?? 0,
                    (double?)m["scale"] ?? 1, (bool?)m["autoScale"] ?? true, _model.Settings.ReaderLayout == ReaderLayout.TwoUp ? 3 : 1, DateTime.UtcNow));
                break;
            case "scroll":
                var other = pane == _main ? _parallel : _main;
                other?.Send(new { cmd = "scrollTo", page = (int)m["page"]!, fraction = (double)m["fraction"]! });
                break;
            case "selection":
                _selection = m["text"]?.ToString() is { Length: > 0 } ? m : null;
                break;
            case "markup":
                WriteMarkup(pane, m);
                break;
            case "ink":
                var ink = m["strokes"]!.AsArray().Select(s => s!.AsArray().Select(v => (double)v!).ToArray()).ToList();
                var inkPage = (int)m["page"]!;
                var inkTemp = m["temp"]!.ToString();
                pane.Change(path => Resolved([inkTemp], AnnotationWriter.Add(path, [new NewAnnotation(inkPage, "Ink", m["color"]?.ToString() ?? _color, Strokes: ink, Author: Author)])));
                break;
            case "note":
            case "textbox":
                PlaceTextAnnotation(pane, m);
                break;
            case "annotationEdit":
                EditText(pane, m["contents"]?.ToString() ?? "", Point(m), text => SetContents(pane, m, text));
                break;
            case "annotationDelete":
                DeleteAnnotation(pane, m, pageAlreadyUpdated: true);
                break;
            case "annotationMoved":
                pane.Change(path => { AnnotationWriter.Modify(path, (int)m["page"]!, ObjectNumber(m), dx: (double)m["dx"]!, dy: (double)m["dy"]!); return null; });
                break;
            case "contextMenu":
                ShowContextMenu(pane, m);
                break;
            case "findCount":
                if (pane == _main) _searchCount.Text = (int?)m["total"] is > 0 and var total ? $"{(int?)m["current"]}/{total}" : "";
                break;
            case "toolReset":
                SetTool("select");
                break;
            case "key":
                if (Enum.TryParse<Windows.System.VirtualKey>(KeyName(m["code"]?.ToString() ?? ""), out var key))
                {
                    bool ctrl = (bool?)m["ctrl"] == true, alt = (bool?)m["alt"] == true, shift = (bool?)m["shift"] == true;
                    if (App.Current?.Window?.HandleGlobalKey(key, ctrl, alt, shift) != true) HandleKey(key, ctrl, alt, shift);
                }
                break;
            case "link":
                Shell.Open(m["url"]!.ToString());
                break;
        }
    }

    /// <summary>A KeyboardEvent.code as the name of a VirtualKey.</summary>
    static string KeyName(string code)
    {
        if (code.StartsWith("Key")) return code[3..];
        if (code.StartsWith("Digit")) return "Number" + code[5..];
        return code switch
        {
            "ArrowLeft" => "Left", "ArrowRight" => "Right", "ArrowUp" => "Up", "ArrowDown" => "Down",
            "Equal" => "187", "Minus" => "189", "Comma" => "188", "BracketLeft" => "219", "BracketRight" => "221",
            "NumpadAdd" => "Add", "NumpadSubtract" => "Subtract", "Numpad0" => "NumberPad0",
            _ => code,
        };
    }

    string? Author => Text.NonEmpty(_model.Settings.AnnotationAuthor);

    static Point Point(JsonNode m) => new((double?)m["clientX"] ?? 0, (double?)m["clientY"] ?? 0);

    /// <summary>pdf.js names an annotation after its object: "123R".</summary>
    static long ObjectNumber(JsonNode m)
    {
        var id = m["id"]?.ToString() ?? "";
        var digits = new string(id.TakeWhile(char.IsDigit).ToArray());
        return long.TryParse(digits, out var n) ? n : throw new InvalidOperationException(Loc.S("这个批注不能修改"));
    }

    /// <summary>A locked PDF: asks for its password (it stays in memory only).</summary>
    async Task AskPassword(PdfPane pane, bool wrong)
    {
        var box = new PasswordBox { Width = 320, PlaceholderText = Loc.S("密码") };
        var content = new StackPanel { Spacing = 8 };
        if (wrong) content.Children.Add(new TextBlock { Text = Loc.S("密码不正确"), Foreground = UI.Hex("#FF3B30"), FontSize = 12 });
        content.Children.Add(box);
        box.Loaded += (_, _) => box.Focus(FocusState.Programmatic);
        var dialog = new ContentDialog { Title = Loc.S("这个 PDF 需要密码"), Content = content, PrimaryButtonText = Loc.S("好"), CloseButtonText = Loc.S("取消"), DefaultButton = ContentDialogButton.Primary };
        bool ok = await Dialogs.Custom(dialog) == ContentDialogResult.Primary;
        pane.Send(new { cmd = "password", value = ok ? box.Password : null });
    }

    /// <summary>Tells the page the object numbers of what it drew under a temporary name.</summary>
    static object Resolved(IReadOnlyList<string> temps, IReadOnlyList<long> numbers) =>
        new { cmd = "resolved", map = temps.Zip(numbers, (temp, number) => new { temp, id = $"{number}R" }).ToArray() };

    void WriteMarkup(PdfPane pane, JsonNode m)
    {
        var subtype = m["subtype"]!.ToString();
        var color = m["color"]?.ToString() ?? _color;
        var annotations = new List<NewAnnotation>();
        var temps = new List<string>();
        foreach (var page in m["pages"]!.AsArray())
        {
            var quads = page!["quads"]!.AsArray().Select(q => q!.AsArray().Select(v => (double)v!).ToArray()).ToList();
            annotations.Add(new NewAnnotation((int)page["page"]!, subtype, color, Quads: quads, Author: Author));
            temps.Add(page["temp"]!.ToString());
        }
        pane.Change(path => Resolved(temps, AnnotationWriter.Add(path, annotations)));
    }

    void PlaceTextAnnotation(PdfPane pane, JsonNode m)
    {
        bool note = m["type"]!.ToString() == "note";
        double x = (double)m["x"]!, y = (double)m["y"]!;
        int page = (int)m["page"]!;
        var color = m["color"]?.ToString() ?? _color;
        SetTool("select");
        EditText(pane, "", Point(m), text =>
        {
            if (text.Length == 0) return;
            int lines = Math.Max(1, (int)Math.Ceiling(text.Sum(c => c > 0x2E80 ? 12.0 : 6.5) / 208) + text.Count(c => c == '\n'));
            var rect = note ? new[] { x - 10, y - 10, x + 10, y + 10 } : [x, y - Math.Max(24, lines * 15 + 8), x + 220, y];
            var subtype = note ? "Text" : "FreeText";
            var temp = $"pending-{Guid.NewGuid():N}";
            pane.Send(new { cmd = "addEntry", temp, page, subtype, rect, color, contents = text });
            pane.Change(path => Resolved([temp], AnnotationWriter.Add(path, [new NewAnnotation(page, subtype, color, Rect: rect, Contents: text, Author: Author)])));
        });
    }

    void SetContents(PdfPane pane, JsonNode m, string text)
    {
        int page = (int)m["page"]!;
        var id = m["id"]!.ToString();
        var number = ObjectNumber(m);
        pane.Send(new { cmd = "modifyEntry", page, id, contents = text });
        pane.Change(path => { AnnotationWriter.Modify(path, page, number, contents: text); return null; });
    }

    void SetColor(PdfPane pane, JsonNode m, string color)
    {
        int page = (int)m["page"]!;
        var id = m["id"]!.ToString();
        var number = ObjectNumber(m);
        pane.Send(new { cmd = "modifyEntry", page, id, color });
        pane.Change(path => { AnnotationWriter.Modify(path, page, number, color: color); return null; });
    }

    /// <summary>The small text editor beside an annotation; what it holds when it closes is applied.</summary>
    void EditText(PdfPane pane, string text, Point at, Action<string> done)
    {
        var box = new TextBox { Text = text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Width = 280, Height = 140 };
        ScrollViewer.SetVerticalScrollBarVisibility(box, ScrollBarVisibility.Auto);
        var flyout = new Flyout { Content = box, ShouldConstrainToRootBounds = true };
        flyout.Opened += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectionStart = box.Text.Length; };
        flyout.Closed += (_, _) =>
        {
            if (UI.Lf(box.Text) != UI.Lf(text)) done(UI.Lf(box.Text).Trim());
            pane.Web.Focus(FocusState.Programmatic);
        };
        flyout.ShowAt(pane.Web, new FlyoutShowOptions { Position = at, Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
    }

    void DeleteAnnotation(PdfPane pane, JsonNode m, bool pageAlreadyUpdated = false)
    {
        var page = (int)m["page"]!;
        var number = ObjectNumber(m);
        if (!pageAlreadyUpdated) pane.Send(new { cmd = "removeEntry", page, id = m["id"]!.ToString() });
        pane.Change(path => { AnnotationWriter.Remove(path, page, number); return null; });
    }

    void ShowContextMenu(PdfPane pane, JsonNode m)
    {
        var menu = new MenuFlyout();
        switch (m["kind"]?.ToString())
        {
            case "annotation":
                FillAnnotationMenu(menu, pane, m);
                break;
            case "selection":
                var text = m["text"]!.ToString();
                int page = (int?)m["pages"]?[0]?["page"] ?? 1;
                menu.Items.Add(UI.Item(Loc.S("拷贝"), () => Shell.CopyText(text), "copy"));
                menu.Items.Add(UI.Item(Loc.S("拷贝为引用"), () => CopyAsCitation(text, page), "cite"));
                menu.Items.Add(new MenuFlyoutSeparator());
                foreach (var (subtype, title, icon) in new[] { ("Highlight", "高亮", "highlight"), ("Underline", "下划线", "underline"), ("StrikeOut", "删除线", "strike") })
                    menu.Items.Add(UI.Item(Loc.S(title), () => pane.Send(new { cmd = "markSelection", subtype }), icon));
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(UI.Item(Loc.S("添加到笔记"), () => AddToNote(text, page), "note"));
                break;
            case "page":
                menu.Items.Add(UI.Item(Loc.S("放大"), () => Zoom("in"), "zoomIn"));
                menu.Items.Add(UI.Item(Loc.S("缩小"), () => Zoom("out"), "zoomOut"));
                menu.Items.Add(UI.Item(Loc.S("实际大小"), () => Zoom("page-actual")));
                menu.Items.Add(UI.Item(Loc.S("适合页宽"), () => Zoom("page-width")));
                menu.Items.Add(new MenuFlyoutSeparator());
                menu.Items.Add(UI.Item(Loc.S("单页连续"), () => { Layout("single"); _model.Settings.ReaderLayout = ReaderLayout.Single; }));
                menu.Items.Add(UI.Item(Loc.S("双页连续"), () => { Layout("twoUp"); _model.Settings.ReaderLayout = ReaderLayout.TwoUp; }));
                break;
            default:
                return;
        }
        menu.ShowAt(pane.Web, new FlyoutShowOptions { Position = Point(m) });
    }

    void FillAnnotationMenu(MenuFlyout menu, PdfPane pane, JsonNode m)
    {
        var subtype = m["subtype"]?.ToString();
        var contents = m["contents"]?.ToString() ?? "";
        var quoted = m["quoted"]?.ToString() ?? "";
        var current = m["colorKey"]?.ToString();
        int page = (int)m["page"]!;
        var at = Point(m);
        var colors = new MenuFlyoutSubItem { Text = Loc.S("颜色") };
        foreach (var (key, title, _, _, _) in AnnotationColors.All)
        {
            var color = new MenuFlyoutItem { Text = Loc.S(title), Icon = UI.ColorIcon(AnnotationColors.Hex(key)) };
            if (key == current) color.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            color.Click += (_, _) => SetColor(pane, m, key);
            colors.Items.Add(color);
        }
        menu.Items.Add(colors);
        menu.Items.Add(new MenuFlyoutSeparator());
        bool textual = subtype is "Text" or "FreeText";
        var editTitle = textual ? Loc.S("编辑内容…") : contents.Length == 0 ? Loc.S("添加评论…") : Loc.S("编辑评论…");
        menu.Items.Add(UI.Item(editTitle, () => EditText(pane, contents, at, text => SetContents(pane, m, text)), "edit"));
        var text = quoted.Length > 0 ? quoted : contents;
        if (text.Length > 0)
        {
            menu.Items.Add(UI.Item(Loc.S("添加到笔记"), () => AddToNote(text, page), "note"));
            menu.Items.Add(UI.Item(Loc.S("拷贝文字"), () => Shell.CopyText(text), "copy"));
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(UI.Item(Loc.S("删除批注"), () => DeleteAnnotation(pane, m), "delete"));
    }

    void AddSelectionToNote()
    {
        if (_selection?["text"]?.ToString() is not { Length: > 0 } text)
        {
            _model.Toasts.Show(Loc.S("先选中要摘录的文字"), "info");
            return;
        }
        AddToNote(text, (int?)_selection["pages"]?[0]?["page"] ?? 1);
    }

    void AddToNote(string text, int page)
    {
        if (!NotesVisible) ToggleNotes();
        _notes.AppendQuote(_file.ItemId, text, page);
        _notes.FocusEditor();
    }

    void CopyAsCitation(string text, int page)
    {
        var reference = "";
        if (_model.Snapshot.Items.GetValueOrDefault(_file.ItemId) is { Kind: ItemKind.Regular } item)
        {
            var first = item.Authors.FirstOrDefault()?.Family;
            var author = first == null ? "" : item.Authors.Count > 1 ? $"{first} et al." : first;
            reference = string.Join(", ", new[] { author, item.Year?.ToString() }.Where(s => !string.IsNullOrEmpty(s)));
        }
        var citation = reference.Length == 0 ? $"p. {page}" : $"{reference}, p. {page}";
        Shell.CopyText(Loc.S("“%1$@”（%2$@）", text, citation));
        _model.Toasts.Show(Loc.S("已拷贝为引用"), "cite");
    }
}
