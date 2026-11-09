using System.Text.RegularExpressions;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Translate.Layout;

// Port of macos/.../FolioTranslate/Layout/LayoutAnalyzer.swift (split over LayoutAnalyzer*.cs).

public readonly record struct Gap(double Lower, double Upper)
{
    public bool Contains(double x) => x >= Lower && x <= Upper;
}

/// <summary>
/// Finds the blocks of text on each page and decides which of them to translate. Works from exact geometry: glyph
/// positions, the fonts and positions of text operators, and the bounds of images and vector paths.
/// </summary>
public sealed partial class LayoutAnalyzer
{
    public sealed class Options
    {
        public bool TranslateTables { get; set; } = true;
        public bool TranslateReferences { get; set; }
    }

    public Options Opts { get; }
    bool _inReferences;
    public double BodySize { get; private set; } = 10;
    Func<double, (double Lo, double Hi)>? _columnOf;
    double _typicalWidth = double.PositiveInfinity;
    List<Rect> _pageRules = [];
    int _currentPage;

    public LayoutAnalyzer(Options? options = null) { Opts = options ?? new Options(); }

    // MARK: Document

    /// <summary>Analyses pages (1-based numbers) of the document.</summary>
    public List<PageLayout> Analyze(PdfSource source, IReadOnlyCollection<int> pages)
    {
        var prepared = new List<(int Number, ContentInterpreter Interpreter, List<PageChar> Chars)>();
        var sizeCounts = new Dictionary<double, int>();
        var selected = pages.ToHashSet();
        int through = Math.Min(pages.Count == 0 ? 0 : pages.Max(), source.Pages.Count);
        for (int number = 1; number <= through; number++)
        {
            var interpreter = new ContentInterpreter();
            interpreter.Run(source.Pages[number - 1]);
            var chars = PageText.Characters(source, number, interpreter);
            foreach (var c in chars)
            {
                if (c.IsSpace || c.IsNewline || c.IsRotated) continue;
                var key = Math.Round(c.Size * 2) / 2;
                sizeCounts[key] = sizeCounts.GetValueOrDefault(key) + 1;
            }
            prepared.Add((number, interpreter, chars));
        }
        BodySize = sizeCounts.Count == 0 ? 10 : sizeCounts.MaxBy(kv => kv.Value).Key;
        _inReferences = false;
        var result = new List<PageLayout>();
        foreach (var (number, interpreter, chars) in prepared)
        {
            var layout = AnalyzePage(number, source.Pages[number - 1], interpreter, chars);
            if (selected.Contains(number)) result.Add(layout);
        }
        return result;
    }

    // MARK: Page

