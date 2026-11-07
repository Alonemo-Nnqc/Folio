using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Folio.Core;
using Appearance = Folio.Core.Appearance;

namespace Folio.App;

/// <summary>Folio's icon in the notification area. Closing the window leaves Folio running there, ready to come back at
/// once; only "Exit Folio" (here or in the app menu) ends it. Its menu is Windows' own popup menu: rounded and in the
/// system's font on Windows 11, light or dark with Folio's appearance.</summary>
static class Tray
{
    static NotifyIcon? _icon;
    const string HintShownKey = "trayHintShown";
    const int OpenCommand = 1, SettingsCommand = 2, QuitCommand = 3;

    public static void Install()
    {
        _icon = new NotifyIcon { Icon = LoadIcon(), Text = "Folio", Visible = true };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) App.BringToFront();
            else if (e.Button == MouseButtons.Right) ShowMenu();
        };
    }

    static Icon? LoadIcon()
    {
        try { return new Icon(Path.Combine(AppContext.BaseDirectory, "Assets", "Folio.ico"), SystemInformation.SmallIconSize); }
        catch { return SystemIcons.Application; }
    }

    static void ShowMenu()
    {
        var owner = App.Main.Handle;
        FollowAppearance(owner);
        var menu = CreatePopupMenu();
        try
        {
            AppendMenu(menu, MF_STRING, OpenCommand, Loc.S("打开 Folio"));
            AppendMenu(menu, MF_STRING, SettingsCommand, Loc.S("设置…"));
            AppendMenu(menu, MF_SEPARATOR, 0, null);
            AppendMenu(menu, MF_STRING, QuitCommand, Loc.S("退出 Folio"));
            SetMenuDefaultItem(menu, OpenCommand, 0);
            GetCursorPos(out var at);
            // Without the foreground, the menu would not close when the user clicks elsewhere.
            SetForegroundWindow(owner);
            int chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_RIGHTALIGN, at.X, at.Y, owner, 0);
            PostMessage(owner, WM_NULL, 0, 0);
            switch (chosen)
            {
                case OpenCommand: App.BringToFront(); break;
                case SettingsCommand: App.BringToFront(); App.OpenSettings(); break;
                case QuitCommand: App.Quit(); break;
            }
        }
        finally { DestroyMenu(menu); }
    }

    /// <summary>Popup menus are drawn dark only when the app says it may be: the same choice as Folio's appearance setting.</summary>
    static void FollowAppearance(nint owner)
    {
        try
        {
            int mode = App.Model.Settings.Appearance switch { Appearance.Dark => ForceDark, Appearance.Light => ForceLight, _ => AllowDark };
            SetPreferredAppMode(mode);
            AllowDarkModeForWindow(owner, mode != ForceLight);
            FlushMenuThemes();
        }
        catch (Exception e) when (e is EntryPointNotFoundException or DllNotFoundException) { }
    }

    /// <summary>The first time the window goes, say where Folio went.</summary>
    public static void HintOnce()
    {
        if (_icon == null || (App.Model.Settings.Raw(HintShownKey) is System.Text.Json.Nodes.JsonValue shown && shown.TryGetValue<bool>(out var done) && done)) return;
        App.Model.Settings.SetRaw(HintShownKey, true);
        _icon.ShowBalloonTip(6000, Loc.S("Folio 仍在运行"),
            Loc.S("关闭窗口后，Folio 会留在通知区域继续运行。点击图标重新打开，在图标的菜单中选择“退出 Folio”彻底退出。"), ToolTipIcon.None);
    }

    public static void Remove()
    {
        if (_icon == null) return;
        _icon.Visible = false;
        _icon.Dispose();
        _icon = null;
    }

    const uint MF_STRING = 0, MF_SEPARATOR = 0x800;
    const uint TPM_RETURNCMD = 0x100, TPM_RIGHTBUTTON = 0x2, TPM_BOTTOMALIGN = 0x20, TPM_RIGHTALIGN = 0x8;
    const int WM_NULL = 0;
    const int AllowDark = 1, ForceDark = 2, ForceLight = 3;

    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    [DllImport("user32.dll")] static extern nint CreatePopupMenu();
    [DllImport("user32.dll")] static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool AppendMenu(nint menu, uint flags, nint id, string? text);
    [DllImport("user32.dll")] static extern bool SetMenuDefaultItem(nint menu, uint item, uint byPosition);
    [DllImport("user32.dll")] static extern int TrackPopupMenuEx(nint menu, uint flags, int x, int y, nint hwnd, nint parameters);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] static extern bool PostMessage(nint hwnd, int msg, nint wParam, nint lParam);
    // uxtheme's unnamed exports, the ones Explorer and Notepad use for dark menus (stable since Windows 10 1903).
    [DllImport("uxtheme.dll", EntryPoint = "#135")] static extern int SetPreferredAppMode(int mode);
    [DllImport("uxtheme.dll", EntryPoint = "#133")] static extern bool AllowDarkModeForWindow(nint hwnd, bool allow);
    [DllImport("uxtheme.dll", EntryPoint = "#136")] static extern void FlushMenuThemes();
}
