using System.Globalization;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Translate.Layout;

// Ports of macos/.../FolioTranslate/Layout/PageText.swift and MathDetector.swift.

public static class PageText
{
    /// <summary>
    /// The characters of a page, one per glyph drawn (duplicates drawn on top of each other count once), in drawing
    /// order, with spaces where words are apart and line breaks where the drawing jumps. Where the font does not say
    /// what a glyph is, the text PdfPig reads at that place is used (PDFKit's on macOS).
    /// </summary>
    public static List<PageChar> Characters(PdfSource source, int pageNumber, ContentInterpreter interpreter)
    {
        var glyphs = interpreter.Glyphs;
        var fonts = interpreter.Fonts;
        FallbackText? fallback = null;
        if (glyphs.Any(g => g.IsVisible && !g.Reliable)) fallback = new FallbackText(source, pageNumber);
        var runSpacing = new Dictionary<int, double>();
        for (int r = 0; r < interpreter.Runs.Count; r++)
        {
            var run = interpreter.Runs[r];
            if (run.GlyphEnd - run.GlyphStart <= 3) continue;
            var gaps = new List<double>();
            Glyph? previous = null;
            for (int k = run.GlyphStart; k < run.GlyphEnd; k++)
            {
                var g = glyphs[k];
                if (!g.IsVisible || g.Text == " ") continue;
                if (previous != null && previous.Size > 0) gaps.Add((g.Origin.X - previous.End.X) / previous.Size);
                previous = g;
            }
            var small = gaps.Where(x => x > -0.2 && x < 0.5).OrderBy(x => x).ToList();
            if (small.Count >= 3 && small[small.Count / 2] > 0.04) runSpacing[r] = small[small.Count / 2];
        }
        var chars = new List<PageChar>(glyphs.Count + glyphs.Count / 4);
        var placed = new Dictionary<(int, int), List<int>>();
        static (int, int) Key(double x, double y) => ((int)Math.Floor(x / 2), (int)Math.Floor(y / 2));
        double anchorBaseline = 0, anchorSize = 0;
        PageChar? last = null;
        bool spaceSince = false;
        for (int index = 0; index < glyphs.Count; index++)
        {
            var g = glyphs[index];
            if (!g.IsVisible || g.Size <= 0.5 || g.Size >= 400) continue;
            var text = g.Text;
            if (!g.Reliable || text == null)
                if (fallback?.TextAt(g) is { } read) text = read;
            if (text != null && text.All(ch => ch is ' ' or '\t' or ' ' || char.GetUnicodeCategory(ch) == UnicodeCategory.SpaceSeparator))
            {
                spaceSince = true;
                continue;
            }
            bool horizontal = g.IsHorizontal;
            var origin = g.Origin;
            var end = g.End;
            if (g.Depth is { } depth && horizontal) origin = origin with { Y = origin.Y - ((depth - 0.04) / 2 + 0.25) * g.Size };
            var rect = horizontal ? new Rect(origin.X, origin.Y - g.Size * 0.22, Math.Max(end.X - origin.X, 0), g.Size * 1.2) : g.Box;
            if (g.Depth != null && horizontal) rect = rect.Union(g.Box);
            var label = text ?? "�";
            var probe = Key(rect.MinX, origin.Y);
            int? duplicate = null;
            for (int dx = -1; dx <= 1 && duplicate == null; dx++)
                for (int dy = -1; dy <= 1 && duplicate == null; dy++)
                {
                    if (!placed.TryGetValue((probe.Item1 + dx, probe.Item2 + dy), out var list)) continue;
                    foreach (var c in list)
                    {
                        if (chars[c].Text == label && Math.Abs(chars[c].Rect.MinX - rect.MinX) < g.Size * 0.15
                            && Math.Abs(chars[c].Baseline - origin.Y) < g.Size * 0.15 && Math.Abs(chars[c].Size - g.Size) < g.Size * 0.1)
                        {
                            duplicate = c;
                            break;
                        }
                    }
                }
            if (duplicate is { } dup)
            {
                chars[dup].Glyphs.Add(index);
                continue;
            }
            var metrics = g.Font >= 0 && g.Font < fonts.Count ? fonts[g.Font] : null;
            var font = metrics?.Info ?? FontInfo.Unknown;
            if (g.RenderMode == 2) font = font with { IsBold = true };
            var ch = new PageChar
            {
                Text = label, Rect = rect, Size = g.Size, Baseline = origin.Y, Font = font, Color = g.Color, Run = g.Run, IsRotated = !horizontal,
                Glyphs = [index],
            };
            if (g.Depth != null && horizontal) ch.Ink = g.Box;
            if (text == null || (g.Text == null && metrics?.Info.IsSymbolic == true)) ch.IsMath = true;
            if (last is { } p)
            {
                bool newLine;
                if (p.IsRotated != ch.IsRotated) newLine = true;
                else if (ch.IsRotated) newLine = Math.Sqrt(Math.Pow(rect.MidX - p.Rect.MidX, 2) + Math.Pow(rect.MidY - p.Rect.MidY, 2)) > Math.Max(p.Size, ch.Size) * 3;
                else
                {
                    double dy = Math.Abs(origin.Y - anchorBaseline);
                    double reach = ch.Size < anchorSize * 0.9 ? anchorSize * 0.95 : Math.Max(anchorSize, ch.Size) * 0.6;
                    newLine = dy > reach || rect.MinX < p.Rect.MinX - Math.Max(p.Size, ch.Size) * 1.5 || rect.MinX - p.Rect.MaxX > Math.Max(p.Size, ch.Size) * 3;
                }
                if (newLine)
                {
                    var br = p.Clone();
                    br.Text = "\n"; br.IsNewline = true; br.IsMath = false; br.Glyphs = []; br.Run = null; br.Link = null; br.LinkTarget = null;
                    chars.Add(br);
                    anchorBaseline = origin.Y;
                    anchorSize = ch.Size;
                }
                else if (!ch.IsRotated)
                {
                    double gap = rect.MinX - p.Rect.MaxX;
                    double size = Math.Min(p.Size, ch.Size);
                    double threshold = size * (0.15 + (p.Run == ch.Run ? runSpacing.GetValueOrDefault(ch.Run ?? -1) : 0));
                    if (gap > threshold || (spaceSince && gap > size * 0.05))
                    {
                        var space = p.Clone();
                        space.Text = " "; space.IsSpace = true; space.IsMath = false; space.Glyphs = []; space.Run = null; space.Link = null; space.LinkTarget = null;
                        space.Rect = new Rect(p.Rect.MaxX, p.Rect.MinY, Math.Max(gap, 0), p.Rect.H);
                        chars.Add(space);
                    }
                    if (ch.Size > anchorSize * 1.15) { anchorBaseline = origin.Y; anchorSize = ch.Size; }
                }
            }
            else
            {
                anchorBaseline = origin.Y;
                anchorSize = ch.Size;
            }
            spaceSince = false;
            (placed.TryGetValue(probe, out var bucket) ? bucket : placed[probe] = []).Add(chars.Count);
            chars.Add(ch);
            last = ch;
        }
        return chars;
    }