    public PageLayout AnalyzePage(int number, PDict page, ContentInterpreter interpreter, List<PageChar> rawChars)
    {
        var geometry = PdfComposer.Geometry(page);
        var media = geometry.MediaBox;
        var crop = geometry.CropBox;
        _currentPage = number;
        var chars = rawChars.Select(c => c.Clone()).ToList();
        MathDetector.Mark(chars);
        var links = PageLinks.Links(page);
        PageLinks.Assign(links, chars, crop);
        var marks = interpreter.Marks.Where(m => !m.IsWhite && m.Rect.W * m.Rect.H < crop.W * crop.H * 0.6).ToList();
        var lines = BuildLines(chars, [], pageWidth: crop.W);
        var icons = InlineIcons(interpreter, lines);
        if (icons.Count > 0)
        {
            Insert(icons, chars);
            var taken = icons.Select(i => interpreter.Marks[i.Mark].Location).ToHashSet();
            marks.RemoveAll(m => taken.Contains(m.Location));
        }
        var rules = marks.Where(m => (m.Kind == GraphicMark.MarkKind.Fill || m.Kind == GraphicMark.MarkKind.Stroke) && m.Rect.H < 2.5 && m.Rect.W > 30)
            .Select(m => m.Rect).Where(rule => !lines.Any(line =>
            {
                double below = line.Baseline - rule.MidY;
                return below > -0.5 && below < line.Size * 0.17 && rule.MinX >= line.MinX - 1 && rule.MaxX <= line.MaxX + 1;
            })).ToList();
        var tables = TableFrames(rules, lines).Select(t => TrimCaptions(t, lines)).Where(t => IsTable(t, lines, marks)).ToList();
        var figures = FigureRegions(marks, lines, tables, crop);
        tables.RemoveAll(table => figures.Any(f => f.Intersection(table).Area > table.Area * 0.4));
        var gutters = tables.Select(t => ColumnGutters(t, lines)).ToList();
        lines = BuildLines(chars, tables, gutters, crop.W).Select(MarkScripts).ToList();
        JoinWordFractions(lines, marks);
        MarkChips(lines, marks);
        lines = ReadingOrder(lines);
        var algorithms = new List<Rect>();
        tables.RemoveAll(table =>
        {
            var first = lines.Where(l => table.InsetBy(-1, -BodySize * 1.6).Contains(l.Rect.Center)).MaxBy(l => l.Baseline);
            if (first == null || !IsAlgorithmStart(first.Text)) return false;
            algorithms.Add(table);
            return true;
        });
        var numbers = lines.Where(l => Regex.IsMatch(l.Text.Trim(), @"^\(\d{1,3}[a-z]?\)$")).ToList();
        var equations = new HashSet<int>();
        var flat = lines.Where(l => !l.IsRotated).ToList();
        var columnGutters = flat.Count == 0 ? [] : Gutters(flat, flat.Min(l => l.MinX), flat.Max(l => l.MaxX) - flat.Min(l => l.MinX));
        foreach (var num in numbers)
        {
            for (int k = 0; k < lines.Count; k++)
            {
                var line = lines[k];
                if (!(line.MaxX < num.MinX && Math.Abs(line.Baseline - num.Baseline) < num.Size * 0.6)) continue;
                if (columnGutters.Any(g => line.MaxX <= g.Upper && num.MinX >= g.Lower)) continue;
                int prose = line.Text.Split(' ').Count(w => w.Length >= 3 && w.All(char.IsLower));
                if (TextWords(line) <= 3 || (line.Text.Contains('=') && prose <= 1)) equations.Add(k);
            }
        }
        for (int k = 0; k < lines.Count; k++)
        {
            var line = lines[k];
            if (equations.Contains(k) || line.MathRatio < 0.3 || TextWords(line) > 2) continue;
            bool setOff = lines.Any(other => other.InkRect.W > line.InkRect.W + other.Size * 4 && Math.Abs(other.Baseline - line.Baseline) < other.Size * 4
                                             && other.MinX + other.Size * 1.5 < line.MinX && line.MaxX < other.MaxX - other.Size * 1.5);
            bool firstIsMath = line.Chars.FirstOrDefault(c => !c.IsSpace)?.IsMath == true;
            if (setOff && firstIsMath) equations.Add(k);
        }
        GrowDisplays(equations, lines, columnGutters, BodySize);
        var pseudocode = PseudocodeLines(lines);
        var edges = ColumnEdges(lines, columnGutters);
        _pageRules = marks.Where(m => m.Kind != GraphicMark.MarkKind.Image && m.Rect.H < 2.5 && m.Rect.W > 8).Select(m => m.Rect).ToList();
        _columnOf = edges;
        var bodyWidths = flat.Where(l => Math.Abs(l.Size - BodySize) < BodySize * 0.12).Select(l => l.InkRect.W).OrderBy(w => w).ToList();
        _typicalWidth = bodyWidths.Count >= 8 ? bodyWidths[bodyWidths.Count * 4 / 5] : double.PositiveInfinity;
        var captionLines = new HashSet<int>();
        for (int k = 0; k < lines.Count; k++)
        {
            var line = lines[k];
            if (!IsCaptionStart(line.Text)) continue;
            var last = line;
            int claimed = 0;
            while (claimed < 12)
            {
                int j = Enumerable.Range(0, lines.Count).FirstOrDefault(j =>
                {
                    var next = lines[j];
                    double drop = last.Baseline - next.Baseline;
                    return j != k && !captionLines.Contains(j) && drop > last.Size * 0.5 && drop < last.Size * 1.7 && next.Font == line.Font
                           && Math.Abs(next.Size - last.Size) < last.Size * 0.1 && !IsCaptionStart(next.Text)
                           && (Math.Abs(next.MinX - line.MinX) < line.Size || Math.Abs((next.MinX + next.MaxX) - (line.MinX + line.MaxX)) < line.Size * 4)
                           && figures.Any(f => f.Contains(next.Rect.Center));
                }, -1);
                if (j < 0) break;
                captionLines.Add(j);
                last = lines[j];
                claimed++;
            }
        }
        for (int k = 0; k < lines.Count; k++)
            if (number == 1 && lines[k].Size >= BodySize * 1.25 && TextWords(lines[k]) >= 3) captionLines.Add(k);
        var blocks = new List<LayoutBlock>();
        var flowing = new List<LayoutLine>();
        for (int k = 0; k < lines.Count; k++)
        {
            var line = lines[k];
            var center = line.Rect.Center;
            if (line.IsRotated) blocks.Add(new LayoutBlock { Kind = BlockKind.Rotated, Lines = [line] });
            else if (algorithms.Any(a => a.InsetBy(-1, -2).Contains(center)) || (IsAlgorithmStart(line.Text) && algorithms.Any(a => a.InsetBy(-1, -BodySize * 1.6).Contains(center))))
                blocks.Add(new LayoutBlock { Kind = BlockKind.Code, Lines = [line] });
            else if (figures.Any(f => f.InsetBy(-1, -1).Contains(center)) && !IsCaptionStart(line.Text) && !captionLines.Contains(k))
                blocks.Add(new LayoutBlock { Kind = BlockKind.Figure, Lines = [line] });
            else if (pseudocode.Contains(k)) blocks.Add(new LayoutBlock { Kind = BlockKind.Code, Lines = [line] });
            else if (tables.Any(t => t.InsetBy(-1, -2).Contains(center)))
            {
                bool translate = Opts.TranslateTables && HasWords(line.Text) && !line.Font.IsMonospace && IsCellText(line.Text);
                blocks.Add(new LayoutBlock { Kind = BlockKind.TableCell, Lines = [line], Translate = translate });
            }
            else if (IsMarginal(line, crop, lines)) blocks.Add(new LayoutBlock { Kind = BlockKind.Header, Lines = [line] });
            else if (IsDisplayMath(line) || equations.Contains(k) || numbers.Any(n => n.InkRect == line.InkRect))
                blocks.Add(new LayoutBlock { Kind = BlockKind.Formula, Lines = [line] });
            else flowing.Add(line);
        }
        var textBlocks = new List<LayoutBlock>();
        foreach (var line in flowing)
        {
            int found = -1;
            for (int k = textBlocks.Count - 1, tried = 0; k >= 0 && tried < 12; k--, tried++)
                if (CanJoin(textBlocks[k], line)) { found = k; break; }
            if (found >= 0) textBlocks[found].Lines.Add(line);
            else textBlocks.Add(new LayoutBlock { Kind = BlockKind.Paragraph, Lines = [line], Translate = true });
        }
        var beside = tables.Concat(figures).Concat(marks.Where(m => m.Rect.W * m.Rect.H > 20).Select(m => m.Rect))
            .Concat(blocks.Where(b => !b.Translate).Select(b => b.Rect)).ToList();
        var snapshot = textBlocks.ToList();
        textBlocks = snapshot.SelectMany(block =>
        {
            var others = snapshot.Where(b => b.Rect != block.Rect).Select(b => b.Rect);
            return SplitBesideObstacles(block, beside.Concat(others).ToList());
        }).ToList();
        var boxes = marks.Where(m => m.Kind == GraphicMark.MarkKind.Fill && m.Rect.W * m.Rect.H > 3000).Select(m => m.Rect).ToList();
        Classify(textBlocks, number, crop, boxes);
        // The running text only: a stamp up the margin (arXiv's) would put the middle of the page somewhere else.
        double textLeft = flowing.Count > 0 ? flowing.Min(l => l.MinX) : crop.MinX, textRight = flowing.Count > 0 ? flowing.Max(l => l.MaxX) : crop.MaxX;
        foreach (var block in textBlocks)
        {
            var r = block.Rect;
            double size = block.Size;
            var column = edges(r.MidX);
            bool inColumn = Math.Abs(r.MidX - (column.Lo + column.Hi) / 2) < size * 0.8 && r.MinX - column.Lo > size * 1.5;
            bool onPage = Math.Abs(r.MidX - (textLeft + textRight) / 2) < size * 0.8 && r.MinX - textLeft > size * 1.5;
            // A title about as wide as the text leaves no room to show it, but its translation will be shorter.
            bool fillsPage = block.Kind == BlockKind.Title && Math.Min(Math.Abs(r.MidX - (textLeft + textRight) / 2), Math.Abs(r.MidX - crop.MidX)) < size * 0.8;
            block.CenteredInColumn = inColumn || onPage || fillsPage;
        }
        blocks.AddRange(textBlocks);
        MergeInterleaved(blocks);
        AbsorbStrays(blocks);
        MergeTableCells(blocks, tables, rules);
        var graphics = marks.Select(m => m.Rect).Concat(figures).ToList();
        return new PageLayout
        {
            Number = number, MediaBox = media, CropBox = crop, Blocks = blocks, Figures = figures, Tables = tables, Graphics = graphics,
            Runs = interpreter.Runs, Glyphs = interpreter.Glyphs, Links = links,
        };
    }

