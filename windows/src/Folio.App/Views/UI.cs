using Folio.Core;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Folio.App;

/// <summary>Small helpers for building the interface in code.</summary>
static class UI
{
    public static readonly FontFamily IconFont = new("Segoe Fluent Icons,Segoe MDL2 Assets");

    /// <summary>Glyphs standing in for the SF Symbols the macOS app uses.</summary>
    public static string Glyph(string name) => name switch
    {
        "library" => "",
        "all" => "",
        "unfiled" => "",
        "trash" or "delete" => "",
        "folder" => "",
        "tag" => "",
        "add" => "",
        "search" => "",
        "document" => "",
        "pdf" => "",
        "share" or "export" => "",
        "copy" => "",
        "refresh" => "",
        "settings" => "",
        "download" => "",
        "info" => "",
        "checkmark" => "\uE73E",
        "warning" => "",
        "check" => "",
        "globe" => "",
        "attach" => "",
        "sidebar" => "",
        "inspector" => "",
        "read" or "reader" => "",
        "translate" => "",
        "star" => "",
        "starFill" => "",
        "chevronUp" => "\uE70E",
        "chevronRight" => "",
        "chevronDown" => "",
        "close" => "",
        "question" => "",
        "offline" => "",
        "note" => "",
        "highlight" => "",
        "edit" => "",
        "link" => "",
        "open" => "",
        "more" => "",
        "cite" => "",
        "ai" => "",
        "browser" => "",
        "update" => "",
        "general" => "",
        "back" => "",
        "forward" => "",
        "zoomIn" => "",
        "zoomOut" => "",
        "select" => "",
        "underline" => "",
        "strike" => "",
        "textbox" => "",
        "ink" => "",
        "thumbnails" => "",
        "outline" => "",
        "sidebarHide" => "\uE8A0",
        "sidebarShow" => "\uE89F",
        "inspectorHide" => "\uEA5B",
        "inspectorShow" => "\uEA49",
        "print" => "\uE749",
        "parallel" => "\uE736",
        "restore" => "",
        _ => "",
    };

    public static FontIcon Icon(string name, double size = 16, Brush? foreground = null)
    {
        var icon = new FontIcon { Glyph = Glyph(name), FontFamily = IconFont, FontSize = size };
        if (foreground != null) icon.Foreground = foreground;
        return icon;
    }

