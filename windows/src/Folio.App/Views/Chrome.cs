using Folio.Core;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Folio.App;

/// <summary>The windows' backdrop: blurred desktop tinted a neutral grey, so it never takes on the wallpaper's colour as
/// Mica does. How much shows through is set by UI.SetTransparency, here and on the surfaces painted over it.</summary>
public sealed class TranslucentBackdrop : Microsoft.UI.Xaml.Media.SystemBackdrop
{
    Microsoft.UI.Composition.SystemBackdrops.DesktopAcrylicController? _controller;
    Microsoft.UI.Composition.SystemBackdrops.SystemBackdropConfiguration? _configuration;
    bool _dark;

    protected override void OnTargetConnected(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop target, XamlRoot root)
    {
        base.OnTargetConnected(target, root);
        if (!Microsoft.UI.Composition.SystemBackdrops.DesktopAcrylicController.IsSupported()) return;
        // Stays translucent when the window is in the background.
        _configuration = new Microsoft.UI.Composition.SystemBackdrops.SystemBackdropConfiguration { IsInputActive = true, IsHighContrast = false };
        _controller = new Microsoft.UI.Composition.SystemBackdrops.DesktopAcrylicController();
        Paint();
        _controller.AddSystemBackdropTarget(target);
        _controller.SetSystemBackdropConfiguration(_configuration);
    }

    protected override void OnTargetDisconnected(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop target)
    {
        base.OnTargetDisconnected(target);
        _controller?.RemoveSystemBackdropTarget(target);
        _controller?.Dispose();
        _controller = null;
    }

    /// <summary>Folio sets the colours itself (and the base class would reject this controller's target).</summary>
    protected override void OnDefaultSystemBackdropConfigurationChanged(Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot) { }

    public void Apply(bool dark)
    {
        _dark = dark;
        Paint();
    }

    public void Refresh() => Paint();

    void Paint()
    {
        if (_controller == null) return;
        var tint = _dark ? Windows.UI.Color.FromArgb(255, 0x14, 0x14, 0x15) : Windows.UI.Color.FromArgb(255, 0xF4, 0xF4, 0xF5);
        _controller.TintColor = tint;
        // The more transparent the window, the less the blur is veiled.
        float t = (float)UI.Transparency;
        _controller.TintOpacity = 0.7f - 0.6f * t;
        _controller.LuminosityOpacity = 0.8f - 0.5f * t;
        _controller.FallbackColor = tint;
    }
}

/// <summary>Lays its children out in lines, starting a new one where the next does not fit.</summary>
public sealed partial class WrapPanel : Panel
{
    public double HorizontalSpacing { get; set; }
    public double VerticalSpacing { get; set; }

    protected override Windows.Foundation.Size MeasureOverride(Windows.Foundation.Size available)
    {
        double x = 0, y = 0, line = 0, widest = 0;
        foreach (var child in Children)
        {
            child.Measure(new Windows.Foundation.Size(available.Width, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > available.Width) { y += line + VerticalSpacing; x = 0; line = 0; }
            x += size.Width + HorizontalSpacing;
            widest = Math.Max(widest, x - HorizontalSpacing);
            line = Math.Max(line, size.Height);
        }
        return new Windows.Foundation.Size(double.IsInfinity(available.Width) ? widest : Math.Min(widest, available.Width), y + line);
    }

    protected override Windows.Foundation.Size ArrangeOverride(Windows.Foundation.Size final)
    {
        double x = 0, y = 0, line = 0;
        foreach (var child in Children)
        {
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > final.Width) { y += line + VerticalSpacing; x = 0; line = 0; }
            child.Arrange(new Windows.Foundation.Rect(x, y, Math.Min(size.Width, final.Width), size.Height));
            x += size.Width + HorizontalSpacing;
            line = Math.Max(line, size.Height);
        }
        return final;
    }
}

/// <summary>One tab of the title bar: icon, title, and a close button that appears where it can be used.</summary>
public sealed class TabButton : Grid
{
    public const double TabHeight = 34;
    readonly TextBlock _title;
    readonly FontIcon _icon;
    readonly Button? _close;
    readonly TabStrip _owner;
    bool _hover, _selected;

    public TabButton(TabStrip owner, string title, string icon, bool closable)
    {
        _owner = owner;
        Height = TabHeight;
        CornerRadius = new CornerRadius(7);
        Padding = new Thickness(10, 0, closable ? 4 : 10, 0);
        ColumnSpacing = 7;
        BorderThickness = new Thickness(1);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _icon = UI.Icon(icon, 14);
        _icon.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(_icon);
        _title = new TextBlock { Text = title, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap };
        SetColumn(_title, 1);
        Children.Add(_title);
        if (closable)
        {
            _close = UI.IconButton("close", Loc.S("关闭"), (_, _) => owner.RequestClose(this), 9);
            _close.Width = _close.Height = 22;
            _close.CornerRadius = new CornerRadius(5);
            _close.VerticalAlignment = VerticalAlignment.Center;
            SetColumn(_close, 2);
            Children.Add(_close);
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, title);
        PointerEntered += (_, _) => { _hover = true; Paint(); };
        PointerExited += (_, _) => { _hover = false; Paint(); };
        PointerCanceled += (_, _) => { _hover = false; Paint(); };
        PointerPressed += OnPressed;
        PointerReleased += OnReleased;
        Paint();
    }

    public object? Tag2 { get; set; }

    public bool IsClosable => _close != null;