    // MARK: Inline pictures

    public sealed record Icon(int Mark, PageChar? Anchor, PageChar Char);

    /// <summary>Pictures the size of a character on a line with words beside them, and the character standing in for each.</summary>
    public static List<Icon> InlineIcons(ContentInterpreter interpreter, List<LayoutLine> lines)
    {
        var result = new List<Icon>();
        var flat = lines.Where(l => !l.IsRotated && l.WordCount >= 5).ToList();
        var shapes = new List<(int Result, double Line)>();
        for (int index = 0; index < interpreter.Marks.Count; index++)
        {
            var mark = interpreter.Marks[index];
            bool isImage = mark.Kind == GraphicMark.MarkKind.Image && interpreter.Images.ContainsKey(index);
            bool isShape = mark.Kind == GraphicMark.MarkKind.Fill && !mark.IsWhite && mark.HasCurves && mark.SegmentCount >= 6 && interpreter.Paths.ContainsKey(index);
            if (!isImage && !isShape) continue;
            var r = mark.Rect;
            var candidates = flat.Where(line => r.W <= line.Size * 2.6 && r.H <= line.Size * 1.9 && r.H >= line.Size * 0.5
                && r.MidY > line.Baseline - line.Size * 0.35 && r.MidY < line.Baseline + line.Size * 0.85
                && line.Chars.Any(c => !c.IsSpace && ((c.Rect.MaxX <= r.MidX && r.MinX - c.Rect.MaxX < line.Size * 1.5) || (c.Rect.MinX >= r.MidX && c.Rect.MinX - r.MaxX < line.Size * 1.5)))).ToList();
            var best = candidates.MinBy(l => Math.Abs(l.Baseline + l.Size * 0.3 - r.MidY));
            if (best == null || best.Chars.FirstOrDefault(c => !c.IsSpace) is not { } template) continue;
            var ch = template.Clone();
            ch.Text = "￼";
            ch.Rect = new Rect(r.MinX, best.Baseline - best.Size * 0.22, r.W, best.Size * 1.2);
            ch.Ink = r;
            ch.Size = best.Size;
            ch.Baseline = best.Baseline;
            ch.IsMath = true;
            ch.IsScript = false;
            ch.Glyphs = [];
            ch.Run = null;
            ch.Link = null;
            ch.LinkTarget = null;
            ch.Icon = index;
            if (isShape) shapes.Add((result.Count, best.Baseline));
            result.Add(new Icon(index, best.Chars.LastOrDefault(c => !c.IsSpace && c.Rect.MaxX <= r.MidX), ch));
        }
        var perLine = new Dictionary<double, int>();
        foreach (var s in shapes) perLine[s.Line] = perLine.GetValueOrDefault(s.Line) + 1;
        var tooMany = shapes.Count > 12 ? shapes.Select(s => s.Result).ToHashSet() : shapes.Where(s => perLine[s.Line] > 3).Select(s => s.Result).ToHashSet();
        return result.Where((_, i) => !tooMany.Contains(i)).ToList();
    }

