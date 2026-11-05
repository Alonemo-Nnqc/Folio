using Folio.Core;
using Folio.Core.Citation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;

namespace Folio.App;

/// <summary>Settings (the macOS Settings window): 通用 · 检索 · 阅读 · 翻译 · AI · 浏览器 · 更新.</summary>
public sealed class SettingsWindow : Window
{
    static SettingsWindow? _shared;
    /// <summary>The settings window when it is open (file pickers belong to it).</summary>
    internal static SettingsWindow? Current => _shared;
    readonly AppModel _model;
    readonly NavigationView _nav;
    readonly ScrollViewer _page;

    public static void Open(AppModel model, string page = "general")
    {
        _shared ??= new SettingsWindow(model);
        _shared.Show(page);
        _shared.Activate();
    }

    SettingsWindow(AppModel model)
    {
        _model = model;
        Title = Loc.S("设置");
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Folio.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(860, 680));
        _nav = new NavigationView { IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed, IsSettingsVisible = false, PaneDisplayMode = NavigationViewPaneDisplayMode.Left, OpenPaneLength = 200, IsPaneToggleButtonVisible = false };
        foreach (var (key, title, icon) in new[] { ("general", "通用", "general"), ("retrieval", "检索", "search"), ("reader", "阅读", "reader"), ("translation", "翻译", "translate"),
                                                   ("ai", "AI", "ai"), ("browser", "浏览器", "browser"), ("update", "软件更新", "update") })
            _nav.MenuItems.Add(new NavigationViewItem { Content = key == "ai" ? "AI" : Loc.S(title), Tag = key, Icon = new FontIcon { Glyph = UI.Glyph(icon), FontFamily = UI.IconFont } });
        _page = new ScrollViewer { Padding = new Thickness(32, 24, 32, 32) };
        _nav.Content = _page;
        _nav.SelectionChanged += (_, e) => { if (e.SelectedItem is NavigationViewItem { Tag: string key }) Render(key); };
        var root = new Grid { Padding = new Thickness(0, 32, 0, 0) };
        root.Children.Add(_nav);
        Content = root;
        Closed += (_, _) => _shared = null;
    }

    void Show(string page)
    {
        _nav.SelectedItem = _nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => (string)i.Tag == page);
    }

    void Render(string key)
    {
        _page.Content = key switch
        {
            "general" => General(),
            "retrieval" => Retrieval(),
            "reader" => Reader(),
            "translation" => TranslationSettings.Page(_model),
            "ai" => AiSettings.Page(_model),
            "browser" => Browser(),
            _ => Update(),
        };
    }

    // MARK: Building blocks

    static StackPanel Stack() => new() { Spacing = 6, MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Left };

    internal static TextBlock Header(string text) => new() { Text = text, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 18, 0, 4) };

    internal static TextBlock Note(string text) => new() { Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = UI.Brush("FolioSecondaryTextBrush"), Margin = new Thickness(0, 0, 0, 6) };

    internal static ToggleSwitch Toggle(string title, bool value, Action<bool> changed)
    {
        var t = new ToggleSwitch { Header = title, IsOn = value };
        t.Toggled += (_, _) => changed(t.IsOn);
        return t;
    }

    internal static ComboBox Choice<T>(string title, IEnumerable<(T Value, string Title)> options, T current, Action<T> changed)
    {
        var list = options.ToList();
        var box = new ComboBox { Header = title, MinWidth = 240 };
        foreach (var (_, t) in list) box.Items.Add(t);
        box.SelectedIndex = Math.Max(0, list.FindIndex(o => EqualityComparer<T>.Default.Equals(o.Value, current)));
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) changed(list[box.SelectedIndex].Value); };
        return box;
    }

    internal static TextBox Field(string title, string value, Action<string> changed, string placeholder = "")
    {
        var box = new TextBox { Header = title, Text = value, PlaceholderText = placeholder, MinWidth = 320 };
        box.LostFocus += (_, _) => changed(box.Text.Trim());
        return box;
    }

    nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(this);

    // MARK: Pages

    StackPanel General()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(Header(Loc.S("文献库位置")));
        var location = new TextBlock { Text = _model.Library.Root, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        p.Children.Add(location);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var reveal = new Button { Content = Loc.S("在资源管理器中显示") };
        reveal.Click += (_, _) => Shell.Open(_model.Library.Root);
        var move = new Button { Content = Loc.S("移动…") };
        move.Click += async (_, _) =>
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
            if (await picker.PickSingleFolderAsync() is not { } folder) return;
            try { _model.RelocateLibrary(folder.Path); location.Text = _model.Library.Root; }
            catch (Exception e) { await Dialogs.Message(Loc.S("无法移动文献库"), e.Message); }
        };
        var open = new Button { Content = Loc.S("打开其他文献库…") };
        open.Click += async (_, _) =>
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
            if (await picker.PickSingleFolderAsync() is not { } folder) return;
            _model.SwitchLibrary(folder.Path);
            location.Text = _model.Library.Root;
        };
        buttons.Children.Add(reveal);
        buttons.Children.Add(move);
        buttons.Children.Add(open);
        p.Children.Add(buttons);
        p.Children.Add(Note(Loc.S("Mac 版 Folio 的文献库文件夹可以直接在这里打开（例如放在同步盘中），两边格式相同。")));

        p.Children.Add(Header(Loc.S("界面")));
        p.Children.Add(Choice(Loc.S("语言"), [("", Loc.S("跟随系统")), ("zh-Hans", "简体中文"), ("en", "English")], s.Language, v =>
        {
            s.Language = v;
            _model.Toasts.Show(Loc.S("重新启动 Folio 后生效"), "info");
        }));
        p.Children.Add(Choice(Loc.S("外观"), [(Appearance.System, Loc.S("自动")), (Appearance.Light, Loc.S("浅色")), (Appearance.Dark, Loc.S("深色"))], s.Appearance, v => s.Appearance = v));

        p.Children.Add(Header(Loc.S("文件")));
        p.Children.Add(Toggle(Loc.S("按“作者_年份_标题”自动重命名文件"), s.AutoRenameFiles, v => s.AutoRenameFiles = v));
        p.Children.Add(Toggle(Loc.S("父分组中显示子分组的文献"), s.IncludeSubgroupItems, v => { s.IncludeSubgroupItems = v; _model.ResolveRows(); }));
        p.Children.Add(Toggle(Loc.S("自动删除回收站中超过 30 天的文献"), s.AutoPurgeTrash, v => s.AutoPurgeTrash = v));
        p.Children.Add(Choice(Loc.S("打开 PDF 的方式"), [(OpenWith.Folio, Loc.S("Folio 阅读器")), (OpenWith.System, Loc.S("系统默认应用")), (OpenWith.Custom, Loc.S("指定应用…"))], s.OpenWith, async v =>
        {
            if (v == OpenWith.Custom)
            {
                var picker = new FileOpenPicker();
                picker.FileTypeFilter.Add(".exe");
                WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
                if (await picker.PickSingleFileAsync() is { } app) s.OpenWithAppPath = app.Path; else return;
            }
            s.OpenWith = v;
        }));
        p.Children.Add(Choice(Loc.S("默认引用样式"), CitationStyles.All.Select(st => (st.Raw(), st.DisplayName())), s.CitationStyle, v => s.CitationStyle = v));
        return p;
    }

    StackPanel Retrieval()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(Toggle(Loc.S("添加 PDF 后自动检索元数据"), s.AutoRetrieveOnImport, v => s.AutoRetrieveOnImport = v));
        p.Children.Add(Toggle(Loc.S("使用 Zotero 识别服务"), s.UseZoteroRecognizer, v => s.UseZoteroRecognizer = v));
        p.Children.Add(Note(Loc.S("把 PDF 前几页的文字与版面发送给 Zotero 的识别服务，能识别更多没有 DOI 的论文。")));
        p.Children.Add(Header(Loc.S("数据源")));
        p.Children.Add(Field(Loc.S("联系邮箱（Crossref / OpenAlex）"), s.CrossrefMailto, v => s.CrossrefMailto = v, "name@example.com"));
        p.Children.Add(Note(Loc.S("填写后请求进入 Crossref 与 OpenAlex 的“礼貌队列”，速度更稳定。邮箱只发送给这两个服务。")));
        p.Children.Add(Field("OpenAlex API Key", s.OpenAlexApiKey, v => s.OpenAlexApiKey = v));
        return p;
    }

    StackPanel Reader()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(Choice(Loc.S("默认缩放"), [(ReaderZoom.FitWidth, Loc.S("适合页宽")), (ReaderZoom.ActualSize, Loc.S("实际大小"))], s.ReaderZoom, v => s.ReaderZoom = v));
        p.Children.Add(Choice(Loc.S("页面布局"), [(ReaderLayout.Single, Loc.S("单页连续")), (ReaderLayout.TwoUp, Loc.S("双页连续"))], s.ReaderLayout, v => s.ReaderLayout = v));
        p.Children.Add(Toggle(Loc.S("重新打开上次的阅读标签页"), s.ReopenReaderTabs, v => s.ReopenReaderTabs = v));
        p.Children.Add(Toggle(Loc.S("打开未读文献时标记为在读"), s.MarkReadingOnOpen, v => s.MarkReadingOnOpen = v));
        p.Children.Add(Toggle(Loc.S("页面阴影"), s.ReaderPageShadows, v => s.ReaderPageShadows = v));
        p.Children.Add(Field(Loc.S("标注作者"), s.AnnotationAuthor, v => s.AnnotationAuthor = v));
        p.Children.Add(Note(Loc.S("写入新标注的作者名，其他 PDF 阅读器会在标注列表中显示。")));
        return p;
    }

    StackPanel Browser()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(Toggle(Loc.S("允许浏览器插件保存到 Folio"), s.BrowserConnectorEnabled, v =>
        {
            s.BrowserConnectorEnabled = v;
            if (v) _model.Connector.Start(); else _model.Connector.Stop();
        }));
        var state = _model.Connector.State switch
        {
            ConnectorServer.ServerState.Running => Loc.S("正在运行（127.0.0.1:%@）", Folio.Core.Connector.ConnectorProtocol.Port.ToString()),
            ConnectorServer.ServerState.Failed => _model.Connector.FailureReason ?? "",
            _ => Loc.S("已停止"),
        };
        p.Children.Add(Note(state));
        p.Children.Add(Header(Loc.S("安装浏览器插件")));
        p.Children.Add(Note(Loc.S("插件会以“已解压的扩展程序”方式加载：点击“安装”后，Folio 准备好插件文件夹并打开浏览器的扩展页面，打开“开发者模式”，选择“加载已解压的扩展程序”，再选中这个文件夹。")));
        var browsers = BrowserExtensions.Detect();
        if (browsers.Count == 0) p.Children.Add(Note(Loc.S("没有找到支持的浏览器")));
        foreach (var browser in browsers)
        {
            var row = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 4, 0, 4) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var (installed, enabled, version) = BrowserExtensions.InstallState(browser);
            var info = new StackPanel();
            info.Children.Add(new TextBlock { Text = browser.Name });
            info.Children.Add(Note(installed ? (enabled ? Loc.S("已安装 %@", version ?? "") : Loc.S("已安装，但已停用")) : Loc.S("未安装")));
            row.Children.Add(info);
            var install = new Button { Content = installed ? Loc.S("更新") : Loc.S("安装…") };
            install.Click += (_, _) =>
            {
                try
                {
                    var folder = BrowserExtensions.PrepareCopy(browser.Family);
                    Shell.CopyText(folder);
                    BrowserExtensions.OpenExtensionsPage(browser);
                    Shell.Open(folder);
                    _model.Toasts.Show(Loc.S("插件文件夹的路径已复制，在扩展页面中选择“加载已解压的扩展程序”"), "copy");
                }
                catch (Exception e) { _model.Toasts.Show(e.Message, "warning"); }
            };
            Grid.SetColumn(install, 1);
            row.Children.Add(install);
            p.Children.Add(row);
        }
        return p;
    }

    StackPanel Update()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(new TextBlock { Text = "Folio " + Updater.CurrentVersion, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        p.Children.Add(Note(Loc.S("Windows 版本 %@", Updater.CurrentVersion) + $" · {Updater.Channel}"));
        p.Children.Add(Toggle(Loc.S("自动检查更新"), s.AutoCheckUpdates, v => s.AutoCheckUpdates = v));
        p.Children.Add(Toggle(Loc.S("接收测试版"), s.UpdatePrereleases, v => s.UpdatePrereleases = v));
        var check = new Button { Content = Loc.S("检查更新…"), Margin = new Thickness(0, 8, 0, 0) };
        check.Click += async (_, _) => await _model.Updater.Check(userInitiated: true);
        p.Children.Add(check);
        p.Children.Add(Note(Loc.S("更新从 GitHub Releases 下载，在后台完成，重新启动即完成安装。")));
        return p;
    }
}