    /// <summary>The text PdfPig reads and where it is, for glyphs whose font does not say what they are.</summary>
    sealed class FallbackText
    {
        readonly List<(string Text, Rect Rect)> _items = [];
        readonly Dictionary<int, List<int>> _buckets = [];
        const double BucketHeight = 6;

        public FallbackText(PdfSource source, int pageNumber)
        {
            try
            {
                var page = source.Document.GetPage(pageNumber);
                foreach (var letter in page.Letters)
                {
                    var text = letter.Value;
                    if (string.IsNullOrWhiteSpace(text)) continue;
                    var b = letter.BoundingBox;
                    var rect = new Rect(b.Left, b.Bottom, b.Width, b.Height);
                    if (rect.W <= 0 && rect.H <= 0) continue;
                    int k = _items.Count;
                    _items.Add((text, rect));
                    int key = (int)Math.Floor(rect.MidY / BucketHeight);
                    (_buckets.TryGetValue(key, out var list) ? list : _buckets[key] = []).Add(k);
                }
            }
            catch { }
        }

        public string? TextAt(Glyph g)
        {
            var box = g.Box;
            var found = new List<(double X, string Text)>();
            int lo = (int)Math.Floor((box.MinY - 2) / BucketHeight), hi = (int)Math.Floor((box.MaxY + 2) / BucketHeight);
            if (hi - lo >= 200) return null;
            var area = box.InsetBy(-0.3, -1);
            for (int b = lo; b <= hi; b++)
            {
                if (!_buckets.TryGetValue(b, out var list)) continue;
                foreach (var k in list)
                {
                    var item = _items[k];
                    if (area.Contains(item.Rect.Center)) found.Add((item.Rect.MinX, item.Text));
                }
            }
            if (found.Count == 0) return null;
            var text = string.Concat(found.OrderBy(f => f.X).Select(f => f.Text));
            return FontEncoding.Usable(text) ? text : null;
        }
    }

