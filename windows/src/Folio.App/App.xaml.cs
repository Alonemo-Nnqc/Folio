using Folio.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Velopack;

namespace Folio.App;

public static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // Velopack's install / update / uninstall hooks run here and exit before any window appears.
        VelopackApp.Build().Run();
        AppDomain.CurrentDomain.UnhandledException += (_, e) => CrashLog.Write(e.ExceptionObject as Exception);
        WinRT.ComWrappersSupport.InitializeComWrappers();

        // One Folio at a time: a second launch (a folio:// link, a PDF opened from Explorer) goes to the first.
        var instance = AppInstance.FindOrRegisterForKey("Folio-" + Environment.UserName);
        if (!instance.IsCurrent)
        {
            instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs()).AsTask().Wait();
            return 0;
        }
        instance.Activated += (_, e) => App.Current?.HandleActivation(e);

        Application.Start(callback =>
        {
            var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            new App();
        });
        return 0;
    }
}

public partial class App : Application
{
    public static new App? Current { get; private set; }
    public MainWindow? Window { get; private set; }
    public AppModel Model { get; private set; } = null!;

    public App()
    {
        Current = this;
        Loc.Override = AppSettings.Shared.Language is { Length: > 0 } language ? language : null;
        RequestedTheme = AppSettings.Shared.Appearance switch
        {
            Appearance.Light => ApplicationTheme.Light,
            Appearance.Dark => ApplicationTheme.Dark,
            _ => RequestedTheme,
        };
        InitializeComponent();
        UnhandledException += (_, e) =>
        {
            CrashLog.Write(e.Exception);
            e.Handled = true;
            Model?.Toasts.Show(e.Message, "warning");
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Model = new AppModel(DispatcherQueue.GetForCurrentThread());
            Window = new MainWindow(Model);
            Model.Start();
            Window.Activate();
            HandleActivation(AppInstance.GetCurrent().GetActivatedEventArgs());
        }
        catch (Exception e)
        {
            CrashLog.Write(e);
            throw;
        }
    }

    /// <summary>Files and folio:// links from Explorer, the browser extension or a second launch.</summary>
    public void HandleActivation(AppActivationArguments e)
    {
        Window?.DispatcherQueue.TryEnqueue(() =>
        {
            Window.BringToFront();
            if (e.Kind == ExtendedActivationKind.Launch && e.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch)
            {
                foreach (var arg in CommandLine.Split(launch.Arguments))
                {
                    if (arg.StartsWith("folio://", StringComparison.OrdinalIgnoreCase)) Model.OpenLink(arg);
                    else if (File.Exists(arg) && arg.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) _ = Model.Importer.ImportFiles([arg], null);
                }
            }
        });
    }
}

/// <summary>Unexpected errors, appended to %APPDATA%\Folio\crash.log (shown in Settings ▸ Update for bug reports).</summary>
static class CrashLog
{
    public static string PathName => Path.Combine(AppSettings.Folder, "crash.log");

    public static void Write(Exception? e)
    {
        if (e == null) return;
        try
        {
            Directory.CreateDirectory(AppSettings.Folder);
            File.AppendAllText(PathName, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] Folio {Updater.CurrentVersion}\n{e}\n\n");
        }
        catch { }
    }
}

static class CommandLine
{
    /// <summary>Splits a Windows command line into arguments (quotes respected; the program itself dropped).</summary>
    public static List<string> Split(string commandLine)
    {
        var result = new List<string>();
        var current = new System.Text.StringBuilder();
        bool quoted = false;
        foreach (var ch in commandLine)
        {
            if (ch == '"') { quoted = !quoted; continue; }
            if (char.IsWhiteSpace(ch) && !quoted)
            {
                if (current.Length > 0) { result.Add(current.ToString()); current.Clear(); }
                continue;
            }
            current.Append(ch);
        }
        if (current.Length > 0) result.Add(current.ToString());
        if (result.Count > 0 && result[0].EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) result.RemoveAt(0);
        return result;
    }
}
