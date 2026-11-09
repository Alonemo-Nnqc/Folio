using System.Text;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Layout;

namespace Folio.Core.Translate.Services;

/// <summary>划词翻译: one passage selected in the reader, translated by any service of the catalog (as the macOS app).</summary>
public static class SelectionTranslator
{
    /// <summary>The longest passage sent in one request; a longer selection is cut there.</summary>
    public const int MaximumLength = 6000;

    static bool IsCjk(char c) => c is >= '⺀' and <= '鿿' or >= '가' and <= '힯' or >= '豈' and <= '﫿';

    /// <summary>The selection as one passage: hyphenated line breaks joined, lines of a paragraph run together, paragraphs kept.</summary>
    public static string Normalized(string text)
    {
        var paragraphs = new List<string>();
        foreach (var paragraph in text.Replace("\r\n", "\n").Split("\n\n"))
        {
            var joined = new StringBuilder();
            foreach (var raw in paragraph.Split('\n'))
            {
                var part = raw.Trim();
                if (part.Length == 0) continue;
                if (joined.Length > 0 && joined[^1] == '-' && char.IsLower(part[0])) { joined.Length--; joined.Append(part); }
                else if (joined.Length == 0) joined.Append(part);
                else joined.Append(IsCjk(joined[^1]) || IsCjk(part[0]) ? part : " " + part);
            }
            var clean = Regex.Replace(joined.ToString(), "[ \t]{2,}", " ");
            if (clean.Length > 0) paragraphs.Add(clean);
        }
        var all = string.Join("\n\n", paragraphs);
        return all.Length > MaximumLength ? all[..MaximumLength] : all;
    }

    /// <summary>Free services that stand in for one another when one is rate-limited, in order.</summary>
    static readonly string[] StandIns = ["google", "bing"];

    /// <summary>Services rate-limited lately: skipped (when a stand-in may be used) until the time given.</summary>
    static readonly Dictionary<string, DateTime> CoolingUntil = [];
    static readonly object Gate = new();
    static bool IsCooling(string id) { lock (Gate) return CoolingUntil.GetValueOrDefault(id) > DateTime.UtcNow; }
    static void Cool(string id, double seconds) { lock (Gate) CoolingUntil[id] = DateTime.UtcNow.AddSeconds(seconds); }

    /// <summary>Worth another try, or a stand-in: rate limits, overloaded or unreachable servers, refusals of the free web endpoints.</summary>
    static bool IsTransient(ProviderError e) => e.Kind switch
    {
        ProviderError.Kinds.Http => e.Status is 429 or 403 or 408 || e.Status >= 500,
        ProviderError.Kinds.Network or ProviderError.Kinds.InvalidResponse => true,
        _ => false,
    };

    public sealed record Result(bool Succeeded, string Text, string ServiceId, string? FellBackFrom);

    /// <summary>The translation of text. A rate-limited request is tried again shortly; still refused, and with fallback, another
    /// free service translates it (and the limited one rests for a minute). Errors come back in plain words.</summary>
    public static async Task<Result> Translate(string text, string serviceId, IReadOnlyDictionary<string, string> fields, IReadOnlyDictionary<string, string> secrets,
                                               string from, string to, bool fallback, Func<string, IReadOnlyDictionary<string, string>> standInFields, CancellationToken cancel = default)
    {
        var passage = Normalized(text);
        if (passage.Length == 0) return new Result(false, Loc.S("服务没有返回译文"), serviceId, null);
        var order = new List<string> { serviceId };
        if (fallback) order.AddRange(StandIns.Where(s => s != serviceId));
        if (fallback && IsCooling(serviceId) && order.Count > 1) { order.RemoveAt(0); order.Add(serviceId); }
        ProviderError? firstTransient = null;
        string? firstMessage = null;
        for (int i = 0; i < order.Count; i++)
        {
            var id = order[i];
            if (i > 0 && IsCooling(id)) continue;
            try
            {
                var result = await Attempt(passage, id, id == serviceId ? fields : standInFields(id), id == serviceId ? secrets : new Dictionary<string, string>(), from, to, cancel);
                return new Result(true, result, id, id == serviceId ? null : serviceId);
            }
            catch (ProviderError e) when (IsTransient(e))
            {
                Cool(id, e.RetryAfter is { } r ? Math.Clamp(r, 20, 300) : 60);
                firstTransient ??= e;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception e)
            {
                // Not a passing problem (a key missing, an agent not installed…): say so, unless a stand-in already failed too.
                if (i == 0) return new Result(false, Describe(e), serviceId, null);
                firstMessage ??= Describe(e);
            }
        }
        if (firstTransient is { Kind: ProviderError.Kinds.Http, Status: 429 })
            return new Result(false, Loc.S("翻译服务暂时限流，请稍后再试，或在 设置 ▸ 划词翻译 中换用其他服务"), serviceId, null);
        return new Result(false, firstTransient != null ? Describe(firstTransient) : firstMessage ?? Loc.S("服务没有返回译文"), serviceId, null);
    }

    /// <summary>One service, with up to two quick retries of a passing problem.</summary>
    static async Task<string> Attempt(string passage, string serviceId, IReadOnlyDictionary<string, string> fields, IReadOnlyDictionary<string, string> secrets,
                                      string from, string to, CancellationToken cancel)
    {
        var provider = ProviderFactory.Make(serviceId, fields, secrets, null);
        var context = new TranslationContext(from, to, null, null, []);
        // Paragraphs go as separate items, so every service keeps them apart.
        var items = passage.Split("\n\n").Select(p => new TranslationItem(p, p.Length < 60 && !p.Contains(". ") ? BlockKind.Heading : BlockKind.Paragraph)).ToList();
        var delays = new Queue<double>([0.7, 1.8]);
        while (true)
        {
            try
            {
                var reply = await provider.Translate(items, context, cancel);
                var result = string.Join("\n\n", reply.Select(r => r.Trim()).Where(r => r.Length > 0));
                if (result.Length == 0) throw new InvalidOperationException(Loc.S("服务没有返回译文"));
                return result;
            }
            catch (ProviderError e) when (IsTransient(e) && delays.Count > 0)
            {
                var wait = Math.Min(e.RetryAfter ?? delays.Dequeue(), 3);
                await Task.Delay(TimeSpan.FromSeconds(wait), cancel);
            }
        }
    }

    static string Describe(Exception e) => e switch
    {
        TranslationConfigurationError c => c.Message,
        ProviderError p => TranslationErrorClassifier.Classify(p.Detail + (p.Host != null ? $" https://{p.Host}/" : "")).Message,
        _ => TranslationErrorClassifier.Classify(e.Message).Message,
    };
}