    /// <summary>Puts the stand-ins among the characters, each after the one to its left in the line.</summary>
    public static void Insert(List<Icon> icons, List<PageChar> chars)
    {
        foreach (var icon in icons)
        {
            int place = icon.Anchor is { } anchor
                ? chars.FindIndex(c => !c.IsSpace && !c.IsNewline && c.Glyphs.SequenceEqual(anchor.Glyphs) && c.Icon == anchor.Icon) : -1;
            if (place >= 0) chars.Insert(place + 1, icon.Char);
            else
            {
                int first = chars.FindIndex(c => !c.IsSpace && !c.IsNewline && Math.Abs(c.Baseline - icon.Char.Baseline) < icon.Char.Size * 0.3 && c.Rect.MinX >= icon.Char.Rect.MinX);
                if (first >= 0) chars.Insert(first, icon.Char);
            }
        }
    }

    // MARK: Displays

    static Func<double, (double Lo, double Hi)> ColumnEdges(List<LayoutLine> lines, List<Gap> gutters)
    {
        var flat = lines.Where(l => !l.IsRotated).ToList();
        if (flat.Count == 0) return _ => (0, 0);
        double minX = flat.Min(l => l.MinX), maxX = flat.Max(l => l.MaxX);
        var bounds = new List<double> { minX };
        foreach (var g in gutters.OrderBy(g => g.Lower)) bounds.Add((g.Lower + g.Upper) / 2);
        bounds.Add(maxX);
        var edges = new List<(double From, double To, double Lo, double Hi)>();
        for (int i = 0; i + 1 < bounds.Count; i++)
        {
            double a = bounds[i], b = bounds[i + 1];
            var inside = flat.Where(l => l.MinX >= a - 2 && l.MaxX <= b + 2 && l.InkRect.W > (b - a) * 0.4).ToList();
            var los = inside.Select(l => l.MinX).OrderBy(x => x).ToList();
            var his = inside.Select(l => l.MaxX).OrderBy(x => x).ToList();
            edges.Add((a, b, los.Count == 0 ? a : los[los.Count / 5], his.Count == 0 ? b : his[his.Count * 4 / 5]));
        }
        return x =>
        {
            var column = edges.FirstOrDefault(e => x >= e.From && x <= e.To, edges[^1]);
            return (column.Lo, column.Hi);
        };
    }

