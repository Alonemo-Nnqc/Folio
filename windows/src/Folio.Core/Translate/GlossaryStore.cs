using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using Folio.Core.Translate.Services;

namespace Folio.Core.Translate;

// Port of macos/.../FolioTranslate/GlossaryStore.swift; the file on disk is the same on both.

/// <summary>A term of the glossary Folio keeps (设置 ▸ 翻译 ▸ 术语表): how a term of the field is translated, for every
/// paper translated into that language from then on.</summary>
public sealed class GlossaryTerm
{
    public const string User = "user", Extracted = "extracted";

    [JsonPropertyName("id")] public Guid Id { get; set; } = Guid.NewGuid();
    [JsonPropertyName("source")] public string Source { get; set; } = "";
    [JsonPropertyName("target")] public string Target { get; set; } = "";
    /// <summary>The language the term is translated into (<c>zh</c>, <c>ja</c> …), as in the translation options.</summary>
    [JsonPropertyName("language")] public string Language { get; set; } = "zh";
    /// <summary>Typed (or imported) by the user, or found by a model in a paper while translating it.</summary>
    [JsonPropertyName("origin")] public string Origin { get; set; } = User;
    /// <summary>The paper a model found it in.</summary>
    [JsonPropertyName("paper"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? Paper { get; set; }
    [JsonPropertyName("added"), JsonConverter(typeof(SecondsDateConverter))] public DateTime Added { get; set; } = DateTime.UtcNow;
    /// <summary>Off: kept in the list, not given to the translator.</summary>
    [JsonPropertyName("isEnabled")] public bool IsEnabled { get; set; } = true;

    public GlossaryTerm Copy() => (GlossaryTerm)MemberwiseClone();

    /// <summary>Dates as the macOS app writes them: to the second, in UTC.</summary>
    sealed class SecondsDateConverter : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader reader, Type type, JsonSerializerOptions options) =>
            DateTime.TryParse(reader.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var date) ? date : DateTime.UtcNow;
        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }
}

/// <summary>The glossary on disk: terms the user wrote and terms models found in the papers translated so far, by
/// language. A translation gets the terms of its language that occur in the text; what the user wrote or changed always
/// wins over what a model finds later.</summary>
public sealed class GlossaryStore(string path)
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    static GlossaryStore? _shared;
    static readonly object SharedLock = new();

    /// <summary>The app's glossary, beside the translation cache (wherever <see cref="TranslationJob.SupportDirectory"/> is now).</summary>
    public static GlossaryStore Shared
    {
        get
        {
            var file = System.IO.Path.Combine(TranslationJob.SupportDirectory, "glossary.json");
            lock (SharedLock) return _shared?.Path == file ? _shared : _shared = new GlossaryStore(file);
        }
    }

    public string Path { get; } = path;
    readonly object _lock = new();
    List<GlossaryTerm>? _loaded;

    /// <summary>Languages written differently are one glossary ("zh-CN" and "zh"; "zh-TW" and "zh-Hant").</summary>
    internal static string Key(string language) => language.ToLowerInvariant() switch
    {
        "zh" or "zh-cn" or "zh-hans" or "zh-sg" => "zh",
        "zh-tw" or "zh-hk" or "zh-hant" => "zh-tw",
        var other => other,
    };

    static bool Same(string a, string b) =>
        string.Compare(a.Trim(), b.Trim(), CultureInfo.InvariantCulture, CompareOptions.IgnoreCase | CompareOptions.IgnoreWidth) == 0;

    List<GlossaryTerm> All()
    {
        if (_loaded != null) return _loaded;
        try { _loaded = File.Exists(Path) ? JsonSerializer.Deserialize<List<GlossaryTerm>>(File.ReadAllText(Path), Json) : null; }
        catch { _loaded = null; }
        return _loaded ??= [];
    }

    void Write(List<GlossaryTerm> terms)
    {
        _loaded = terms;
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            var scratch = Path + ".tmp";
            File.WriteAllText(scratch, JsonSerializer.Serialize(terms, Json), new UTF8Encoding(false));
            File.Move(scratch, Path, true);
        }
        catch { }
    }

    /// <summary>The terms of <paramref name="language"/> (null: of every language), in the order they were added.</summary>
    public List<GlossaryTerm> Terms(string? language = null)
    {
        lock (_lock) return All().Where(t => language == null || Key(t.Language) == Key(language)).Select(t => t.Copy()).ToList();
    }

    /// <summary>What a translation into <paramref name="language"/> is given: the terms switched on.</summary>
    public List<GlossaryEntry> Entries(string language) =>
        Terms(language).Where(t => t.IsEnabled).Select(t => new GlossaryEntry(t.Source, t.Target)).ToList();

    /// <summary>Adds a term, or changes the one with its id; a term whose source is already there in that language
    /// replaces it. Empty sources and targets are not kept.</summary>
    public GlossaryTerm? Save(GlossaryTerm term)
    {
        term = term.Copy();
        term.Source = term.Source.Trim();
        term.Target = term.Target.Trim();
        if (term.Source.Length == 0 || term.Target.Length == 0) return null;
        lock (_lock)
        {
            var terms = All().ToList();
            terms.RemoveAll(t => t.Id != term.Id && Key(t.Language) == Key(term.Language) && Same(t.Source, term.Source));
            var index = terms.FindIndex(t => t.Id == term.Id);
            if (index >= 0) terms[index] = term; else terms.Add(term);
            Write(terms);
            return term.Copy();
        }
    }

    public void Remove(IEnumerable<Guid> ids)
    {
        var gone = ids.ToHashSet();
        lock (_lock) Write(All().Where(t => !gone.Contains(t.Id)).ToList());
    }

    /// <summary>Terms a model found in <paramref name="paper"/>: those not in the glossary yet are added (what is there
    /// stays as it is, switched off or changed by the user included). Returns how many were new.</summary>
    public int Learn(IEnumerable<GlossaryEntry> entries, string language, string? paper)
    {
        lock (_lock)
        {
            var terms = All().ToList();
            int added = 0;
            foreach (var entry in entries)
            {
                string source = entry.Source.Trim(), target = entry.Target.Trim();
                if (source.Length == 0 || target.Length == 0 || source.Length >= 80 || Same(source, target)
                    || terms.Any(t => Key(t.Language) == Key(language) && Same(t.Source, source))) continue;
                terms.Add(new GlossaryTerm { Source = source, Target = target, Language = language, Origin = GlossaryTerm.Extracted, Paper = paper });
                added++;
            }
            if (added > 0) Write(terms);
            return added;
        }
    }

    /// <summary>Terms from a CSV file (<c>source,target</c> a line; a header line and further columns are ignored), as
    /// the user's own. Returns how many lines became terms.</summary>
    public int ImportCsv(string file, string language) =>
        TranslationJob.ReadGlossary(file).Count(entry => Save(new GlossaryTerm { Source = entry.Source, Target = entry.Target, Language = language }) != null);

    /// <summary>The terms of <paramref name="language"/> as CSV (<c>source,target</c>), for another computer or another program.</summary>
    public string ExportCsv(string language)
    {
        static string Field(string text) => text.Contains(',') || text.Contains('"') ? "\"" + text.Replace("\"", "\"\"") + "\"" : text;
        return "source,target\n" + string.Join("\n", Terms(language).Select(t => Field(t.Source) + "," + Field(t.Target))) + "\n";
    }
}
