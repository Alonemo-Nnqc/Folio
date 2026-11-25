using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Folio.Core.Translate;
using Folio.Core.Translate.Services;

namespace Folio.Core;

/// <summary>Text locked with a password (PBKDF2-HMAC-SHA256 → AES-256-GCM): the API keys of a settings package. The macOS
/// app's is the same (PasswordBox.swift).</summary>
public sealed class PasswordBox
{
    [JsonPropertyName("salt")] public byte[] Salt { get; set; } = [];
    [JsonPropertyName("rounds")] public int Rounds { get; set; }
    /// <summary>Nonce, ciphertext, tag.</summary>
    [JsonPropertyName("sealed")] public byte[] Sealed { get; set; } = [];

    const int Nonce = 12, Tag = 16;

    public static PasswordBox Seal(byte[] plain, string password, int rounds = 600_000)
    {
        var box = new PasswordBox { Salt = RandomNumberGenerator.GetBytes(16), Rounds = rounds, Sealed = new byte[Nonce + plain.Length + Tag] };
        RandomNumberGenerator.Fill(box.Sealed.AsSpan(0, Nonce));
        using var aes = new AesGcm(Key(password, box.Salt, rounds), Tag);
        aes.Encrypt(box.Sealed.AsSpan(0, Nonce), plain, box.Sealed.AsSpan(Nonce, plain.Length), box.Sealed.AsSpan(Nonce + plain.Length));
        return box;
    }

    /// <summary>What is in it; null: the password is wrong.</summary>
    public byte[]? Open(string password)
    {
        // Whoever made the file says how many rounds: not so many that it never ends.
        if (Rounds is < 1 or > 10_000_000 || Sealed.Length < Nonce + Tag) return null;
        var plain = new byte[Sealed.Length - Nonce - Tag];
        try
        {
            using var aes = new AesGcm(Key(password, Salt, Rounds), Tag);
            aes.Decrypt(Sealed.AsSpan(0, Nonce), Sealed.AsSpan(Nonce, plain.Length), Sealed.AsSpan(Nonce + plain.Length), plain);
            return plain;
        }
        catch (CryptographicException) { return null; }
    }

    static byte[] Key(string password, byte[] salt, int rounds) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(password.Normalize()), salt, rounds, HashAlgorithmName.SHA256, 32);
}

/// <summary>Folio's settings as a part of a package (<c>folio-settings.json</c>): what both platforms know, under the same
/// keys, and what only means something on the platform it was written on. API keys are only in it locked with a password.
/// (SettingsPackage.swift on macOS.)</summary>
public sealed class SettingsPackage
{
    enum Kind { Bool, Number, String, Strings, Table, Tables }

    /// <summary>Settings that mean the same on macOS and Windows.</summary>
    static readonly Dictionary<string, Kind> Shared = new()
    {
        ["includeSubgroupItems"] = Kind.Bool, ["autoRenameFiles"] = Kind.Bool, ["autoPurgeTrash"] = Kind.Bool, ["crossrefMailto"] = Kind.String,
        ["readerZoom"] = Kind.String, ["readerLayout"] = Kind.String, ["reopenReaderTabs"] = Kind.Bool, ["highlightColor"] = Kind.String,
        ["annotationToolColors"] = Kind.Table, ["annotationCustomColors"] = Kind.Strings, ["inkLineWidth"] = Kind.Number, ["textBoxFontSize"] = Kind.Number,
        ["returnToSelectAfterPlacing"] = Kind.Bool, ["rememberReadingPosition"] = Kind.Bool, ["showAnnotationTooltips"] = Kind.Bool, ["readerEraserSize"] = Kind.String,
        ["useZoteroRecognizer"] = Kind.Bool, ["translationService"] = Kind.String, ["translationFields"] = Kind.Tables, ["selectedTranslationProfiles"] = Kind.Table,
        ["appearance"] = Kind.String, ["markReadingOnOpen"] = Kind.Bool, ["readerPageShadows"] = Kind.Bool, ["annotationAuthor"] = Kind.String,
        ["autoRetrieveOnImport"] = Kind.Bool, ["aiAllowWrites"] = Kind.Bool, ["browserConnectorEnabled"] = Kind.Bool,
        ["selectionTranslationEnabled"] = Kind.Bool, ["selectionTranslationTrigger"] = Kind.String, ["selectionTranslationService"] = Kind.String,
        ["selectionTranslationFallback"] = Kind.Bool, ["backgroundTranslucency"] = Kind.Number, ["translationParallelJobs"] = Kind.Number,
        ["translationParallelTotal"] = Kind.Number, ["autoTranslateImports"] = Kind.Bool, ["journalMetricsAutoFetch"] = Kind.Bool, ["showTranslatedBadge"] = Kind.Bool,
        ["inspectorFloating"] = Kind.Bool, ["showReadingRings"] = Kind.Bool, ["offerMarkAsRead"] = Kind.Bool, ["markdownToolbar"] = Kind.Bool,
        ["markdownFontSize"] = Kind.Number, ["markdownPanelFontSize"] = Kind.Number, ["markdownTypeface"] = Kind.String, ["markdownLineHeight"] = Kind.Number, ["markdownParagraphSpacing"] = Kind.Number, ["markdownHeadingScale"] = Kind.Number, ["markdownCodeScale"] = Kind.Number, ["markdownReadableWidth"] = Kind.Number, ["markdownCodeIndent"] = Kind.Number,
        ["markdownShowsHandles"] = Kind.Bool, ["markdownShowsPlaceholders"] = Kind.Bool, ["markdownShowsWordCount"] = Kind.Bool, ["markdownHighlightsCode"] = Kind.Bool, ["markdownStrikesDone"] = Kind.Bool, ["markdownChecksSpelling"] = Kind.Bool, ["markdownSlashMenu"] = Kind.Bool, ["markdownContinuesLists"] = Kind.Bool, ["markdownCompletesSymbols"] = Kind.Bool, ["markdownPastesLinks"] = Kind.Bool,
    };
    /// <summary>This PC's own: kept as they are, for another PC.</summary>
    static readonly string[] PlatformKeys =
        ["openWithMode", "openWithAppPath", "selectionTranslationShortcut", "citationStyle", "autoCheckUpdates", "updatePrereleases", "autoDownloadUpdates",
         "readerToolbar", "columnWidths", "visibleColumns", "venueColumnAdded"];
    const string OpenAlex = "openAlexAPIKey", EasyScholar = "easyscholar", EasyScholarKey = "secretKey";

    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    // MARK: Writing