    public string Title
    {
        get => _title.Text;
        set { _title.Text = value; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, value); }
    }

    public bool IsSelected
    {
        get => _selected;
        set { _selected = value; Paint(); }
    }

    void OnPressed(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(this).Properties;
        if (point.IsLeftButtonPressed) _owner.Select(this);
        else if (point.IsMiddleButtonPressed) e.Handled = true;
    }

    void OnReleased(object sender, PointerRoutedEventArgs e)
    {
        if (e.GetCurrentPoint(this).Properties.PointerUpdateKind == PointerUpdateKind.MiddleButtonReleased && IsClosable)
        {
            _owner.RequestClose(this);
            e.Handled = true;
        }
    }

    void Paint()
    {
        Background = UI.Brush(_selected ? "TabSelectedBrush" : _hover ? "HoverBrush" : "TransparentBrush");
        BorderBrush = UI.Brush(_selected ? "TabSelectedBorderBrush" : "TransparentBrush");
        var foreground = UI.Brush(_selected ? "TextFillColorPrimaryBrush" : "FolioSecondaryTextBrush");
        _title.Foreground = foreground;
        _icon.Foreground = _selected ? UI.Brush("FolioAccentBrush") : foreground;
        if (_close != null) _close.Opacity = _selected || _hover ? 1 : 0;
    }
}

/// <summary>The tabs of the title bar. Equal widths, narrowing as more open; what no longer fits scrolls.</summary>
public sealed class TabStrip : Grid
{
    const double MinTab = 104, MaxTab = 260, Gap = 2;
    readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = Gap, VerticalAlignment = VerticalAlignment.Center };
    readonly List<TabButton> _tabs = [];
    double _available = 800;

    public event Action? SelectionChanged;
    public event Action<TabButton>? CloseRequested;

    public IReadOnlyList<TabButton> Tabs => _tabs;
    public TabButton? Selected { get; private set; }

    public TabStrip()
    {
        Children.Add(new ScrollViewer
        {
            Content = _row,
            HorizontalScrollMode = ScrollMode.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            ZoomMode = ZoomMode.Disabled,
        });
        VerticalAlignment = VerticalAlignment.Center;
    }

    public TabButton Add(string title, string icon, bool closable)
    {
        var tab = new TabButton(this, title, icon, closable);
        _tabs.Add(tab);
        _row.Children.Add(tab);
        Arrange();
        return tab;
    }

    public void Remove(TabButton tab)
    {
        int index = _tabs.IndexOf(tab);
        if (index < 0) return;
        _tabs.RemoveAt(index);
        _row.Children.Remove(tab);
        Arrange();
        if (Selected == tab) Select(_tabs[Math.Min(index, _tabs.Count - 1)]);
    }

    public void Select(TabButton tab)
    {
        if (Selected == tab) return;
        if (Selected != null) Selected.IsSelected = false;
        Selected = tab;
        tab.IsSelected = true;
        tab.StartBringIntoView();
        SelectionChanged?.Invoke();
    }

    public void SelectNext(bool backwards)
    {
        if (_tabs.Count < 2 || Selected == null) return;
        int index = _tabs.IndexOf(Selected);
        Select(_tabs[(index + (backwards ? _tabs.Count - 1 : 1)) % _tabs.Count]);
    }

    public void RequestClose(TabButton tab) => CloseRequested?.Invoke(tab);

    /// <summary>The width the title bar can give to the tabs.</summary>
    public void SetAvailableWidth(double width)
    {
        _available = Math.Max(width, MinTab);
        Arrange();
    }

    void Arrange()
    {
        if (_tabs.Count == 0) return;
        double each = Math.Clamp((_available - Gap * (_tabs.Count - 1)) / _tabs.Count, MinTab, MaxTab);
        foreach (var tab in _tabs) tab.Width = each;
        Width = Math.Min(_available, each * _tabs.Count + Gap * (_tabs.Count - 1));
    }
}

/// <summary>A row of choices of which one is on (the macOS segmented control).</summary>
public sealed class SegmentedControl : Grid
{
    readonly StackPanel _row = new() { Orientation = Orientation.Horizontal, Spacing = 2 };
    readonly bool _accent;
    public event Action<string>? Changed;
    public string Selected { get; private set; }

    public SegmentedControl((string Key, string Title)[] options, string selected, bool accent = false, double height = 26, double fontSize = 12, double padding = 12)
    {
        _accent = accent;
        Selected = selected;
        Children.Add(_row);
        Background = UI.Brush("SegmentBackgroundBrush");
        CornerRadius = new CornerRadius(7);
        Padding = new Thickness(2);
        HorizontalAlignment = HorizontalAlignment.Left;
        foreach (var (key, title) in options)
        {
            var button = new Button
            {
                Content = title, Tag = key, Height = height, MinWidth = 0, FontSize = fontSize, Padding = new Thickness(padding, 0, padding, 0),
                CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(0), VerticalAlignment = VerticalAlignment.Center,
            };
            UI.FlatResources(button);
            button.Click += (_, _) =>
            {
                Select(key);
                Changed?.Invoke(key);
            };
            _row.Children.Add(button);
        }
        Paint();
    }

    public void Select(string key)
    {
        Selected = key;
        Paint();
    }

    public void SetTitle(string key, string title)
    {
        foreach (var b in _row.Children.OfType<Button>()) if ((string)b.Tag == key) b.Content = title;
    }

    public void SetVisible(string key, bool visible)
    {
        foreach (var b in _row.Children.OfType<Button>()) if ((string)b.Tag == key) b.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
    }

    void Paint()
    {
        foreach (var b in _row.Children.OfType<Button>())
        {
            bool on = (string)b.Tag == Selected;
            b.Background = on ? UI.Brush(_accent ? "FolioAccentBrush" : "SegmentSelectedBrush") : UI.Brush("TransparentBrush");
            b.Foreground = on ? (_accent ? UI.Brush("OnAccentBrush") : UI.Brush("TextFillColorPrimaryBrush")) : UI.Brush("FolioSecondaryTextBrush");
        }
    }
}
