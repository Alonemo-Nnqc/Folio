using System.Text.Json;
using Folio.Core;
using Folio.Core.Citation;

namespace Folio.App;

/// <summary>What the page can ask of the app. Each area lives in its own file.</summary>
public static partial class Api
{
    static AppModel M = null!;

    public static void Install(AppModel model)
    {
        M = model;
        InstallApp();
        InstallLibrary();
        InstallReader();
        InstallTranslation();
        InstallIntegrations();
        WireEvents();
    }

    static void InstallApp()
    {
        Bridge.On("app.boot", a => new
        {
            strings = Loc.IsEnglish ? Loc.EnglishTable : null,
            isEnglish = Loc.IsEnglish,
            settings = AllSettings(),
            version = Updater.CurrentVersion,
            translucency = HostWindow.SupportsTranslucency,
            channel = Updater.Channel,
            captionWidth = a.Window?.CaptionWidthLogical ?? 138,
            windowState = a.Window?.WindowStateName,
            library = LibraryState(full: true),
            rows = RowsState(),
            jobs = JobsState(),
            startupProblem = M.StartupProblem,
            annotationColors = AnnotationColors.All.Select(c => new { key = c.Key, title = Loc.S(c.Title), hex = AnnotationColors.Hex(c.Key) }),
            tagPresets = TagPalette.Presets.Select(c => new { name = Loc.S(c.Name), hex = c.Hex }),
            citationStyles = CitationStyles.All.Select(s => new { raw = s.Raw(), name = s.DisplayName() }),
            referenceFormats = Enum.GetValues<ReferenceFormat>().Select(f => new { raw = f.ToString().ToLowerInvariant(), name = f.DisplayName() }),
            itemTypes = ItemTypes.All.Select(t => new { raw = t.Raw(), name = t.DisplayName() }),
            statuses = Enum.GetValues<ReadStatus>().Select(s => new { raw = (int)s, name = s.DisplayName() }),
            homeFolder = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            userName = Environment.UserName,
        });
        Bridge.On("app.ready", a =>
        {
            a.Window?.PageReady();
            if (a.Window == App.Main && M.StartupProblem is { } problem) Dialogs.Message(Loc.S("无法打开文献库"), problem).Fire();
            return null;
        });
        Bridge.On("window.close", a => { App.Ui.TryEnqueue(() => a.Window?.Close()); return null; });
        Bridge.On("window.fullScreen", a => { a.Window?.ToggleFullScreen(); return null; });
        Bridge.On("window.resize", a => { a.Window?.BeginResize(a.Str("edge")); return null; });
        Bridge.On("window.caption", a => { a.Window?.SetCaptionColors(a.Str("background"), a.Str("foreground"), a.Bool("animate")); return null; });
        Bridge.On("window.translucency", a => { a.Window?.SetTranslucency(a.Num("value")); return null; });
        Bridge.On("window.theme", a => { a.Window?.ApplyTheme(a.Bool("dark")); return null; });
        Bridge.On("window.title", a => { if (a.Window != null) a.Window.Text = a.Str("title"); return null; });
        Bridge.On("window.settings", a => { App.OpenSettings(a.OptStr("page") ?? ""); return null; });
        Bridge.On("window.onboarding", _ => { App.OpenOnboarding(); return null; });
        Bridge.On("window.quit", _ => { App.Quit(); return null; });
        Bridge.On("app.restart", _ => { App.Restart(); return null; });
        Bridge.On("app.onboardingDone", a => { M.Settings.OnboardingDone = true; App.Ui.TryEnqueue(() => a.Window?.Close()); return null; });

        Bridge.On("shell.open", a => { Shell.OpenUrl(a.Str("target")); return null; });
        Bridge.On("shell.reveal", a => { Shell.Reveal(a.Str("path")); return null; });
        Bridge.On("shell.copy", a => { Shell.CopyText(a.Str("text"), a.OptStr("html")); return null; });
        Bridge.On("toast.show", a => { M.Toasts.Show(a.Str("message"), a.OptStr("icon") ?? "info"); return null; });
        Bridge.On("toast.run", a => { M.Toasts.Run(a.Int("id")); return null; });
        Bridge.On("drop.paths", a => a.DroppedPaths);
        Bridge.On("pick.file", a => Pickers.OpenFiles(a.OptStr("filter"), a.Bool("multiple", true)));
        Bridge.On("pick.folder", _ => Pickers.Folder());

        Bridge.On("settings.all", _ => AllSettings());
        Bridge.On("settings.set", a =>
        {
            M.Settings.SetRaw(a.Str("key"), a.Node("value"));
            return null;
        });

        Bridge.OnAsync("update.check", _ => M.Updater.Check(userInitiated: true));
        Bridge.On("update.state", _ => M.Updater.State);
        Bridge.OnAsync("update.install", _ => M.Updater.Install());
    }

