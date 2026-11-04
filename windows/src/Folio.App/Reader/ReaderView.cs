using System.Text.Json;
using System.Text.Json.Nodes;
using Folio.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;

namespace Folio.App;

/// <summary>One PDF shown with pdf.js in a WebView2 (Reader/Web/viewer.html).</summary>
sealed class PdfPane : Grid
{
    readonly AppModel _model;
    public WebView2 Web { get; } = new();
    public FileRecord File { get; private set; }
    public event Action<JsonNode>? Message;
    bool _ready;
    readonly Queue<string> _pending = new();

    public PdfPane(AppModel model, FileRecord file)
    {
        _model = model;
        File = file;
        Children.Add(Web);
        _ = Initialize();
    }

    async Task Initialize()
    {
        var folder = Path.Combine(AppSettings.Folder, "WebView2");
        var environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, folder, new CoreWebView2EnvironmentOptions());
        await Web.EnsureCoreWebView2Async(environment);
        var core = Web.CoreWebView2;
        core.Settings.AreDevToolsEnabled = System.Diagnostics.Debugger.IsAttached;
        core.Settings.IsStatusBarEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = true;
        core.Settings.IsZoomControlEnabled = false;
        core.SetVirtualHostNameToFolderMapping("folio.reader", AppContext.BaseDirectory, CoreWebView2HostResourceAccessKind.Allow);
        // The paper itself is served from the library under the same origin.
        core.AddWebResourceRequestedFilter("https://folio.reader/library/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += (_, e) =>
        {
            var path = _model.Library.FilePath(File);
            try
            {
                var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                e.Response = core.Environment.CreateWebResourceResponse(stream.AsRandomAccessStream(), 200, "OK", "Content-Type: application/pdf\r\nCache-Control: no-store");
            }
            catch (IOException) { e.Response = core.Environment.CreateWebResourceResponse(null, 404, "Not Found", ""); }
        };
        core.NewWindowRequested += (_, e) => { e.Handled = true; Shell.Open(e.Uri); };
        core.WebMessageReceived += (_, e) =>
        {
            var node = JsonNode.Parse(e.WebMessageAsJson);
            if (node?["type"]?.ToString() == "ready")
            {
                _ready = true;
                while (_pending.Count > 0) core.PostWebMessageAsJson(_pending.Dequeue());
            }
            if (node != null) Message?.Invoke(node);
        };
        core.Navigate("https://folio.reader/Reader/Web/viewer.html");
    }

    public string Url => $"https://folio.reader/library/{File.Id}?v={DateTime.UtcNow.Ticks}";

    public void Send(object command)
    {
        var json = JsonSerializer.Serialize(command);
        if (_ready) Web.CoreWebView2.PostWebMessageAsJson(json); else _pending.Enqueue(json);
    }
}

/// <summary>
/// A paper in a tab (the macOS ReaderWindowController): toolbar with page, layout, markup tools and colour, search;
/// pdf.js pages with a thumbnails / outline / annotations / search sidebar; the item's note on the right; the
/// translation side by side with synchronized scrolling.
/// </summary>
public sealed class ReaderView : Grid
{
    readonly AppModel _model;
    readonly PdfPane _main;
    PdfPane? _parallel;
    readonly Grid _panes;
    readonly ColumnDefinition _notesColumn;
    readonly NoteEditor _notes;
    readonly TextBlock _title, _pageLabel;
    readonly StackPanel _tools;
    readonly Button _colorButton;
    readonly AutoSuggestBox _search;
    string _tool = "select";
    string _color;
    JsonNode? _selection;
    bool _sidebarVisible = true;
    public string FileId => _main.File.Id;

