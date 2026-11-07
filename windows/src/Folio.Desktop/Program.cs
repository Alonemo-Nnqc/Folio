using System.IO.Pipes;
using System.Text;
using System.Windows.Forms;
using Folio.Core;

namespace Folio.App;

public static class Program
{
    const string PipeName = "Folio-Activation";

    [STAThread]
    static int Main(string[] args)
    {
        // The uninstaller asks Folio to remove what it registered (the folio:// link), then goes on.
        if (args is ["--unregister"])
        {
            UrlProtocol.Unregister();
            return 0;
        }
        AppDomain.CurrentDomain.UnhandledException += (_, e) => CrashLog.Write(e.ExceptionObject as Exception);

        // One Folio at a time: a second launch (a folio:// link, a PDF opened from Explorer) goes to the first.
        using var mutex = new Mutex(true, $"Folio-{Environment.UserName}", out bool first);
        if (!first)
        {
            Forward(args);
            return 0;
        }
        // "--quit" (the uninstaller's) with no Folio running: nothing to do.
        if (args is ["--quit"]) return 0;

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.ThreadException += (_, e) =>
        {
            CrashLog.Write(e.Exception);
            App.Model?.Toasts.Show(e.Exception.Message, "warning");
        };
        Loc.Override = AppSettings.Shared.Language is { Length: > 0 } language ? language : null;
        try
        {
            App.Start(args);
            Listen();
            Application.Run(App.Main);
        }
        catch (Exception e)
        {
            CrashLog.Write(e);
            MessageBox.Show(Loc.S("Folio 无法启动：%@", e.Message), "Folio", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        return 0;
    }

    static void Forward(string[] args)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName + Environment.UserName, PipeDirection.Out);
            pipe.Connect(2000);
            using var writer = new StreamWriter(pipe, new UTF8Encoding(false));
            foreach (var arg in args) writer.WriteLine(arg);
            writer.WriteLine();
        }
        catch (Exception e) { CrashLog.Write(e); }
    }

    /// <summary>Later launches hand their arguments over here.</summary>
    static void Listen() => Task.Run(async () =>
    {
        while (true)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(PipeName + Environment.UserName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await pipe.WaitForConnectionAsync();
                using var reader = new StreamReader(pipe, Encoding.UTF8);
                var args = new List<string>();
                while (await reader.ReadLineAsync() is { Length: > 0 } line) args.Add(line);
                App.Ui.TryEnqueue(() => App.HandleActivation(args));
            }
            catch (Exception e) { CrashLog.Write(e); await Task.Delay(1000); }
        }
    });
}

/// <summary>The application: the one model, the main window, and the settings and guide windows.</summary>
public static class App
{
    public static UiQueue Ui { get; private set; } = null!;
    public static AppModel Model { get; private set; } = null!;
    public static HostWindow Main { get; private set; } = null!;
    static HostWindow? _settings, _onboarding;
    static readonly List<HostWindow> Windows = [];

    public static IEnumerable<HostWindow> AllWindows => Windows;

    /// <summary>The window the user is in: dialogs and file pickers belong to it.</summary>
    public static HostWindow Active => Windows.FirstOrDefault(w => w.ContainsFocus || Form.ActiveForm == w) ?? Main;

    internal static void Start(string[] args)
    {
        // A control's handle fixes the thread that WinForms posts to.
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        Ui = new UiQueue(SynchronizationContext.Current!);
        Model = new AppModel(Ui);
        Api.Install(Model);
        Main = new HostWindow("main", new HostWindow.Options(MinWidth: 900, MinHeight: 560, RememberBounds: true, CaptionHeight: 52));
        Windows.Add(Main);
        // Closing the window keeps Folio in the notification area; Exit Folio ends it.
        Main.HideInsteadOfClosing = () => !Quitting;
        Main.HiddenToTray += () =>
        {
            foreach (var other in Windows.Where(w => w != Main).ToList()) other.Close();
            Tray.HintOnce();
        };
        Main.FormClosed += (_, _) =>
        {
            Tray.Remove();
            Model.Updater.InstallOnQuit();
            Model.Translations.CancelAll();
            foreach (var other in Windows.Where(w => w != Main).ToList()) other.Close();
        };
        Tray.Install();
        Model.Start();
        UrlProtocol.Register();
        AiIntegration.RepairAfterLaunch();
        BrowserExtensions.RefreshInstalledCopies();
        Main.Ready += () =>
        {
            HandleActivation(args);
            if (!Model.Settings.OnboardingDone) OpenOnboarding();
        };
    }

