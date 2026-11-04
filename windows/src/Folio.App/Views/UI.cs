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
        "restore" => "",
        _ => "",
    };

    public static FontIcon Icon(string name, double size = 16, Brush? foreground = null)
    {
        var icon = new FontIcon { Glyph = Glyph(name), FontFamily = IconFont, FontSize = size };
        if (foreground != null) icon.Foreground = foreground;
        return icon;
    }

    public static Brush Brush(string key) => (Brush)Application.Current.Resources[key];

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
        Foreground = secondary ? Brush("FolioSecondaryTextBrush") : (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"],
    };

    public static Button IconButton(string icon, string tooltip, RoutedEventHandler click, double size = 16)
    {
        var button = new Button
        {
            Content = Icon(icon, size),
            Padding = new Thickness(8, 6, 8, 6),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(button, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip);
        button.Click += click;
        return button;
    }

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

    public static Microsoft.UI.Xaml.Shapes.Ellipse Dot(string colorHex, double size = 12) => new() { Width = size, Height = size, Fill = Hex(colorHex) };
}