    public ReaderView(AppModel model, FileRecord file, int? page)
    {
        _model = model;
        _color = model.Settings.HighlightColor;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Background = UI.Brush("FolioContentBrush");

        var bar = new Grid { Padding = new Thickness(12, 6, 12, 6), ColumnSpacing = 8, BorderBrush = UI.Brush("FolioSeparatorBrush"), BorderThickness = new Thickness(0, 0, 0, 1) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var item = model.Snapshot.Items.GetValueOrDefault(file.ItemId);
        _title = UI.Label(item?.Kind == ItemKind.Regular ? item.Title : file.FileName, 13, bold: true);
        _pageLabel = UI.Label("", 11, secondary: true);
        titles.Children.Add(_title);
        titles.Children.Add(_pageLabel);
        bar.Children.Add(titles);

        _tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        var view = new DropDownButton { Content = UI.Icon("thumbnails", 14), Padding = new Thickness(8, 5, 8, 5) };
        ToolTipService.SetToolTip(view, Loc.S("显示"));
        var viewMenu = new MenuFlyout();
        viewMenu.Items.Add(UI.Item(Loc.S("单页连续"), () => { _main.Send(new { cmd = "layout", value = "single" }); model.Settings.ReaderLayout = ReaderLayout.Single; }));
        viewMenu.Items.Add(UI.Item(Loc.S("双页连续"), () => { _main.Send(new { cmd = "layout", value = "twoUp" }); model.Settings.ReaderLayout = ReaderLayout.TwoUp; }));
        viewMenu.Items.Add(new MenuFlyoutSeparator());
        viewMenu.Items.Add(UI.Item(Loc.S("适合页宽"), () => Zoom("page-width"), "zoomIn"));
        viewMenu.Items.Add(UI.Item(Loc.S("实际大小"), () => Zoom("page-actual")));
        viewMenu.Items.Add(UI.Item(Loc.S("放大"), () => Zoom("in"), "zoomIn"));
        viewMenu.Items.Add(UI.Item(Loc.S("缩小"), () => Zoom("out"), "zoomOut"));
        view.Flyout = viewMenu;
        _tools.Children.Add(view);
        _tools.Children.Add(new AppBarSeparator());
        foreach (var (key, icon, tip) in new[] { ("select", "select", "选择"), ("highlight", "highlight", "高亮"), ("underline", "underline", "下划线"), ("strike", "strike", "删除线"),
                                                 ("note", "note", "便签"), ("textbox", "textbox", "文本框"), ("ink", "ink", "手绘") })
        {
            var b = new ToggleButton { Content = UI.Icon(icon, 15), Padding = new Thickness(8, 5, 8, 5), Tag = key, IsChecked = key == "select", Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
            ToolTipService.SetToolTip(b, Loc.S(tip));
            b.Click += (_, _) => SetTool(key);
            _tools.Children.Add(b);
        }
        _colorButton = new Button { Padding = new Thickness(8, 5, 8, 5), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
        var colorMenu = new MenuFlyout();
        foreach (var (key, title, _, _, _) in AnnotationColors.All)
            colorMenu.Items.Add(new MenuFlyoutItem { Text = Loc.S(title), Icon = new FontIcon { Glyph = "", FontFamily = UI.IconFont, Foreground = UI.Hex(AnnotationColors.Hex(key)) } }
                .With(m => m.Click += (_, _) => { _color = key; model.Settings.HighlightColor = key; PaintColor(); SetTool(_tool); }));
        _colorButton.Flyout = colorMenu;
        ToolTipService.SetToolTip(_colorButton, Loc.S("颜色"));
        PaintColor();
        _tools.Children.Add(_colorButton);
        _tools.Children.Add(new AppBarSeparator());
        _tools.Children.Add(UI.IconButton("note", Loc.S("加入笔记"), (_, _) => AddSelectionToNote(), 15));
        var translations = model.Snapshot.FilesOf(file.ItemId).Where(f => f.TranslationOf == file.Id || (file.TranslationOf != null && f.Id == file.TranslationOf)).ToList();
        if (translations.Count > 0)
            _tools.Children.Add(UI.IconButton("translate", Loc.S("对照阅读"), (_, _) => ToggleParallel(translations[0]), 15));
        SetColumn(_tools, 1);
        bar.Children.Add(_tools);
        _search = new AutoSuggestBox { PlaceholderText = Loc.S("搜索"), QueryIcon = new SymbolIcon(Symbol.Find), Width = 200, VerticalAlignment = VerticalAlignment.Center };
        _search.QuerySubmitted += (_, e) => _main.Send(new { cmd = "find", query = e.QueryText });
        SetColumn(_search, 2);
        bar.Children.Add(_search);
        Children.Add(bar);

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _notesColumn = new ColumnDefinition { Width = new GridLength(0) };
        body.ColumnDefinitions.Add(_notesColumn);
        _panes = new Grid();
        _panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _main = new PdfPane(model, file);
        _main.Message += m => OnMessage(_main, m);
        _panes.Children.Add(_main);
        body.Children.Add(_panes);
        _notes = new NoteEditor(model) { Background = UI.Brush("FolioInspectorBrush"), BorderBrush = UI.Brush("FolioSeparatorBrush"), BorderThickness = new Thickness(1, 0, 0, 0) };
        _notes.Show(file.ItemId);
        SetColumn(_notes, 1);
        body.Children.Add(_notes);
        SetRow(body, 1);
        Children.Add(body);

        var state = model.Library.ReadingState(file.Id);
        _main.Send(new
        {
            cmd = "open", url = _main.Url, page = page ?? (state?.PageIndex + 1),
            scale = page == null && state is { AutoScale: false } ? state.Scale : (double?)null,
            top = page == null ? state?.PointY : null, left = page == null ? state?.PointX : null,
            layout = model.Settings.ReaderLayout == ReaderLayout.TwoUp ? "twoUp" : "single",
            zoom = model.Settings.ReaderZoom == ReaderZoom.ActualSize ? "actualSize" : "fitWidth",
            labels = Labels(),
        });
        _main.Send(new { cmd = "theme", dark = ActualTheme == ElementTheme.Dark });
        _main.Send(new { cmd = "shadows", on = model.Settings.ReaderPageShadows });
        ActualThemeChanged += (_, _) => { _main.Send(new { cmd = "theme", dark = ActualTheme == ElementTheme.Dark }); _parallel?.Send(new { cmd = "theme", dark = ActualTheme == ElementTheme.Dark }); };
        SetTool("select");
    }

    static Dictionary<string, string> Labels() => new()
    {
        ["page"] = Loc.S("第 %lld 页", 0).Replace("0", "%d"),
        ["noAnnotations"] = Loc.S("没有标注"),
        ["noOutline"] = Loc.S("没有目录"),
        ["noMatches"] = Loc.S("没有找到"),
        ["Highlight"] = Loc.S("高亮"), ["Underline"] = Loc.S("下划线"), ["StrikeOut"] = Loc.S("删除线"),
        ["Text"] = Loc.S("便签"), ["FreeText"] = Loc.S("文本框"), ["Ink"] = Loc.S("手绘"),
    };

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

    public void GoToPage(int page) => _main.Send(new { cmd = "goto", page });

    public void ToggleSidebar()
    {
        _sidebarVisible = !_sidebarVisible;
        _main.Send(new { cmd = "sidebar", visible = _sidebarVisible });
    }

    public void ToggleNotes() => _notesColumn.Width = new GridLength(_notesColumn.ActualWidth < 1 ? 300 : 0);

    public void Close()
    {
        _main.Web.Close();
        _parallel?.Web.Close();
    }

    void ToggleParallel(FileRecord other)
    {
        if (_parallel != null)
        {
            _panes.Children.Remove(_parallel);
            _parallel.Web.Close();
            _parallel = null;
            _panes.ColumnDefinitions.RemoveAt(1);
            return;
        }
        _panes.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _parallel = new PdfPane(_model, other);
        _parallel.Message += m => OnMessage(_parallel, m);
        SetColumn(_parallel, 1);
        _panes.Children.Add(_parallel);
        _parallel.Send(new { cmd = "open", url = _parallel.Url, zoom = "fitWidth", labels = Labels() });
        _parallel.Send(new { cmd = "sidebar", visible = false });
        _parallel.Send(new { cmd = "theme", dark = ActualTheme == ElementTheme.Dark });
    }

    // MARK: Messages from the page

    void OnMessage(PdfPane pane, JsonNode m)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            switch (m["type"]?.ToString())
            {
                case "page" when pane == _main:
                    _pageLabel.Text = Loc.S("第 %lld / %lld 页", (int)m["page"]!, (int)m["pages"]!);
                    break;
                case "position" when pane == _main:
                    _model.Library.SaveReadingState(new ReadingState(pane.File.Id, (int)m["page"]! - 1, (double?)m["left"] ?? 0, (double?)m["top"] ?? 0,
                        (double?)m["scale"] ?? 1, (bool?)m["autoScale"] ?? true, _model.Settings.ReaderLayout == ReaderLayout.TwoUp ? 3 : 1, DateTime.UtcNow));
                    break;
                case "scroll":
                    var other = pane == _main ? _parallel : _main;
                    other?.Send(new { cmd = "scrollTo", ratio = (double)m["ratio"]! });
                    break;
                case "selection":
                    _selection = m["text"]?.ToString() is { Length: > 0 } ? m : null;
                    break;
                case "markup":
                    WriteMarkup(pane, m);
                    break;
                case "ink":
                    var ink = m["strokes"]!.AsArray().Select(s => s!.AsArray().Select(v => (double)v!).ToArray()).ToList();
                    Write(pane, [new NewAnnotation((int)m["page"]!, "Ink", _color, Strokes: ink, Author: _model.Settings.AnnotationAuthor)]);
                    break;
                case "note":
                case "textbox":
                    _ = AddTextAnnotation(pane, m);
                    break;
                case "link":
                    Shell.Open(m["url"]!.ToString());
                    break;
            }
        });
    }

