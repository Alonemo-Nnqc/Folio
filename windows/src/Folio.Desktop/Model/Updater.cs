using System.Net.Http.Json;
using System.Runtime.InteropServices;
using System.Text.Json;
using Folio.Core;
using Velopack;
using Velopack.Sources;

namespace Folio.App;

/// <summary>
/// In-app updates for Windows, through Velopack and GitHub Releases.
///
/// The repository also publishes the macOS app, whose releases (tags v*) are the ones GitHub marks "latest" — the
/// macOS app's Sparkle feed reads releases/latest/download/appcast.xml. So Windows never asks GitHub for "latest":
/// it lists the releases, keeps the win-v* tags, takes the newest (prereleases only when the user opted in), and
/// points Velopack at that release's assets (releases.win-x64.json or releases.win-arm64.json plus the package).
/// </summary>
public sealed class Updater
{
    public const string Repository = "Alonemo-Nnqc/Folio";
    const string TagPrefix = "win-v";
    static readonly HttpClient Http = CreateClient();

    readonly AppModel _model;
    UpdateManager? _manager;
    VelopackAsset? _downloaded;
    System.Windows.Forms.Timer? _timer;

    public Updater(AppModel model) { _model = model; }

    public static string CurrentVersion =>
        typeof(Updater).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "1.0.0";

    /// <summary>win-x64 or win-arm64: each architecture updates from its own feed.</summary>
    public static string Channel => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64";

    public bool IsInstalled
    {
        get
        {
            try { return new UpdateManager(new SimpleWebSource("https://localhost/")).IsInstalled; }
            catch { return false; }
        }
    }

    public string? PendingVersion => _downloaded?.Version.ToString();

    static HttpClient CreateClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"Folio-Windows/{CurrentVersion}");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return http;
    }

    public void StartAutomaticChecks()
    {
        if (!_model.Settings.AutoCheckUpdates || !IsInstalled) return;
        Check(userInitiated: false).Fire();
        _timer = new System.Windows.Forms.Timer { Interval = 24 * 60 * 60 * 1000 };
        _timer.Tick += (_, _) => { if (_model.Settings.AutoCheckUpdates) Check(userInitiated: false).Fire(); };
        _timer.Start();
    }

    /// <summary>The newest Windows release on GitHub (never a macOS one).</summary>
    public static async Task<(string Tag, string Version)?> LatestWindowsRelease(bool includePrereleases, CancellationToken ct = default)
    {
        using var doc = JsonDocument.Parse(await Http.GetStringAsync($"https://api.github.com/repos/{Repository}/releases?per_page=100", ct));
        (string Tag, Version Parsed, string Text)? best = null;
        foreach (var release in doc.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean()) continue;
            if (release.GetProperty("prerelease").GetBoolean() && !includePrereleases) continue;
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith(TagPrefix, StringComparison.Ordinal)) continue;
            var text = tag[TagPrefix.Length..];
            if (!Version.TryParse(text.Split('-')[0], out var parsed)) continue;
            if (best == null || parsed > best.Value.Parsed) best = (tag, parsed, text);
        }
        return best is { } b ? (b.Tag, b.Text) : null;
    }

    public async Task Check(bool userInitiated)
    {
        if (!IsInstalled)
        {
            if (userInitiated) await Dialogs.Message(Loc.S("检查更新"), Loc.S("从开发环境运行时无法自动更新。"));
            return;
        }
        if (_downloaded != null)
        {
            await OfferRestart();
            return;
        }
        try
        {
            var latest = await LatestWindowsRelease(_model.Settings.UpdatePrereleases);
            if (latest == null)
            {
                if (userInitiated) await Dialogs.Message(Loc.S("已是最新版本"), Loc.S("Folio %@ 是目前最新的 Windows 版本。", CurrentVersion));
                return;
            }
            var source = new SimpleWebSource($"https://github.com/{Repository}/releases/download/{latest.Value.Tag}/");
            _manager = new UpdateManager(source, new UpdateOptions { ExplicitChannel = Channel });
            var update = await _manager.CheckForUpdatesAsync();
            if (update == null)
            {
                if (userInitiated) await Dialogs.Message(Loc.S("已是最新版本"), Loc.S("Folio %@ 是目前最新的 Windows 版本。", CurrentVersion));
                return;
            }
            if (userInitiated) _model.Toasts.Show(Loc.S("正在下载 Folio %@…", update.TargetFullRelease.Version.ToString()), "download");
            await _manager.DownloadUpdatesAsync(update);
            _downloaded = update.TargetFullRelease;
            // Installed on the next start even if the user never restarts from the prompt (like Sparkle on macOS).
            _manager.WaitExitThenApplyUpdates(_downloaded, silent: true, restart: false);
            await OfferRestart();
        }
        catch (Exception e)
        {
            if (userInitiated) await Dialogs.Message(Loc.S("检查更新"), Loc.S("无法检查更新：%@", e.Message));
        }
    }

    async Task OfferRestart()
    {
        if (_manager == null || _downloaded == null) return;
        if (await Dialogs.Confirm(Loc.S("有新版本可用"), Loc.S("Folio %@ 已下载，重新启动即可完成安装。", _downloaded.Version.ToString()),
                                  Loc.S("立即重新启动"), Loc.S("稍后")))
            _manager.ApplyUpdatesAndRestart(_downloaded);
    }
}
