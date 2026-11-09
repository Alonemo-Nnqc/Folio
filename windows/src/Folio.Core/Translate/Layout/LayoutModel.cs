using System.Text;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Pdf;
using UglyToad.PdfPig.Tokens;

namespace Folio.Core.Translate.Layout;

// Ports of macos/.../FolioTranslate/Layout/LayoutModel.swift, PageText.swift (PageChar) and PageLinks.swift.

/// <summary>One character of a page: a glyph drawn by the content stream, with its text, position, size, font and colour.</summary>
public sealed class PageChar
{
    public string Text = "";
    /// <summary>The glyph's advance horizontally, a line's height vertically (from a fifth of an em below the baseline).</summary>
    public Rect Rect;
    public bool IsSpace, IsNewline;
    public double Size, Baseline;
    public FontInfo Font = FontInfo.Unknown;
    public RGBColor Color;
    public int? Run;
    public bool IsRotated;
    public bool IsMath;
    public bool IsScript;
    public List<int> Glyphs = [];
    public Rect? Ink;
    public int? Link;
    public int? LinkTarget;
    public int? Icon;

    public PageChar Clone()
    {
        var c = (PageChar)MemberwiseClone();
        c.Glyphs = [.. Glyphs];
        return c;
    }

    public Pt Center => new(Rect.MidX, Baseline + Size * 0.3);

    public Rect GlyphBox
    {
        get
        {
            if (Ink is { } ink) return ink;
            double width = Math.Min(Rect.W, Size * 1.1);
            return new Rect(Rect.MinX, Baseline - Size * 0.28, Math.Max(width, 0.1), Size * 1.2);
        }
    }

    public Rect InkBox
    {
        get
        {
            if (Ink is { } ink) return ink;
            var (bottom, top) = VerticalExtent(Text);
            return new Rect(Rect.MinX, Baseline + Size * bottom, Math.Max(Math.Min(Rect.W, Size * 1.1), 0.1), Size * (top - bottom));
        }
    }

    /// <summary>Bottom and top of a character's ink, in ems from the baseline.</summary>
    public static (double, double) VerticalExtent(string text)
    {
        if (text.Length == 0) return (-0.02, 0.72);
        var c = text.EnumerateRunes().First().ToString();
        if ("acemnorsuvwxzαειονοπστυω".Contains(c) && c.Length == 1 && "acemnorsuvwxzαειονοπστυω".IndexOf(c[0]) >= 0) return (-0.02, 0.48);
        if (c.Length == 1 && "gpqyγημρφχψ".IndexOf(c[0]) >= 0) return (-0.22, 0.48);
        if (c.Length == 1 && "jQβζξ,;".IndexOf(c[0]) >= 0) return (-0.22, c is "," or ";" ? 0.46 : 0.72);
        if (c.Length == 1 && "()[]{}|/\\∥⟨⟩".IndexOf(c[0]) >= 0) return (-0.26, 0.76);
        if (c is "." or ":" or "·") return (-0.02, 0.46);
        if (c.Length == 1 && "-–—−=+<>~≈×≤≥→←↑↓∈⊂≠".IndexOf(c[0]) >= 0) return (0.02, 0.56);
        if (c.Length == 1 && "'\"′″^ˆ˜`´¯˙¨∗*".IndexOf(c[0]) >= 0) return (0.36, 0.76);
        return (-0.02, 0.72);
    }
}

/// <summary>A line of text: characters on one baseline, between column gutters.</summary>
public sealed class LayoutLine
{
    public List<PageChar> Chars = [];
    public Rect InkRect;
    public double Baseline;
    public double Size;
    public FontInfo Font = FontInfo.Unknown;
    public RGBColor Color;
    public bool IsRotated;

    public double MinX => InkRect.MinX;
    public double MaxX => InkRect.MaxX;

    public Rect Rect => new Rect(InkRect.MinX, Baseline - Size * 0.24, InkRect.W, Size * 1.02).Union(InkRect);
    public string Text => string.Concat(Chars.Select(c => c.IsSpace ? " " : c.Text));
    public int WordCount => Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
    public int VisibleCount => Chars.Count(c => !c.IsSpace);
    public double MathRatio
    {
        get
        {
            var visible = Chars.Where(c => !c.IsSpace).ToList();
            return visible.Count == 0 ? 0 : (double)visible.Count(c => c.IsMath) / visible.Count;
        }
    }

