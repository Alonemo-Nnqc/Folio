using System.Text;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;
using SkiaSharp;

namespace Folio.Core.Translate.Typeset;

// Port of macos/.../FolioTranslate/Typeset/Typesetter.swift (Core Text replaced by TextLines.cs).

/// <summary>Where a formula is drawn in the translation: the original's rectangle, scaled and moved so its baseline
/// sits on <see cref="Origin"/>.</summary>
public readonly record struct Transplant(FormulaSpan Formula, Pt Origin, double Scale)
{
    public Affine Transform => new(Scale, 0, 0, Scale, Origin.X - Scale * Formula.Rect.MinX, Origin.Y - Scale * Formula.Baseline);
}

/// <summary>Sets a translation into the space of the original block: the same first baseline and line pitch as the
/// original where possible, smaller type and tighter lines when the text needs more room — never outside the frame.</summary>
public sealed partial class Typesetter(string language)
{
    public string Language { get; } = language;

    public sealed class Result
    {
        public List<(TextLine Line, Pt Origin)> Lines = [];
        public List<Transplant> Transplants = [];
        public double Scale;
        public bool Fits;
        public double Pitch;
    }

    public enum Alignment { Justified, Left, Center, Right }

    /// <summary>The lines of a translation at the size that fits, and the range of line spacing that keeps them in
    /// their frame. The caller picks the spacing (<see cref="Finish"/>), so paragraphs of a page can share one.</summary>
    public sealed class Plan
    {
        public List<(TextLine Line, double X)> Lines = [];
        public double Scale, FontSize, FirstBaseline;
        /// <summary>The tightest spacing used to make it fit.</summary>
        public double MinPitch;
        /// <summary>The widest spacing that still ends inside the frame and reads well.</summary>
        public double MaxPitch;
        /// <summary>The spacing that ends on the original's last line.</summary>
        public double FillPitch;
        public bool Fits;
        public List<double> Clearances = [];
        public double Room;
        public double Deepest;
        public Plan Copy() => (Plan)MemberwiseClone();
    }

    public static List<double> Offsets(double pitch, IReadOnlyList<double> clearances)
    {
        var offsets = new List<double> { 0 };
        foreach (var c in clearances) offsets.Add(offsets[^1] + Math.Max(pitch, c));
        return offsets;
    }

    /// <summary>The largest spacing at most <paramref name="limit"/> whose lines stay within <paramref name="height"/>.</summary>
    public static double Pitch(double height, IReadOnlyList<double> clearances, double low, double limit)
    {
        double Total(double p) => clearances.Sum(c => Math.Max(p, c));
        if (Total(limit) <= height) return limit;
        if (Total(low) >= height) return low;
        double lo = low, hi = limit;
        for (int i = 0; i < 24; i++)
        {
            double middle = (lo + hi) / 2;
            if (Total(middle) <= height) lo = middle; else hi = middle;
        }
        return lo;
    }

    public Result Layout(string text, LayoutBlock block, List<FormulaSpan> formulas, Rect frame)
    {
        var plan = MakePlan(text, block, formulas, frame);
        return Finish(plan, plan.FillPitch, formulas);
    }

