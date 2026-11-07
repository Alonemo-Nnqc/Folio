using System.Text.RegularExpressions;
using Folio.Core.Translate.Layout;

namespace Folio.Core.Translate.Engine;

// Port of macos/.../FolioTranslate/Engine/Continuations.swift (and Placeholders from Services/TranslationProvider.swift).

public static partial class Placeholders
{
    /// <summary>{v1} as written, or as a translator mangled it ({ v1 }, ｛v1｝, {V1}).</summary>
    [GeneratedRegex(@"[{｛]\s*[vV]\s*(\d+)\s*[}｝]")]
    public static partial Regex Pattern();

    public static string Replace(string text, Func<int, string> transform) =>
        Pattern().Replace(text, m => transform(int.TryParse(m.Groups[1].Value, out var n) ? n : 0));

    public static List<int> Numbers(string text) =>
        Pattern().Matches(text).Select(m => int.TryParse(m.Groups[1].Value, out var n) ? n : 0).ToList();
}

/// <summary>A paragraph that runs on into the next column or onto the next page, translated as one text.</summary>
public sealed class Continuation
{
    public TextSegment Joined = new();
    public List<TextSegment> Parts = [];
    public List<int> Counts = [];
    public List<double> Shares = [];
}

public static class Continuations
{
    /// <summary>Marks a break; numbered like a formula, so translators keep it as they keep formulas.</summary>
    public const string Marker = "{v0}";

    /// <summary>Paragraphs that go on in the next column or on the next page, in reading order.</summary>
    public static List<Continuation> Find(List<TextSegment> segments, List<PageLayout> layouts, int maxCharacters = 6000)
    {
        var pages = new Dictionary<int, PageLayout>();
        foreach (var l in layouts) pages.TryAdd(l.Number, l);
        var used = new HashSet<int>();
        var result = new List<Continuation>();
        for (int i = 0; i < segments.Count; i++)
        {
            if (used.Contains(i)) continue;
            var chain = new List<int> { i };
            while (chain.Count < 3 && Follower(chain[^1], segments, pages) is { } next && !used.Contains(next))
            {
                int length = chain.Append(next).Sum(k => segments[k].Source.Length);
                if (length > maxCharacters) break;
                chain.Add(next);
            }
            if (chain.Count <= 1) continue;
            foreach (var k in chain) used.Add(k);
            result.Add(Make(chain.Select(k => segments[k]).ToList()));
        }
        return result;
    }

    static int? Follower(int i, List<TextSegment> segments, Dictionary<int, PageLayout> pages)
    {
        var a = segments[i];
        if (a.Kind != BlockKind.Paragraph || a.IsLead || !pages.TryGetValue(a.Page, out var pageA) || a.Block >= pageA.Blocks.Count) return null;
        int j = i + 1;
        while (j < segments.Count && j < i + 40)
        {
            var s = segments[j];
            if (s.Kind is BlockKind.Heading or BlockKind.Title || s.IsLead) return null;
            if (s.Kind == BlockKind.Paragraph) break;
            j++;
        }
        if (j >= segments.Count || j >= i + 40) return null;
        var b = segments[j];
        if (!pages.TryGetValue(b.Page, out var pageB) || b.Block >= pageB.Blocks.Count) return null;
        var blockA = pageA.Blocks[a.Block];
        var blockB = pageB.Blocks[b.Block];
        if (blockA.Lines.Count == 0 || blockB.Lines.Count == 0 || Math.Abs(blockA.Size - blockB.Size) >= 0.6) return null;
        var lastA = blockA.Lines[^1];
        var firstB = blockB.Lines[0];
        bool nextColumn = b.Page == a.Page && firstB.Baseline > lastA.Baseline + blockA.Size && firstB.MinX > lastA.MinX + blockA.Rect.W * 0.5;
        bool nextPage = b.Page == a.Page + 1;
        if (!nextColumn && !nextPage) return null;
        var tail = a.Source.Trim(' ');
        if (EndsSentence(tail)) return null;
        if (blockA.Lines.Count >= 2) { if (lastA.MaxX < blockA.Rect.MaxX - blockA.Size * 2) return null; }
        else if (lastA.Rect.W < firstB.Rect.W * 0.7) return null;
        static bool SameColumn(LayoutBlock x, LayoutBlock y) => Math.Min(x.Rect.MaxX, y.Rect.MaxX) - Math.Max(x.Rect.MinX, y.Rect.MinX) > Math.Min(x.Rect.W, y.Rect.W) * 0.5;
        static bool Body(BlockKind k) => k is BlockKind.Paragraph or BlockKind.Heading;
        if (pageA.Blocks.Any(x => x.Translate && Body(x.Kind) && SameColumn(x, blockA) && x.Rect.MaxY < blockA.Rect.MinY - 1)) return null;
        if (pageB.Blocks.Any(x => x.Translate && Body(x.Kind) && SameColumn(x, blockB) && x.Rect.MinY > blockB.Rect.MaxY + 1)) return null;
        if (blockB.Lines.Count >= 2 && firstB.MinX > blockB.Lines[1].MinX + blockB.Size * 0.6) return null;
        var head = b.Source.Trim(' ');
        var firstWord = head.Split(' ').FirstOrDefault(w => !w.StartsWith('{')) ?? "";
        if (firstWord.Length == 0 || !char.IsLetterOrDigit(firstWord[0])) return null;
        char initial = firstWord[0];
        var lastWord = tail.Split(' ').LastOrDefault()?.ToLowerInvariant() ?? "";
        if (tail.EndsWith('-')) return char.IsLower(initial) ? j : null;
        if (char.IsLower(initial) && segments.Any(s => s.Kind == BlockKind.Paragraph && (s.Page == a.Page || s.Page == b.Page)
                && s.Source.Trim(' ').EndsWith('-') && s.Source.Trim(' ').Length >= 2 && char.IsLetter(s.Source.Trim(' ')[^2]))) return null;
        if (head.Split(' ').Length < 3) return null;
        bool carriesOn = char.IsLower(initial) || ((tail.EndsWith(',') || Connectives.Contains(lastWord)) && !char.IsUpper(initial))
                         || (Connectives.Contains(lastWord) && !head.StartsWith('{'));
        return carriesOn ? j : null;
    }

