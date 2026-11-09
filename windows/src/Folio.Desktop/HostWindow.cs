using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Folio.Core;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Appearance = Folio.Core.Appearance;

namespace Folio.App;

/// <summary>
/// A Folio window: a WebView2 that fills it, with no title bar of Windows' own. The minimize, maximize and close buttons stay
/// Windows' in behaviour (Snap Layouts, hover states): the page has a hole there, and this window paints and answers them.
/// </summary>
public sealed class HostWindow : Form
{
    public sealed record Options(int Width = 1320, int Height = 820, int MinWidth = 640, int MinHeight = 420, bool Minimizable = true,
                                 bool Maximizable = true, bool Resizable = true, bool RememberBounds = false, HostWindow? Owner = null, int CaptionHeight = 40);

    const string ReaderHost = "folio.ui", LibraryHost = "folio.library";
    const int CaptionButtonLogical = 46, CaptionFadeMs = 200;

    static Task<CoreWebView2Environment>? _environment;

    /// <summary>One browser environment for all windows: only the first one pays for starting it.</summary>
    static Task<CoreWebView2Environment> Environment_() =>
        _environment ??= CoreWebView2Environment.CreateAsync(null, Path.Combine(AppSettings.Folder, "WebView2"), new CoreWebView2EnvironmentOptions());

    readonly string _route;
    readonly Options _options;
    readonly WebView2 _web = new() { Dock = DockStyle.Fill };
    public Bridge Bridge { get; }
    public event Action? Ready;
    /// <summary>Asked when the user closes the window: true hides it instead (the main window, while Folio keeps running).</summary>
    public Func<bool>? HideInsteadOfClosing;
    public event Action? HiddenToTray;
    bool _fullScreen;
    FormWindowState _beforeFullScreen;
    Rectangle _normalBounds;
    Color _captionBack = Color.White, _captionText = Color.Black;
    /// <summary>背景透明度: 0 opaque; otherwise the share of the panels' colour left over the Acrylic backdrop.</summary>
    double _veil = 1;
    bool Translucent => _veil < 1;
    bool? _themeDark;
    System.Windows.Forms.Timer? _captionFade;
    int _hover = HTNOWHERE, _pressed = HTNOWHERE;
    readonly HashSet<string> _previewHosts = [];
    bool _pageFlushed, _ready;
    static readonly string IconFontName = FontFamily.Families.Any(f => f.Name == "Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";

    public HostWindow(string route, Options options)
    {
        _route = route;
        _options = options;
        Bridge = new Bridge(this);
        Text = "Folio";
        Icon = LoadIcon();
        AutoScaleMode = AutoScaleMode.None;
        StartPosition = FormStartPosition.Manual;
        FormBorderStyle = options.Resizable ? FormBorderStyle.Sizable : FormBorderStyle.FixedSingle;
        MinimizeBox = options.Minimizable;
        MaximizeBox = options.Maximizable;
        ShowInTaskbar = options.Owner == null;
        if (options.Owner != null) Owner = options.Owner;
        ApplyTheme(App.Model.Settings.Appearance == Appearance.Dark || (App.Model.Settings.Appearance == Appearance.System && SystemIsDark()));
        Controls.Add(_web);
        PlaceWindow();
        DoubleBuffered = true;
        Load += async (_, _) => await Initialize();
        Activated += (_, _) => { Bridge.Emit("window.active", true); InvalidateCaption(); };
        Deactivate += (_, _) => { Bridge.Emit("window.active", false); InvalidateCaption(); };
        Resize += (_, _) => { UpdateHole(); RememberNormalBounds(); Bridge.Emit("window.state", WindowStateName); };
        // Hidden in the notification area, the page gives back what memory it can.
        VisibleChanged += (_, _) =>
        {
            try
            {
                if (_web.CoreWebView2 is { } core)
                    core.MemoryUsageTargetLevel = Visible ? CoreWebView2MemoryUsageTargetLevel.Normal : CoreWebView2MemoryUsageTargetLevel.Low;
            }
            catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException) { }
        };
        Move += (_, _) => RememberNormalBounds();
        DpiChanged += (_, _) => UpdateHole();
        FormClosing += (_, e) =>
        {
            if (e.CloseReason == CloseReason.UserClosing && HideInsteadOfClosing?.Invoke() == true)
            {
                e.Cancel = true;
                if (options.RememberBounds) SaveBounds();
                // What is in flight is saved as on closing (a note being typed, the reading position); the page itself stays.
                Bridge.Emit("app.willClose", null);
                Hide();
                HiddenToTray?.Invoke();
                return;
            }
            if (options.RememberBounds) SaveBounds();
            // The page saves what is still in flight (a note being typed, the reading position), then the window goes.
            if (route != "main" || _pageFlushed || !_ready) return;
            e.Cancel = true;
            _pageFlushed = true;
            Bridge.Emit("app.willClose", null);
            var timer = new System.Windows.Forms.Timer { Interval = 250 };
            timer.Tick += (_, _) => { timer.Dispose(); Close(); };
            timer.Start();
        };
        FormClosed += (_, _) => { Bridge.Core = null; StopCaptionFade(); };
        App.Model.Settings.Changed += OnSettingsChanged;
        FormClosed += (_, _) => App.Model.Settings.Changed -= OnSettingsChanged;
    }