    public Plan MakePlan(string text, LayoutBlock block, List<FormulaSpan> formulas, Rect frame, double maxScale = 1, double? givenIndent = null)
    {
        double size = block.Size, pitch = block.Pitch;
        var alignment = block.Kind switch
        {
            BlockKind.Paragraph or BlockKind.Caption => block.IsCentered ? Alignment.Center : Alignment.Justified,
            BlockKind.TableCell => block.CellAlignment switch
            {
                CellAlignment.Left => Alignment.Left,
                CellAlignment.Right => Alignment.Right,
                _ => Alignment.Center,
            },
            _ => block.IsCentered ? Alignment.Center : Alignment.Left,
        };
        double indent = givenIndent ?? (block.Kind == BlockKind.Paragraph ? block.FirstLineIndent : 0);
        double hanging = block.Kind is BlockKind.Paragraph or BlockKind.Caption ? block.HangingIndent : 0;
        bool bold = block.Kind is BlockKind.Title or BlockKind.Heading || block.Font.IsBold;
        double top = block.Rect.MaxY;
        double firstBaseline = block.Lines[0].Baseline, lastBaseline = block.Lines[^1].Baseline;

        Plan? best = null;
        double scale = Math.Max(Math.Min(maxScale, 1), 0.4);
        while (scale >= 0.4 - 1e-9)
        {
            double fontSize = size * scale;
            // Chinese and Japanese need a little more air than the original's Latin lines.
            double minPitch = Math.Max(pitch * scale * 0.96, fontSize * 1.14);
            var paragraph = AttributedString(text, fontSize, bold, block.Font.IsSerif || block.Font.Name.Length == 0, block.Color, formulas, scale);
            var ranges = BreakLineRanges(paragraph, frame.W, indent * scale, hanging);
            // Smaller type keeps the block's top line where it was; a single line keeps its middle.
            double baseline0 = block.Lines.Count == 1 ? firstBaseline + (size - fontSize) * 0.3 : top - (top - firstBaseline) * scale;
            var lines = new List<(TextLine Line, double X)>();
            for (int k = 0; k < ranges.Count; k++)
            {
                var line = ranges[k];
                double lineIndent = k == 0 ? indent * scale : hanging;
                // A full-width opening bracket has its ink in its right half: at the start of a line it hangs into the margin.
                bool opening = alignment == Alignment.Justified && OpensWithBracket(line);
                double squeeze = opening ? fontSize * 0.5 : 0;
                double available = frame.W - lineIndent + squeeze;
                bool isLast = k == ranges.Count - 1;
                // Justify full lines only: stretching a short one (before an unbreakable citation list) leaves holes.
                double natural = line.NaturalWidth;
                if (alignment == Alignment.Justified && !isLast && natural > available * (SpacesBetweenCharacters ? 0.72 : 0.9))
                {
                    if (SpacesBetweenCharacters) line = JustifiedByKerning(line, available - natural, fontSize) ?? line;
                    else line = line.Justified(available) ?? line;
                }
                double width = line.NaturalWidth;
                double x = frame.MinX + lineIndent - squeeze;
                if (alignment == Alignment.Center) x = frame.MinX + Math.Max(0, (frame.W - width) / 2);
                if (alignment == Alignment.Right) x = Math.Max(frame.MinX, frame.MaxX - width);
                lines.Add((line, x));
            }
            var clearances = LineClearances(lines.Select(l => l.Line).ToList(), formulas, scale, fontSize);
            // The last line's deepest ink (a formula's subscripts) has to stay in the frame.
            double deepest = lines.Count > 0 ? Depth(lines[^1].Line, formulas, scale) : 0;
            double room = baseline0 - Math.Max(fontSize * 0.22, deepest) - frame.MinY;
            double widest = lines.Count == 0 ? 0 : lines.Max(l => l.Line.NaturalWidth - Math.Max(frame.MinX - l.X, 0));
            // Chinese and Japanese characters fill the em: their tops must stay clear of the line above.
            bool clear = !SpacesBetweenCharacters || block.Lines.Count > 1 || baseline0 + fontSize * 0.86 <= frame.MaxY + size * 0.02;
            double tightest = clearances.Sum(c => Math.Max(minPitch, c));
            bool fits = tightest <= room + 0.5 && widest <= frame.W + 0.5 && clear;
            double maxPitch = minPitch, fillPitch = minPitch;
            if (lines.Count > 1)
            {
                maxPitch = Pitch(room + 0.5, clearances, minPitch, Math.Max(minPitch, fontSize * 1.85));
                fillPitch = Pitch(baseline0 - lastBaseline, clearances, minPitch, maxPitch);
            }
            var plan = new Plan
            {
                Lines = lines, Scale = scale, FontSize = fontSize, FirstBaseline = baseline0, MinPitch = minPitch, MaxPitch = maxPitch,
                FillPitch = fillPitch, Fits = fits, Clearances = clearances, Room = room, Deepest = deepest,
            };
            if (fits) return plan;
            best = plan;
            scale -= scale > 0.7 ? 0.04 : 0.05;
        }
        return best!;
    }

    /// <summary>Places the planned lines <paramref name="requested"/> apart and finds where their formulas go.</summary>
    public Result Finish(Plan plan, double requested, List<FormulaSpan> formulas, double? firstBaseline = null)
    {
        double pitch = Math.Min(Math.Max(requested, plan.MinPitch), plan.MaxPitch);
        var offsets = Offsets(pitch, plan.Clearances);
        var result = new Result { Scale = plan.Scale, Fits = plan.Fits, Pitch = pitch };
        for (int k = 0; k < plan.Lines.Count; k++)
        {
            var (line, x) = plan.Lines[k];
            var origin = new Pt(x, (firstBaseline ?? plan.FirstBaseline) - (k < offsets.Count ? offsets[k] : k * pitch));
            result.Lines.Add((line, origin));
            result.Transplants.AddRange(Transplants(line, origin, formulas, plan.Scale));
        }
        return result;
    }

    static double Depth(TextLine line, List<FormulaSpan> formulas, double scale)
    {
        double below = 0;
        foreach (var (o, _) in line.Layout().Objects)
            if (Span(o, formulas) is { } f && !f.Ink.IsNull) below = Math.Max(below, (f.Baseline - f.Ink.MinY) * scale);
        return below;
    }

