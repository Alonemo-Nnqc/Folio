using System.Text.Json;
using System.Text.Json.Nodes;

namespace Folio.Core;

public enum OpenWith { Folio, System, Custom }
public enum ReaderZoom { FitWidth, ActualSize }
public enum ReaderLayout { Single, TwoUp }
public enum Appearance { System, Light, Dark }

/// <summary>
/// The app's preferences, with the macOS app's keys and defaults, stored as JSON in %APPDATA%\Folio\settings.json.
/// folio-cli reads the same file (aiAllowWrites, libraryPath). Changes raise Changed with the key.
/// </summary>
public sealed class AppSettings
{
    public static string Folder => OperatingSystem.IsWindows()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Folio")
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "folio-windows");

    readonly string _path;
    JsonObject _values;
    readonly object _lock = new();

    public event Action<string>? Changed;

    public AppSettings(string? path = null)
    {
        _path = path ?? Path.Combine(Folder, "settings.json");
        _values = Load(_path);
    }

    public static AppSettings Shared { get; } = new(Environment.GetEnvironmentVariable("FOLIO_SETTINGS"));

    static JsonObject Load(string path)
    {
        try { return JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? []; }
        catch { return []; }
    }

    /// <summary>Re-reads the file (another process — folio-cli or a second window — may have changed it).</summary>
    public void Reload() { lock (_lock) _values = Load(_path); }

    void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var temp = _path + ".tmp";
        File.WriteAllText(temp, _values.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, _path, overwrite: true);
    }

    T Get<T>(string key, T fallback)
    {
        lock (_lock)
        {
            if (_values[key] is not { } node) return fallback;
            try { return node.Deserialize<T>() ?? fallback; } catch { return fallback; }
        }
    }

    void Set<T>(string key, T value)
    {
        lock (_lock)
        {
            _values[key] = JsonSerializer.SerializeToNode(value);
            Save();
        }
        Changed?.Invoke(key);
    }

    public JsonNode? Raw(string key) { lock (_lock) return _values[key]?.DeepClone(); }

    public void SetRaw(string key, JsonNode? value)
    {
        lock (_lock)
        {
            _values[key] = value?.DeepClone();
            Save();
        }
        Changed?.Invoke(key);
    }

    /// <summary>Where Folio keeps its library when the chosen one cannot be opened.</summary>
    public static string FallbackLibrary => DefaultLibrary;

    static string DefaultLibrary => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Folio");

    /// <summary>FOLIO_LIBRARY (tests, development) overrides the stored location.</summary>
    public string LibraryPath
    {
        get => Environment.GetEnvironmentVariable("FOLIO_LIBRARY") is { Length: > 0 } env ? env : Get("libraryPath", DefaultLibrary);
        set => Set("libraryPath", value);
    }

    public OpenWith OpenWith { get => Enum.TryParse<OpenWith>(Get("openWithMode", "folio"), true, out var v) ? v : OpenWith.Folio; set => Set("openWithMode", value.ToString().ToLowerInvariant()); }
    public string OpenWithAppPath { get => Get("openWithAppPath", ""); set => Set("openWithAppPath", value); }
    public bool IncludeSubgroupItems { get => Get("includeSubgroupItems", true); set => Set("includeSubgroupItems", value); }
    /// <summary>设置 ▸ 通用 ▸ 列表: the green "已翻译" badge after the title of papers that have a translation.</summary>
    public bool ShowTranslatedBadge { get => Get("showTranslatedBadge", true); set => Set("showTranslatedBadge", value); }
    /// <summary>设置 ▸ 通用 ▸ 在列表中显示阅读进度环; 设置 ▸ 阅读 ▸ 读完时提示标为"已读".</summary>
    /// <summary>The right panel floats over the content instead of taking room beside it.</summary>
    public bool InspectorFloating { get => Get("inspectorFloating", false); set => Set("inspectorFloating", value); }
    /// <summary>设置 ▸ Markdown, as the macOS app keeps it (MarkdownPreferences.swift); the page knows the defaults.</summary>
    public static readonly string[] MarkdownKeys =
    [
        "markdownFontSize", "markdownPanelFontSize", "markdownZoom", "markdownPanelZoom", "markdownTypeface", "markdownLineHeight", "markdownParagraphSpacing", "markdownHeadingScale", "markdownCodeScale", "markdownReadableWidth", "markdownCodeIndent",
        "markdownShowsHandles", "markdownShowsPlaceholders", "markdownShowsWordCount", "markdownHighlightsCode", "markdownStrikesDone", "markdownChecksSpelling", "markdownSlashMenu", "markdownContinuesLists", "markdownCompletesSymbols", "markdownPastesLinks",
        "markdownToolbar",
    ];
    public bool ShowReadingRings { get => Get("showReadingRings", true); set => Set("showReadingRings", value); }
    public bool OfferMarkAsRead { get => Get("offerMarkAsRead", true); set => Set("offerMarkAsRead", value); }
    public bool AutoRenameFiles { get => Get("autoRenameFiles", true); set => Set("autoRenameFiles", value); }
    public bool AutoPurgeTrash { get => Get("autoPurgeTrash", true); set => Set("autoPurgeTrash", value); }
    public string CrossrefMailto { get => Get("crossrefMailto", ""); set => Set("crossrefMailto", value); }
    public string OpenAlexApiKey { get => Get("openAlexAPIKey", ""); set => Set("openAlexAPIKey", value); }
    public ReaderZoom ReaderZoom { get => Get("readerZoom", "fitWidth") == "actualSize" ? ReaderZoom.ActualSize : ReaderZoom.FitWidth; set => Set("readerZoom", value == ReaderZoom.ActualSize ? "actualSize" : "fitWidth"); }
    public ReaderLayout ReaderLayout { get => Get("readerLayout", "single") == "twoUp" ? ReaderLayout.TwoUp : ReaderLayout.Single; set => Set("readerLayout", value == ReaderLayout.TwoUp ? "twoUp" : "single"); }
    public bool ReopenReaderTabs { get => Get("reopenReaderTabs", true); set => Set("reopenReaderTabs", value); }
    /// <summary>设置 ▸ 通用 ▸ 背景透明度: how much of the desktop shows through the panels, 0 (opaque) to 1 (as the macOS app).</summary>
    public double BackgroundTranslucency { get => Math.Clamp(Get("backgroundTranslucency", 0.0), 0, 1); set => Set("backgroundTranslucency", Math.Clamp(value, 0, 1)); }
    /// <summary>The highlighter's colour before 1.4 (设置 ▸ 阅读 ▸ 默认高亮颜色): the reader takes it as the highlighter's
    /// until a colour is chosen on the toolbar.</summary>
    public string HighlightColor { get => Get("highlightColor", "yellow"); set => Set("highlightColor", value); }
    /// <summary>Each annotation tool's colour, chosen in its own menu on the reader's toolbar: tool → colour key.</summary>
    public Dictionary<string, string> AnnotationToolColors { get => Get<Dictionary<string, string>>("annotationToolColors", []); set => Set("annotationToolColors", value); }
    /// <summary>Colours mixed for the annotation tools (自定义颜色…), newest first, at most five: "#RRGGBB".</summary>
    public List<string> AnnotationCustomColors { get => Get<List<string>>("annotationCustomColors", []); set => Set("annotationCustomColors", value); }
    public double InkLineWidth { get => Get("inkLineWidth", 2.0); set => Set("inkLineWidth", value); }
    public double TextBoxFontSize { get => Get("textBoxFontSize", 13.0); set => Set("textBoxFontSize", value); }
    public bool ReturnToSelectAfterPlacing { get => Get("returnToSelectAfterPlacing", true); set => Set("returnToSelectAfterPlacing", value); }
    public bool RememberReadingPosition { get => Get("rememberReadingPosition", true); set => Set("rememberReadingPosition", value); }
    public bool ShowAnnotationTooltips { get => Get("showAnnotationTooltips", true); set => Set("showAnnotationTooltips", value); }
    public bool UseZoteroRecognizer { get => Get("useZoteroRecognizer", true); set => Set("useZoteroRecognizer", value); }
    public bool MarkReadingOnOpen { get => Get("markReadingOnOpen", true); set => Set("markReadingOnOpen", value); }
    public bool ReaderPageShadows { get => Get("readerPageShadows", true); set => Set("readerPageShadows", value); }
    public string AnnotationAuthor { get => Get("annotationAuthor", Environment.UserName); set => Set("annotationAuthor", value); }
    public bool AutoRetrieveOnImport { get => Get("autoRetrieveOnImport", true); set => Set("autoRetrieveOnImport", value); }
    public bool AiAllowWrites { get => Get("aiAllowWrites", true); set => Set("aiAllowWrites", value); }
    public bool BrowserConnectorEnabled { get => Get("browserConnectorEnabled", true); set => Set("browserConnectorEnabled", value); }
    public Appearance Appearance { get => Enum.TryParse<Appearance>(Get("appearance", "system"), true, out var v) ? v : Appearance.System; set => Set("appearance", value.ToString().ToLowerInvariant()); }
    /// <summary>"zh-Hans", "en" or "" (follow Windows).</summary>
    public string Language { get => Get("language", ""); set => Set("language", value); }
    public string CitationStyle { get => Get("citationStyle", "gbt7714"); set => Set("citationStyle", value); }
    public bool AutoCheckUpdates { get => Get("autoCheckUpdates", true); set => Set("autoCheckUpdates", value); }
    public bool UpdatePrereleases { get => Get("updatePrereleases", false); set => Set("updatePrereleases", value); }
    /// <summary>Updates found by the automatic check are downloaded in the background; Folio then asks to restart.</summary>
    public bool AutoDownloadUpdates { get => Get("autoDownloadUpdates", false); set => Set("autoDownloadUpdates", value); }

    // 划词翻译 (same keys as the macOS app).
    public bool SelectionTranslationEnabled { get => Get("selectionTranslationEnabled", true); set => Set("selectionTranslationEnabled", value); }
    /// <summary>"button" (a button beside the selection), "automatic" or "shortcut".</summary>
    public string SelectionTranslationTrigger { get => Get("selectionTranslationTrigger", "button"); set => Set("selectionTranslationTrigger", value); }
    /// <summary>Service id; empty: the full-text translation's service.</summary>
    public string SelectionTranslationService { get => Get("selectionTranslationService", ""); set => Set("selectionTranslationService", value); }
    /// <summary>划词翻译: a rate-limited free service hands over to another free one.</summary>
    public bool SelectionTranslationFallback { get => Get("selectionTranslationFallback", true); set => Set("selectionTranslationFallback", value); }
    /// <summary>"Alt+D" style: modifiers then the key's code without its "Key"/"Digit" prefix.</summary>
    public string SelectionTranslationShortcut { get => Get("selectionTranslationShortcut", "Alt+D"); set => Set("selectionTranslationShortcut", value); }
    /// <summary>The reader toolbar's buttons in order (ids from the page); empty: the standard set.</summary>
    public List<string> ReaderToolbar { get => Get<List<string>>("readerToolbar", []); set => Set("readerToolbar", value); }
    public int MetadataEngineRevision { get => Get("metadataEngineRevision", 0); set => Set("metadataEngineRevision", value); }
    public bool OnboardingDone { get => Get("onboardingDone", false); set => Set("onboardingDone", value); }
    public List<string> OpenReaderTabs { get => Get<List<string>>("openReaderTabs", []); set => Set("openReaderTabs", value); }
    /// <summary>The reader's eraser size (READER-30): small, medium or large (InkEraser.Diameters).</summary>
    /// <summary>设置 ▸ 检索 ▸ 期刊指标: look up the ranks of new and changed items' journals by itself (META-30).</summary>
    public bool JournalMetricsAutoFetch { get => Get("journalMetricsAutoFetch", true); set => Set("journalMetricsAutoFetch", value); }
    public string ReaderEraserSize { get => Get("readerEraserSize", "medium"); set => Set("readerEraserSize", value); }
    /// <summary>Sidebar groups the user collapsed, at any level (SIDE-05/17).</summary>
    public List<string> SidebarCollapsedGroups { get => Get<List<string>>("sidebarCollapsedGroups", []); set => Set("sidebarCollapsedGroups", value); }
    public Dictionary<string, double> ColumnWidths { get => Get<Dictionary<string, double>>("columnWidths", []); set => Set("columnWidths", value); }
    public List<string> VisibleColumns { get => Get<List<string>>("visibleColumns", ["title", "venue", "authors", "year", "tags", "dateAdded"]); set => Set("visibleColumns", value); }
    public bool InspectorVisible { get => Get("inspectorVisible", true); set => Set("inspectorVisible", value); }

    /// <summary>The 出版物 column (1.5) shows once for lists whose columns were chosen before it existed, after the title
    /// (as on the Mac, where a new column is visible by default); hiding it afterwards is kept.</summary>
    public void AddVenueColumnOnce()
    {
        if (Get("venueColumnAdded", false)) return;
        if (Raw("visibleColumns") != null)
        {
            var columns = VisibleColumns;
            if (!columns.Contains("venue"))
            {
                int title = columns.IndexOf("title");
                columns.Insert(title < 0 ? 0 : title + 1, "venue");
                VisibleColumns = columns;
            }
        }
        Set("venueColumnAdded", true);
    }
    public bool SidebarVisible { get => Get("sidebarVisible", true); set => Set("sidebarVisible", value); }

    // Translation (same keys and shapes as the macOS app).
    public string TranslationService
    {
        get => Translate.Services.TranslationServiceCatalog.Resolve(Get("translationService", Translate.Services.TranslationServiceCatalog.DefaultServiceId)).Id;
        set => Set("translationService", value);
    }
    /// <summary>Service id → option → value (keys are kept in the secret store, not here).</summary>
    public Dictionary<string, Dictionary<string, string>> TranslationFields { get => Get<Dictionary<string, Dictionary<string, string>>>("translationFields", []); set => Set("translationFields", value); }
    public Dictionary<string, string> FieldsOf(string serviceId) => TranslationFields.GetValueOrDefault(serviceId) ?? [];
    public void SetFields(string serviceId, Dictionary<string, string> fields)
    {
        var all = TranslationFields;
        all[serviceId] = fields;
        TranslationFields = all;
    }
    public Translate.TranslationOptions TranslationOptions { get => Get("translationOptions", new Translate.TranslationOptions()); set => Set("translationOptions", value); }
    public List<Translate.Services.TranslationProfile> TranslationProfiles { get => Get<List<Translate.Services.TranslationProfile>>("translationProfiles", []); set => Set("translationProfiles", value); }
    /// <summary>Papers of one service translated at the same time (设置 ▸ 翻译 ▸ 同一服务同时翻译); the rest wait their turn.</summary>
    public int TranslationParallelJobs { get => Get("translationParallelJobs", 2); set => Set("translationParallelJobs", value); }
    /// <summary>Papers translated at the same time across all services (设置 ▸ 翻译 ▸ 同时翻译总数).</summary>
    public int TranslationParallelTotal { get => Get("translationParallelTotal", 6); set => Set("translationParallelTotal", value); }
    /// <summary>New PDFs that have no translation yet are translated as they are added (设置 ▸ 翻译 ▸ 自动翻译新论文).</summary>
    public bool AutoTranslateImports { get => Get("autoTranslateImports", false); set => Set("autoTranslateImports", value); }
    /// <summary>The configuration in use per service: service id → profile id.</summary>
    public Dictionary<string, string> SelectedTranslationProfiles { get => Get<Dictionary<string, string>>("selectedTranslationProfiles", []); set => Set("selectedTranslationProfiles", value); }
}
