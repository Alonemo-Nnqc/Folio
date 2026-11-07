using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Forms;
using Folio.Core;
using Folio.Core.Agent;

namespace Folio.App;

/// <summary>Opening files, folders and links with Windows.</summary>
static class Shell
{
    static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { App.Model?.Toasts.Show(e.Message, "warning"); }
    }

    /// <summary>A web or mail link: from a PDF, a paper's metadata, Folio's own menus. Nothing else, so that a link in a
    /// document can never start a program (file:, ms-msdt:, search-ms: and the like go to ShellExecute too).</summary>
    public static void OpenUrl(string url)
    {
        if (Uri.TryCreate(url.Trim(), UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" or "mailto")
            Open(uri.AbsoluteUri);
        else
            App.Model?.Toasts.Show(Loc.S("不能打开这个链接：%@", url.Length > 80 ? url[..80] + "…" : url), "warning");
    }

    /// <summary>What Windows would run rather than show.</summary>
    static readonly HashSet<string> Runnable = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".com", ".bat", ".cmd", ".ps1", ".psm1", ".vbs", ".vbe", ".js", ".jse", ".wsf", ".wsh", ".msi", ".msp", ".msc",
        ".scr", ".pif", ".lnk", ".url", ".hta", ".cpl", ".jar", ".reg", ".inf", ".application", ".appref-ms", ".appx",
        ".appxbundle", ".msix", ".msixbundle", ".appinstaller", ".library-ms", ".search-ms", ".settingcontent-ms", ".gadget",
    };

    /// <summary>A folder, or a document of the library, in the app Windows uses for it. A file that would be run instead
    /// of shown (an attachment ending in .exe or .lnk) is not opened.</summary>
    public static void OpenPath(string path)
    {
        if (!Path.IsPathFullyQualified(path) || !(Directory.Exists(path) || File.Exists(path))) return;
        if (File.Exists(path) && Runnable.Contains(Path.GetExtension(path)))
        {
            App.Model?.Toasts.Show(Loc.S("为了安全，Folio 不会直接运行“%@”，可以在资源管理器中查看它", Path.GetFileName(path)), "warning");
            return;
        }
        Open(path);
    }

    public static void OpenWith(string app, string path)
    {
        try { Process.Start(new ProcessStartInfo(app) { ArgumentList = { path }, UseShellExecute = false }); }
        catch (Exception e) { App.Model?.Toasts.Show(e.Message, "warning"); }
    }

    /// <summary>Windows' "open with" dialog.</summary>
    public static void OpenWithDialog(string path)
    {
        try { Process.Start(new ProcessStartInfo("rundll32.exe") { ArgumentList = { "shell32.dll,OpenAs_RunDLL", path }, UseShellExecute = false }); }
        catch (Exception e) { App.Model?.Toasts.Show(e.Message, "warning"); }
    }

    /// <summary>Opens File Explorer with the file selected.</summary>
    public static void Reveal(string path)
    {
        try { Process.Start("explorer.exe", $"/select,\"{path}\""); } catch { }
    }

    public static void CopyText(string text, string? html = null)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        if (html != null) data.SetText(CfHtml(html), TextDataFormat.Html);
        // Another program may hold the clipboard for a moment.
        Clipboard.SetDataObject(data, true, 5, 100);
    }

    /// <summary>The clipboard's HTML format: a header with byte offsets around the fragment.</summary>
    static string CfHtml(string html)
    {
        const string Header = "Version:0.9\r\nStartHTML:{0:0000000000}\r\nEndHTML:{1:0000000000}\r\nStartFragment:{2:0000000000}\r\nEndFragment:{3:0000000000}\r\n";
        const string Pre = "<html><body><!--StartFragment-->", Post = "<!--EndFragment--></body></html>";
        int headerLength = string.Format(Header, 0, 0, 0, 0).Length;
        int start = headerLength + Pre.Length, end = start + Encoding.UTF8.GetByteCount(html);
        return string.Format(Header, headerLength, end + Post.Length, start, end) + Pre + html + Post;
    }
}