    /// <summary>The run's em box in page space (rotated runs: the bounding box of the rotated box).</summary>
    public static Rect Box(this TextRun run)
    {
        var up = new Pt(-Math.Sin(run.Angle) * run.FontSize, Math.Cos(run.Angle) * run.FontSize);
        var down = new Pt(-up.X * 0.25, -up.Y * 0.25);
        return Rect.Bounds([
            new Pt(run.Origin.X + down.X, run.Origin.Y + down.Y), new Pt(run.End.X + down.X, run.End.Y + down.Y),
            new Pt(run.Origin.X + up.X, run.Origin.Y + up.Y), new Pt(run.End.X + up.X, run.End.Y + up.Y),
        ]);
    }
}

/// <summary>
/// Marks characters that belong to formulas: glyphs from math fonts, mathematical symbols, and sub- or superscripts.
/// Inline formulas are kept as drawn (moved into the translation) instead of being translated.
/// </summary>
public static class MathDetector
{
    static readonly string[] MathFonts =
    [
        "cmmi", "cmsy", "cmex", "cmbsy", "cmmib", "msbm", "msam", "eufm", "eusm", "eurm", "rsfs", "lmmath", "math",
        "symbol", "lasy", "mathabx", "mtmi", "mtsy", "mtex", "mathematica", "euclid", "esint", "wasy", "stmary", "txsy", "pxsy", "txmi",
        "pxmi", "txex", "pxex", "rtxmi", "ntxmi", "ntxsy", "zplm", "mnsymbol", "mdput", "mdbch", "lmsy", "lmmi", "cmbrm",
        "dsrom", "bbold", "bbm", "mathdesign", "stixgeneral-italic", "xits", "fourier", "lucidanewmath",
    ];

    public static bool IsMathFont(string name)
    {
        var lower = name.ToLowerInvariant();
        return MathFonts.Any(lower.Contains);
    }

    public static bool IsMathScalar(int v) => v switch
    {
        >= 0x2200 and <= 0x22FF or >= 0x27C0 and <= 0x27EF or >= 0x2980 and <= 0x2AFF or >= 0x1D400 and <= 0x1D7FF or >= 0x2190 and <= 0x21FF => true,
        0x221E or 0x2032 or 0x2033 or 0x00B1 or 0x00D7 or 0x00F7 or 0x2016 => true,
        >= 0x02C6 and <= 0x02DD or >= 0x0300 and <= 0x036F or 0x00AF or 0x00A8 or 0x00B4 or 0x02D9 or >= 0x20D0 and <= 0x20FF => true,
        _ => false,
    };

    public static bool IsGreek(int v) => v is >= 0x0391 and <= 0x03C9 or >= 0x03D0 and <= 0x03F5;

    public static readonly HashSet<string> OperatorNames =
    [
        "arg", "max", "min", "argmax", "argmin", "log", "ln", "lg", "exp", "sin", "cos", "tan", "tanh", "sinh", "cosh", "arctan",
        "sigmoid", "softmax", "Softmax", "lim", "sup", "inf", "det", "tr", "diag", "sgn", "mod", "Var", "Cov", "Pr", "ker", "gcd", "erf",
    ];