    public static void OpenSettings(string page = "")
    {
        if (page.Length > 0) Model.Settings.SetRaw("settingsPane", page);
        if (_settings is { IsDisposed: false }) { _settings.BringForward(); Broadcast("settings.page", page); return; }
        _settings = new HostWindow("settings", new HostWindow.Options(Width: 820, Height: 620, MinWidth: 640, MinHeight: 420, Minimizable: false, Maximizable: false, Owner: Main));
        Add(_settings);
    }

    public static void OpenOnboarding()
    {
        if (_onboarding is { IsDisposed: false }) { _onboarding.BringForward(); return; }
        _onboarding = new HostWindow("onboarding", new HostWindow.Options(Width: 640, Height: 560, MinWidth: 640, MinHeight: 560, Minimizable: false, Maximizable: false, Resizable: false, Owner: Main));
        Add(_onboarding);
    }

    static void Add(HostWindow window)
    {
        Windows.Add(window);
        window.FormClosed += (_, _) => Windows.Remove(window);
        window.Show();
    }

    public static void Broadcast(string name, object? data)
    {
        foreach (var w in Windows) w.Bridge.Emit(name, data);
    }

    public static void BringToFront() => Main.BringForward();

    /// <summary>Set once Folio is really going: the main window then closes instead of hiding.</summary>
    public static bool Quitting { get; private set; }

    public static void Quit()
    {
        Quitting = true;
        Main.Close();
    }

    /// <summary>Starts a new Folio once this one has gone (a language change).</summary>
    public static void Restart()
    {
        if (Environment.ProcessPath is { } exe)
        {
            var script = $"Start-Sleep -Milliseconds 800; Start-Process '{exe.Replace("'", "''")}'";
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("powershell.exe") { ArgumentList = { "-NoProfile", "-WindowStyle", "Hidden", "-Command", script }, UseShellExecute = false, CreateNoWindow = true });
        }
        Quit();
    }

    /// <summary>Files and folio:// links from Explorer, the browser extension or a second launch.</summary>
    public static void HandleActivation(IReadOnlyList<string> args)
    {
        // The uninstaller asks the running Folio to finish (saving what is in flight) before it removes the files.
        if (args is ["--quit"])
        {
            Quit();
            return;
        }
        Main.BringForward();
        foreach (var arg in args)
        {
            if (arg.StartsWith("folio://", StringComparison.OrdinalIgnoreCase)) Model.OpenLink(arg);
            else if (File.Exists(arg) && arg.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) Model.Importer.ImportFiles([arg], null).Fire();
        }
    }
}

/// <summary>Work for the interface thread.</summary>
public sealed class UiQueue(SynchronizationContext context)
{
    readonly int _thread = Environment.CurrentManagedThreadId;
    public bool HasThreadAccess => Environment.CurrentManagedThreadId == _thread;
    public bool TryEnqueue(Action action)
    {
        context.Post(_ =>
        {
            try { action(); }
            catch (Exception e) { CrashLog.Write(e); }
        }, null);
        return true;
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

static class TaskExtensions
{
    /// <summary>Runs a task nobody waits for; what goes wrong in it is logged and shown instead of vanishing.</summary>
    public static void Fire(this Task task) => task.ContinueWith(t =>
    {
        var error = t.Exception?.GetBaseException();
        CrashLog.Write(error);
        if (error != null) App.Model?.Toasts.Show(error.Message, "warning");
    }, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
}