    /// <summary><paramref name="password"/>: API keys go along, locked with it (null: without them).</summary>
    public static byte[] Data(AppSettings settings, ISecretStore secrets, GlossaryStore glossary, string? password)
    {
        var values = new JsonObject();
        foreach (var (key, kind) in Shared)
            if (settings.Raw(key) is { } value && Fits(value, kind)) values[key] = value;
        // A file of this computer, pages of one paper.
        var options = settings.TranslationOptions.Copy();
        options.GlossaryFile = null;
        options.Pages = null;
        values["translationOptions"] = JsonSerializer.SerializeToNode(options);
        var profiles = settings.TranslationProfiles;
        values["translationProfiles"] = JsonSerializer.SerializeToNode(profiles);
        values["language"] = settings.Language;
        var own = new JsonObject();
        foreach (var key in PlatformKeys) if (settings.Raw(key) is { } value) own[key] = value;
        var root = new JsonObject { ["platform"] = "windows", ["values"] = values, ["platformValues"] = own, ["glossary"] = JsonSerializer.SerializeToNode(glossary.Terms(), Json) };
        if (!string.IsNullOrEmpty(password))
        {
            var keys = new Dictionary<string, string>();
            foreach (var (owner, option) in Owners(profiles))
                if (secrets.Get(owner, option) is { Length: > 0 } value) keys[SecretStore.Account(owner, option)] = value;
            if (secrets.Get(EasyScholar, EasyScholarKey) is { Length: > 0 } scholar) keys[SecretStore.Account(EasyScholar, EasyScholarKey)] = scholar;
            if (settings.OpenAlexApiKey is { Length: > 0 } openAlex) keys[OpenAlex] = openAlex;
            root["secrets"] = JsonSerializer.SerializeToNode(PasswordBox.Seal(JsonSerializer.SerializeToUtf8Bytes(keys), password));
        }
        return JsonSerializer.SerializeToUtf8Bytes(root, Json);
    }

    static IEnumerable<(string Owner, string Option)> Owners(List<TranslationProfile> profiles) =>
        from service in TranslationServiceCatalog.All
        from owner in profiles.Where(p => p.ServiceId == service.Id).Select(p => p.SecretOwner).Prepend(service.Id)
        from field in service.SecretFields
        select (owner, field.Option);

    static bool Fits(JsonNode? node, Kind kind) => node != null && (node.GetValueKind(), kind) switch
    {
        (JsonValueKind.True or JsonValueKind.False, Kind.Bool) => true,
        // The macOS app may have stored a switch as a number.
        (JsonValueKind.Number, Kind.Bool) => node.ToJsonString() is "0" or "1",
        (JsonValueKind.Number, Kind.Number) => true,
        (JsonValueKind.String, Kind.String) => true,
        (JsonValueKind.Array, Kind.Strings) => node.AsArray().All(x => x?.GetValueKind() == JsonValueKind.String),
        (JsonValueKind.Object, Kind.Table) => node.AsObject().All(x => x.Value?.GetValueKind() == JsonValueKind.String),
        (JsonValueKind.Object, Kind.Tables) => node.AsObject().All(x => Fits(x.Value, Kind.Table)),
        _ => false,
    };

    // MARK: Reading

    readonly JsonObject _root, _values;
    readonly PasswordBox? _box;

