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
    public bool AutoRenameFiles { get => Get("autoRenameFiles", true); set => Set("autoRenameFiles", value); }
    public bool AutoPurgeTrash { get => Get("autoPurgeTrash", true); set => Set("autoPurgeTrash", value); }
    public string CrossrefMailto { get => Get("crossrefMailto", ""); set => Set("crossrefMailto", value); }
    public string OpenAlexApiKey { get => Get("openAlexAPIKey", ""); set => Set("openAlexAPIKey", value); }
    public ReaderZoom ReaderZoom { get => Get("readerZoom", "fitWidth") == "actualSize" ? ReaderZoom.ActualSize : ReaderZoom.FitWidth; set => Set("readerZoom", value == ReaderZoom.ActualSize ? "actualSize" : "fitWidth"); }
    public ReaderLayout ReaderLayout { get => Get("readerLayout", "single") == "twoUp" ? ReaderLayout.TwoUp : ReaderLayout.Single; set => Set("readerLayout", value == ReaderLayout.TwoUp ? "twoUp" : "single"); }
    public bool ReopenReaderTabs { get => Get("reopenReaderTabs", true); set => Set("reopenReaderTabs", value); }
    /// <summary>How much of the desktop shows through the windows: 0 (opaque) to 1.</summary>
    public double WindowTransparency { get => Math.Clamp(Get("windowTransparency", 0.2), 0, 1); set => Set("windowTransparency", Math.Clamp(value, 0, 1)); }
    public string HighlightColor { get => Get("highlightColor", "yellow"); set => Set("highlightColor", value); }
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
    public int MetadataEngineRevision { get => Get("metadataEngineRevision", 0); set => Set("metadataEngineRevision", value); }
    public bool OnboardingDone { get => Get("onboardingDone", false); set => Set("onboardingDone", value); }
    public List<string> OpenReaderTabs { get => Get<List<string>>("openReaderTabs", []); set => Set("openReaderTabs", value); }
    public Dictionary<string, double> ColumnWidths { get => Get<Dictionary<string, double>>("columnWidths", []); set => Set("columnWidths", value); }
    public List<string> VisibleColumns { get => Get<List<string>>("visibleColumns", ["title", "source", "authors", "year", "tags", "dateAdded"]); set => Set("visibleColumns", value); }
    public double SidebarWidth { get => Get("sidebarWidth", 240.0); set => Set("sidebarWidth", value); }
    public double InspectorWidth { get => Get("inspectorWidth", 320.0); set => Set("inspectorWidth", value); }
    public bool InspectorVisible { get => Get("inspectorVisible", true); set => Set("inspectorVisible", value); }
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
    /// <summary>The configuration in use per service: service id → profile id.</summary>
    public Dictionary<string, string> SelectedTranslationProfiles { get => Get<Dictionary<string, string>>("selectedTranslationProfiles", []); set => Set("selectedTranslationProfiles", value); }
}