    /// <summary>Words on a coloured chip inside a line: chip and word move together, as a formula.</summary>
    static void MarkChips(List<LayoutLine> lines, List<GraphicMark> marks)
    {
        foreach (var mark in marks)
        {
            if (mark.Kind != GraphicMark.MarkKind.Fill || mark.IsWhite || mark.HasCurves || mark.Rect.H >= 40 || mark.Rect.W <= 4) continue;
            var box = mark.Rect;
            foreach (var line in lines)
            {
                if (line.IsRotated) continue;
                if (!(box.H > line.Size * 0.7 && box.H < line.Size * 2 && box.W < line.InkRect.W * 0.5 && line.VisibleCount >= 20
                      && box.MinY <= line.Baseline && box.MaxY >= line.Baseline + line.Size * 0.5)) continue;
                foreach (var c in line.Chars)
                    if (!c.IsSpace && box.Contains(new Pt(c.Rect.MidX, line.Baseline + line.Size * 0.25))) c.IsMath = true;
            }
        }
    }

    /// <summary>Words set as a fraction inside a line of text: both go into the line, as one formula.</summary>
    static void JoinWordFractions(List<LayoutLine> lines, List<GraphicMark> marks)
    {
        foreach (var mark in marks)
        {
            if (mark.Kind == GraphicMark.MarkKind.Image || mark.Rect.H >= 1.5 || mark.Rect.W <= 6 || mark.Rect.W >= 200) continue;
            var rule = mark.Rect;
            bool Holds(LayoutLine l) => l.MinX >= rule.MinX - 1.5 && l.MaxX <= rule.MaxX + 1.5 && l.InkRect.W > rule.W * 0.5 && !l.IsRotated;
            int upper = lines.FindIndex(l => Holds(l) && l.Baseline > rule.MidY && l.Baseline - rule.MidY < l.Size * 1.1);
            int lower = lines.FindIndex(l => Holds(l) && l.Baseline < rule.MidY && rule.MidY - l.Baseline < l.Size * 1.3);
            if (upper < 0 || lower < 0 || upper == lower) continue;
            double size = lines[upper].Size;
            var hosts = Enumerable.Range(0, lines.Count).Where(k => k != upper && k != lower && !lines[k].IsRotated && lines[k].Size >= size * 1.05
                && Math.Abs(lines[k].Baseline + lines[k].Size * 0.25 - rule.MidY) < lines[k].Size * 0.5
                && ((lines[k].MaxX <= rule.MinX + 1 && rule.MinX - lines[k].MaxX < lines[k].Size * 1.5) || (lines[k].MinX >= rule.MaxX - 1 && lines[k].MinX - rule.MaxX < lines[k].Size * 1.5))).ToList();
            if (hosts.Count == 0) continue;
            var parts = lines[upper].Chars.Concat(lines[lower].Chars).ToList();
            foreach (var c in parts) if (!c.IsSpace) c.IsMath = true;
            foreach (var k in hosts) parts.AddRange(lines[k].Chars);
            if (MakeLine(parts) is not { } joined) continue;
            var gone = hosts.Append(upper).Append(lower).ToHashSet();
            int keep = hosts.Min();
            lines[keep] = joined;
            var kept = Enumerable.Range(0, lines.Count).Where(i => i == keep || !gone.Contains(i)).Select(i => lines[i]).ToList();
            lines.Clear();
            lines.AddRange(kept);
        }
    }

