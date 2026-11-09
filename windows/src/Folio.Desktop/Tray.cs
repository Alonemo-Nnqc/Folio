using System.Drawing;
using System.Windows.Forms;
using Folio.Core;

namespace Folio.App;

/// <summary>Folio's icon in the notification area. Closing the window leaves Folio running there, ready to come back at
/// once; only "Exit Folio" (here or in the app menu) ends it. Its menu is Folio's own (TrayMenu): rounded, roomy, Acrylic.</summary>
static class Tray
{
    static NotifyIcon? _icon;
    const string HintShownKey = "trayHintShown";

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
        int running = App.Model.Translations.ActiveItemIds.Count;
        var subtitle = running > 0 ? Loc.S("%lld 篇正在翻译", running) : Loc.S("版本 %@", Updater.CurrentVersion);
        TrayMenu.Show([
            new("\uE8A7", Loc.S("打开 Folio"), App.BringToFront),
            new("\uE713", Loc.S("设置…"), () => { App.BringToFront(); App.OpenSettings(); }),
            new("\uE895", Loc.S("检查更新…"), () => App.Model.Updater.Check(userInitiated: true).Fire()),
            new("", "", () => { }, Separator: true),
            new("\uE7E8", Loc.S("退出 Folio"), App.Quit),
        ], subtitle);
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

}
