using Folio.Core;
using Folio.Core.Citation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;

namespace Folio.App;

/// <summary>Settings (the macOS Settings window): 通用 · 阅读 · 文献库 · 检索 · 翻译 · 浏览器 · AI.</summary>
public sealed class SettingsWindow : Window
{
    static SettingsWindow? _shared;
    /// <summary>The settings window when it is open (file pickers belong to it).</summary>
    internal static SettingsWindow? Current => _shared;
    /// <summary>Whether this is the window the user is in (dialogs then open over it).</summary>
    internal static bool IsActive { get; private set; }
    readonly AppModel _model;
    readonly NavigationView _nav;
    readonly ScrollViewer _page;
    readonly TextBlock _paneTitle;

    public static void Open(AppModel model, string page = "")
    {
        _shared ??= new SettingsWindow(model);
        _shared.Show(page.Length > 0 ? page : model.Settings.Raw("settingsPane")?.ToString() ?? "general");
        _shared.Activate();
    }

    SettingsWindow(AppModel model)
    {
        _model = model;
        Title = Loc.S("设置");
        var backdrop = new TranslucentBackdrop();
        SystemBackdrop = backdrop;
        ExtendsContentIntoTitleBar = true;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Folio.ico"));
        PlaceWindow();

        _nav = new NavigationView { IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed, IsSettingsVisible = false, PaneDisplayMode = NavigationViewPaneDisplayMode.Left, OpenPaneLength = 200, IsPaneToggleButtonVisible = false, IsTitleBarAutoPaddingEnabled = false };
        foreach (var (key, title, icon) in new[] { ("general", "通用", "general"), ("reader", "阅读", "reader"), ("library", "文献库", "library"), ("retrieval", "检索", "search"),
                                                   ("translation", "翻译", "translate"), ("browser", "浏览器", "browser"), ("ai", "AI", "ai") })
            _nav.MenuItems.Add(new NavigationViewItem { Content = key == "ai" ? "AI" : Loc.S(title), Tag = key, Icon = new FontIcon { Glyph = UI.Glyph(icon), FontFamily = UI.IconFont } });
        var right = new Grid();
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _paneTitle = new TextBlock { FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(28, 6, 28, 8) };
        right.Children.Add(_paneTitle);
        _page = new ScrollViewer { Padding = new Thickness(28, 0, 28, 28) };
        Grid.SetRow(_page, 1);
        right.Children.Add(_page);
        _nav.Content = right;
        _nav.SelectionChanged += (_, e) => { if (e.SelectedItem is NavigationViewItem { Tag: string key } item) { _paneTitle.Text = item.Content?.ToString(); _model.Settings.SetRaw("settingsPane", key); Render(key); } };

        // The panes' own backgrounds would hide the window's.
        foreach (var key in new[] { "NavigationViewContentBackground", "NavigationViewDefaultPaneBackground", "NavigationViewExpandedPaneBackground", "NavigationViewContentGridBorderBrush", "NavigationViewPaneContentGridBorderBrush" })
            _nav.Resources[key] = UI.Brush("TransparentBrush");
        var root = new Grid { Background = UI.Brush("WindowBackgroundBrush") };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(32) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var bar = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        bar.Children.Add(new TextBlock { Text = Loc.S("设置"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 0, 0) });
        root.Children.Add(bar);
        Grid.SetRow(_nav, 1);
        root.Children.Add(_nav);
        Content = root;
        SetTitleBar(bar);
        void ApplyTheme()
        {
            root.RequestedTheme = UI.ThemeOf(model.Settings.Appearance);
            UI.ApplyTitleBarTheme(this, UI.IsDark);
            backdrop.Apply(UI.IsDark);
        }
        ApplyTheme();
        root.ActualThemeChanged += (_, _) =>
        {
            UI.ApplyTitleBarTheme(this, root.ActualTheme == ElementTheme.Dark);
            backdrop.Apply(root.ActualTheme == ElementTheme.Dark);
        };
        _settingsChanged = key => { if (key == "appearance") DispatcherQueue.TryEnqueue(ApplyTheme); };
        model.Settings.Changed += _settingsChanged;
        UI.SurfacesChanged += backdrop.Refresh;
        Activated += (_, e) => IsActive = e.WindowActivationState != WindowActivationState.Deactivated;
        Closed += (_, _) =>
        {
            IsActive = false;
            UI.SurfacesChanged -= backdrop.Refresh;
            model.Settings.Changed -= _settingsChanged;
            _shared = null;
        };
    }

