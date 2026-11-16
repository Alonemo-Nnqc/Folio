using System.Globalization;
using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;
using Folio.Core.Translate.Services;

namespace Folio.Core.Translate;

// Port of macos/.../FolioTranslate/TranslationEstimator.swift.

/// <summary>What a translation is expected to take, before it starts: how much text goes to the service, about how many
/// tokens that is with a large language model, and, where the model's public price is known, about what it costs.
/// An estimate, and said so wherever it shows: tokens are counted by rule of thumb, what a model thinks before
/// answering is not in it, and prices change.</summary>
public sealed record TranslationEstimate
{
    /// <summary>Characters still to translate (what earlier runs left in the cache, standard headings and repeats are not sent).</summary>
    public int Characters { get; init; }
    public int TotalCharacters { get; init; }
    public int InputTokens { get; init; }
    public int OutputTokens { get; init; }
    /// <summary>In US dollars; null when the model's price is not known.</summary>
    public double? Cost { get; init; }
    /// <summary>The service charges by the character (machine translation), not by the token.</summary>
    public bool ByCharacter { get; init; }

    public static TranslationEstimate operator +(TranslationEstimate a, TranslationEstimate b) => new()
    {
        Characters = a.Characters + b.Characters, TotalCharacters = a.TotalCharacters + b.TotalCharacters,
        InputTokens = a.InputTokens + b.InputTokens, OutputTokens = a.OutputTokens + b.OutputTokens,
        Cost = a.Cost is { } x && b.Cost is { } y ? x + y : null, ByCharacter = a.ByCharacter || b.ByCharacter,
    };
}

/// <summary>Public prices of the models most used for translating, in US dollars per million tokens (input, output), as
/// their makers listed them in November 2026. A model not listed here has no price shown, only its tokens.</summary>
public static class TranslationPricing
{
    public const string AsOf = "2026-11";

    static readonly (string Prefix, double Input, double Output)[] PerMillion =
    [
        // OpenAI
        ("gpt-6-astra", 10, 50), ("gpt-6.1-sol", 2, 10), ("gpt-6.1-terra", 1, 5), ("gpt-6-luna", 0.10, 0.50), ("gpt-6-sol", 2, 10),
        ("gpt-5.6-sol", 4, 20), ("gpt-5.6-terra", 2, 12), ("gpt-5.6-luna", 0.20, 1.20), ("gpt-5.5-pro", 30, 180), ("gpt-5.5", 5, 30),
        ("gpt-5.4-pro", 30, 180), ("gpt-5.4-mini", 0.75, 4.50), ("gpt-5.4-nano", 0.20, 1.25), ("gpt-5.4", 2.50, 15),
        ("gpt-5.2-pro", 21, 168), ("gpt-5.2", 1.75, 14), ("gpt-5.1", 1.25, 10), ("gpt-5-mini", 0.25, 2), ("gpt-5-nano", 0.05, 0.40),
        ("gpt-5-pro", 15, 120), ("gpt-5", 1.25, 10), ("gpt-4.1-mini", 0.40, 1.60), ("gpt-4.1", 2, 8), ("gpt-4o-mini", 0.15, 0.60),
        ("gpt-4o", 2.50, 10), ("o3-pro", 20, 80), ("o3", 2, 8),
        // Anthropic
        ("claude-fable-5-2", 8, 40), ("claude-fable-5", 10, 50), ("claude-opus-5-5", 4, 20), ("claude-opus-5", 5, 25),
        ("claude-opus-4-8", 5, 25), ("claude-opus-4-7", 5, 25), ("claude-opus-4-6", 5, 25), ("claude-sonnet-5", 2, 10),
        ("claude-sonnet-4-6", 3, 15), ("claude-haiku-5-5", 0.10, 0.50), ("claude-haiku-4-5", 1, 5),
        // Gemini
        ("gemini-3.8-flash", 0.75, 3.75), ("gemini-3.6-flash", 0.75, 3.75), ("gemini-3.5-flash-lite", 0.30, 2.50),
        ("gemini-3.1-pro", 2, 12), ("gemini-3.1-flash-lite", 0.25, 1.50), ("gemini-3-flash", 0.50, 3),
        ("gemini-2.5-pro", 1.25, 10), ("gemini-2.5-flash-lite", 0.10, 0.40), ("gemini-2.5-flash", 0.30, 2.50),
        // DeepSeek (its peak-hour prices; off-peak is half)
        ("deepseek-flash", 0.30, 1.20), ("deepseek-v4-flash", 0.30, 1.20), ("deepseek-v4-pro", 1.32, 3.96),
    ];

    /// <summary>The price of a model, per million tokens: by the start of its name (the longest match wins), provider
    /// prefixes of gateways aside.</summary>
    public static (double Input, double Output)? Price(string model)
    {
        var name = model.ToLowerInvariant().Split('/').Last();
        var match = PerMillion.Where(p => name.StartsWith(p.Prefix, StringComparison.Ordinal)).OrderByDescending(p => p.Prefix.Length).ToList();
        return match.Count > 0 ? (match[0].Input, match[0].Output) : null;
    }
}