    /// <summary>Lines belonging to a displayed formula, grown from the lines already known to.</summary>
    static void GrowDisplays(HashSet<int> equations, List<LayoutLine> lines, List<Gap> gutters, double bodySize)
    {
        var edges = ColumnEdges(lines, gutters);
        static int Prose(LayoutLine line)
        {
            int count = 0, run = 0;
            foreach (var c in line.Chars)
            {
                if (!c.IsMath && !c.IsSpace && c.Text.Length > 0 && char.IsLower(c.Text[0])) run++;
                else
                {
                    if (run >= 3) count++;
                    run = 0;
                }
            }
            return count + (run >= 3 ? 1 : 0);
        }
        bool IsSetOff(LayoutLine line)
        {
            var column = edges((line.MinX + line.MaxX) / 2);
            return line.MinX - column.Lo > line.Size && column.Hi - line.MaxX > line.Size;
        }
        for (int k = 0; k < lines.Count; k++)
        {
            var line = lines[k];
            if (line.IsRotated || equations.Contains(k) || IsCaptionStart(line.Text)) continue;
            if (!IsSetOff(line) || line.VisibleCount < 3 || Prose(line) > 2) continue;
            if (line.MathRatio >= 0.4 || (line.MathRatio >= 0.15 && line.Text.Contains('=') && Prose(line) <= 1)) equations.Add(k);
        }
        bool changed = true;
        int rounds = 0;
        while (changed && rounds < 8)
        {
            changed = false;
            rounds++;
            for (int k = 0; k < lines.Count; k++)
            {
                var line = lines[k];
                if (line.IsRotated || equations.Contains(k) || IsCaptionStart(line.Text)) continue;
                var column = edges((line.MinX + line.MaxX) / 2);
                if (line.MinX - column.Lo <= line.Size * 0.5) continue;
                bool tiny = line.VisibleCount <= 4 && (line.Text.Length == 0 || !".:;,".Contains(line.Text[^1]));
                bool row = IsSetOff(line) && Prose(line) <= 3 && !(line.Text.EndsWith('.') && Prose(line) >= 2);
                if (!tiny && !row) continue;
                bool next = equations.Any(e =>
                {
                    var other = lines[e];
                    double drop = Math.Abs(other.Baseline - line.Baseline);
                    double shared = Math.Min(other.MaxX, line.MaxX + line.Size) - Math.Max(other.MinX, line.MinX - line.Size);
                    return drop < Math.Max(other.Size, line.Size) * 2.2 && shared >= line.InkRect.W * 0.8;
                });
                if (next)
                {
                    equations.Add(k);
                    changed = true;
                }
            }
        }
    }