    public static readonly HashSet<char> Joiners = [.. "=+-−–×·*/()[]{}|^_<>0123456789'.,:;!∗"];

    static bool IsLetter(string text) => text.Length > 0 && Rune.TryGetRuneAt(text, 0, out var r) && System.Text.Rune.IsLetter(r);

    /// <summary>Sets IsMath on chars (one page, reading order).</summary>
    public static void Mark(List<PageChar> chars)
    {
        var fontCounts = new Dictionary<string, int>();
        int visible = 0;
        foreach (var c in chars)
        {
            if (c.IsSpace || c.IsNewline || !IsLetter(c.Text)) continue;
            fontCounts[c.Font.Name] = fontCounts.GetValueOrDefault(c.Font.Name) + 1;
            visible++;
        }
        var textFaces = fontCounts.Where(kv => kv.Value >= 200 && kv.Value >= visible * 0.4).Select(kv => kv.Key).ToHashSet();
        // 1. Characters that are math by themselves.
        foreach (var c in chars)
        {
            if (c.IsSpace || c.IsNewline) continue;
            var runes = c.Text.EnumerateRunes().Select(r => r.Value).ToList();
            if (IsMathFont(c.Font.Name) && !c.Font.Name.ToLowerInvariant().Contains("cmr") && !textFaces.Contains(c.Font.Name)) c.IsMath = true;
            else if (c.Ink != null) c.IsMath = true;
            else if (runes.Any(IsMathScalar)) c.IsMath = true;
            else if (runes.Any(IsGreek) && (c.Font.IsItalic || IsMathFont(c.Font.Name))) c.IsMath = true;
        }
        // 1b. A letter standing alone in italic type is a variable.
        for (int i = 0; i < chars.Count; i++)
        {
            var c = chars[i];
            if (c.IsMath || !c.Font.IsItalic || Text.Graphemes(c.Text) != 1 || !IsLetter(c.Text) || c.IsSpace || c.IsNewline) continue;
            var before = i > 0 ? chars[i - 1] : null;
            var after = i + 1 < chars.Count ? chars[i + 1] : null;
            static bool Separate(PageChar? o) => o == null || o.IsSpace || o.IsNewline || o.IsMath || (o.Text.Length == 1 && "()[]{},.;:=+−-<>|/".Contains(o.Text[0]));
            if (!Separate(before) || !Separate(after)) continue;
            if (after?.Text == "." && i + 2 < chars.Count && IsLetter(chars[i + 2].Text)) continue;
            if (before?.Text == "." && i >= 2 && IsLetter(chars[i - 2].Text)) continue;
            if (c.Text is not ("a" or "A" or "I")) c.IsMath = true;
            else
            {
                var p = PreviousVisible(i, chars);
                var n = NextVisible(i, chars);
                const string operators = "=+−-<>×·";
                bool Near(int? k) => k is { } kk && (chars[kk].IsMath || (chars[kk].Text.Length == 1 && operators.Contains(chars[kk].Text[0])));
                if (Near(p) || Near(n)) c.IsMath = true;
            }
        }
        // 1c. Operator names set in roman are maths when maths or an argument list is next to them.
        int w = 0;
        while (w < chars.Count)
        {
            if (chars[w].IsSpace || chars[w].IsNewline || !IsLetter(chars[w].Text)) { w++; continue; }
            int e = w;
            while (e + 1 < chars.Count && !chars[e + 1].IsSpace && !chars[e + 1].IsNewline && IsLetter(chars[e + 1].Text) && !chars[e + 1].IsMath) e++;
            var word = string.Concat(chars.Skip(w).Take(e - w + 1).Select(c => c.Text));
            if (OperatorNames.Contains(word) && chars.Skip(w).Take(e - w + 1).All(c => !c.IsMath))
            {
                var p = PreviousVisible(w, chars);
                var n = NextVisible(e, chars);
                bool nextIsArgument = n is { } nk && chars[nk].Text is "(" or "[";
                if ((p is { } pk && chars[pk].IsMath) || (n is { } nk2 && chars[nk2].IsMath) || nextIsArgument)
                    for (int k = w; k <= e; k++) chars[k].IsMath = true;
            }
            w = e + 1;
        }
        // 2. Sub- and superscripts: smaller and off the baseline of the text around them.
        for (int i = 0; i < chars.Count; i++)
        {
            var c = chars[i];
            if (c.IsSpace || c.IsNewline || c.IsMath || c.Run == null) continue;
            if (Neighbour(i, chars) is not { } host) continue;
            if (c.Size < host.Size * 0.82 && Math.Abs(c.Baseline - host.Baseline) > host.Size * 0.12) c.IsMath = true;
        }
        // 3. Grow formulas over touching operators and digits, and over spaces between two formula parts.
        bool changed = true;
        int passes = 0;
        while (changed && passes < 4)
        {
            changed = false;
            passes++;
            for (int i = 0; i < chars.Count; i++)
            {
                var c = chars[i];
                if (c.IsMath || c.IsNewline) continue;
                var prev = PreviousVisible(i, chars);
                var next = NextVisible(i, chars);
                if (c.IsSpace)
                {
                    if (prev is { } p && next is { } n && chars[p].IsMath && chars[n].IsMath && chars[n].Rect.MinX - chars[p].Rect.MaxX < chars[p].Size * 0.9)
                    {
                        c.IsMath = true;
                        changed = true;
                    }
                    continue;
                }
                if (c.Text.Length != 1 || !Joiners.Contains(c.Text[0])) continue;
                bool touchesPrev = prev is { } pp && pp == i - 1 && chars[pp].IsMath;
                bool touchesNext = next is { } nn && nn == i + 1 && chars[nn].IsMath;
                if (".,:;!".Contains(c.Text[0]) && !touchesNext) continue;
                if (touchesPrev || touchesNext)
                {
                    c.IsMath = true;
                    changed = true;
                }
            }
        }
        // 4. Drop single math-marked spaces at the edges of formulas.
        for (int i = 0; i < chars.Count; i++)
        {
            if (!chars[i].IsMath || !chars[i].IsSpace) continue;
            var p = PreviousVisible(i, chars);
            var n = NextVisible(i, chars);
            if (!(p is { } pk && chars[pk].IsMath) || !(n is { } nk && chars[nk].IsMath)) chars[i].IsMath = false;
        }
    }