    public LayoutLine Clone() => new() { Chars = [.. Chars], InkRect = InkRect, Baseline = Baseline, Size = Size, Font = Font, Color = Color, IsRotated = IsRotated };
}

public enum BlockKind { Title, Heading, Paragraph, Caption, TableCell, Formula, Figure, Header, Reference, Author, Code, Rotated, Other }

public static class BlockKinds
{
    public static bool IsTranslatable(this BlockKind k) => k is BlockKind.Title or BlockKind.Heading or BlockKind.Paragraph or BlockKind.Caption or BlockKind.TableCell;
    public static string Raw(this BlockKind k) => char.ToLowerInvariant(k.ToString()[0]) + k.ToString()[1..];
}

public enum CellAlignment { Left, Center, Right }

/// <summary>A unit of text: a paragraph, heading, caption, table cell … with the lines it is made of.</summary>
public sealed class LayoutBlock
{
    public BlockKind Kind;
    public List<LayoutLine> Lines = [];
    public bool Translate;
    public CellAlignment? CellAlignment;
    public bool CenteredInColumn;

    public LayoutBlock Clone() => new() { Kind = Kind, Lines = [.. Lines], Translate = Translate, CellAlignment = CellAlignment, CenteredInColumn = CenteredInColumn };

    public Rect Rect => Lines.Skip(1).Aggregate(Lines[0].Rect, (r, l) => r.Union(l.Rect));

    public double Size
    {
        get
        {
            var counts = new Dictionary<double, int>();
            foreach (var line in Lines)
            {
                var key = Math.Round(line.Size * 4) / 4;
                counts[key] = counts.GetValueOrDefault(key) + line.VisibleCount;
            }
            return counts.Count == 0 ? Lines[0].Size : counts.MaxBy(kv => kv.Value).Key;
        }
    }

    /// <summary>Baseline distance between lines (one line: 1.2 em).</summary>
    public double Pitch
    {
        get
        {
            if (Lines.Count <= 1) return Size * 1.2;
            var gaps = Lines.Zip(Lines.Skip(1)).Select(p => p.First.Baseline - p.Second.Baseline).Where(g => g > 0).OrderBy(g => g).ToList();
            return gaps.Count == 0 ? Size * 1.2 : gaps[gaps.Count / 2];
        }
    }

    public FontInfo Font
    {
        get
        {
            var counts = new Dictionary<FontInfo, int>();
            foreach (var line in Lines) counts[line.Font] = counts.GetValueOrDefault(line.Font) + line.VisibleCount;
            return counts.Count == 0 ? Lines[0].Font : counts.MaxBy(kv => kv.Value).Key;
        }
    }

    public RGBColor Color
    {
        get
        {
            var counts = new Dictionary<RGBColor, int>();
            foreach (var line in Lines) counts[line.Color] = counts.GetValueOrDefault(line.Color) + line.VisibleCount;
            return counts.Count == 0 ? Lines[0].Color : counts.MaxBy(kv => kv.Value).Key;
        }
    }

    public string Text => string.Join(' ', Lines.Select(l => l.Text));

    public double FirstLineIndent
    {
        get
        {
            if (Lines.Count <= 1) return 0;
            var rest = Lines.Skip(1).Min(l => l.MinX);
            return Math.Max(0, Lines[0].MinX - rest);
        }
    }

    public double HangingIndent
    {
        get
        {
            if (Lines.Count <= 1) return 0;
            var rest = Lines.Skip(1).Select(l => l.MinX).ToList();
            double lo = rest.Min(), hi = rest.Max();
            if (hi - lo >= Size * 0.4 || lo - Lines[0].MinX <= Size * 0.5 || lo - Lines[0].MinX >= Size * 4) return 0;
            return lo - Lines[0].MinX;
        }
    }

