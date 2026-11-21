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
    /// <summary>Terms a model finds in a paper are kept in Folio's glossary, for the papers translated after it.</summary>
    [JsonPropertyName("rememberTerms")] public bool RememberTerms { get; set; } = true;
    [JsonPropertyName("translateTables")] public bool TranslateTables { get; set; } = true;
    [JsonPropertyName("translateReferences")] public bool TranslateReferences { get; set; }
    /// <summary>Translate the words inside pictures too (read with OCR, set back over the picture in place).</summary>
    [JsonPropertyName("translateImageText")] public bool TranslateImageText { get; set; }
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
    public List<int> PageNumbers(int count) => PageSelection.Parse(Pages).Pages(count);
}

/// <summary>A page range as people type it: "1-3,5", "4-" (to the end), and the same with full-width digits, Chinese
/// punctuation and other dashes ("１－３，５", "1~3、5", "第3页"); empty or "全部" for every page. (PageSelection in
/// the macOS TranslationOptions.swift.)</summary>
public sealed record PageSelection
{
    public enum Kinds { All, Ranges, Unreadable }
    public Kinds Kind { get; private init; }
    /// <summary>Inclusive ranges as typed; an open end is 1 or <see cref="int.MaxValue"/>.</summary>
    public IReadOnlyList<(int Lo, int Hi)> Ranges { get; private init; } = [];

    public static readonly PageSelection All = new() { Kind = Kinds.All };
    public static readonly PageSelection Unreadable = new() { Kind = Kinds.Unreadable };

    public static PageSelection Parse(string? text)
    {
        // Full-width digits and punctuation (１２，－～；) as their ASCII forms.
        var s = (text ?? "").Normalize(System.Text.NormalizationForm.FormKC).ToLowerInvariant();
        foreach (var dash in new[] { "–", "—", "−", "‐", "‑", "‒", "―", "~", "〜", "至", "到" }) s = s.Replace(dash, "-");
        foreach (var comma in new[] { "、", ";" }) s = s.Replace(comma, ",");
        foreach (var word in new[] { "第", "页", "頁" }) s = s.Replace(word, "");
        s = System.Text.RegularExpressions.Regex.Replace(s, @"\s*-\s*", "-");
        var parts = System.Text.RegularExpressions.Regex.Split(s, @"[,\s]+").Where(p => p.Length > 0).ToList();
        if (parts.Count == 0 || parts.Count == 1 && parts[0] is "全部" or "所有" or "全文" or "all") return All;
        var ranges = new List<(int, int)>();
        static int? Number(string text, int open) =>
            text.Length == 0 ? open : int.TryParse(text, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var n) && n >= 1 ? n : null;
        foreach (var part in parts)
        {
            var bounds = part.Split('-');
            switch (bounds.Length)
            {
                case 1:
                    if (Number(bounds[0], 0) is not { } single || single < 1) return Unreadable;
                    ranges.Add((single, single));
                    break;
                case 2:
                    if (bounds[0].Length + bounds[1].Length == 0 || Number(bounds[0], 1) is not { } lo || Number(bounds[1], int.MaxValue) is not { } hi) return Unreadable;
                    ranges.Add((Math.Min(lo, hi), Math.Max(lo, hi)));
                    break;
                default:
                    return Unreadable;
            }
        }
        return new PageSelection { Kind = Kinds.Ranges, Ranges = ranges };
    }

    /// <summary>The pages (1-based) selected in a document of <paramref name="count"/> pages.</summary>
    public List<int> Pages(int count) => Kind switch
    {
        Kinds.All => Enumerable.Range(1, Math.Max(count, 1)).ToList(),
        Kinds.Ranges => Ranges.Where(r => r.Lo <= count).SelectMany(r => Enumerable.Range(r.Lo, Math.Min(r.Hi, count) - r.Lo + 1)).Distinct().Order().ToList(),
        _ => [],
    };

    /// <summary>What is wrong with a page range typed by the user, in words for them; null when it can be used.</summary>
    public static string? Problem(string? text) => Parse(text).Kind == Kinds.Unreadable ? UnreadableMessage((text ?? "").Trim()) : null;

    internal static string UnreadableMessage(string typed) => Loc.S("无法识别页码范围「%@」。请填写如 1-3,5 的页码，或留空以翻译全部页。", typed);
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
    /// <summary>Something going wrong now that the job works around (a request failed and is tried again): shown at once,
    /// with what the service said, so that a translation never just seems to hang.</summary>
    public sealed record Problem(string Text) : TranslationEvent;
    public sealed record Finished(string? Mono, string? Dual) : TranslationEvent;
    public sealed record Failed(string Message, string LogPath) : TranslationEvent;
    public sealed record Cancelled : TranslationEvent;
}

/// <summary>What the stages of a translation are called.</summary>
public static class TranslationStageText
{
    public static string Paragraphs(int done, int total) => Loc.S("翻译段落 %lld/%lld", done, total);
    public static string Layout => Loc.S("排版译文");
}