    readonly Action<string> _settingsChanged;

    /// <summary>780 × 600 logical pixels, centred over the main window (AppWindow's sizes are physical pixels).</summary>
    void PlaceWindow()
    {
        double scale = UI.Scale(this);
        int width = (int)(780 * scale), height = (int)(600 * scale);
        int x = 0, y = 0;
        if (App.Current?.Window?.AppWindow is { } main)
        {
            x = main.Position.X + (main.Size.Width - width) / 2;
            y = main.Position.Y + (main.Size.Height - height) / 2;
        }
        var area = Microsoft.UI.Windowing.DisplayArea.GetFromPoint(new Windows.Graphics.PointInt32(x, y), Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
        width = Math.Min(width, area.Width);
        height = Math.Min(height, area.Height);
        x = Math.Clamp(x, area.X, area.X + area.Width - width);
        y = Math.Clamp(y, area.Y, area.Y + area.Height - height);
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(x, y, width, height));
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(640 * scale);
            presenter.PreferredMinimumHeight = (int)(420 * scale);
            presenter.IsMinimizable = false;
        }
    }

    void Show(string page)
    {
        _nav.SelectedItem = _nav.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(i => (string)i.Tag == page) ?? _nav.MenuItems[0];
    }

    void Render(string key)
    {
        _page.Content = key switch
        {
            "reader" => Reader(),
            "library" => Library(),
            "retrieval" => Retrieval(),
            "translation" => TranslationSettings.Page(_model),
            "ai" => AiSettings.Page(_model),
            "browser" => Browser(),
            _ => General(),
        };
        _page.ChangeView(null, 0, null, disableAnimation: true);
    }

    // MARK: Building blocks: grouped forms, as in macOS Settings

    static StackPanel Stack() => new() { Spacing = 6, MaxWidth = 680, HorizontalAlignment = HorizontalAlignment.Stretch };

    internal static TextBlock Header(string text) => new() { Text = text, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(2, 14, 0, 2) };

    internal static TextBlock Note(string text) => new() { Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = UI.Brush("FolioSecondaryTextBrush"), Margin = new Thickness(2, 2, 2, 6) };

    /// <summary>A rounded group of rows.</summary>
    internal static Border Card(params FrameworkElement[] rows)
    {
        var stack = new StackPanel();
        for (int i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(new Border { Height = 1, Background = UI.Brush("FolioSeparatorBrush"), Margin = new Thickness(12, 0, 12, 0) });
            rows[i].Margin = new Thickness(12, 6, 12, 6);
            stack.Children.Add(rows[i]);
        }
        return new Border
        {
            Child = stack,
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(1),
            BorderBrush = UI.Brush("CardStrokeColorDefaultBrush"),
            Background = UI.Brush("CardBackgroundFillColorDefaultBrush"),
        };
    }

    /// <summary>Puts the rows of a page into cards; headers and notes stay between them.</summary>
    internal static StackPanel Grouped(StackPanel page)
    {
        var children = page.Children.ToList();
        page.Children.Clear();
        var rows = new List<FrameworkElement>();
        void Flush()
        {
            if (rows.Count > 0) page.Children.Add(Card(rows.ToArray()));
            rows.Clear();
        }
        foreach (var child in children.OfType<FrameworkElement>())
        {
            if (child is TextBlock || (child.Tag as string) == "plain") { Flush(); page.Children.Add(child); }
            else rows.Add(child);
        }
        Flush();
        return page;
    }

    /// <summary>A form row: what it is on the left, its control on the right.</summary>
    internal static Grid Row(string title, FrameworkElement control, string? detail = null)
    {
        var grid = new Grid { ColumnSpacing = 16, MinHeight = 32 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        if (detail != null) text.Children.Add(new TextBlock { Text = detail, FontSize = 11, TextWrapping = TextWrapping.Wrap, Foreground = UI.Brush("FolioSecondaryTextBrush") });
        grid.Children.Add(text);
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);
        return grid;
    }

    internal static Grid Toggle(string title, bool value, Action<bool> changed, string? detail = null)
    {
        var t = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Right };
        t.Toggled += (_, _) => changed(t.IsOn);
        return Row(title, new Grid { Width = 44, Children = { t } }, detail);
    }

    internal static Grid Choice<T>(string title, IEnumerable<(T Value, string Title)> options, T current, Action<T> changed, string? detail = null)
    {
        var list = options.ToList();
        var box = new ComboBox { MinWidth = 180, MaxWidth = 320 };
        foreach (var (_, t) in list) box.Items.Add(t);
        box.SelectedIndex = Math.Max(0, list.FindIndex(o => EqualityComparer<T>.Default.Equals(o.Value, current)));
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) changed(list[box.SelectedIndex].Value); };
        return Row(title, box, detail);
    }

    internal static Grid Field(string title, string value, Action<string> changed, string placeholder = "", string? detail = null)
    {
        var box = new TextBox { Text = value, PlaceholderText = placeholder, Width = 280 };
        box.LostFocus += (_, _) => changed(box.Text.Trim());
        box.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) changed(box.Text.Trim()); };
        return Row(title, box, detail);
    }

    nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(this);

    // MARK: Pages

    StackPanel General()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(Header(Loc.S("外观")));
        var opacity = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var percent = UI.Label($"{Math.Round(s.WindowTransparency * 100)}%", 12, secondary: true);
        percent.Width = 34;
        percent.TextAlignment = TextAlignment.Right;
        var slider = new Slider { Minimum = 0, Maximum = 100, Width = 200, Value = Math.Round(s.WindowTransparency * 100), StepFrequency = 1, IsThumbToolTipEnabled = false, VerticalAlignment = VerticalAlignment.Center };
        slider.ValueChanged += (_, e) => { s.WindowTransparency = e.NewValue / 100; percent.Text = $"{Math.Round(e.NewValue)}%"; };
        opacity.Children.Add(slider);
        opacity.Children.Add(percent);
        p.Children.Add(Card(AppearancePicker(), Row(Loc.S("界面透明度"), opacity, Loc.S("让窗口透出一点桌面；0% 为完全不透明"))));

        p.Children.Add(Header(Loc.S("打开")));
        var openRows = new List<FrameworkElement>
        {
            Choice(Loc.S("打开 PDF 时使用"), [(OpenWith.Folio, Loc.S("Folio 阅读器")), (OpenWith.System, Loc.S("系统默认应用")), (OpenWith.Custom, Loc.S("指定应用…"))], s.OpenWith, v =>
            {
                s.OpenWith = v;
                Render("general");
            }),
        };
        if (s.OpenWith == OpenWith.Custom)
        {
            var choose = new Button { Content = Loc.S("选择…") };
            choose.Click += async (_, _) =>
            {
                var picker = new FileOpenPicker();
                picker.FileTypeFilter.Add(".exe");
                WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
                if (await picker.PickSingleFileAsync() is not { } app) return;
                s.OpenWithAppPath = app.Path;
                Render("general");
            };
            var name = UI.Label(s.OpenWithAppPath is { Length: > 0 } path ? Path.GetFileNameWithoutExtension(path) : Loc.S("未选择"), 13, secondary: true);
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            row.Children.Add(name);
            row.Children.Add(choose);
            openRows.Add(Row(Loc.S("应用"), row));
        }
        openRows.Add(Toggle(Loc.S("打开未读的论文时，标为\"在读\""), s.MarkReadingOnOpen, v => s.MarkReadingOnOpen = v));
        openRows.Add(Toggle(Loc.S("启动时重新打开上次的论文标签页"), s.ReopenReaderTabs, v => s.ReopenReaderTabs = v));
        p.Children.Add(Card(openRows.ToArray()));

        p.Children.Add(Header(Loc.S("列表")));
        p.Children.Add(Card(
            Toggle(Loc.S("父分组中显示子分组的条目"), s.IncludeSubgroupItems, v => { s.IncludeSubgroupItems = v; _model.ResolveRows(); }),
            Choice(Loc.S("默认引用样式"), CitationStyles.All.Select(st => (st.Raw(), st.DisplayName())), s.CitationStyle, v => s.CitationStyle = v)));

        p.Children.Add(Header(Loc.S("语言")));
        var launched = LaunchedLanguage ??= s.Language ?? "";
        var restart = new Button { Content = Loc.S("立即重新启动") };
        restart.Click += (_, _) => App.Restart();
        var restartRow = Row(Loc.S("重新启动 Folio 后生效"), restart);
        restartRow.Visibility = (s.Language ?? "") != launched ? Visibility.Visible : Visibility.Collapsed;
        p.Children.Add(Card(
            Choice(Loc.S("界面语言"), [("", Loc.S("跟随系统")), ("zh-Hans", "简体中文"), ("en", "English")], s.Language ?? "", v =>
            {
                s.Language = v;
                restartRow.Visibility = v != launched ? Visibility.Visible : Visibility.Collapsed;
            }),
            restartRow));

        p.Children.Add(Header(Loc.S("软件更新")));
        var check = new Button { Content = Loc.S("检查更新…") };
        check.Click += async (_, _) => await _model.Updater.Check(userInitiated: true);
        var version = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        version.Children.Add(UI.Label($"{Updater.CurrentVersion} ({Updater.Channel})", 13, secondary: true));
        version.Children.Add(check);
        p.Children.Add(Card(
            Row(Loc.S("当前版本"), version),
            Toggle(Loc.S("自动检查更新"), s.AutoCheckUpdates, v => s.AutoCheckUpdates = v),
            Toggle(Loc.S("接收测试版"), s.UpdatePrereleases, v => s.UpdatePrereleases = v)));
        p.Children.Add(Note(Loc.S("更新从 GitHub Releases 下载，在后台完成，重新启动即完成安装。")));
        return p;
    }

    static string? LaunchedLanguage;

    FrameworkElement AppearancePicker()
    {
        var s = _model.Settings;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 22, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var (value, title, top, bottom, window) in new (Appearance, string, string, string, string)[]
        {
            (Appearance.System, "自动", "#9EC7F2", "#3A3A3C", "#E8E8EA"), (Appearance.Light, "浅色", "#9EC7F2", "#D9E6FA", "#FFFFFF"), (Appearance.Dark, "深色", "#404040", "#1F1F1F", "#2E2E2E"),
        })
        {
            bool selected = s.Appearance == value;
            var preview = new Grid { Width = 80, Height = 54, Background = new LinearGradientBrush { StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(value == Appearance.System ? 1 : 0, value == Appearance.System ? 0 : 1), GradientStops = { new GradientStop { Color = UI.Hex(top).Color, Offset = 0 }, new GradientStop { Color = UI.Hex(bottom).Color, Offset = 1 } } } };
            preview.Children.Add(new Border { Width = 56, Height = 34, CornerRadius = new CornerRadius(3), Background = UI.Hex(window), Margin = new Thickness(8, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top });
            var frame = new Border { Child = preview, CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(selected ? 3 : 1), BorderBrush = selected ? UI.Brush("FolioAccentBrush") : UI.Brush("FolioSeparatorBrush"), Padding = new Thickness(selected ? 0 : 2) };
            var stack = new StackPanel { Spacing = 6 };
            stack.Children.Add(frame);
            stack.Children.Add(UI.Label(Loc.S(title), 12, secondary: !selected).With(l => l.HorizontalAlignment = HorizontalAlignment.Center));
            var button = new Button { Content = stack, Padding = new Thickness(2), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0) };
            button.Click += (_, _) => { s.Appearance = value; Render("general"); };
            row.Children.Add(button);
        }
        return row;
    }

    StackPanel Reader()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(Header(Loc.S("页面")));
        p.Children.Add(Card(
            Choice(Loc.S("首次打开时的缩放"), [(ReaderZoom.FitWidth, Loc.S("适合页宽")), (ReaderZoom.ActualSize, Loc.S("实际大小"))], s.ReaderZoom, v => s.ReaderZoom = v),
            Choice(Loc.S("显示方式"), [(ReaderLayout.Single, Loc.S("单页连续")), (ReaderLayout.TwoUp, Loc.S("双页连续"))], s.ReaderLayout, v => s.ReaderLayout = v),
            Toggle(Loc.S("显示页面阴影"), s.ReaderPageShadows, v => s.ReaderPageShadows = v)));
        p.Children.Add(Header(Loc.S("批注")));
        var swatches = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var (key, title, _, _, _) in AnnotationColors.All)
        {
            bool selected = s.HighlightColor == key;
            var dot = new Button { Width = 22, Height = 22, MinWidth = 0, Padding = new Thickness(0), CornerRadius = new CornerRadius(11), Background = UI.Hex(AnnotationColors.Hex(key)), BorderThickness = new Thickness(selected ? 2 : 0), BorderBrush = UI.Brush("TextFillColorPrimaryBrush") };
            ToolTipService.SetToolTip(dot, Loc.S(title));
            dot.Click += (_, _) => { s.HighlightColor = key; Render("reader"); };
            swatches.Children.Add(dot);
        }
        p.Children.Add(Card(
            Row(Loc.S("默认高亮颜色"), swatches),
            Field(Loc.S("批注作者"), s.AnnotationAuthor, v => s.AnnotationAuthor = v, Environment.UserName)));
        return p;
    }

    StackPanel Library()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(Header(Loc.S("文献库位置")));
        var location = new TextBlock { Text = _model.Library.Root, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono,Consolas"), FontSize = 12, Foreground = UI.Brush("FolioSecondaryTextBrush") };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
        var progress = new ProgressRing { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = UI.Hex("#FF3B30"), Visibility = Visibility.Collapsed };
        var reveal = new Button { Content = Loc.S("在资源管理器中显示") };
        reveal.Click += (_, _) => Shell.Open(_model.Library.Root);
        var move = new Button { Content = Loc.S("更改…") };
        ToolTipService.SetToolTip(move, Loc.S("选择新的文献库位置，Folio 会把整个文献库移动过去"));
        move.Click += async (_, _) =>
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
            if (await picker.PickSingleFolderAsync() is not { } folder) return;
            move.IsEnabled = false;
            progress.IsActive = true;
            progress.Visibility = Visibility.Visible;
            error.Visibility = Visibility.Collapsed;
            try { await _model.RelocateLibrary(folder.Path); location.Text = _model.Library.Root; }
            catch (Exception e) { error.Text = Loc.S("无法移动文献库：%@", e.Message); error.Visibility = Visibility.Visible; }
            move.IsEnabled = true;
            progress.IsActive = false;
            progress.Visibility = Visibility.Collapsed;
        };
        var open = new Button { Content = Loc.S("打开其他文献库…") };
        open.Click += async (_, _) =>
        {
            var picker = new FolderPicker();
            picker.FileTypeFilter.Add("*");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
            if (await picker.PickSingleFolderAsync() is not { } folder) return;
            if (!File.Exists(Path.Combine(folder.Path, Folio.Core.Library.DatabaseFileName))
                && !await Dialogs.Confirm(Loc.S("这个文件夹还不是 Folio 文献库"), Loc.S("要在这里新建一个空的文献库吗？"), Loc.S("新建文献库"), Loc.S("取消"))) return;
            try
            {
                _model.SwitchLibrary(folder.Path);
                location.Text = _model.Library.Root;
            }
            catch (Exception e) { await Dialogs.Message(Loc.S("无法打开文献库"), e.Message); }
        };
        buttons.Children.Add(progress);
        buttons.Children.Add(reveal);
        buttons.Children.Add(move);
        buttons.Children.Add(open);
        var inner = new StackPanel { Spacing = 8 };
        inner.Children.Add(location);
        inner.Children.Add(buttons);
        inner.Children.Add(error);
        p.Children.Add(Card(inner));
        p.Children.Add(Note(Loc.S("Mac 版 Folio 的文献库文件夹可以直接在这里打开（例如放在同步盘中），两边格式相同。")));

        p.Children.Add(Header(Loc.S("文件")));
        p.Children.Add(Card(
            Toggle(Loc.S("检索到元数据后按「作者_年份_标题」重命名文件"), s.AutoRenameFiles, v => s.AutoRenameFiles = v),
            Toggle(Loc.S("自动彻底删除回收站中超过 30 天的内容"), s.AutoPurgeTrash, v => s.AutoPurgeTrash = v)));

        p.Children.Add(Header(Loc.S("导入")));
        var zotero = new Button { Content = Loc.S("从 Zotero 导入…") };
        zotero.Click += (_, _) => ZoteroImportSheet.Show(_model).Fire();
        p.Children.Add(Card(Row("Zotero", zotero)));
        p.Children.Add(Note(Loc.S("导入条目、PDF、分组和标签，不会修改 Zotero")));
        return p;
    }

    StackPanel Retrieval()
    {
        var s = _model.Settings;
        var p = Stack();
        p.Children.Add(Card(
            Toggle(Loc.S("添加 PDF 后自动检索元数据"), s.AutoRetrieveOnImport, v => s.AutoRetrieveOnImport = v),
            Toggle(Loc.S("使用 Zotero 识别服务"), s.UseZoteroRecognizer, v => s.UseZoteroRecognizer = v, Loc.S("会把 PDF 前 5 页的文字发送给 Zotero，无需账号"))));
        p.Children.Add(new Border { Height = 12 });
        var key = new PasswordBox { Password = s.OpenAlexApiKey, Width = 280 };
        key.LostFocus += (_, _) => { if (key.Password != s.OpenAlexApiKey) s.OpenAlexApiKey = key.Password.Trim(); };
        p.Children.Add(Card(
            Field(Loc.S("联系邮箱（选填）"), s.CrossrefMailto, v => { if (v != s.CrossrefMailto) s.CrossrefMailto = v; }, "name@example.com", Loc.S("Crossref 会更快地响应带联系邮箱的请求；邮箱只发送给 Crossref 和 OpenAlex")),
            Row(Loc.S("OpenAlex API Key（选填）"), key, Loc.S("可在 openalex.org 免费申请，用于提高 OpenAlex 的访问额度"))));
        p.Children.Add(Note(Loc.S("选填，可让检索更快、更稳定\n不填也能正常检索")));
        return p;
    }

    StackPanel Browser()
    {
        var s = _model.Settings;
        var p = Stack();
        var status = Note("");
        void Update()
        {
            status.Text = _model.Connector.State switch
            {
                ConnectorServer.ServerState.Running => Loc.S("正在运行（127.0.0.1:%@）", Folio.Core.Connector.ConnectorProtocol.Port.ToString()),
                ConnectorServer.ServerState.Failed => _model.Connector.FailureReason ?? "",
                _ => Loc.S("已停止"),
            };
        }
        Update();
        p.Children.Add(Card(Toggle(Loc.S("允许浏览器插件保存到 Folio"), s.BrowserConnectorEnabled, v =>
        {
            s.BrowserConnectorEnabled = v;
            if (v) _model.Connector.Start(); else _model.Connector.Stop();
            Update();
        })));
        p.Children.Add(status);
        p.Children.Add(Header(Loc.S("安装浏览器插件")));
        p.Children.Add(Note(Loc.S("插件会以“已解压的扩展程序”方式加载：点击“安装”后，Folio 准备好插件文件夹并打开浏览器的扩展页面，打开“开发者模式”，选择“加载已解压的扩展程序”，再选中这个文件夹。")));
        var browsers = BrowserExtensions.Detect();
        if (browsers.Count == 0) p.Children.Add(Note(Loc.S("没有找到支持的浏览器")));
        var rows = new List<FrameworkElement>();
        foreach (var browser in browsers)
        {
            var (installed, enabled, version) = BrowserExtensions.InstallState(browser);
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
            rows.Add(Row(browser.Name, install, installed ? (enabled ? Loc.S("已安装 %@", version ?? "") : Loc.S("已安装，但已停用")) : Loc.S("未安装")));
        }
        if (rows.Count > 0) p.Children.Add(Card(rows.ToArray()));
        return p;
    }
}
