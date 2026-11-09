using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Folio.Core;
using Appearance = Folio.Core.Appearance;

namespace Folio.App;

/// <summary>The notification-area icon's menu, drawn by Folio: a rounded Acrylic panel with Folio's name, roomy rows with
/// Fluent icons and a rounded highlight, light or dark with Folio's appearance (Windows 11; plain on Windows 10).</summary>
sealed class TrayMenu : Form
{
    public sealed record Entry(string Glyph, string Title, Action Action, bool Separator = false);

    readonly List<Entry> _entries;
    readonly string _subtitle;
    readonly bool _dark;
    readonly bool _glass = System.Environment.OSVersion.Version.Build >= 22000;
    int _hover = -1;
    readonly Bitmap? _logo = LoadLogo();
    static readonly string IconFont = FontFamily.Families.Any(f => f.Name == "Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
    static readonly string TextFont = FontFamily.Families.Any(f => f.Name == "Segoe UI Variable Text") ? "Segoe UI Variable Text" : "Segoe UI";
    static TrayMenu? _open;

    float S => DeviceDpi / 96f;
    int Pad => (int)(6 * S);
    int HeaderHeight => (int)(56 * S);
    int RowHeight => (int)(34 * S);
    int SeparatorHeight => (int)(9 * S);

    TrayMenu(List<Entry> entries, string subtitle)
    {
        _entries = entries;
        _subtitle = subtitle;
        _dark = App.Model.Settings.Appearance == Appearance.Dark || (App.Model.Settings.Appearance == Appearance.System && HostWindow.SystemIsDark());
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        DoubleBuffered = true;
        KeyPreview = true;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = _glass ? Color.Black : Panel;
        Deactivate += (_, _) => Close();
        KeyDown += (_, e) => { if (e.KeyCode == Keys.Escape) Close(); };
        FormClosed += (_, _) => { if (_open == this) _open = null; };
    }

    Color Panel => _dark ? Color.FromArgb(44, 44, 46) : Color.FromArgb(249, 249, 250);
    Color Text_ => _dark ? Color.FromArgb(240, 240, 242) : Color.FromArgb(28, 28, 30);
    Color Secondary => _dark ? Color.FromArgb(160, 160, 166) : Color.FromArgb(110, 110, 115);
    Color Hover => _dark ? Color.FromArgb(28, 255, 255, 255) : Color.FromArgb(16, 0, 0, 0);
    Color Line => _dark ? Color.FromArgb(30, 255, 255, 255) : Color.FromArgb(20, 0, 0, 0);

    protected override CreateParams CreateParams
    {
        get
        {
            var p = base.CreateParams;
            p.ExStyle |= 0x80;          // WS_EX_TOOLWINDOW: not in Alt+Tab
            p.ClassStyle |= 0x20000;    // CS_DROPSHADOW where DWM does not draw one
            return p;
        }
    }

    public static void Show(List<Entry> entries, string subtitle)
    {
        _open?.Close();
        var menu = new TrayMenu(entries, subtitle);
        _open = menu;
        menu.Place();
        menu.Show();
        menu.Activate();
        // The menu is a window of its own: it must be in front to close when the user clicks elsewhere.
        SetForegroundWindow(menu.Handle);
    }

    void Place()
    {
        int width = (int)(220 * S);
        int height = Pad * 2 + HeaderHeight + _entries.Sum(e => e.Separator ? SeparatorHeight : RowHeight);
        var at = Cursor.Position;
        var area = Screen.FromPoint(at).WorkingArea;
        int x = Math.Clamp(at.X - width + (int)(8 * S), area.Left + 8, area.Right - width - 8);
        int y = at.Y - height - (int)(8 * S);
        if (y < area.Top + 8) y = Math.Min(at.Y + (int)(8 * S), area.Bottom - height - 8);
        Bounds = new Rectangle(x, y, width, height);
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int dark = _dark ? 1 : 0, round = 2;
        DwmSetWindowAttribute(Handle, 20, ref dark, 4);     // DWMWA_USE_IMMERSIVE_DARK_MODE
        DwmSetWindowAttribute(Handle, 33, ref round, 4);    // DWMWA_WINDOW_CORNER_PREFERENCE: round
        if (_glass)
        {
            int backdrop = 3;                               // DWMSBT_TRANSIENTWINDOW (Acrylic)
            DwmSetWindowAttribute(Handle, 38, ref backdrop, 4);
            var margins = new MARGINS { bottom = 32767 };
            DwmExtendFrameIntoClientArea(Handle, ref margins);
        }
    }

    static Bitmap? LoadLogo()
    {
        try { return new Icon(Path.Combine(AppContext.BaseDirectory, "Assets", "Folio.ico"), 64, 64).ToBitmap(); }
        catch { return null; }
    }

    Rectangle RowRect(int index)
    {
        int y = Pad + HeaderHeight;
        for (int i = 0; i < index; i++) y += _entries[i].Separator ? SeparatorHeight : RowHeight;
        return new Rectangle(Pad, y, ClientSize.Width - Pad * 2, _entries[index].Separator ? SeparatorHeight : RowHeight);
    }

    int HitRow(Point p)
    {
        for (int i = 0; i < _entries.Count; i++) if (!_entries[i].Separator && RowRect(i).Contains(p)) return i;
        return -1;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        // A veil over the Acrylic, written with its alpha (GDI would leave the glass clear).
        g.CompositingMode = CompositingMode.SourceCopy;
        using (var veil = new SolidBrush(_glass ? Color.FromArgb(_dark ? 150 : 170, Panel) : Panel)) g.FillRectangle(veil, ClientRectangle);
        g.CompositingMode = CompositingMode.SourceOver;

        // Header: the app's icon, its name and what it is doing.
        int hx = Pad + (int)(10 * S), hy = Pad;
        int iconSize = (int)(30 * S);
        if (_logo != null)
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(_logo, new Rectangle(hx, hy + (HeaderHeight - iconSize) / 2 - (int)(2 * S), iconSize, iconSize));
        }
        using (var title = new Font(TextFont, 14f * S, FontStyle.Bold, GraphicsUnit.Pixel))
        using (var brush = new SolidBrush(Text_))
            g.DrawString("Folio", title, brush, hx + iconSize + (int)(10 * S), hy + (int)(7 * S));
        using (var small = new Font(TextFont, 11.5f * S, FontStyle.Regular, GraphicsUnit.Pixel))
        using (var brush = new SolidBrush(Secondary))
            g.DrawString(_subtitle, small, brush, hx + iconSize + (int)(10 * S), hy + (int)(26 * S));
        using (var line = new Pen(Line, Math.Max(1, S)))
            g.DrawLine(line, Pad + (int)(8 * S), Pad + HeaderHeight - (int)(4 * S), ClientSize.Width - Pad - (int)(8 * S), Pad + HeaderHeight - (int)(4 * S));

        using var glyphFont = new Font(IconFont, 14f * S, GraphicsUnit.Pixel);
        using var textFont = new Font(TextFont, 13f * S, GraphicsUnit.Pixel);
        for (int i = 0; i < _entries.Count; i++)
        {
            var entry = _entries[i];
            var rect = RowRect(i);
            if (entry.Separator)
            {
                using var line = new Pen(Line, Math.Max(1, S));
                int y = rect.Top + rect.Height / 2;
                g.DrawLine(line, rect.Left + (int)(8 * S), y, rect.Right - (int)(8 * S), y);
                continue;
            }
            if (i == _hover)
            {
                using var path = Rounded(rect, (int)(6 * S));
                using var fill = new SolidBrush(Hover);
                g.FillPath(fill, path);
            }
            using var brush = new SolidBrush(Text_);
            using var dim = new SolidBrush(i == _hover ? Text_ : Secondary);
            var format = new StringFormat { LineAlignment = StringAlignment.Center };
            g.DrawString(entry.Glyph, glyphFont, dim, new RectangleF(rect.Left + (int)(10 * S), rect.Top + 1 * S, 22 * S, rect.Height), format);
            g.DrawString(entry.Title, textFont, brush, new RectangleF(rect.Left + (int)(38 * S), rect.Top, rect.Width - 44 * S, rect.Height), format);
        }
    }

    static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var path = new GraphicsPath();
        int d = radius * 2;
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        int hit = HitRow(e.Location);
        if (hit != _hover) { _hover = hit; Invalidate(); }
    }

    protected override void OnMouseLeave(EventArgs e)
    {
        if (_hover != -1) { _hover = -1; Invalidate(); }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        int hit = HitRow(e.Location);
        if (hit < 0) return;
        var action = _entries[hit].Action;
        Close();
        action();
    }

    [StructLayout(LayoutKind.Sequential)] struct MARGINS { public int left, right, top, bottom; }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(nint hwnd, ref MARGINS margins);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint hwnd);
}