    /// <summary>How far a line's ink reaches above and below its baseline: its text, and the formulas set in it.</summary>
    public (double Above, double Below) Reach(TextLine line, List<FormulaSpan> formulas, double scale)
    {
        var (above, below) = line.Ink();
        foreach (var (o, _) in line.Layout().Objects)
        {
            if (Span(o, formulas) is not { } f || f.Ink.IsNull) continue;
            above = Math.Max(above, (f.Ink.MaxY - f.Baseline) * scale);
            below = Math.Max(below, (f.Baseline - f.Ink.MinY) * scale);
        }
        return (above, below);
    }

    List<double> LineClearances(List<TextLine> lines, List<FormulaSpan> formulas, double scale, double fontSize)
    {
        if (lines.Count <= 1) return [];
        var extents = lines.Select(l => Reach(l, formulas, scale)).ToList();
        return extents.Zip(extents.Skip(1)).Select(p => p.First.Below + p.Second.Above + fontSize * 0.04).ToList();
    }

    public double Depth(Plan plan) => plan.Deepest;

    /// <summary>Draws the lines (not their formulas) on a y-down canvas whose top is at <paramref name="pageTop"/> in PDF space.</summary>
    public void Draw(Result result, SKCanvas canvas, double pageTop, HashSet<ushort>? used = null)
    {
        foreach (var (line, origin) in result.Lines) line.Draw(canvas, origin.X, pageTop - origin.Y, used);
    }

    /// <summary>The piece of a formula an object stands for.</summary>
    public static FormulaSpan? Span(InlineObject o, List<FormulaSpan> formulas)
    {
        int n = o.Formula;
        if (n < 1 || n > formulas.Count) return null;
        int piece = o.Piece;
        return piece == 0 ? formulas[n - 1] : piece <= formulas[n - 1].Continuation.Count ? formulas[n - 1].Continuation[piece - 1] : null;
    }

    // MARK: Text

    /// <summary>Around a heading run into a paragraph (private use characters: they never come from a translation).</summary>
    public const string LeadStart = "", LeadEnd = "";

    const string Cjk = @"[一-鿿㐀-䶿]";
    const string CjkKana = @"[一-鿿㐀-䶿぀-ヿ]";

    [GeneratedRegex(@"\{\s*[vV]\s*(\d+)\s*\}")]
    private static partial Regex Placeholder();

    public Paragraph AttributedString(string raw, double fontSize, bool bold, bool serif, RGBColor color, List<FormulaSpan> formulas, double scale)
    {
        // Placeholders as a translator may have mangled them (`｛v1｝`, `{ V1 }`).
        var text = Placeholders.Replace(raw, TextSegment.Placeholder);
        // Chinese punctuation next to Chinese text ("训练线性探针,(2)" → "训练线性探针，(2)").
        if (Language.ToLowerInvariant().StartsWith("zh"))
        {
            foreach (var (ascii, full) in new[] { (",", "，"), (";", "；"), (":", "："), ("?", "？"), ("!", "！") })
            {
                var mark = Regex.Escape(ascii);
                text = Regex.Replace(text, $@"(?<={Cjk})\s?{mark}\s?", full);
                text = Regex.Replace(text, $@"\s?{mark}\s?(?={Cjk})", full);
            }
            // …and after a short Latin aside in brackets that follows Chinese ("探针 (LP),").
            text = Regex.Replace(text, $@"(?<={Cjk}\s?\([^()]{{1,24}}\)),\s?", "，");
        }
        // One even space between Chinese or Japanese and what is set among it (Latin words, numbers, formulas).
        if (SpacesBetweenCharacters)
        {
            text = Regex.Replace(text, $@"(?<={CjkKana})\s*(?=[A-Za-z0-9{{\[])", " ");
            text = Regex.Replace(text, $@"(?<=[A-Za-z0-9}}\]])\s*(?={CjkKana})", " ");
        }
        // Punctuation after a formula stays on its line (a word joiner forbids the break before it).
        text = Regex.Replace(text, @"(\{\s*[vV]\s*\d+\s*\})\s?([,.;:!?，。：；！？、）)\]])", "$1⁠$2");
        // Long citation lists ("[7,21,25,26,31]") may break after their commas.
        text = Regex.Replace(text, @"([,，])(?=\s?\d)", "$1​");

        var sb = new StringBuilder();
        var objects = new List<InlineObject?>();
        var used = new HashSet<int>();
        void AppendText(string s)
        {
            sb.Append(s);
            for (int i = 0; i < s.Length; i++) objects.Add(null);
        }
        void AppendPiece(FormulaSpan f, int n, int piece)
        {
            sb.Append('￼');
            objects.Add(new InlineObject
            {
                Ascent = Math.Max(0, f.Rect.MaxY - f.Baseline) * scale, Descent = Math.Max(0, f.Baseline - f.Rect.MinY) * scale,
                Width = f.Rect.W * scale, Formula = n, Piece = piece,
            });
        }
        void AppendFormula(int n)
        {
            if (n < 1 || n > formulas.Count) return;
            used.Add(n);
            AppendPiece(formulas[n - 1], n, 0);
            for (int k = 0; k < formulas[n - 1].Continuation.Count; k++)
            {
                var more = formulas[n - 1].Continuation[k];
                if (more.Spaced) AppendText(" ");
                AppendPiece(more, n, k + 1);
            }
        }
        int cursor = 0;
        foreach (Match m in Placeholder().Matches(text))
        {
            if (m.Index > cursor) AppendText(text[cursor..m.Index]);
            AppendFormula(int.TryParse(m.Groups[1].Value, out var n) ? n : 0);
            cursor = m.Index + m.Length;
        }
        if (cursor < text.Length) AppendText(text[cursor..]);
        // Formulas the translation dropped still appear, at the end (a lone operator was probably translated as text).
        for (int n = 1; n <= formulas.Count; n++)
        {
            var f = formulas[n - 1];
            if (used.Contains(n) || !(f.Rect.W > f.Size * 1.2 || f.Links.Count > 0 || f.Icons.Count > 0)) continue;
            AppendText(" ");
            AppendFormula(n);
        }
        var result = sb.ToString();
        var bolds = Enumerable.Repeat(bold, result.Length).ToList();
        // A heading run into the paragraph: bold, between its markers.
        int opening = result.IndexOf(LeadStart, StringComparison.Ordinal), closing = result.IndexOf(LeadEnd, StringComparison.Ordinal);
        if (opening >= 0 && closing > opening)
        {
            for (int i = opening; i < closing; i++) bolds[i] = true;
            foreach (var at in new[] { closing, opening })
            {
                result = result.Remove(at, 1);
                bolds.RemoveAt(at);
                objects.RemoveAt(at);
            }
        }
        return new Paragraph(result, bolds.ToArray(), objects.ToArray(), Language, serif, fontSize, color);
    }