/// <summary>Short messages at the bottom of the window (the macOS ToastCenter).</summary>
public sealed class ToastCenter(UiQueue ui)
{
    readonly Dictionary<int, Action> _actions = [];
    int _next;

    public void Show(string message, string icon = "info", string? actionTitle = null, Action? action = null) => ui.TryEnqueue(() =>
    {
        int id = ++_next;
        if (action != null)
        {
            _actions[id] = action;
            // Old toasts' actions go; a toast shows for seconds, not for ever.
            foreach (var old in _actions.Keys.Where(k => k < id - 8).ToList()) _actions.Remove(old);
        }
        App.Main?.Bridge.Emit("toast", new { id, message, icon, actionTitle = action != null ? actionTitle : null });
    });

    public void Run(int id)
    {
        if (_actions.Remove(id, out var action)) action();
    }
}

public enum ContentDialogResult { None, Primary, Secondary }

/// <summary>Sheets over the window the user is in, drawn by the page.</summary>
static class Dialogs
{
    static async Task<ContentDialogResult> Ask(string title, string message, string primary, string secondary, string cancel, bool destructive)
    {
        var answer = await App.Active.Bridge.Request("dialog", new { title, message, primary, secondary = secondary.Length > 0 ? secondary : null, cancel, destructive });
        return answer.ValueKind == JsonValueKind.String ? answer.GetString() switch
        {
            "primary" => ContentDialogResult.Primary,
            "secondary" => ContentDialogResult.Secondary,
            _ => ContentDialogResult.None,
        } : ContentDialogResult.None;
    }

    public static Task Message(string title, string message) => Ask(title, message, Loc.S("好"), "", "", false);

    public static async Task<bool> Confirm(string title, string message, string primary, string cancel, bool destructive = false) =>
        await Ask(title, message, primary, "", cancel, destructive) == ContentDialogResult.Primary;

    /// <summary>Three choices: Primary, Secondary or None (cancel).</summary>
    public static Task<ContentDialogResult> Choose(string title, string message, string primary, string secondary, string cancel) =>
        Ask(title, message, primary, secondary, cancel, false);
}

/// <summary>Windows' own file dialogs, owned by the window the user is in.</summary>
static class Pickers
{
    public static List<string> OpenFiles(string? filter = null, bool multiple = true)
    {
        using var dialog = new OpenFileDialog { Multiselect = multiple, Filter = filter ?? "", CheckFileExists = true };
        return dialog.ShowDialog(App.Active) == DialogResult.OK ? dialog.FileNames.ToList() : [];
    }

    public static string? SaveFile(string suggestedName, string filter)
    {
        using var dialog = new SaveFileDialog { FileName = suggestedName, Filter = filter, OverwritePrompt = true };
        return dialog.ShowDialog(App.Active) == DialogResult.OK ? dialog.FileName : null;
    }

    public static string? Folder()
    {
        using var dialog = new FolderBrowserDialog { UseDescriptionForTitle = true, ShowNewFolderButton = true };
        return dialog.ShowDialog(App.Active) == DialogResult.OK ? dialog.SelectedPath : null;
    }
}

/// <summary>The browser extension, installed unpacked from the copy Folio ships (shared with the macOS app).</summary>
public static class BrowserExtensions
{
    public enum Family { Chromium, Firefox }
    public sealed record Browser(string Id, string Name, Family Family, string Exe, string ExtensionsPage, string? ProfileRoot);

    /// <summary>Fixed by the key in the Chromium manifest, whatever folder the extension is loaded from.</summary>
    public const string ChromiumExtensionId = "ljlmdoodaogoghgikjgdbpigeamnjejd";

    static string Source => Path.Combine(AppContext.BaseDirectory, "BrowserExtension");
    public static string InstallRoot => Path.Combine(AppSettings.Folder, "BrowserExtension");
    public static string Folder(Family family) => Path.Combine(InstallRoot, family == Family.Chromium ? "chromium" : "firefox");