    /// <summary>The app's colours as brushes shared by everything: a theme change repaints them all at once. (Resources
    /// looked up from code would keep the colours of the theme they were first read in.)</summary>
    static readonly Dictionary<string, (Color Light, Color Dark)> Palette = new()
    {
        ["FolioAccentBrush"] = (Rgba(0xFF, 0x00, 0x7A, 0xFF), Rgba(0xFF, 0x0A, 0x84, 0xFF)),
        ["WindowBackgroundBrush"] = (Rgba(0xFF, 0xF1, 0xF2, 0xF4), Rgba(0xFF, 0x1A, 0x1A, 0x1B)),
        ["FolioSidebarBrush"] = (Rgba(0xFF, 0xF2, 0xF4, 0xF6), Rgba(0xFF, 0x20, 0x20, 0x21)),
        ["FolioContentBrush"] = (Rgba(0xFF, 0xFF, 0xFF, 0xFF), Rgba(0xFF, 0x1E, 0x1E, 0x1E)),
        ["FolioInspectorBrush"] = (Rgba(0xFF, 0xF7, 0xF8, 0xFA), Rgba(0xFF, 0x22, 0x22, 0x23)),
        ["FolioSelectionBrush"] = (Rgba(0xFF, 0xE3, 0xE3, 0xE8), Rgba(0xFF, 0x3A, 0x3A, 0x3C)),
        ["FolioSecondaryTextBrush"] = (Rgba(0xFF, 0x6E, 0x6E, 0x73), Rgba(0xFF, 0x98, 0x98, 0x9D)),
        ["FolioSeparatorBrush"] = (Rgba(0xFF, 0xE5, 0xE5, 0xEA), Rgba(0xFF, 0x38, 0x38, 0x3A)),
        ["TextFillColorPrimaryBrush"] = (Rgba(0xE4, 0x00, 0x00, 0x00), Rgba(0xFF, 0xFF, 0xFF, 0xFF)),
        ["CardStrokeColorDefaultBrush"] = (Rgba(0x12, 0x00, 0x00, 0x00), Rgba(0x24, 0xFF, 0xFF, 0xFF)),
        ["CardBackgroundFillColorDefaultBrush"] = (Rgba(0xB3, 0xFF, 0xFF, 0xFF), Rgba(0x0D, 0xFF, 0xFF, 0xFF)),
        ["ToastBackgroundBrush"] = (Rgba(0xF7, 0xFC, 0xFC, 0xFC), Rgba(0xF7, 0x2E, 0x2E, 0x30)),
        ["TransparentBrush"] = (Rgba(0, 0xFF, 0xFF, 0xFF), Rgba(0, 0, 0, 0)),
        ["HoverBrush"] = (Rgba(0x0F, 0, 0, 0), Rgba(0x14, 0xFF, 0xFF, 0xFF)),
        ["PressedBrush"] = (Rgba(0x1A, 0, 0, 0), Rgba(0x20, 0xFF, 0xFF, 0xFF)),
        ["RowSelectedBrush"] = (Rgba(0x17, 0, 0, 0), Rgba(0x1F, 0xFF, 0xFF, 0xFF)),
        ["TabSelectedBrush"] = (Rgba(0xFF, 0xFF, 0xFF, 0xFF), Rgba(0xFF, 0x3A, 0x3A, 0x3C)),
        ["TabSelectedBorderBrush"] = (Rgba(0x14, 0, 0, 0), Rgba(0x14, 0xFF, 0xFF, 0xFF)),
        ["SegmentBackgroundBrush"] = (Rgba(0x0F, 0, 0, 0), Rgba(0x14, 0xFF, 0xFF, 0xFF)),
        ["SegmentSelectedBrush"] = (Rgba(0xFF, 0xFF, 0xFF, 0xFF), Rgba(0xFF, 0x48, 0x48, 0x4A)),
        ["OnAccentBrush"] = (Rgba(0xFF, 0xFF, 0xFF, 0xFF), Rgba(0xFF, 0xFF, 0xFF, 0xFF)),
    };
    static readonly Dictionary<string, SolidColorBrush> Shared = [];
    static bool _dark;
    static double _transparency;

    /// <summary>How much each surface lets the desktop through at full transparency. The list keeps most of its colour so
    /// text stays easy to read.</summary>
    static double SurfaceShare(string key) => key switch
    {
        "WindowBackgroundBrush" or "FolioSidebarBrush" or "FolioInspectorBrush" => 0.92,
        "FolioContentBrush" => 0.75,
        _ => 0,
    };

    static Color ColorOf(string key)
    {
        var c = _dark ? Palette[key].Dark : Palette[key].Light;
        double share = SurfaceShare(key);
        return share == 0 ? c : Color.FromArgb((byte)Math.Round(c.A * (1 - share * _transparency)), c.R, c.G, c.B);
    }

    /// <summary>Opacity of the reader page's own surfaces, in step with the window's.</summary>
    public static double ReaderSurfaceOpacity => 1 - 0.92 * _transparency;
    public static double Transparency => _transparency;
    public static event Action? SurfacesChanged;

    public static void SetTransparency(double value)
    {
        if (Math.Abs(_transparency - value) < 0.001) return;
        _transparency = value;
        foreach (var (key, brush) in Shared) brush.Color = ColorOf(key);
        SurfacesChanged?.Invoke();
    }

    static Color Rgba(byte a, byte r, byte g, byte b) => Color.FromArgb(a, r, g, b);

    public static bool IsDark => _dark;

    public static Brush Brush(string key)
    {
        if (!Palette.TryGetValue(key, out var colors)) return (Brush)Application.Current.Resources[key];
        if (!Shared.TryGetValue(key, out var brush)) Shared[key] = brush = new SolidColorBrush(ColorOf(key));
        return brush;
    }

    /// <summary>Repaints every themed brush.</summary>
    public static void SetDark(bool dark)
    {
        if (_dark == dark) return;
        _dark = dark;
        foreach (var (key, brush) in Shared) brush.Color = ColorOf(key);
        SurfacesChanged?.Invoke();
    }