    static List<TextLine> BreakLineRanges(Paragraph text, double width, double indent, double hanging = 0)
    {
        var lines = new List<TextLine>();
        int start = 0, length = text.Length;
        while (start < length)
        {
            double available = Math.Max(lines.Count == 0 ? width - indent : width - hanging, 4);
            int count = text.SuggestLineBreak(start, available);
            if (count <= 0) count = 1;
            lines.Add(text.Line(start, count));
            start += count;
            // No line starts with a space.
            while (start < length && text.Text[start] == ' ') start++;
        }
        return lines;
    }

    /// <summary>Whether a line starts with a full-width opening bracket.</summary>
    static bool OpensWithBracket(TextLine line) => line.Length > 0 && "（《「『【〈〔".Contains(line.Paragraph.Text[line.Start]);

    /// <summary>Scripts set without spaces between words.</summary>
    public bool SpacesBetweenCharacters => new[] { "zh", "ja" }.Any(p => Language.ToLowerInvariant().StartsWith(p));

    /// <summary>The line again with <paramref name="extra"/> points spread over the gaps between its characters.</summary>
    static TextLine? JustifiedByKerning(TextLine line, double extra, double fontSize)
    {
        var text = line.Paragraph.Text;
        int length = line.Length;
        while (length > 0 && text[line.Start + length - 1] is ' ' or '\t' or '　') length--;
        if (length <= 1 || extra <= 0) return null;
        // Gaps after a Chinese / Japanese character or before one; Latin words keep their letters together.
        static bool IsCJK(char u) => u is >= '⺀' and <= '鿿' or >= '＀' and <= '￯' or >= '　' and <= '〿';
        var gaps = new List<int>();
        for (int k = 0; k < length - 1; k++)
        {
            char a = text[line.Start + k], b = text[line.Start + k + 1];
            if (IsCJK(a) || IsCJK(b) || a == ' ') gaps.Add(k);
        }
        if (gaps.Count == 0) gaps = Enumerable.Range(0, length - 1).ToList();
        double kern = extra / gaps.Count;
        if (kern >= fontSize * 0.3) return null;
        return line.WithExtra(gaps.ToDictionary(k => k, _ => kern));
    }

    public static List<Transplant> Transplants(TextLine line, Pt origin, List<FormulaSpan> formulas, double scale)
    {
        var result = new List<Transplant>();
        foreach (var (o, x) in line.Layout().Objects)
            if (Span(o, formulas) is { } span) result.Add(new Transplant(span, new Pt(origin.X + x, origin.Y), scale));
        return result;
    }
}
