using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using Folio.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Folio.App;

/// <summary>Opening files, folders and links with Windows.</summary>
static class Shell
{
    public static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { App.Current?.Model.Toasts.Show(e.Message, "warning"); }
    }

    public static void OpenWith(string app, string path)
    {
        try { Process.Start(new ProcessStartInfo(app) { ArgumentList = { path }, UseShellExecute = false }); }
        catch (Exception e) { App.Current?.Model.Toasts.Show(e.Message, "warning"); }
    }

    /// <summary>Opens File Explorer with the file selected.</summary>
    public static void Reveal(string path)
    {
        try { Process.Start("explorer.exe", $"/select,\"{path}\""); } catch { }
    }

    public static void CopyText(string text, string? html = null)
    {
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(text);
        if (html != null) package.SetHtmlFormat(Windows.ApplicationModel.DataTransfer.HtmlFormatHelper.CreateHtmlFormat(html));
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
        Windows.ApplicationModel.DataTransfer.Clipboard.Flush();
    }
}

/// <summary>Short messages at the bottom of the window (the macOS ToastCenter).</summary>
public sealed class ToastCenter(DispatcherQueue ui)
{
    public sealed record Toast(string Message, string Icon, string? ActionTitle, Action? Action);
    public event Action<Toast>? Shown;

    public void Show(string message, string icon = "info", string? actionTitle = null, Action? action = null) =>
        ui.TryEnqueue(() => Shown?.Invoke(new Toast(message, icon, actionTitle, action)));
}

/// <summary>Content dialogs on the main window.</summary>
static class Dialogs
{
    static XamlRoot? Root => App.Current?.Window?.Content?.XamlRoot;
    static readonly SemaphoreSlim Gate = new(1, 1);

    static async Task<ContentDialogResult> Show(ContentDialog dialog)
    {
        await Gate.WaitAsync();
        try
        {
            dialog.XamlRoot = Root;
            dialog.RequestedTheme = (App.Current?.Window?.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default;
            return await dialog.ShowAsync();
        }
        finally { Gate.Release(); }
    }

    public static async Task Message(string title, string message) =>
        await Show(new ContentDialog { Title = title, Content = Wrap(message), CloseButtonText = Loc.S("好"), DefaultButton = ContentDialogButton.Close });

    public static async Task<bool> Confirm(string title, string message, string primary, string cancel, bool destructive = false)
    {
        var dialog = new ContentDialog { Title = title, Content = Wrap(message), PrimaryButtonText = primary, CloseButtonText = cancel, DefaultButton = ContentDialogButton.Primary };
        if (destructive) dialog.PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"];
        return await Show(dialog) == ContentDialogResult.Primary;
    }

    /// <summary>Three choices: Primary, Secondary or Close (cancel).</summary>
    public static async Task<ContentDialogResult> Choose(string title, string message, string primary, string secondary, string cancel) =>
        await Show(new ContentDialog { Title = title, Content = Wrap(message), PrimaryButtonText = primary, SecondaryButtonText = secondary, CloseButtonText = cancel, DefaultButton = ContentDialogButton.Primary });

    public static async Task<string?> Ask(string title, string placeholder, string initial = "", string primary = "")
    {
        var box = new TextBox { Text = initial, PlaceholderText = placeholder, MinWidth = 320 };
        box.Loaded += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        var dialog = new ContentDialog { Title = title, Content = box, PrimaryButtonText = primary.Length > 0 ? primary : Loc.S("好"), CloseButtonText = Loc.S("取消"), DefaultButton = ContentDialogButton.Primary };
        return await Show(dialog) == ContentDialogResult.Primary ? box.Text : null;
    }

    public static Task<ContentDialogResult> Custom(ContentDialog dialog) => Show(dialog);

    static TextBlock Wrap(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };
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