    public bool IsCentered
    {
        get
        {
            var r = Rect;
            if (!Lines.All(l => Math.Abs((l.MinX + l.MaxX) / 2 - r.MidX) < Math.Max(1.5, Size * 0.2))) return false;
            if (Lines.Count == 1) return CenteredInColumn;
            if (Lines.Any(l => l.MinX - r.MinX > Size * 0.8 && r.MaxX - l.MaxX > Size * 0.8)) return true;
            // Lines of nearly one width have none set in from both sides; a title's place on the page still says it is centred.
            return CenteredInColumn && Kind is BlockKind.Title or BlockKind.Heading;
        }
    }
}

/// <summary>The analysed page.</summary>
public sealed class PageLayout
{
    public int Number;
    public Rect MediaBox, CropBox;
    public List<LayoutBlock> Blocks = [];
    public List<Rect> Figures = [];
    public List<Rect> Tables = [];
    public List<Rect> Graphics = [];
    public List<TextRun> Runs = [];
    public List<Glyph> Glyphs = [];
    public List<PageLink> Links = [];
}

/// <summary>A link annotation of a page: a citation, a cross-reference, a web address.</summary>
public sealed record PageLink(int Index, List<Rect> Rects, string Target = "");

/// <summary>Where a link's text went in a translated line (original page space).</summary>
public readonly record struct SpanLink(int Link, Rect Rect);

public static class PageLinks
{
    /// <summary>The link annotations of a page, in order.</summary>
    public static List<PDict> Annotations(PDict page)
    {
        var result = new List<PDict>();
        if (page.Array("Annots") is not { } annots) return result;
        for (int i = 0; i < annots.Count; i++)
            if (annots.Dict(i) is { } annot && annot.Name("Subtype") == "Link") result.Add(annot);
        return result;
    }

    public static List<PageLink> Links(PDict page)
    {
        var result = new List<PageLink>();
        var annotations = Annotations(page);
        for (int index = 0; index < annotations.Count; index++)
        {
            var annot = annotations[index];
            var rects = new List<Rect>();
            if (annot.Array("QuadPoints") is { } quads)
            {
                var n = quads.Numbers();
                for (int q = 0; q + 7 < n.Count; q += 8)
                {
                    var xs = new[] { n[q], n[q + 2], n[q + 4], n[q + 6] };
                    var ys = new[] { n[q + 1], n[q + 3], n[q + 5], n[q + 7] };
                    rects.Add(new Rect(xs.Min(), ys.Min(), xs.Max() - xs.Min(), ys.Max() - ys.Min()));
                }
            }
            if (rects.Count == 0 && annot.Rect("Rect") is { } rect) rects.Add(rect);
            if (rects.Count > 0) result.Add(new PageLink(index, rects, Target(annot)));
        }
        return result;
    }

    static string Target(PDict annot)
    {
        string Describe(IToken raw)
        {
            var token = annot.Source.Resolve(raw);
            switch (token)
            {
                case NameToken n: return n.Data;
                case StringToken s: return Convert.ToBase64String(s.GetBytes());
                case HexToken h: return Convert.ToBase64String(h.Bytes.ToArray());
                case ArrayToken:
                    var array = annot.Source.WrapArray(raw)!;
                    var page = array.Dict(0);
                    return $"{page?.Key ?? 0}|" + string.Join(",", array.Numbers().Skip(1).Select(v => v.ToString(System.Globalization.CultureInfo.InvariantCulture)));
                default: return "";
            }
        }
        if (annot.RawObject("Dest") is { } dest) return Describe(dest);
        if (annot.Dict("A") is not { } action) return "";
        if (action.RawObject("D") is { } d) return Describe(d);
        if (action.RawObject("URI") is { } uri) return Describe(uri);
        return "";
    }