    void WriteMarkup(PdfPane pane, JsonNode m)
    {
        var annotations = new List<NewAnnotation>();
        foreach (var page in m["pages"]!.AsArray())
        {
            var quads = page!["quads"]!.AsArray().Select(q => q!.AsArray().Select(v => (double)v!).ToArray()).ToList();
            annotations.Add(new NewAnnotation((int)page["page"]!, m["subtype"]!.ToString(), m["color"]?.ToString() ?? _color, Quads: quads, Author: _model.Settings.AnnotationAuthor));
        }
        Write(pane, annotations);
    }

    async Task AddTextAnnotation(PdfPane pane, JsonNode m)
    {
        bool note = m["type"]!.ToString() == "note";
        var text = await Dialogs.Ask(note ? Loc.S("便签") : Loc.S("文本框"), Loc.S("输入内容"), primary: Loc.S("添加"));
        if (string.IsNullOrWhiteSpace(text)) return;
        double x = (double)m["x"]!, y = (double)m["y"]!;
        var rect = note ? new[] { x, y - 20, x + 20, y } : [x, y - 24, x + Math.Max(80, Math.Min(360, text.Length * 7)), y];
        Write(pane, [new NewAnnotation((int)m["page"]!, note ? "Text" : "FreeText", _color, Rect: rect, Contents: text, Author: _model.Settings.AnnotationAuthor)]);
    }

    void Write(PdfPane pane, List<NewAnnotation> annotations)
    {
        var path = _model.Library.FilePath(pane.File);
        _ = Task.Run(() =>
        {
            try
            {
                AnnotationWriter.Add(path, annotations);
                DispatcherQueue.TryEnqueue(() =>
                {
                    pane.Send(new { cmd = "reload", url = pane.Url });
                    _model.Importer.RefreshChangedFiles();
                });
            }
            catch (Exception e) { _model.Toasts.Show(Loc.S("无法保存标注：%@", e.Message), "warning"); }
        });
    }

    void AddSelectionToNote()
    {
        if (_selection?["text"]?.ToString() is not { Length: > 0 } text)
        {
            _model.Toasts.Show(Loc.S("先选中要摘录的文字"), "info");
            return;
        }
        int page = (int?)_selection["pages"]?[0]?["page"] ?? 1;
        if (_notesColumn.ActualWidth < 1) ToggleNotes();
        _notes.AppendQuote(_main.File.ItemId, text, page);
    }
}