    /// <summary>The settings as they are stored, with the app's defaults for what was never set.</summary>
    public static Dictionary<string, object?> AllSettings()
    {
        var s = M.Settings;
        return new()
        {
            ["libraryPath"] = M.Library.Root,
            ["openWithMode"] = s.OpenWith.ToString().ToLowerInvariant(),
            ["openWithAppPath"] = s.OpenWithAppPath,
            ["includeSubgroupItems"] = s.IncludeSubgroupItems,
            ["autoRenameFiles"] = s.AutoRenameFiles,
            ["autoPurgeTrash"] = s.AutoPurgeTrash,
            ["crossrefMailto"] = s.CrossrefMailto,
            ["openAlexAPIKey"] = s.OpenAlexApiKey,
            ["readerZoom"] = s.ReaderZoom == ReaderZoom.ActualSize ? "actualSize" : "fitWidth",
            ["readerLayout"] = s.ReaderLayout == ReaderLayout.TwoUp ? "twoUp" : "single",
            ["reopenReaderTabs"] = s.ReopenReaderTabs,
            ["highlightColor"] = s.HighlightColor,
            ["useZoteroRecognizer"] = s.UseZoteroRecognizer,
            ["markReadingOnOpen"] = s.MarkReadingOnOpen,
            ["readerPageShadows"] = s.ReaderPageShadows,
            ["annotationAuthor"] = s.AnnotationAuthor,
            ["autoRetrieveOnImport"] = s.AutoRetrieveOnImport,
            ["aiAllowWrites"] = s.AiAllowWrites,
            ["browserConnectorEnabled"] = s.BrowserConnectorEnabled,
            ["appearance"] = s.Appearance.ToString().ToLowerInvariant(),
            ["language"] = s.Language,
            ["citationStyle"] = s.CitationStyle,
            ["autoCheckUpdates"] = s.AutoCheckUpdates,
            ["updatePrereleases"] = s.UpdatePrereleases,
            ["autoDownloadUpdates"] = s.AutoDownloadUpdates,
            ["backgroundTranslucency"] = s.BackgroundTranslucency,
            ["selectionTranslationEnabled"] = s.SelectionTranslationEnabled,
            ["selectionTranslationTrigger"] = s.SelectionTranslationTrigger,
            ["selectionTranslationService"] = s.SelectionTranslationService,
            ["selectionTranslationShortcut"] = s.SelectionTranslationShortcut,
            ["readerToolbar"] = s.ReaderToolbar,
            ["onboardingDone"] = s.OnboardingDone,
            ["openReaderTabs"] = s.OpenReaderTabs,
            ["columnWidths"] = s.ColumnWidths,
            ["visibleColumns"] = s.VisibleColumns,
            ["sidebarWidth"] = s.Raw("sidebarWidth")?.GetValue<double>() ?? 210.0, // the macOS window's
            ["inspectorWidth"] = s.Raw("inspectorWidth")?.GetValue<double>() ?? 270.0,
            ["inspectorVisible"] = s.InspectorVisible,
            ["sidebarVisible"] = s.SidebarVisible,
            ["settingsPane"] = s.Raw("settingsPane")?.ToString() ?? "general",
            ["readerSidebarWidth"] = s.Raw("readerSidebarWidth")?.GetValue<double>() ?? 220.0,
        };
    }

    static void WireEvents()
    {
        M.SnapshotChanged += () => App.Main?.Bridge.Emit("library", LibraryState(full: false));
        M.RowsChanged += () => App.Main?.Bridge.Emit("rows", RowsState());
        M.RevealRequested += id => App.Main?.Bridge.Emit("reveal", id);
        M.OpenInReaderRequested += (file, page) => App.Main?.Bridge.Emit("reader.open", new { fileId = file.Id, page });
        M.LibraryWillChange += () => App.Main?.Bridge.Emit("library.willChange", null);
        M.Updater.StateChanged += () => App.Ui.TryEnqueue(() => App.Main?.Bridge.Emit("update", M.Updater.State));
        M.Translations.JobsChanged += () => App.Main?.Bridge.Emit("translation.jobs", JobsState());
        M.Translations.ProgressChanged += _ => App.Main?.Bridge.Emit("translation.jobs", JobsState());
        M.Connector.StateChanged += () => App.Broadcast("connector", ConnectorState());
        M.Settings.Changed += key => App.Ui.TryEnqueue(() =>
        {
            if (key == "browserConnectorEnabled")
            {
                if (M.Settings.BrowserConnectorEnabled) M.Connector.Start(); else M.Connector.Stop();
            }
            if (key == "includeSubgroupItems") M.Refresh();
            App.Broadcast("settings", AllSettings());
        });
    }

    static long Ms(DateTime t) => new DateTimeOffset(t.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(t, DateTimeKind.Utc) : t).ToUnixTimeMilliseconds();
    static long? Ms(DateTime? t) => t is { } v ? Ms(v) : null;
}