    /// <summary>The theme Folio's windows show: the setting's, or the system's.</summary>
    public static bool ResolveDark(Appearance appearance) => appearance switch
    {
        Appearance.Dark => true,
        Appearance.Light => false,
        _ => Application.Current.RequestedTheme == ApplicationTheme.Dark,
    };

    public static ElementTheme ThemeOf(Appearance appearance) => appearance switch
    {
        Appearance.Light => ElementTheme.Light,
        Appearance.Dark => ElementTheme.Dark,
        _ => ElementTheme.Default,
    };

    /// <summary>A window's caption buttons follow its content.</summary>
    public static void ApplyTitleBarTheme(Window window, bool dark) =>
        window.AppWindow.TitleBar.PreferredTheme = dark ? Microsoft.UI.Windowing.TitleBarTheme.Dark : Microsoft.UI.Windowing.TitleBarTheme.Light;

    public static SolidColorBrush Hex(string? hex, byte alpha = 255)
    {
        if (hex is { Length: 7 } && hex[0] == '#' && uint.TryParse(hex[1..], System.Globalization.NumberStyles.HexNumber, null, out var rgb))
            return new SolidColorBrush(Color.FromArgb(alpha, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
        return new SolidColorBrush(Colors.Gray);
    }

    public static TextBlock Label(string text, double size = 13, bool secondary = false, bool bold = false) => new()
    {
        Text = text,
        FontSize = size,
        TextTrimming = TextTrimming.CharacterEllipsis,
        TextWrapping = TextWrapping.NoWrap,
        VerticalAlignment = VerticalAlignment.Center,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        Foreground = secondary ? Brush("FolioSecondaryTextBrush") : Brush("TextFillColorPrimaryBrush"),
    };

    /// <summary>Hover and press colours for buttons without a frame.</summary>
    public static void FlatResources(FrameworkElement control)
    {
        var r = control.Resources;
        r["ButtonBackgroundPointerOver"] = Brush("HoverBrush");
        r["ButtonBackgroundPressed"] = Brush("PressedBrush");
        r["ButtonBorderBrushPointerOver"] = Brush("TransparentBrush");
        r["ButtonBorderBrushPressed"] = Brush("TransparentBrush");
        r["ButtonForegroundPointerOver"] = Brush("TextFillColorPrimaryBrush");
        r["ButtonForegroundPressed"] = Brush("TextFillColorPrimaryBrush");
        r["ToggleButtonBackgroundPointerOver"] = Brush("HoverBrush");
        r["ToggleButtonBackgroundPressed"] = Brush("PressedBrush");
        r["ToggleButtonBorderBrushPointerOver"] = Brush("TransparentBrush");
        r["ToggleButtonBorderBrushPressed"] = Brush("TransparentBrush");
        r["ToggleButtonBackgroundChecked"] = Brush("RowSelectedBrush");
        r["ToggleButtonBackgroundCheckedPointerOver"] = Brush("RowSelectedBrush");
        r["ToggleButtonBackgroundCheckedPressed"] = Brush("PressedBrush");
        r["ToggleButtonBorderBrushChecked"] = Brush("TransparentBrush");
        r["ToggleButtonBorderBrushCheckedPointerOver"] = Brush("TransparentBrush");
        r["ToggleButtonBorderBrushCheckedPressed"] = Brush("TransparentBrush");
        r["ToggleButtonForegroundChecked"] = Brush("FolioAccentBrush");
        r["ToggleButtonForegroundCheckedPointerOver"] = Brush("FolioAccentBrush");
        r["ToggleButtonForegroundCheckedPressed"] = Brush("FolioAccentBrush");
        r["ToggleButtonForegroundPointerOver"] = Brush("TextFillColorPrimaryBrush");
        r["ToggleButtonForegroundPressed"] = Brush("TextFillColorPrimaryBrush");
    }

    /// <summary>The app's icon button: every toolbar uses the same 32 × 32 square; small icons get a smaller one.</summary>
    public static Button IconButton(string icon, string tooltip, RoutedEventHandler click, double size = 16)
    {
        double box = size >= 14 ? 32 : size + 12;
        var button = new Button
        {
            Content = Icon(icon, size),
            Width = box, Height = box, MinWidth = 0, MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(box >= 32 ? 6 : 4),
            Background = Brush("TransparentBrush"),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        FlatResources(button);
        ToolTipService.SetToolTip(button, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip);
        button.Click += click;
        return button;
    }

    /// <summary>A title bar button: the size and square shape of Windows' own minimize, maximize and close buttons.</summary>
    public static Button TitleBarButton(string icon, string tooltip, RoutedEventHandler click, double height)
    {
        var button = IconButton(icon, tooltip, click, 14);
        button.Width = 46;
        button.Height = height;
        button.CornerRadius = new CornerRadius(0);
        return button;
    }

    /// <summary>A two-state tool of a toolbar, the same size as an icon button.</summary>
    public static Microsoft.UI.Xaml.Controls.Primitives.ToggleButton ToolToggle(string icon, string tooltip, string tag)
    {
        var button = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton
        {
            Content = Icon(icon, 15),
            Width = 32, Height = 32, MinWidth = 0, MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(6),
            Tag = tag,
            Background = Brush("TransparentBrush"),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        FlatResources(button);
        ToolTipService.SetToolTip(button, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip);
        return button;
    }

    /// <summary>The thin line between groups of a toolbar.</summary>
    public static Border ToolbarSeparator() => new() { Width = 1, Height = 18, Margin = new Thickness(5, 0, 5, 0), Background = Brush("FolioSeparatorBrush"), VerticalAlignment = VerticalAlignment.Center };

    public static MenuFlyoutItem Item(string text, Action action, string? icon = null, bool enabled = true)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (icon != null) item.Icon = Icon(icon, 14);
        item.Click += (_, _) => action();
        return item;
    }

    /// <summary>A rounded tag chip like the macOS CapsuleLabel.</summary>
    public static Border Chip(string text, string colorHex, bool compact = true, Action? remove = null)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        content.Children.Add(new TextBlock { Text = text, FontSize = compact ? 11 : 12, Foreground = Hex(colorHex), VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 120 });
        if (remove != null)
        {
            var x = new Button { Content = Icon("close", 8, Hex(colorHex)), Padding = new Thickness(2), MinWidth = 0, MinHeight = 0, Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
            x.Click += (_, _) => remove();
            content.Children.Add(x);
        }
        return new Border
        {
            Child = content,
            Background = Hex(colorHex, 0x26),
            BorderBrush = Hex(colorHex, 0x55),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 1, 6, 1),
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    /// <summary>A filled dot as a menu item's icon (colours of tags, groups and annotations).</summary>
    public static IconElement ColorIcon(string colorHex) => new FontIcon { Glyph = "\uEA3B", FontFamily = IconFont, Foreground = Hex(colorHex) };

    /// <summary>The first element of a type under an element (templates' inner parts).</summary>
    public static T? FindDescendant<T>(this DependencyObject root) where T : DependencyObject
    {
        for (int i = 0, n = VisualTreeHelper.GetChildrenCount(root); i < n; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match) return match;
            if (child.FindDescendant<T>() is { } deeper) return deeper;
        }
        return null;
    }

    /// <summary>Text boxes end lines with a carriage return; everything stored uses line feeds (the macOS app reads it too).</summary>
    public static string Lf(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');

    /// <summary>Runs a task nobody waits for; what goes wrong in it is logged and shown instead of vanishing.</summary>
    public static void Fire(this Task task) => task.ContinueWith(t =>
    {
        var error = t.Exception?.GetBaseException();
        CrashLog.Write(error);
        if (error != null) App.Current?.Model?.Toasts.Show(error.Message, "warning");
    }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);

    /// <summary>Shows the left-right arrows over a divider or column edge.</summary>
    public static void ResizeCursor(UIElement element)
    {
        var property = typeof(UIElement).GetProperty("ProtectedCursor", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
        property?.SetValue(element, Microsoft.UI.Input.InputSystemCursor.Create(Microsoft.UI.Input.InputSystemCursorShape.SizeWestEast));
    }

    /// <summary>A window's scale: sizes given to AppWindow are physical pixels.</summary>
    public static double Scale(Window window) => GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)) / 96.0;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern uint GetDpiForWindow(nint hwnd);

    public static Microsoft.UI.Xaml.Shapes.Ellipse Dot(string colorHex, double size = 12) => new() { Width = size, Height = size, Fill = Hex(colorHex) };
}