    /// <summary>Tells each character which link it is under (a link covering a good part of the page is not about any words).</summary>
    public static void Assign(List<PageLink> links, List<PageChar> chars, Rect page)
    {
        var targets = new Dictionary<string, int>();
        foreach (var link in links)
        {
            int target = link.Target.Length == 0 ? targets.Count + 1_000_000 : targets.TryGetValue(link.Target, out var t) ? t : targets.Count;
            if (link.Target.Length > 0) targets[link.Target] = target;
            foreach (var rect in link.Rects)
            {
                if (rect.W * rect.H >= page.W * page.H * 0.25) continue;
                var area = rect.InsetBy(-0.2, -0.5);
                foreach (var c in chars)
                {
                    if (c.IsSpace || c.IsNewline || c.Link != null) continue;
                    if (area.Contains(new Pt(c.Rect.MidX, c.Baseline + c.Size * 0.3)))
                    {
                        c.Link = link.Index;
                        c.LinkTarget = target;
                    }
                }
            }
        }
    }
}

/// <summary>What to do with the words a link covers when the text around them is translated.</summary>
public static partial class LinkText
{
    public abstract record Role
    {
        public sealed record Whole : Role;
        public sealed record Number(int After) : Role;
        public sealed record Prose : Role;
    }

    [GeneratedRegex(@"^\s*((?:Figures?|Figs?\.?|Tables?|Tabs?\.?|Sections?|Secs?\.?|Sects?\.?|§+|Equations?|Eqs?\.?|Eqns?\.?|Algorithms?|Algs?\.?|Appendix|Appendices|Apps?\.?|Theorems?|Thms?\.?|Lemmas?|Corollary|Corollaries|Cors?\.?|Propositions?|Props?\.?|Definitions?|Defs?\.?|Chapters?|Chaps?\.?|Ch\.?|Parts?|Steps?|Lines?|Remarks?|Examples?|Exps?\.?|Experiments?|Assumptions?)\s*)(\(?[A-Z]?[\d.]*\d[a-z]?\)?|[A-Z])\s*$")]
    private static partial Regex Label();

    public static Role RoleOf(string text)
    {
        var trimmed = text.Trim();
        var m = Label().Match(text);
        if (m.Success && m.Groups[1].Success)
            return new Role.Number(Utf16ToGraphemeOffset(text, m.Groups[1].Index + m.Groups[1].Length));
        var words = trimmed.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (words.Length <= 3) return new Role.Whole();
        if (Regex.IsMatch(trimmed, @"://|www\.|doi|@|\.(com|org|net|edu|io|ai)\b", RegexOptions.IgnoreCase)) return new Role.Whole();
        if (Regex.IsMatch(trimmed, @"et al|(19|20)\d\d")) return new Role.Whole();
        var lowerWords = words.Where(w => char.IsLower(w[0]) && !new[] { "and", "of", "de", "van", "von", "der", "la", "le" }.Contains(w)).ToList();
        return lowerWords.Count == 0 && words.Length <= 8 ? new Role.Whole() : new Role.Prose();
    }

    // NSRange offsets are UTF-16 offsets, like .NET's; the Swift caller counts them against String.count (characters).
    static int Utf16ToGraphemeOffset(string text, int utf16) => Text.Graphemes(text[..Math.Min(utf16, text.Length)]);

