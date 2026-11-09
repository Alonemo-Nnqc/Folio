using System.Text;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Layout;

namespace Folio.Core.Translate.Services;

/// <summary>划词翻译: one passage selected in the reader, translated by any service of the catalog (as the macOS app).</summary>
public static class SelectionTranslator
{
    /// <summary>The longest passage sent in one request; a longer selection is cut there.</summary>
    public const int MaximumLength = 6000;

    public sealed record Outcome(bool Succeeded, string Text);

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

    public static async Task<Outcome> Translate(string text, string serviceId, IReadOnlyDictionary<string, string> fields, IReadOnlyDictionary<string, string> secrets,
                                                string from, string to, CancellationToken cancel = default)
    {
        var passage = Normalized(text);
        if (passage.Length == 0) return new Outcome(false, Loc.S("服务没有返回译文"));
        try
        {
            var provider = ProviderFactory.Make(serviceId, fields, secrets, null);
            var context = new TranslationContext(from, to, null, null, []);
            // Paragraphs go as separate items, so every service keeps them apart.
            var items = passage.Split("\n\n").Select(p => new TranslationItem(p, p.Length < 60 && !p.Contains(". ") ? BlockKind.Heading : BlockKind.Paragraph)).ToList();
            var reply = await provider.Translate(items, context, cancel);
            var result = string.Join("\n\n", reply.Select(r => r.Trim()).Where(r => r.Length > 0));
            return result.Length > 0 ? new Outcome(true, result) : new Outcome(false, Loc.S("服务没有返回译文"));
        }
        catch (TranslationConfigurationError e) { return new Outcome(false, e.Message); }
        catch (ProviderError e) { return new Outcome(false, TranslationErrorClassifier.Classify(e.Detail + (e.Host != null ? $" https://{e.Host}/" : "")).Message); }
        catch (OperationCanceledException) { throw; }
        catch (Exception e) { return new Outcome(false, TranslationErrorClassifier.Classify(e.Message).Message); }
    }
}
