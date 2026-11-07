using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Folio.Core;

namespace Folio.App;

/// <summary>
/// In-app updates for Windows, from GitHub Releases.
///
/// One release (tag v1.2.0) carries both apps: Folio-1.2.0-macOS.dmg with the appcast.xml installed Macs read, and an
/// installer per Windows architecture, Folio-1.2.0-Windows-x64-Setup.exe and Folio-1.2.0-Windows-ARM64-Setup.exe. Folio
/// downloads the one for this computer, checks it against the SHA-256 GitHub records for the file, and runs it quietly:
/// on "Restart now" (it closes Folio, installs and starts it again), or otherwise when Folio quits, as Sparkle does.
/// </summary>
public sealed class Updater
{
    public const string Repository = "Alonemo-Nnqc/Folio";
    static readonly HttpClient Http = CreateClient();

    readonly AppModel _model;
    string? _installer;
    string? _pendingVersion;
    System.Windows.Forms.Timer? _timer;

    public Updater(AppModel model) { _model = model; }

    public static string CurrentVersion =>
        typeof(Updater).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "1.0.0";

    static bool IsArm64 => RuntimeInformation.ProcessArchitecture == Architecture.Arm64;

    /// <summary>win-x64 or win-arm64, shown in Settings beside the version.</summary>
    public static string Channel => IsArm64 ? "win-arm64" : "win-x64";

    /// <summary>The installer this computer takes from a release.</summary>
    static string InstallerName(string version) => $"Folio-{version}-Windows-{(IsArm64 ? "ARM64" : "x64")}-Setup.exe";

    /// <summary>Installed by Folio's installer (not run from a build folder): only then is there something to update.</summary>
    public bool IsInstalled => File.Exists(Path.Combine(AppContext.BaseDirectory, "unins000.exe"));

    public string? PendingVersion => _pendingVersion;

    static HttpClient CreateClient()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"Folio-Windows/{CurrentVersion}");
        http.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return http;
    }

    public void StartAutomaticChecks()
    {
        if (!_model.Settings.AutoCheckUpdates || !IsInstalled) return;
        Check(userInitiated: false).Fire();
        _timer = new System.Windows.Forms.Timer { Interval = 24 * 60 * 60 * 1000 };
        _timer.Tick += (_, _) => { if (_model.Settings.AutoCheckUpdates && _installer == null) Check(userInitiated: false).Fire(); };
        _timer.Start();
    }

    public sealed record Release(string Version, Version Parsed, string Url, string? Sha256);

    /// <summary>The newest release with an installer for this computer (prereleases only when the user opted in).</summary>
    public static async Task<Release?> LatestRelease(bool includePrereleases, CancellationToken ct = default)
    {
        using var doc = JsonDocument.Parse(await Http.GetStringAsync($"https://api.github.com/repos/{Repository}/releases?per_page=30", ct));
        Release? best = null;
        foreach (var release in doc.RootElement.EnumerateArray())
        {
            if (release.GetProperty("draft").GetBoolean()) continue;
            if (release.GetProperty("prerelease").GetBoolean() && !includePrereleases) continue;
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith('v')) continue;
            var text = tag[1..];
            if (!Version.TryParse(text.Split('-')[0], out var parsed)) continue;
            foreach (var asset in release.GetProperty("assets").EnumerateArray())
            {
                if (asset.GetProperty("name").GetString() != InstallerName(text)) continue;
                string? sha = asset.TryGetProperty("digest", out var digest) && digest.GetString() is { } d && d.StartsWith("sha256:") ? d[7..] : null;
                if (best == null || parsed > best.Parsed)
                    best = new Release(text, parsed, asset.GetProperty("browser_download_url").GetString()!, sha);
            }
        }
        return best;
    }

    public async Task Check(bool userInitiated)
    {
        if (!IsInstalled)
        {
            if (userInitiated) await Dialogs.Message(Loc.S("检查更新"), Loc.S("从开发环境运行时无法自动更新。"));
            return;
        }
        if (_installer != null)
        {
            await OfferRestart();
            return;
        }
        try
        {
            var latest = await LatestRelease(_model.Settings.UpdatePrereleases);
            if (latest == null || !Version.TryParse(CurrentVersion, out var current) || latest.Parsed <= current)
            {
                if (userInitiated) await Dialogs.Message(Loc.S("已是最新版本"), Loc.S("Folio %@ 是目前最新的 Windows 版本。", CurrentVersion));
                return;
            }
            if (userInitiated) _model.Toasts.Show(Loc.S("正在下载 Folio %@…", latest.Version), "download");
            _installer = await Download(latest);
            _pendingVersion = latest.Version;
            await OfferRestart();
        }
        catch (Exception e)
        {
            if (userInitiated) await Dialogs.Message(Loc.S("检查更新"), Loc.S("无法检查更新：%@", e.Message));
        }
    }

    /// <summary>The installer, saved under %TEMP% once its SHA-256 matches the one GitHub keeps for the file.</summary>
    static async Task<string> Download(Release release)
    {
        if (release.Sha256 == null) throw new InvalidOperationException("the release does not say the installer's SHA-256");
        var folder = Path.Combine(Path.GetTempPath(), "Folio-Update");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, InstallerName(release.Version));
        var bytes = await Http.GetByteArrayAsync(release.Url);
        if (!Convert.ToHexString(SHA256.HashData(bytes)).Equals(release.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("the downloaded installer does not match its SHA-256");
        await File.WriteAllBytesAsync(path, bytes);
        return path;
    }

    async Task OfferRestart()
    {
        if (_installer == null || _pendingVersion == null) return;
        if (!await Dialogs.Confirm(Loc.S("有新版本可用"), Loc.S("Folio %@ 已下载，重新启动即可完成安装。", _pendingVersion),
                                   Loc.S("立即重新启动"), Loc.S("稍后")))
            return;
        // The installer closes Folio, shows its progress, and starts Folio again (/RELAUNCH).
        if (Run("/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RELAUNCH")) { _installer = null; App.Quit(); }
    }

    /// <summary>Folio is quitting with an update downloaded: it installs now, out of sight, for the next start.</summary>
    public void InstallOnQuit()
    {
        if (_installer != null) Run("/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS");
    }

    bool Run(string arguments)
    {
        try
        {
            Process.Start(new ProcessStartInfo(_installer!, arguments) { UseShellExecute = false });
            return true;
        }
        catch (Exception e)
        {
            CrashLog.Write(e);
            _model.Toasts.Show(Loc.S("无法检查更新：%@", e.Message), "warning");
            return false;
        }
    }
}
