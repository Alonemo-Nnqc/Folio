using System.Text.Json.Serialization;

namespace Folio.Core.Translate;

// Port of macos/.../FolioTranslate/TranslationOptions.swift and TranslationEvent.swift.

/// <summary>General translation options (“通用选项”). Saved as JSON with the same keys as the macOS app.</summary>
public sealed class TranslationOptions
{
    [JsonConverter(typeof(JsonStringEnumConverter<OutputKinds>))]
    public enum OutputKinds { mono, dual, both }

    [JsonConverter(typeof(JsonStringEnumConverter<DualLayouts>))]
    public enum DualLayouts { sideBySide, alternatingPages }

    [JsonConverter(typeof(JsonStringEnumConverter<DuplicateHandling>))]
    public enum DuplicateHandling { keepBoth, replace }

    [JsonPropertyName("langIn")] public string LangIn { get; set; } = "en";
    [JsonPropertyName("langOut")] public string LangOut { get; set; } = "zh";
    [JsonPropertyName("outputs")] public OutputKinds Outputs { get; set; } = OutputKinds.both;
    [JsonPropertyName("dualLayout")] public DualLayouts DualLayout { get; set; } = DualLayouts.sideBySide;
    /// <summary>Page selection (<c>1,3,5-7</c>); null = all pages.</summary>
    [JsonPropertyName("pages")] public string? Pages { get; set; }
    [JsonPropertyName("onlyIncludeTranslatedPages")] public bool OnlyIncludeTranslatedPages { get; set; }
    [JsonPropertyName("glossaryFile")] public string? GlossaryFile { get; set; }
    [JsonPropertyName("translateTables")] public bool TranslateTables { get; set; } = true;
    [JsonPropertyName("translateReferences")] public bool TranslateReferences { get; set; }
    [JsonPropertyName("concurrency")] public int? Concurrency { get; set; }
    [JsonPropertyName("ignoreCache")] public bool IgnoreCache { get; set; }
    [JsonPropertyName("duplicates")] public DuplicateHandling Duplicates { get; set; } = DuplicateHandling.keepBoth;

    public TranslationOptions Copy() => (TranslationOptions)MemberwiseClone();

    /// <summary>Common target languages offered in settings (code, display name).</summary>
    public static IReadOnlyList<(string Code, string Name)> CommonLanguages =>
    [
        ("en", Loc.S("英语")), ("zh", Loc.S("简体中文")), ("zh-TW", Loc.S("繁体中文")), ("ja", Loc.S("日语")), ("ko", Loc.S("韩语")),
        ("fr", Loc.S("法语")), ("de", Loc.S("德语")), ("es", Loc.S("西班牙语")), ("it", Loc.S("意大利语")), ("pt", Loc.S("葡萄牙语")),
        ("ru", Loc.S("俄语")), ("ar", Loc.S("阿拉伯语")),
    ];

    /// <summary>Page numbers (1-based) selected by <see cref="Pages"/> within a document of <paramref name="count"/> pages.</summary>
    public List<int> PageNumbers(int count)
    {
        var pages = Pages?.Replace(" ", "");
        if (string.IsNullOrEmpty(pages)) return Enumerable.Range(1, Math.Max(count, 1)).ToList();
        var result = new HashSet<int>();
        foreach (var part in pages.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var bounds = part.Split('-').Select(b => int.TryParse(b, out var n) ? n : (int?)null).ToList();
            if (bounds.Count == 1 && bounds[0] is { } single) result.Add(single);
            else if (bounds.Count == 2)
            {
                int lo = bounds[0] ?? 1, hi = bounds[1] ?? count;
                for (int n = lo; n <= hi; n++) result.Add(n);
            }
        }
        return result.Where(n => n >= 1 && n <= count).OrderBy(n => n).ToList();
    }
}

/// <summary>Everything needed to translate one PDF.</summary>
public sealed class TranslationRequest
{
    public string Input = "";
    /// <summary>Directory receiving the translated PDFs (created if needed).</summary>
    public string OutputDirectory = "";
    public string ServiceId = "";
    /// <summary>Non-secret field values keyed by field option (<c>--openai-model</c> → <c>gpt-5</c>).</summary>
    public Dictionary<string, string> FieldValues = [];
    /// <summary>Secret field values keyed by option, normally read from the secret store.</summary>
    public Dictionary<string, string> Secrets = [];
    public TranslationOptions Options = new();
}

/// <summary>Progress of one translation job.</summary>
public abstract record TranslationEvent
{
    /// <summary>What the engine is doing, in the user's language (“翻译段落 34/120”).</summary>
    public sealed record Stage(string Text) : TranslationEvent;
    /// <summary>Overall progress, 0…1, never going down.</summary>
    public sealed record Progress(double Value) : TranslationEvent;
    /// <summary>A translated PDF of the pages done so far, to read while the translation goes on.</summary>
    public sealed record Preview(string Path) : TranslationEvent;
    /// <summary>Something the user should know once the translation is done.</summary>
    public sealed record Notice(string Text) : TranslationEvent;
    public sealed record Finished(string? Mono, string? Dual) : TranslationEvent;
    public sealed record Failed(string Message, string LogPath) : TranslationEvent;
    public sealed record Cancelled : TranslationEvent;
}

/// <summary>What the stages of a translation are called.</summary>
public static class TranslationStageText
{
    public static string Paragraphs(int done, int total) => Loc.S("翻译段落 %lld/%lld", done, total);
    public static string Layout => Loc.S("排版译文");
    /// <summary>The stages' widest forms.</summary>
    public static IReadOnlyList<string> Widest => [Paragraphs(888, 888), Layout];
}