    static readonly HashSet<string> Connectives =
    [
        "the", "a", "an", "of", "in", "on", "to", "for", "with", "by", "and", "or", "from", "as", "at", "that", "which", "is",
        "are", "be", "was", "were", "its", "their", "our", "this", "these", "into", "than", "between", "such", "not", "can",
    ];

    /// <summary>Ends with a full stop, question mark and so on (a closing bracket or quote may follow).</summary>
    public static bool EndsSentence(string text)
    {
        var t = text.TrimEnd(')', ']', '}', '”', '’', '"', '\'');
        if (t.Length == 0) return true;
        return ".!?:;。！？：；".Contains(t[^1]);
    }

    public static Continuation Make(List<TextSegment> parts)
    {
        var text = parts[0].Source;
        int offset = parts[0].Formulas.Count;
        foreach (var part in parts.Skip(1))
        {
            int shift = offset;
            var shifted = Placeholders.Replace(part.Source, n => TextSegment.Placeholder(n + shift));
            var words = text.Split(' ');
            var last = words[^1];
            if (last.Length > 1 && last.EndsWith('-') && char.IsLetter(last[^2]) && shifted.Length > 0 && char.IsLower(shifted[0]))
            {
                bool compound = last[..^1].Contains('-') || last.Contains('/');
                text = text[..^last.Length].Trim(' ');
                text += " " + Marker + (compound ? last : last[..^1]) + shifted;
            }
            else text += " " + Marker + " " + shifted;
            offset += part.Formulas.Count;
        }
        double total = Math.Max(1, parts.Sum(p => p.Source.Length));
        var first = parts[0];
        var joined = new TextSegment { Page = first.Page, Block = first.Block, Kind = first.Kind, Source = text, Formulas = parts.SelectMany(p => p.Formulas).ToList(), IsLead = first.IsLead };
        return new Continuation { Joined = joined, Parts = parts, Counts = parts.Select(p => p.Formulas.Count).ToList(), Shares = parts.Select(p => p.Source.Length / total).ToList() };
    }

    /// <summary>The translation of the joined text, cut where each part ends; null when no cut keeps every formula with its part.</summary>
    public static List<string>? Split(string text, Continuation c)
    {
        int length = text.Length;
        if (length == 0) return null;
        var matches = Placeholders.Pattern().Matches(text).ToList();
        var offsets = new List<int>();
        int running = 0;
        foreach (var count in c.Counts) { offsets.Add(running); running += count; }
        int? Owner(int n)
        {
            if (n <= 0) return null;
            for (int k = offsets.Count - 1; k >= 0; k--) if (offsets[k] < n && n <= offsets[k] + c.Counts[k]) return k;
            return null;
        }
        var formulas = matches.Select(m => (Match: m, Part: Owner(int.TryParse(m.Groups[1].Value, out var n) ? n : 0)))
            .Where(x => x.Part != null).Select(x => (Start: x.Match.Index, End: x.Match.Index + x.Match.Length, Part: x.Part!.Value)).ToList();
        var markers = matches.Where(m => (int.TryParse(m.Groups[1].Value, out var n) ? n : -1) == 0).ToList();
        bool InsidePlaceholder(int p) => matches.Any(m => m.Index < p && p < m.Index + m.Length);
        var breaks = new List<int>();
        int previous = 0;
        double share = 0;
        for (int k = 0; k < c.Parts.Count - 1; k++)
        {
            share += c.Shares[k];
            int lo = Math.Max(previous, formulas.Where(f => f.Part <= k).Select(f => f.End).DefaultIfEmpty(0).Max());
            int hi = formulas.Where(f => f.Part > k).Select(f => f.Start).DefaultIfEmpty(length).Min();
            if (lo > hi) return null;
            int target = (int)(length * share);
            int? cut = null;
            if (markers.Count == c.Parts.Count - 1)
            {
                int at = markers[k].Index;
                if (at >= lo && at <= hi && Math.Abs((double)at / length - share) <= 0.25) cut = at;
            }
            if (cut == null)
            {
                const string punctuation = "，,、；;：:。．.！!？? ）)";
                (int Position, double Score)? best = null;
                for (int p = lo; p <= hi; p++)
                {
                    if (InsidePlaceholder(p)) continue;
                    char before = p > 0 ? text[p - 1] : '\0';
                    double score = Math.Abs(p - target) - (punctuation.Contains(before) ? length * 0.08 : 0);
                    if (best == null || score < best.Value.Score) best = (p, score);
                }
                cut = best?.Position;
            }
            if (cut is not { } atCut) return null;
            breaks.Add(atCut);
            previous = atCut;
        }
        var pieces = new List<string>();
        int start = 0;
        var ends = breaks.Append(length).ToList();
        for (int k = 0; k < ends.Count; k++)
        {
            var piece = text[start..ends[k]];
            int kk = k;
            piece = Placeholders.Replace(piece, n => n == 0 ? "" : TextSegment.Placeholder(n - offsets[kk]));
            piece = piece.Replace("  ", " ").Trim(' ');
            if (piece.Length == 0 && SegmentBuilder.HasWords(c.Parts[k].Source)) return null;
            pieces.Add(piece);
            start = ends[k];
        }
        return pieces;
    }
}