    public SettingsPackage(byte[] data)
    {
        try
        {
            _root = JsonNode.Parse(data) as JsonObject ?? throw PackageArchive.NotAPackage();
            _values = _root["values"] as JsonObject ?? throw PackageArchive.NotAPackage();
            _box = _root["secrets"]?.Deserialize<PasswordBox>();
        }
        catch (Exception e) when (e is JsonException or FormatException) { throw PackageArchive.NotAPackage(); }
    }

    /// <summary>API keys are in it.</summary>
    public bool HasSecrets => _box != null;

    /// <summary>The API keys; null: the password is wrong.</summary>
    public Dictionary<string, string>? Secrets(string password) =>
        _box?.Open(password) is { } plain ? JsonSerializer.Deserialize<Dictionary<string, string>>(plain) : null;

    /// <summary>Makes these the settings. What is only here — translation services set up, terms of the glossary — stays.
    /// <paramref name="keys"/>: the API keys, unlocked (null: those here stay).</summary>
    public void Apply(AppSettings settings, ISecretStore secrets, GlossaryStore glossary, Dictionary<string, string>? keys)
    {
        // A key that is here is never sent to another address than it was entered for, unless the package brings its own.
        bool KeepsKeySafe(string owner, string serviceId, IReadOnlyDictionary<string, string>? here, IReadOnlyDictionary<string, string> now)
        {
            if (TranslationServiceCatalog.Service(serviceId) is not { } service) return true;
            if (!service.Fields.Any(f => f.Kind == FieldKind.Url && (here?.GetValueOrDefault(f.Option) ?? "") != (now.GetValueOrDefault(f.Option) ?? ""))) return true;
            return service.SecretFields.All(f => string.IsNullOrEmpty(secrets.Get(owner, f.Option)) || keys?.ContainsKey(SecretStore.Account(owner, f.Option)) == true);
        }
        foreach (var (key, kind) in Shared)
        {
            var value = _values[key];
            if (value == null)
            {
                // Not changed there: as it comes.
                if (kind is Kind.Bool or Kind.Number or Kind.String && settings.Raw(key) != null) settings.SetRaw(key, null);
                continue;
            }
            if (!Fits(value, kind)) continue;
            if (kind == Kind.Bool) value = value.GetValueKind() == JsonValueKind.True || value.ToJsonString() == "1";
            if (kind == Kind.Tables)
            {
                var all = settings.TranslationFields;
                foreach (var (service, fields) in value.Deserialize<Dictionary<string, Dictionary<string, string>>>()!)
                    if (KeepsKeySafe(service, service, all.GetValueOrDefault(service), fields)) all[service] = fields;
                value = JsonSerializer.SerializeToNode(all);
            }
            if (key == "selectedTranslationProfiles")
            {
                var all = settings.SelectedTranslationProfiles;
                foreach (var (service, profile) in value.Deserialize<Dictionary<string, string>>()!) all[service] = profile;
                value = JsonSerializer.SerializeToNode(all);
            }
            settings.SetRaw(key, value);
        }
        if (Read<TranslationOptions>(_values["translationOptions"]) is { } options)
        {
            options.GlossaryFile = null;
            options.Pages = null;
            settings.TranslationOptions = options;
        }
        var profiles = Read<List<TranslationProfile>>(_values["translationProfiles"]) ?? [];
        if (profiles.Count > 0)
        {
            var here = settings.TranslationProfiles;
            var now = profiles.Where(p => KeepsKeySafe(p.SecretOwner, p.ServiceId, here.FirstOrDefault(h => h.Id == p.Id)?.Fields, p.Fields)).ToList();
            settings.TranslationProfiles = [.. here.Where(h => now.All(p => p.Id != h.Id)), .. now];
        }
        if (_values["language"]?.GetValueKind() == JsonValueKind.String)
            settings.Language = _values["language"]!.GetValue<string>() switch { "zh-Hans" => "zh-Hans", "en" => "en", _ => "" };
        if (_root["platform"]?.ToString() == "windows" && _root["platformValues"] is JsonObject own)
            foreach (var key in PlatformKeys) if (own[key] is { } value) settings.SetRaw(key, value);
        if (Read<List<GlossaryTerm>>(_root["glossary"]) is { Count: > 0 } terms) glossary.Merge(terms);
        if (keys == null) return;
        foreach (var (owner, option) in Owners(profiles))
            if (keys.TryGetValue(SecretStore.Account(owner, option), out var value)) secrets.Set(value, owner, option);
        if (keys.TryGetValue(SecretStore.Account(EasyScholar, EasyScholarKey), out var scholar)) secrets.Set(scholar, EasyScholar, EasyScholarKey);
        if (keys.TryGetValue(OpenAlex, out var openAlex)) settings.OpenAlexApiKey = openAlex;
    }

    static T? Read<T>(JsonNode? node) where T : class
    {
        try { return node?.Deserialize<T>(); } catch (Exception e) when (e is JsonException or NotSupportedException) { return null; }
    }
}