public static class TranslationEstimator
{
    /// <summary>About how many tokens a text is: Latin text runs to four characters a token, Chinese, Japanese and
    /// Korean to well under two.</summary>
    public static double Tokens(string text)
    {
        double total = 0;
        foreach (var rune in text.EnumerateRunes())
            total += rune.Value < 0x80 ? 0.25 : rune.Value is >= 0x2E80 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF or >= 0xF900 and <= 0xFAFF or >= 0xFF00 and <= 0xFFEF ? 0.7 : 0.5;
        return total;
    }

    static int Length(string text) => text.EnumerateRunes().Count();

    /// <summary>What translating the request is expected to take; null when the service costs nothing to use (free
    /// services, models on this computer, agents that run on a subscription) or the PDF cannot be read. Analyses the
    /// pages, so call it off the UI thread.</summary>
    public static TranslationEstimate? Estimate(TranslationRequest request)
    {
        if (TranslationServiceCatalog.Service(request.ServiceId) is not { Category: ServiceCategory.Llm or ServiceCategory.Machine } service
            || service.Backend is TranslationBackend.Command) return null;
        PdfSource source;
        try { source = PdfSource.Open(request.Input); } catch { return null; }
        using var scope = source;
        var options = request.Options;
        var analyzer = new LayoutAnalyzer(new LayoutAnalyzer.Options { TranslateTables = options.TranslateTables, TranslateReferences = options.TranslateReferences });
        var segments = SegmentBuilder.Segments(analyzer.Analyze(source, options.PageNumbers(source.Pages.Count)), options.LangOut);
        var cache = new TranslationCache(Path.Combine(TranslationJob.SupportDirectory, "cache"), request.Input, TranslationJob.Signature(request), options.IgnoreCache);
        // What the job would send: nothing it has from before, nothing it sets from its own lists, and each text once.
        var seen = new HashSet<string>();
        var pending = segments.Where(segment =>
            !(segment.Kind == BlockKind.Heading && StandardHeadings.Translate(segment.Source, options.LangOut) != null)
            && !(segment.Kind == BlockKind.TableCell && StandardCells.Translate(segment.Source, options.LangOut) != null)
            && cache.Lookup(segment.Source) == null && seen.Add(segment.Source)).ToList();
        var estimate = new TranslationEstimate { Characters = pending.Sum(s => Length(s.Source)), TotalCharacters = segments.Sum(s => Length(s.Source)) };
        if (!service.IsLLM) return estimate with { ByCharacter = true };
        if (pending.Count == 0) return estimate with { Cost = 0 };
        var model = service.ModelField is { } field ? request.FieldValues.GetValueOrDefault(field.Option) is { Length: > 0 } chosen ? chosen : field.DefaultValue ?? "" : "";
        double text = pending.Sum(s => Tokens(s.Source));
        // Each batch carries the instructions, the paper's title and abstract and its terms; the terms are asked for once.
        double batches = Math.Ceiling(estimate.Characters / 2600.0);
        var title = segments.FirstOrDefault(s => s.Kind == BlockKind.Title)?.Source ?? "";
        var summary = TranslationJob.Summary(segments) ?? "";
        double perBatch = 420 + Tokens(title) + Tokens(summary[..Math.Min(1500, summary.Length)]) + 150;
        double input = text + pending.Count * 6 + batches * perBatch + Tokens(TranslationJob.TermExcerpt(segments)) + 120;
        // A translation into Chinese, Japanese or Korean takes more tokens than its English source, though fewer characters.
        double output = text * (ImageText.IsCjk(options.LangOut.ToLowerInvariant()) ? 1.3 : 1.1) + pending.Count * 6 + 500;
        return estimate with
        {
            InputTokens = (int)input, OutputTokens = (int)output,
            Cost = TranslationPricing.Price(model) is { } price ? (input * price.Input + output * price.Output) / 1_000_000 : null,
        };
    }

    /// <summary>The estimate in a line, for the sheet that starts a translation; null when there is nothing to say (a
    /// scan whose text is not read yet).</summary>
    public static string? Text(TranslationEstimate estimate)
    {
        if (estimate.TotalCharacters <= 0) return null;
        if (estimate.Characters == 0) return Loc.S("译文已在缓存中，不需要再次请求翻译服务。");
        if (estimate.ByCharacter) return Loc.S("预计发送约 %@ 个字符（按字符计费的服务）。", Count(estimate.Characters));
        string input = Count(estimate.InputTokens), output = Count(estimate.OutputTokens);
        if (estimate.Cost is not { } cost) return Loc.S("预计约 %@ 输入 + %@ 输出 tokens（估算，不含模型思考）。", input, output);
        var price = cost < 0.01 ? Loc.S("不到 $0.01") : "$" + cost.ToString("0.00", CultureInfo.InvariantCulture);
        return Loc.S("预计约 %@ 输入 + %@ 输出 tokens，费用约 %@（按公开价格估算，不含模型思考）。", input, output, price);
    }

    /// <summary>A count to two figures: "1200", "4.2 万" or "42k".</summary>
    public static string Count(int n)
    {
        if (n < 10_000) return (n >= 1000 ? (int)(Math.Round(n / 100.0) * 100) : n).ToString(CultureInfo.InvariantCulture);
        return Loc.IsEnglish ? (n / 1000.0).ToString("0", CultureInfo.InvariantCulture) + "k"
            : (n / 10_000.0).ToString("0.#", CultureInfo.InvariantCulture) + " 万";
    }
}