    /// <summary>Which characters of each line stay as drawn (formulas and citations, whole), and where a long list may part.</summary>
    public static (List<bool[]> Held, List<HashSet<int>> Breaks) Held(LayoutBlock block)
    {
        var held = block.Lines.Select(l => l.Chars.Select(c => c.IsMath).ToArray()).ToList();
        var breaks = block.Lines.Select(_ => new HashSet<int>()).ToList();
        var byLink = new Dictionary<int, List<(int Line, int Char)>>();
        for (int l = 0; l < block.Lines.Count; l++)
            for (int c = 0; c < block.Lines[l].Chars.Count; c++)
                if (block.Lines[l].Chars[c].Link is { } link)
                    (byLink.TryGetValue(link, out var list) ? list : byLink[link] = []).Add((l, c));
        if (byLink.Count == 0) return (held, breaks);
        var numeric = new HashSet<int>();
        foreach (var (link, places) in byLink)
        {
            var sb = new StringBuilder();
            (int Line, int Char)? previous = null;
            foreach (var place in places)
            {
                if (previous is { } p && (p.Line != place.Line || place.Char > p.Char + 1)) sb.Append(' ');
                sb.Append(block.Lines[place.Line].Chars[place.Char].Text);
                previous = place;
            }
            var text = sb.ToString();
            var bare = text.Trim('[', ']', '(', ')', ',', ';', '.', ' ');
            if (Regex.IsMatch(bare, @"^\d+[a-z]?([–—\-]\d+[a-z]?)?$")) numeric.Add(link);
            switch (RoleOf(text))
            {
                case Role.Prose: continue;
                case Role.Whole:
                    foreach (var place in places) held[place.Line][place.Char] = true;
                    break;
                case Role.Number num:
                    int offset = 0;
                    for (int k = 0; k < places.Count; k++)
                    {
                        var place = places[k];
                        if (k > 0 && (places[k - 1].Line != place.Line || place.Char > places[k - 1].Char + 1)) offset++;
                        if (offset >= num.After) held[place.Line][place.Char] = true;
                        offset += Text.Graphemes(block.Lines[place.Line].Chars[place.Char].Text);
                    }
                    break;
            }
            for (int k = 0; k + 1 < places.Count; k++)
            {
                var (a, b) = (places[k], places[k + 1]);
                if (a.Line != b.Line || b.Char <= a.Char + 1) continue;
                if (held[a.Line][a.Char] && held[b.Line][b.Char])
                    for (int x = a.Char + 1; x < b.Char; x++) if (block.Lines[a.Line].Chars[x].IsSpace) held[a.Line][x] = true;
            }
        }
        for (int l = 0; l < block.Lines.Count; l++)
        {
            var line = block.Lines[l];
            var chars = line.Chars;
            bool IsNumber(int k) => chars[k].Link is { } lk && numeric.Contains(lk) && held[l][k];
            bool IsSeparator(int k) => chars[k].IsSpace || (chars[k].Text.Length == 1 && ",;–—-".Contains(chars[k].Text[0]));
            int i = 0;
            while (i < chars.Count)
            {
                if (!IsNumber(i)) { i++; continue; }
                int last = i, j = i + 1;
                while (j < chars.Count && (IsNumber(j) || IsSeparator(j)))
                {
                    if (IsNumber(j)) last = j;
                    j++;
                }
                for (int k = i; k <= last; k++) held[l][k] = true;
                int first = i;
                if (i > 0 && last + 1 < chars.Count && chars[i - 1].Text.Length == 1 && chars[last + 1].Text.Length == 1
                    && ((chars[i - 1].Text == "[" && chars[last + 1].Text == "]") || (chars[i - 1].Text == "(" && chars[last + 1].Text == ")")))
                {
                    held[l][i - 1] = true;
                    held[l][last + 1] = true;
                    first = i - 1;
                    last++;
                }
                if (chars[last].Rect.MaxX - chars[first].Rect.MinX > line.Size * 7)
                    for (int k = first + 1; k <= last; k++)
                        if (chars[k - 1].Text is "," or ";") breaks[l].Add(k);
                i = Math.Max(j, last + 1);
            }
        }
        return (held, breaks);
    }

    /// <summary>Where a link over running words goes when they are translated: the same stretch of the translation.</summary>
    public static List<Rect> Places(int link, LayoutBlock block, IReadOnlyList<(double Width, Pt Origin)> lines, double fontSize)
    {
        int before = 0, inside = 0, after = 0;
        foreach (var line in block.Lines)
            foreach (var c in line.Chars)
            {
                if (c.IsSpace) continue;
                if (c.Link == link) { inside++; after = 0; }
                else if (inside == 0) before++;
                else after++;
            }
        int total = before + inside + after;
        if (inside == 0 || total == 0) return [];
        double length = lines.Sum(l => l.Width);
        double start = length * before / total, end = length * (before + inside) / total;
        var result = new List<Rect>();
        double position = 0;
        foreach (var (width, origin) in lines)
        {
            double from = Math.Max(start, position), to = Math.Min(end, position + width);
            if (to > from) result.Add(new Rect(origin.X + from - position, origin.Y - fontSize * 0.25, to - from, fontSize * 1.15));
            position += width;
        }
        return result;
    }
}