    public static string? BundledVersion
    {
        get
        {
            try { return JsonNode.Parse(File.ReadAllText(Path.Combine(Source, "chromium", "manifest.json")))?["version"]?.ToString(); }
            catch { return null; }
        }
    }

    public static List<Browser> Detect()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roaming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var programs = new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), local };
        (string Id, string Name, Family Family, string Exe, string Page, string? Profiles)[] known =
        [
            ("edge", "Microsoft Edge", Family.Chromium, @"Microsoft\Edge\Application\msedge.exe", "edge://extensions", Path.Combine(local, @"Microsoft\Edge\User Data")),
            ("chrome", "Google Chrome", Family.Chromium, @"Google\Chrome\Application\chrome.exe", "chrome://extensions", Path.Combine(local, @"Google\Chrome\User Data")),
            ("brave", "Brave", Family.Chromium, @"BraveSoftware\Brave-Browser\Application\brave.exe", "brave://extensions", Path.Combine(local, @"BraveSoftware\Brave-Browser\User Data")),
            ("vivaldi", "Vivaldi", Family.Chromium, @"Vivaldi\Application\vivaldi.exe", "vivaldi://extensions", Path.Combine(local, @"Vivaldi\User Data")),
            ("opera", "Opera", Family.Chromium, @"Programs\Opera\opera.exe", "opera://extensions", Path.Combine(roaming, @"Opera Software\Opera Stable")),
            ("arc", "Arc", Family.Chromium, @"Microsoft\WindowsApps\Arc.exe", "arc://extensions", Path.Combine(local, @"Packages\TheBrowserCompany.Arc_ttt1ap7aakyb4\LocalCache\Local\Arc\User Data")),
            ("firefox", "Firefox", Family.Firefox, @"Mozilla Firefox\firefox.exe", "about:debugging#/runtime/this-firefox", null),
        ];
        var result = new List<Browser>();
        foreach (var k in known)
        {
            var exe = programs.Select(p => Path.Combine(p, k.Exe)).FirstOrDefault(File.Exists);
            if (exe != null) result.Add(new Browser(k.Id, k.Name, k.Family, exe, k.Page, k.Profiles));
        }
        return result;
    }

    /// <summary>Copies the extension (shared files + the family's manifest) to a stable folder and returns it.</summary>
    public static string PrepareCopy(Family family)
    {
        var target = Folder(family);
        var staging = Path.Combine(InstallRoot, $".{Path.GetFileName(target)}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(staging);
        CopyDirectory(Path.Combine(Source, "shared"), staging);
        File.Copy(Path.Combine(Source, family == Family.Chromium ? "chromium" : "firefox", "manifest.json"), Path.Combine(staging, "manifest.json"), true);
        if (Directory.Exists(target))
        {
            // Replace the contents, keeping the folder the browser loaded.
            foreach (var entry in Directory.EnumerateFileSystemEntries(target))
            {
                if (Directory.Exists(entry)) Directory.Delete(entry, true); else File.Delete(entry);
            }
            CopyDirectory(staging, target);
            Directory.Delete(staging, true);
        }
        else Directory.Move(staging, target);
        return target;
    }

    public static void RefreshInstalledCopies()
    {
        foreach (var family in new[] { Family.Chromium, Family.Firefox })
            if (Directory.Exists(Folder(family))) try { PrepareCopy(family); } catch { }
    }

    static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)), true);
        foreach (var dir in Directory.GetDirectories(from)) CopyDirectory(dir, Path.Combine(to, Path.GetFileName(dir)));
    }

    /// <summary>Whether a Chromium browser has Folio's extension (from its profiles' preferences).</summary>
    public static (bool Installed, bool Enabled, string? Version) InstallState(Browser browser)
    {
        if (browser.Family != Family.Chromium || browser.ProfileRoot is not { } root || !Directory.Exists(root)) return (false, false, null);
        (bool, bool, string?) best = (false, false, null);
        var profiles = new[] { root }.Concat(Directory.GetDirectories(root).Where(d => Path.GetFileName(d) is "Default" || Path.GetFileName(d).StartsWith("Profile")));
        foreach (var profile in profiles)
            foreach (var name in new[] { "Secure Preferences", "Preferences" })
            {
                var path = Path.Combine(profile, name);
                if (!File.Exists(path)) continue;
                try
                {
                    var text = File.ReadAllText(path);
                    if (!text.Contains(ChromiumExtensionId)) continue;
                    var entry = JsonNode.Parse(text)?["extensions"]?["settings"]?[ChromiumExtensionId];
                    if (entry == null) continue;
                    var reasons = entry["disable_reasons"];
                    bool disabled = reasons is JsonArray a ? a.Count > 0 : reasons is JsonValue v && v.TryGetValue<int>(out var n) && n != 0;
                    disabled |= entry["state"] is JsonValue s && s.TryGetValue<int>(out var st) && st == 0;
                    var version = entry["manifest"]?["version"]?.ToString();
                    if (!disabled) return (true, true, version);
                    best = (true, false, version);
                }
                catch (IOException) { }
                catch (JsonException) { }
            }
        return best;
    }

    public static void OpenExtensionsPage(Browser browser)
    {
        try { Process.Start(new ProcessStartInfo(browser.Exe) { ArgumentList = { browser.ExtensionsPage }, UseShellExecute = false }); }
        catch { Shell.CopyText(browser.ExtensionsPage); }
    }
}