    static int? PreviousVisible(int i, List<PageChar> chars)
    {
        for (int j = i - 1; j >= 0; j--)
        {
            if (chars[j].IsNewline) return null;
            if (!chars[j].IsSpace) return j;
        }
        return null;
    }

    static int? NextVisible(int i, List<PageChar> chars)
    {
        for (int j = i + 1; j < chars.Count; j++)
        {
            if (chars[j].IsNewline) return null;
            if (!chars[j].IsSpace) return j;
        }
        return null;
    }

    static PageChar? Neighbour(int i, List<PageChar> chars)
    {
        var c = chars[i];
        foreach (var step in new[] { -1, 1 })
        {
            int j = i + step, seen = 0;
            while (j >= 0 && j < chars.Count && seen < 6)
            {
                var o = chars[j];
                if (o.IsNewline) break;
                j += step;
                if (o.IsSpace || o.IsRotated || o.Run == null) continue;
                seen++;
                if (Math.Abs(o.Baseline - c.Baseline) > o.Size * 0.7 || Math.Abs(o.Rect.MinX - c.Rect.MinX) > o.Size * 8) continue;
                if (o.Size >= c.Size * 1.15 && o.Size <= c.Size * 2.2) return o;
            }
        }
        return null;
    }
}

file static class Rune
{
    public static bool TryGetRuneAt(string s, int index, out System.Text.Rune rune) => System.Text.Rune.TryGetRuneAt(s, index, out rune);
}