    public string WindowStateName => _fullScreen ? "fullScreen" : WindowState == FormWindowState.Maximized ? "maximized" : "normal";

    void OnSettingsChanged(string key)
    {
        if (key != "appearance") return;
        App.Ui.TryEnqueue(() =>
        {
            if (_web.CoreWebView2 != null) _web.CoreWebView2.Profile.PreferredColorScheme = ColorScheme(App.Model.Settings.Appearance);
        });
    }

    static CoreWebView2PreferredColorScheme ColorScheme(Appearance appearance) => appearance switch
    {
        Appearance.Light => CoreWebView2PreferredColorScheme.Light,
        Appearance.Dark => CoreWebView2PreferredColorScheme.Dark,
        _ => CoreWebView2PreferredColorScheme.Auto,
    };

    static Icon? LoadIcon()
    {
        try { return new Icon(Path.Combine(AppContext.BaseDirectory, "Assets", "Folio.ico")); }
        catch { return null; }
    }

    public static bool SystemIsDark()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is 0;
        }
        catch { return false; }
    }

    async Task Initialize()
    {
        try
        {
            await _web.EnsureCoreWebView2Async(await Environment_());
        }
        catch (Exception e)
        {
            // Windows 10 without the WebView2 runtime, or a broken one.
            CrashLog.Write(e);
            if (MessageBox.Show(this, Loc.S("无法打开阅读器：这台电脑缺少 Microsoft Edge WebView2 运行时。") + "\n\n" + Loc.S("下载 WebView2 运行时"), "Folio", MessageBoxButtons.OKCancel, MessageBoxIcon.Error) == DialogResult.OK)
                Shell.OpenUrl("https://developer.microsoft.com/microsoft-edge/webview2/");
            Close();
            return;
        }
        var core = _web.CoreWebView2;
        Bridge.Core = core;
        var settings = core.Settings;
#if DEBUG
        settings.AreDevToolsEnabled = true;
#else
        settings.AreDevToolsEnabled = System.Environment.GetEnvironmentVariable("FOLIO_DEVTOOLS") == "1";
#endif
        settings.IsStatusBarEnabled = false;
        settings.AreDefaultContextMenusEnabled = false;
        // Ctrl+P, Ctrl+F, F5 and the like are Folio's; the page handles them.
        settings.AreBrowserAcceleratorKeysEnabled = false;
        settings.IsZoomControlEnabled = false;
        // Must stay on: without it a touchpad pinch never reaches the page. The page handles it itself.
        settings.IsPinchZoomEnabled = true;
        settings.IsSwipeNavigationEnabled = false;
        settings.IsGeneralAutofillEnabled = false;
        settings.IsPasswordAutosaveEnabled = false;
        settings.IsNonClientRegionSupportEnabled = true;
        core.Profile.PreferredColorScheme = ColorScheme(App.Model.Settings.Appearance);
        core.SetVirtualHostNameToFolderMapping(ReaderHost, Path.Combine(AppContext.BaseDirectory, "wwwroot"), CoreWebView2HostResourceAccessKind.Allow);
        MapLibrary();
        core.NewWindowRequested += (_, e) => { e.Handled = true; Shell.OpenUrl(e.Uri); };
        // Anything that would leave the interface (a dropped file, a link) opens outside instead.
        core.NavigationStarting += (_, e) =>
        {
            if (e.Uri.StartsWith($"https://{ReaderHost}/", StringComparison.OrdinalIgnoreCase)) return;
            e.Cancel = true;
            if (IsWebLink(e.Uri)) Shell.OpenUrl(e.Uri);
        };
        // The readers' frames stay on Folio's pages too.
        core.FrameNavigationStarting += (_, e) =>
        {
            if (e.Uri.StartsWith($"https://{ReaderHost}/", StringComparison.OrdinalIgnoreCase) || e.Uri.StartsWith("about:", StringComparison.OrdinalIgnoreCase)) return;
            e.Cancel = true;
            if (IsWebLink(e.Uri)) Shell.OpenUrl(e.Uri);
        };
        core.WebMessageReceived += (_, e) => Bridge.Receive(e);
        core.ProcessFailed += (_, e) =>
        {
            CrashLog.Write(new InvalidOperationException($"WebView2 process failed: {e.ProcessFailedKind} {e.Reason}"));
            if (e.ProcessFailedKind is CoreWebView2ProcessFailedKind.RenderProcessExited or CoreWebView2ProcessFailedKind.RenderProcessUnresponsive) core.Reload();
        };
        UpdateHole();
        App.Model.LibraryOpened += MapLibrary;
        FormClosed += (_, _) => App.Model.LibraryOpened -= MapLibrary;
        core.Navigate($"https://{ReaderHost}/index.html#{_route}");
    }

    static bool IsWebLink(string uri) =>
        uri.StartsWith("http:", StringComparison.OrdinalIgnoreCase) || uri.StartsWith("https:", StringComparison.OrdinalIgnoreCase) || uri.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase);

    public void MapLibrary()
    {
        if (_web.CoreWebView2 is not { } core) return;
        core.ClearVirtualHostNameToFolderMapping(LibraryHost);
        core.SetVirtualHostNameToFolderMapping(LibraryHost, App.Model.Library.Root, CoreWebView2HostResourceAccessKind.Allow);
    }

    /// <summary>A translation still being written lives outside the library: it gets its own address.</summary>
    public string MapPreview(string folder)
    {
        var host = "folio.preview-" + Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(System.Text.Encoding.UTF8.GetBytes(folder)))[..12].ToLowerInvariant();
        if (_previewHosts.Add(host)) _web.CoreWebView2?.SetVirtualHostNameToFolderMapping(host, folder, CoreWebView2HostResourceAccessKind.Allow);
        return host;
    }

    /// <summary>Called by the page once it has drawn.</summary>
    public void PageReady()
    {
        _ready = true;
        Bridge.MarkReady();
        if (System.Environment.GetEnvironmentVariable("FOLIO_TIMING") is { Length: > 0 } timing)
            File.AppendAllText(timing, $"{_route} ready {(DateTime.Now - System.Diagnostics.Process.GetCurrentProcess().StartTime).TotalMilliseconds:F0} ms\n");
        Ready?.Invoke();
        Ready = null;
    }

    public void BringForward()
    {
        if (!Visible) Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
        // A window activated from another process's request only flashes without this.
        SetForegroundWindow(Handle);
    }

    /// <summary>Colours of the buttons' part of the title bar, from what the page shows there.</summary>
    public void SetCaptionColors(string background, string foreground, bool animate = false)
    {
        var to = ColorTranslator.FromHtml(background);
        _captionText = ColorTranslator.FromHtml(foreground);
        StopCaptionFade();
        if (!animate || !Visible || to == _captionBack)
        {
            _captionBack = to;
            if (!Translucent) BackColor = to;
            InvalidateCaption();
            return;
        }
        // Keeps pace with the panel sliding in underneath.
        var from = _captionBack;
        long start = System.Environment.TickCount64;
        _captionFade = new System.Windows.Forms.Timer { Interval = 15 };
        _captionFade.Tick += (_, _) =>
        {
            double t = Math.Min(1, (System.Environment.TickCount64 - start) / (double)CaptionFadeMs);
            double eased = 1 - (1 - t) * (1 - t);
            int Mix(byte a, byte b) => (int)Math.Round(a + (b - a) * eased);
            _captionBack = Color.FromArgb(Mix(from.R, to.R), Mix(from.G, to.G), Mix(from.B, to.B));
            InvalidateCaption();
            if (t < 1) return;
            StopCaptionFade();
            _captionBack = to;
            if (!Translucent) BackColor = to;
        };
        _captionFade.Start();
    }

    void StopCaptionFade()
    {
        _captionFade?.Dispose();
        _captionFade = null;
    }

    public void ApplyTheme(bool dark)
    {
        int on = dark ? 1 : 0;
        if (IsHandleCreated) DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int));
        // The page sends this after every change of settings: only a real change of theme may reset the colours it chose for the buttons.
        if (_themeDark == dark) return;
        _themeDark = dark;
        StopCaptionFade();
        _captionBack = dark ? ColorTranslator.FromHtml("#1E1E1E") : Color.White;
        _captionText = dark ? Color.White : Color.Black;
        if (!Translucent)
        {
            BackColor = _captionBack;
            _web.DefaultBackgroundColor = dark ? ColorTranslator.FromHtml("#1E1E1E") : Color.White;
        }
        InvalidateCaption();
    }

    /// <summary>Acrylic behind the window (Windows 11): what the page leaves transparent shows the desktop, blurred.</summary>
    public static bool SupportsTranslucency => System.Environment.OSVersion.Version.Build >= 22000;

    /// <summary>Applies 背景透明度 (0 … 1). The page makes its panels translucent to the same degree.</summary>
    public void SetTranslucency(double amount)
    {
        double veil = SupportsTranslucency && amount > 0.001 ? 0.94 * Math.Pow(1 - Math.Clamp(amount, 0, 1), 1.3) : 1;
        bool was = Translucent;
        _veil = veil;
        if (!IsHandleCreated) return;
        if (Translucent != was || Translucent)
        {
            // Extended from the bottom edge over the whole window: extended from the top, DWM would draw its own caption
            // buttons over ours.
            var margins = Translucent ? new MARGINS { bottom = 32767 } : new MARGINS();
            DwmExtendFrameIntoClientArea(Handle, ref margins);
            int backdrop = Translucent ? DWMSBT_TRANSIENTWINDOW : DWMSBT_AUTO;
            DwmSetWindowAttribute(Handle, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
            if (Translucent)
            {
                BackColor = Color.Black;   // black is what DWM fills with the backdrop
                _web.DefaultBackgroundColor = Color.Transparent;
            }
            else
            {
                BackColor = _captionBack;
                _web.DefaultBackgroundColor = _themeDark == true ? ColorTranslator.FromHtml("#1E1E1E") : Color.White;
            }
        }
        Invalidate();
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        ApplyTheme(App.Model.Settings.Appearance == Appearance.Dark || (App.Model.Settings.Appearance == Appearance.System && SystemIsDark()));
        // Rounded corners and the shadow, on Windows 11.
        int round = DWMWCP_ROUND;
        DwmSetWindowAttribute(Handle, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));
        SetTranslucency(App.Model.Settings.BackgroundTranslucency);
    }

    public void ToggleFullScreen()
    {
        if (!_fullScreen)
        {
            _beforeFullScreen = WindowState;
            _fullScreen = true;
            FormBorderStyle = FormBorderStyle.None;
            WindowState = FormWindowState.Normal;
            WindowState = FormWindowState.Maximized;
        }
        else
        {
            _fullScreen = false;
            FormBorderStyle = _options.Resizable ? FormBorderStyle.Sizable : FormBorderStyle.FixedSingle;
            WindowState = _beforeFullScreen;
        }
        UpdateHole();
        Bridge.Emit("window.state", WindowStateName);
    }

    /// <summary>The page asked for the window to be resized from its top edge (its top pixels are the page's).</summary>
    public void BeginResize(string edge)
    {
        if (!_options.Resizable || WindowState != FormWindowState.Normal) return;
        int hit = edge switch { "topleft" => HTTOPLEFT, "topright" => HTTOPRIGHT, _ => HTTOP };
        ReleaseCapture();
        SendMessage(Handle, WM_NCLBUTTONDOWN, hit, 0);
    }

    // MARK: Placement

    void PlaceWindow()
    {
        double scale = DeviceDpi / 96.0;
        MinimumSize = new Size((int)(_options.MinWidth * scale), (int)(_options.MinHeight * scale));
        if (_options.RememberBounds)
        {
            var parts = App.Model.Settings.Raw("windowBounds")?.ToString()?.Split(',').Select(p => int.TryParse(p, out var v) ? v : int.MinValue).ToArray();
            if (parts is { Length: >= 4 } && parts.All(p => p != int.MinValue) && parts[2] > 400 && parts[3] > 300)
            {
                var rect = new Rectangle(parts[0], parts[1], parts[2], parts[3]);
                // Only where a screen still is.
                if (Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(rect)))
                {
                    Bounds = rect;
                    _normalBounds = rect;
                    if (parts.Length > 4 && parts[4] == 1) WindowState = FormWindowState.Maximized;
                    return;
                }
            }
            var area = Screen.PrimaryScreen!.WorkingArea;
            int w = (int)Math.Min(_options.Width * scale, area.Width * 0.92), h = (int)Math.Min(_options.Height * scale, area.Height * 0.92);
            Bounds = new Rectangle(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h);
            return;
        }
        int width = (int)(_options.Width * scale), height = (int)(_options.Height * scale);
        var parent = _options.Owner?.Bounds ?? Screen.PrimaryScreen!.WorkingArea;
        var work = Screen.FromRectangle(parent).WorkingArea;
        width = Math.Min(width, work.Width);
        height = Math.Min(height, work.Height);
        Bounds = new Rectangle(Math.Clamp(parent.X + (parent.Width - width) / 2, work.X, work.Right - width), Math.Clamp(parent.Y + (parent.Height - height) / 2, work.Y, work.Bottom - height), width, height);
    }

    void RememberNormalBounds()
    {
        if (WindowState == FormWindowState.Normal && !_fullScreen) _normalBounds = Bounds;
    }

    void SaveBounds()
    {
        if (_normalBounds.IsEmpty) return;
        var b = _normalBounds;
        App.Model.Settings.SetRaw("windowBounds", $"{b.X},{b.Y},{b.Width},{b.Height},{(WindowState == FormWindowState.Maximized ? 1 : 0)}");
    }

    // MARK: The buttons

    int ButtonWidth => (int)Math.Round(CaptionButtonLogical * DeviceDpi / 96.0);
    int CaptionHeight => (int)Math.Round(_options.CaptionHeight * DeviceDpi / 96.0);
    int ButtonCount => 1 + (_options.Minimizable ? 1 : 0) + (_options.Maximizable ? 1 : 0);
    /// <summary>The caption area's width in the page's units.</summary>
    public int CaptionWidthLogical => _fullScreen ? 0 : ButtonCount * CaptionButtonLogical;

    Rectangle CaptionRect => new(ClientSize.Width - ButtonCount * ButtonWidth, 0, ButtonCount * ButtonWidth, CaptionHeight);

    void UpdateHole()
    {
        if (_fullScreen) { _web.Region = null; return; }
        if (ClientSize.Width <= 0 || ClientSize.Height <= 0) return;
        var region = new Region(new Rectangle(0, 0, ClientSize.Width, ClientSize.Height));
        region.Exclude(CaptionRect);
        var old = _web.Region;
        _web.Region = region;
        old?.Dispose();
        InvalidateCaption();
    }

    void InvalidateCaption() { if (IsHandleCreated) Invalidate(CaptionRect); }

    int HitButton(Point client)
    {
        if (_fullScreen) return HTNOWHERE;
        var rect = CaptionRect;
        if (!rect.Contains(client)) return HTNOWHERE;
        int index = (client.X - rect.X) / ButtonWidth;
        var buttons = new List<int>();
        if (_options.Minimizable) buttons.Add(HTMINBUTTON);
        if (_options.Maximizable) buttons.Add(HTMAXBUTTON);
        buttons.Add(HTCLOSE);
        return buttons[Math.Clamp(index, 0, buttons.Count - 1)];
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        if (_fullScreen) return;
        var rect = CaptionRect;
        if (Translucent)
        {
            // Written with its alpha (GDI would leave the glass fully clear), the same veil as the page beside it.
            e.Graphics.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
            // The page lays two translucent layers there (the window's background and the column's): the same cover.
            double cover = 1 - (1 - _veil) * (1 - _veil);
            using (var veil = new SolidBrush(Color.FromArgb((int)Math.Round(255 * cover), _captionBack))) e.Graphics.FillRectangle(veil, rect);
            e.Graphics.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceOver;
            e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        }
        else
        {
            using var back = new SolidBrush(_captionBack);
            e.Graphics.FillRectangle(back, rect);
        }
        bool active = ContainsFocus || Form.ActiveForm == this;
        var glyphs = new List<(int Hit, string Glyph)>();
        if (_options.Minimizable) glyphs.Add((HTMINBUTTON, ""));
        if (_options.Maximizable) glyphs.Add((HTMAXBUTTON, WindowState == FormWindowState.Maximized ? "" : ""));
        glyphs.Add((HTCLOSE, ""));
        using var font = new Font(IconFontName, 10 * DeviceDpi / 96f, GraphicsUnit.Pixel);
        bool dark = _captionBack.GetBrightness() < 0.5;
        for (int i = 0; i < glyphs.Count; i++)
        {
            var (hit, glyph) = glyphs[i];
            var cell = new Rectangle(rect.X + i * ButtonWidth, 0, ButtonWidth, CaptionHeight);
            bool hover = _hover == hit, pressed = _pressed == hit && hover;
            var text = active ? _captionText : Color.FromArgb(120, _captionText);
            if (hover || pressed)
            {
                Color fill = hit == HTCLOSE
                    ? (pressed ? ColorTranslator.FromHtml("#C84031") : ColorTranslator.FromHtml("#C42B1C"))
                    : Color.FromArgb(pressed ? 22 : 16, dark ? Color.White : Color.Black);
                using var brush = new SolidBrush(fill);
                e.Graphics.FillRectangle(brush, cell);
                if (hit == HTCLOSE) text = Color.White;
            }
            if (Translucent)
            {
                using var brush = new SolidBrush(text);
                using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                e.Graphics.DrawString(glyph, font, brush, cell, format);
            }
            else TextRenderer.DrawText(e.Graphics, glyph, font, cell, text, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }

    void SetHover(int hit)
    {
        if (hit == _hover) return;
        _hover = hit;
        InvalidateCaption();
    }

    protected override void WndProc(ref Message m)
    {
        switch (m.Msg)
        {
            case WM_NCCALCSIZE when m.WParam != 0 && !_fullScreen:
            {
                // Windows keeps its frame on the other three sides (invisible resize borders, shadow); the page reaches the top.
                var before = Marshal.PtrToStructure<NCCALCSIZE_PARAMS>(m.LParam);
                int top = before.rgrc0.top;
                base.WndProc(ref m);
                var after = Marshal.PtrToStructure<NCCALCSIZE_PARAMS>(m.LParam);
                after.rgrc0.top = top;
                if (WindowState == FormWindowState.Maximized)
                {
                    // A maximized window hangs over the screen's edge by its frame.
                    int dpi = (int)GetDpiForWindow(Handle);
                    after.rgrc0.top += GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
                }
                Marshal.StructureToPtr(after, m.LParam, false);
                m.Result = 0;
                return;
            }
            case WM_NCHITTEST:
            {
                base.WndProc(ref m);
                int x = (short)(m.LParam.ToInt64() & 0xFFFF), y = (short)((m.LParam.ToInt64() >> 16) & 0xFFFF);
                var client = PointToClient(new Point(x, y));
                int hit = HitButton(client);
                if (hit != HTNOWHERE) { m.Result = hit; return; }
                if (m.Result == HTCLIENT && client.Y >= 0 && client.Y < (int)(4 * DeviceDpi / 96.0) && _options.Resizable && WindowState == FormWindowState.Normal && !_fullScreen) m.Result = HTTOP;
                return;
            }
            case WM_NCMOUSEMOVE:
            {
                int hit = m.WParam.ToInt32() is HTMINBUTTON or HTMAXBUTTON or HTCLOSE ? m.WParam.ToInt32() : HTNOWHERE;
                SetHover(hit);
                var track = new TRACKMOUSEEVENT { cbSize = Marshal.SizeOf<TRACKMOUSEEVENT>(), dwFlags = TME_LEAVE | TME_NONCLIENT, hwndTrack = Handle };
                TrackMouseEvent(ref track);
                if (hit != HTNOWHERE) { m.Result = 0; return; }
                break;
            }
            case WM_NCMOUSELEAVE:
            case WM_MOUSELEAVE:
                SetHover(HTNOWHERE);
                _pressed = HTNOWHERE;
                InvalidateCaption();
                break;
            case WM_NCLBUTTONDOWN when m.WParam.ToInt32() is HTMINBUTTON or HTMAXBUTTON or HTCLOSE:
                _pressed = m.WParam.ToInt32();
                InvalidateCaption();
                m.Result = 0;
                return;
            case WM_NCLBUTTONUP when m.WParam.ToInt32() is HTMINBUTTON or HTMAXBUTTON or HTCLOSE:
            {
                int hit = m.WParam.ToInt32();
                bool same = hit == _pressed;
                _pressed = HTNOWHERE;
                InvalidateCaption();
                if (same)
                {
                    if (hit == HTMINBUTTON) WindowState = FormWindowState.Minimized;
                    else if (hit == HTMAXBUTTON) WindowState = WindowState == FormWindowState.Maximized ? FormWindowState.Normal : FormWindowState.Maximized;
                    else Close();
                }
                m.Result = 0;
                return;
            }
            case WM_SETTINGCHANGE:
                Bridge.Emit("system.changed", null);
                break;
        }
        base.WndProc(ref m);
    }

    // MARK: Windows

    const int WM_NCCALCSIZE = 0x83, WM_NCHITTEST = 0x84, WM_NCMOUSEMOVE = 0xA0, WM_NCLBUTTONDOWN = 0xA1, WM_NCLBUTTONUP = 0xA2, WM_NCMOUSELEAVE = 0x2A2, WM_MOUSELEAVE = 0x2A3, WM_SETTINGCHANGE = 0x1A;
    const int HTNOWHERE = 0, HTCLIENT = 1, HTMINBUTTON = 8, HTMAXBUTTON = 9, HTTOP = 12, HTTOPLEFT = 13, HTTOPRIGHT = 14, HTCLOSE = 20;
    const int SM_CYSIZEFRAME = 33, SM_CXPADDEDBORDER = 92;
    const uint TME_LEAVE = 2, TME_NONCLIENT = 0x10;
    const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20, DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2;
    const int DWMWA_SYSTEMBACKDROP_TYPE = 38, DWMSBT_AUTO = 0, DWMSBT_TRANSIENTWINDOW = 3;
    [StructLayout(LayoutKind.Sequential)] struct MARGINS { public int left, right, top, bottom; }
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(nint hwnd, ref MARGINS margins);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct NCCALCSIZE_PARAMS { public RECT rgrc0, rgrc1, rgrc2; public nint lppos; }
    [StructLayout(LayoutKind.Sequential)] struct TRACKMOUSEEVENT { public int cbSize; public uint dwFlags; public nint hwndTrack; public uint dwHoverTime; }

    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern nint SendMessage(nint hwnd, int msg, nint wParam, nint lParam);
    [DllImport("user32.dll")] static extern bool TrackMouseEvent(ref TRACKMOUSEEVENT e);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("user32.dll")] static extern int GetSystemMetricsForDpi(int index, int dpi);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);
}