/// <summary>folio:// links (agents, the browser extension, notes) open in Folio: registered for this Windows user at each
/// launch, so the command follows Folio wherever it is installed; removed on uninstall.</summary>
static class UrlProtocol
{
    const string Key = @"Software\Classes\folio";

    public static void Register()
    {
        try
        {
            if (Environment.ProcessPath is not { } exe) return;
            using var root = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(Key);
            root.SetValue("", "URL:Folio");
            root.SetValue("URL Protocol", "");
            using (var icon = root.CreateSubKey("DefaultIcon")) icon.SetValue("", $"\"{exe}\",0");
            using var command = root.CreateSubKey(@"shell\open\command");
            var value = $"\"{exe}\" \"%1\"";
            if (command.GetValue("") as string != value) command.SetValue("", value);
        }
        catch { }
    }

    public static void Unregister()
    {
        try { Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(Key, false); } catch { }
    }
}

static class AiIntegration
{
    /// <summary>folio-cli next to Folio.exe.</summary>
    public static string CliPath => Path.Combine(AppContext.BaseDirectory, "folio-cli.exe");

    public static AgentIntegrator Integrator => new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), CliPath);

    /// <summary>What each agent needs beyond Folio's configuration.</summary>
    public static readonly Dictionary<string, string> Hints = new()
    {
        ["gemini-cli"] = "Gemini CLI 只在受信任的文件夹中启用 MCP 服务器\n首次在某个文件夹中运行时选择信任",
        ["claude-desktop"] = "修改后需要完全退出并重新打开 Claude 桌面版",
        ["copilot-cli"] = "在 Copilot CLI 中输入 /mcp 可查看连接状态",
        ["cursor"] = "与 Cursor 编辑器共用 ~/.cursor/mcp.json，编辑器中也会出现 folio 服务器",
        ["kiro"] = "与 Kiro 编辑器共用 ~/.kiro/settings/mcp.json",
        ["antigravity"] = "在 Antigravity 的 设置 ▸ Customizations 中可看到 folio 服务器\n修改后重新打开 Antigravity",
    };

    static readonly HashSet<string> InlineHints = ["gemini-cli", "claude-desktop"];

    public static bool ShowsInline(string id) => InlineHints.Contains(id);

    /// <summary>At launch: if Folio moved, re-point installed MCP entries and refresh installed skills.</summary>
    public static void RepairAfterLaunch()
    {
        if (!File.Exists(CliPath)) return;
        Task.Run(() =>
        {
            try
            {
                var integrator = Integrator;
                integrator.RepairMovedPaths();
                integrator.RefreshInstalledSkills();
            }
            catch { }
        }).Fire();
    }
}