    /// <summary>Lines of pseudocode: three or more lines numbered in sequence, some reading like code.</summary>
    static HashSet<int> PseudocodeLines(List<LayoutLine> lines)
    {
        static int? Number(LayoutLine line)
        {
            var m = Regex.Match(line.Text, @"^\s*(\d{1,3})[:.)]?\s");
            return m.Success ? int.Parse(m.Groups[1].Value) : null;
        }
        static bool ReadsLikeCode(LayoutLine line)
        {
            var text = Regex.Replace(line.Text, @"^\s*\d{1,3}[:.)]?\s*", "");
            return Regex.IsMatch(text, @"^(for|foreach|if|else|elif|while|repeat|until|end|return|function|procedure|def|break|continue)\b|(\bdo|\bthen)\s*;?\s*$|←|:=|▷");
        }
        var result = new HashSet<int>();
        int k = 0;
        while (k < lines.Count)
        {
            if (lines[k].IsRotated || Number(lines[k]) is not { } start) { k++; continue; }
            int expected = start + 1, last = k;
            var numbered = new List<int> { k };
            int j = k + 1;
            while (j < lines.Count && j - last <= 6 && !lines[j].IsRotated)
            {
                double drop = lines[last].Baseline - lines[j].Baseline;
                if (!(drop > 0 && drop < lines[last].Size * (3 + (j - last)) && Math.Abs(lines[j].Size - lines[k].Size) < lines[k].Size * 0.3)) break;
                if (Number(lines[j]) == expected)
                {
                    numbered.Add(j);
                    last = j;
                    expected++;
                }
                j++;
            }
            int evidence = Enumerable.Range(k, last - k + 1).Count(i => ReadsLikeCode(lines[i]));
            bool underHeading = Enumerable.Range(Math.Max(0, k - 6), k - Math.Max(0, k - 6))
                .Any(i => IsAlgorithmStart(lines[i].Text) && lines[i].Baseline > lines[k].Baseline && lines[i].Baseline - lines[k].Baseline < lines[k].Size * 10);
            if ((numbered.Count >= 2 && underHeading) || (numbered.Count >= 3 && (evidence >= 2 || evidence * 4 >= numbered.Count)))
            {
                for (int i = k; i <= last; i++) result.Add(i);
                int lo = Math.Max(0, k - 8);
                int heading = Enumerable.Range(lo, k - lo).LastOrDefault(i => IsAlgorithmStart(lines[i].Text), -1);
                if (heading >= 0)
                {
                    for (int i = heading + 1; i < k; i++) result.Add(i);
                }
                else
                {
                    int input = Enumerable.Range(lo, k - lo).FirstOrDefault(i => Regex.IsMatch(lines[i].Text, @"^\s*(Input|Output|Require|Ensure)\b"), -1);
                    if (input >= 0) for (int i = input; i < k; i++) result.Add(i);
                }
                k = last + 1;
            }
            else k++;
        }
        return result;
    }
}
