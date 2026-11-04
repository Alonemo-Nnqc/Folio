using System.Text.RegularExpressions;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Translate.Layout;

public sealed partial class LayoutAnalyzer
{
    static bool StartsWithLetter(string s) => s.Length > 0 && System.Text.Rune.TryGetRuneAt(s, 0, out var r) && System.Text.Rune.IsLetter(r);
    static bool StartsWithLetterOrDigit(string s) => s.Length > 0 && System.Text.Rune.TryGetRuneAt(s, 0, out var r) && System.Text.Rune.IsLetterOrDigit(r);
    static bool StartsLower(string s) => s.Length > 0 && System.Text.Rune.TryGetRuneAt(s, 0, out var r) && System.Text.Rune.IsLower(r);

    static PageChar SpaceAfter(PageChar template, double x, double width)
    {
        var space = template.Clone();
        space.Text = " ";
        space.IsSpace = true;
        space.IsMath = false;
        space.Glyphs = [];
        space.Run = null;
        space.Link = null;
        space.Rect = new Rect(x, template.Rect.MinY, width, template.Rect.H);
        return space;
    }

    // MARK: Table cells

    /// <summary>Lines of one table cell joined; then each cell learns how its column is aligned.</summary>
    static void MergeTableCells(List<LayoutBlock> blocks, List<Rect> tables, List<Rect> rules)
    {
        foreach (var table in tables)
        {
            var area = table.InsetBy(-1, -2);
            var indices = Enumerable.Range(0, blocks.Count).Where(i => blocks[i].Kind == BlockKind.TableCell && area.Contains(blocks[i].Rect.Center)).ToList();
            indices.Sort((x, y) => blocks[y].Lines[0].Baseline.CompareTo(blocks[x].Lines[0].Baseline));
            var removed = new HashSet<int>();
            static bool IsNumeric(string text) => Regex.IsMatch(text, @"^[\s\d.,±%()\-–+*†‡/×~<>≤≥]*$");
            foreach (var a in indices)
            {
                if (removed.Contains(a)) continue;
                while (true)
                {
                    var upper = blocks[a].Lines[^1];
                    if (!upper.Text.Any(char.IsLetter)) break;
                    var below = indices.Where(b =>
                    {
                        if (b == a || removed.Contains(b) || blocks[b].Lines.Count != 1) return false;
                        var lower0 = blocks[b].Lines[0];
                        double drop = upper.Baseline - lower0.Baseline;
                        return drop > upper.Size * 0.5 && drop < upper.Size * 1.5 && lower0.MinX < upper.MaxX && lower0.MaxX > upper.MinX;
                    }).ToList();
                    if (below.Count != 1) break;
                    int bIndex = below[0];
                    var lower = blocks[bIndex].Lines[0];
                    bool aligned = Math.Abs(lower.MinX - upper.MinX) < upper.Size * 0.6 || Math.Abs((lower.MinX + lower.MaxX) - (upper.MinX + upper.MaxX)) < upper.Size * 1.2;
                    if (!aligned || Math.Abs(lower.Size - upper.Size) >= upper.Size * 0.1 || lower.Font.IsBold != upper.Font.IsBold
                        || IsNumeric(lower.Text) || !lower.Text.Any(char.IsLetter)) break;
                    bool separated = rules.Any(rule => rule.MidY < upper.Baseline && rule.MidY > lower.Baseline + lower.Size * 0.6 && rule.MinX < upper.MaxX && rule.MaxX > upper.MinX);
                    if (separated) break;
                    List<LayoutLine> Peers(LayoutLine line) => indices.Where(k => !removed.Contains(k) && k != a && k != bIndex)
                        .SelectMany(k => blocks[k].Lines).Where(l => Math.Abs(l.Baseline - line.Baseline) < line.Size * 0.3).ToList();
                    var lowerPeers = Peers(lower);
                    var upperPeers = Peers(upper);
                    if (lowerPeers.Any(p => IsNumeric(p.Text))) break;
                    bool startsLow = StartsLower(lower.Text.Trim());
                    bool endsOpen = Regex.IsMatch(upper.Text, @"(-|,|\b(and|or|of|the|for|to|with|in|on|by|a|an))\s*$");
                    if (!(startsLow || endsOpen || (lowerPeers.Count == 0 && upperPeers.Count > 0))) break;
                    blocks[a].Lines.Add(lower);
                    blocks[a].Translate = blocks[a].Translate || blocks[bIndex].Translate;
                    removed.Add(bIndex);
                }
            }
            var cells = indices.Where(i => !removed.Contains(i)).ToList();
            foreach (var c in cells)
            {
                var block = blocks[c];
                var r = block.Rect;
                var others = cells.Where(o => o != c).Select(o => blocks[o].Rect).Where(o => o.MinX < r.MaxX + block.Size && o.MaxX > r.MinX - block.Size).ToList();
                int left = others.Count(o => Math.Abs(o.MinX - r.MinX) < 1);
                int right = others.Count(o => Math.Abs(o.MaxX - r.MaxX) < 1);
                int middle = others.Count(o => Math.Abs(o.MidX - r.MidX) < 1);
                if (left > 0 && left >= middle && left >= right) block.CellAlignment = Layout.CellAlignment.Left;
                else if (right > 0 && right > left && right >= middle) block.CellAlignment = Layout.CellAlignment.Right;
                else block.CellAlignment = Layout.CellAlignment.Center;
            }
            foreach (var k in removed.OrderByDescending(x => x)) blocks.RemoveAt(k);
        }
    }

    /// <summary>Splits a block where its lines change width around something beside them.</summary>
    static List<LayoutBlock> SplitBesideObstacles(LayoutBlock block, List<Rect> obstacles)
    {
        var lines = block.Lines;
        if (lines.Count < 2) return [block];
        double margin = block.Size * 4;
        var cuts = new List<int>();
        for (int k = 1; k < lines.Count; k++)
        {
            var previous = lines[k - 1];
            var line = lines[k];
            bool narrows = line.MaxX < previous.MaxX - margin || line.MinX > previous.MinX + margin;
            bool widens = line.MaxX > previous.MaxX + margin || line.MinX < previous.MinX - margin;
            if (!narrows && !widens) continue;
            var wide = narrows ? previous : line;
            var run = new List<LayoutLine>();
            int j = narrows ? k : k - 1;
            while (j >= 0 && j < lines.Count && (lines[j].MaxX < wide.MaxX - margin || lines[j].MinX > wide.MinX + margin) && run.Count < 4)
            {
                run.Add(lines[j]);
                j += narrows ? 1 : -1;
            }
            if (run.Count == 0) continue;
            double top = run.Max(l => l.Rect.MaxY), bottom = run.Min(l => l.Rect.MinY);
            double rightX = run.Max(l => l.MaxX) + 1;
            var rightSide = new Rect(rightX, bottom, Math.Max(wide.MaxX - rightX - 1, 0), top - bottom);
            double leftEdge = run.Min(l => l.MinX);
            var leftSide = new Rect(wide.MinX + 1, bottom, Math.Max(leftEdge - wide.MinX - 2, 0), top - bottom);
            bool found = obstacles.Any(o => !o.InsetBy(1, 1).Intersects(wide.InkRect) && new[] { rightSide, leftSide }.Any(side =>
            {
                var shared = o.Intersection(side);
                return side.W > 0 && !shared.IsNull && shared.W > block.Size && shared.H > block.Size * 0.8;
            }));
            if (found) cuts.Add(k);
        }
        if (cuts.Count == 0) return [block];
        var pieces = new List<LayoutBlock>();
        int start = 0;
        foreach (var cut in cuts.Append(lines.Count))
        {
            if (cut <= start) continue;
            pieces.Add(new LayoutBlock { Kind = block.Kind, Lines = lines.GetRange(start, cut - start), Translate = block.Translate });
            start = cut;
        }
        return pieces;
    }

    /// <summary>Paragraph blocks whose areas run through each other are one paragraph read in pieces.</summary>
    static void MergeInterleaved(List<LayoutBlock> blocks)
    {
        bool changed = true;
        while (changed)
        {
            changed = false;
            for (int a = 0; a < blocks.Count && !changed; a++)
            {
                if (blocks[a].Kind != BlockKind.Paragraph || !blocks[a].Translate) continue;
                for (int b = 0; b < blocks.Count; b++)
                {
                    if (b == a || blocks[b].Kind != BlockKind.Paragraph || !blocks[b].Translate) continue;
                    var ra = blocks[a].Rect.InsetBy(0, blocks[a].Size * 0.2);
                    var rb = blocks[b].Rect.InsetBy(0, blocks[b].Size * 0.2);
                    double shared = ra.Intersection(rb).Area;
                    if (!(shared > Math.Min(ra.Area, rb.Area) * 0.25 && Math.Abs(blocks[a].Size - blocks[b].Size) < blocks[a].Size * 0.15)) continue;
                    var all = blocks[a].Lines.Concat(blocks[b].Lines).OrderByDescending(l => l.Baseline).ToList();
                    var lines = new List<LayoutLine>();
                    foreach (var line in all)
                    {
                        if (lines.Count > 0 && Math.Abs(lines[^1].Baseline - line.Baseline) < Math.Min(lines[^1].Size, line.Size) * 0.45
                            && MakeLine([.. lines[^1].Chars, Spacer(lines[^1]), .. line.Chars]) is { } merged)
                            lines[^1] = merged;
                        else lines.Add(line);
                    }
                    int keep = Math.Min(a, b);
                    blocks[keep].Lines = lines;
                    blocks.RemoveAt(Math.Max(a, b));
                    changed = true;
                    break;
                }
            }
        }
    }

    /// <summary>A space to put between two pieces of a line.</summary>
    static PageChar Spacer(LayoutLine line)
    {
        var space = line.Chars[^1].Clone();
        space.Text = " ";
        space.IsSpace = true;
        space.IsMath = false;
        space.Link = null;
        space.Rect = new Rect(line.MaxX, space.Rect.MinY, 0.1, space.Rect.H);
        return space;
    }

    /// <summary>Small formula pieces left inside a translated paragraph join the paragraph line they sit on.</summary>
    static void AbsorbStrays(List<LayoutBlock> blocks)
    {
        var removed = new HashSet<int>();
        for (int i = 0; i < blocks.Count; i++)
        {
            var cap = blocks[i];
            if (cap.Lines.Count != 1 || cap.Lines[0].VisibleCount != 1 || cap.Translate) continue;
            if (cap.Lines[0].Chars.FirstOrDefault(c => !c.IsSpace) is not { } letter || !StartsWithLetter(letter.Text)) continue;
            int p = Enumerable.Range(0, blocks.Count).FirstOrDefault(j => j != i && blocks[j].Translate && blocks[j].Kind == BlockKind.Paragraph && letter.Size > blocks[j].Size * 1.8
                && blocks[j].Lines[0].MinX - cap.Rect.MaxX < blocks[j].Size * 1.5 && blocks[j].Lines[0].MinX > cap.Rect.MinX
                && Math.Abs(blocks[j].Lines[0].Rect.MaxY - cap.Rect.MaxY) < letter.Size * 0.5, -1);
            if (p < 0) continue;
            var plain = letter.Clone();
            plain.Size = blocks[p].Lines[0].Size;
            plain.Baseline = blocks[p].Lines[0].Baseline;
            var chars = new List<PageChar> { plain };
            chars.AddRange(blocks[p].Lines[0].Chars);
            if (MakeLine(chars) is { } merged)
            {
                blocks[p].Lines[0] = merged;
                removed.Add(i);
            }
        }
        for (int i = 0; i < blocks.Count; i++)
        {
            var stray = blocks[i];
            if (removed.Contains(i) || !(stray.Kind is BlockKind.Formula or BlockKind.Other) || stray.Lines.Count > 2) continue;
            var line = stray.Lines[0];
            var hosts = Enumerable.Range(0, blocks.Count).Where(j => j != i && blocks[j].Translate && blocks[j].Kind == BlockKind.Paragraph
                && stray.Rect.W < Math.Max(blocks[j].Rect.W * 0.6, 1)
                && blocks[j].Lines.Any(host =>
                {
                    bool enclosed = blocks[j].Lines.Any(l => l.Baseline > line.Baseline + host.Size * 0.5 && l.MinX < line.MaxX && l.MaxX > line.MinX)
                                    && blocks[j].Lines.Any(l => l.Baseline < line.Baseline - host.Size * 0.5 && l.MinX < line.MaxX && l.MaxX > line.MinX);
                    return Math.Abs(host.Baseline - line.Baseline) < host.Size * 0.6
                           && (enclosed || (line.MinX < host.MaxX + host.Size * 0.3 && line.MaxX > host.MinX - host.Size * 0.3));
                })).ToList();
            if (hosts.Count == 0) continue;
            int p = hosts.MinBy(j => blocks[j].Lines.Select(l => Math.Abs(l.Baseline - line.Baseline)).DefaultIfEmpty(99).Min());
            foreach (var strayLine in stray.Lines)
            {
                var host = blocks[p];
                int k = Enumerable.Range(0, host.Lines.Count).MinBy(x => Math.Abs(host.Lines[x].Baseline - strayLine.Baseline));
                if (Math.Abs(host.Lines[k].Baseline - strayLine.Baseline) >= host.Lines[k].Size * 1.2) continue;
                var chars = strayLine.Chars.Select(c => { var copy = c.Clone(); if (!copy.IsSpace) copy.IsMath = true; return copy; }).ToList();
                if (MakeLine([.. host.Lines[k].Chars, .. chars]) is { } merged) host.Lines[k] = merged;
            }
            removed.Add(i);
        }
        var kept = blocks.Where((_, i) => !removed.Contains(i)).ToList();
        blocks.Clear();
        blocks.AddRange(kept);
    }

    // MARK: Lines

    /// <summary>Groups characters (in reading order) into lines; in tables a gap of under an em ends a line.</summary>
    List<LayoutLine> BuildLines(List<PageChar> chars, List<Rect> tables, List<List<Gap>>? gutters = null, double pageWidth = 600)
    {
        gutters ??= [];
        var lines = new List<LayoutLine>();
        var current = new List<PageChar>();
        double mainSize = 0, mainBaseline = 0;
        void Flush()
        {
            while (current.Count > 0 && current[^1].IsSpace) current.RemoveAt(current.Count - 1);
            if (current.Count > 0 && MakeLine(current) is { } line) lines.Add(line);
            current = [];
            mainSize = 0;
        }
        foreach (var c in chars)
        {
            if (c.IsNewline) { Flush(); continue; }
            if (c.IsSpace)
            {
                if (current.Count > 0 && !current[^1].IsSpace) current.Add(c);
                continue;
            }
            if (c.Rect.W <= 0 && c.Rect.H <= 0) continue;
            if (current.LastOrDefault(x => !x.IsSpace) is { } last)
            {
                bool small = c.Size < mainSize * 0.85;
                double dy = Math.Abs(c.Baseline - mainBaseline);
                double overlap = Math.Min(c.Rect.MaxY, mainBaseline + mainSize) - Math.Max(c.Rect.MinY, mainBaseline - mainSize * 0.3);
                bool sameLine = dy < mainSize * 0.5 || (small && dy < mainSize * 0.9 && overlap > 0);
                double gap = c.Rect.MinX - last.Rect.MaxX;
                int table = tables.FindIndex(t => t.InsetBy(-1, -2).Contains(c.Center));
                double limit = (table >= 0 ? 0.75 : 2.2) * Math.Max(mainSize, c.Size);
                bool acrossGutter = table >= 0 && table < gutters.Count && gutters[table].Any(g => last.Rect.MaxX <= g.Lower + 0.5 && c.Rect.MinX >= g.Upper - 0.5);
                if (!sameLine || gap > limit || acrossGutter || gap < -Math.Max(mainSize, 4) * 1.5 || c.IsRotated != last.IsRotated) Flush();
            }
            if (current.Count == 0 || c.Size > mainSize * 1.15 || (c.Size >= mainSize * 0.85 && current.Count < 3))
            {
                if (c.Size >= mainSize * 0.85 || current.Count == 0)
                {
                    mainSize = Math.Max(mainSize, c.Size);
                    mainBaseline = c.Baseline;
                }
            }
            current.Add(c);
        }
        Flush();
        return Regroup(lines, tables, pageWidth);
    }

    /// <summary>Repairs lines geometrically: scripts go to the line they sit on, pieces of one line are joined.</summary>
    static List<LayoutLine> Regroup(List<LayoutLine> input, List<Rect> tables, double pageWidth)
    {
        var lines = input.ToList();
        bool InTable(Rect r) => tables.Any(t => t.InsetBy(-1, -2).Contains(r.Center));
        var moved = new List<(PageChar Char, int Host)>();
        for (int k = 0; k < lines.Count; k++)
        {
            if (lines[k].IsRotated) continue;
            var line = lines[k];
            var keep = new List<PageChar>();
            foreach (var c in line.Chars)
            {
                bool inBand = c.Center.Y > line.Baseline - line.Size * 0.45 && c.Center.Y < line.Baseline + line.Size * 1.0;
                if (c.IsSpace || inBand || c.Size >= line.Size * 0.85) { keep.Add(c); continue; }
                var candidates = Enumerable.Range(0, lines.Count).Where(j => j != k && !lines[j].IsRotated && lines[j].Size > c.Size * 1.1
                    && c.Center.Y > lines[j].Baseline - lines[j].Size * 0.45 && c.Center.Y < lines[j].Baseline + lines[j].Size * 1.0
                    && c.Rect.MidX > lines[j].MinX - lines[j].Size * 1.5 && c.Rect.MidX < lines[j].MaxX + lines[j].Size * 1.5).ToList();
                if (candidates.Count == 0) { keep.Add(c); continue; }
                double Distance(int j) => Math.Max(Math.Max(lines[j].MinX - c.Rect.MidX, c.Rect.MidX - lines[j].MaxX), 0);
                int host = candidates.OrderBy(Distance).ThenBy(j => Math.Abs(lines[j].Baseline - c.Baseline)).First();
                moved.Add((c, host));
            }
            if (keep.Count != line.Chars.Count && MakeLine(TrimSpaces(keep)) is { } rebuilt) lines[k] = rebuilt;
        }
        foreach (var (c, host) in moved)
        {
            var chars = lines[host].Chars.ToList();
            int at = chars.FindIndex(x => !x.IsSpace && x.Rect.MidX > c.Rect.MidX);
            chars.Insert(at < 0 ? chars.Count : at, c);
            if (MakeLine(chars) is { } rebuilt) lines[host] = rebuilt;
        }
        lines.RemoveAll(l => l.Chars.All(c => c.IsSpace));
        bool merged = true;
        while (merged)
        {
            merged = false;
            var order = Enumerable.Range(0, lines.Count).OrderBy(i => lines[i].Baseline).ToList();
            double window = (lines.Count > 0 ? lines.Max(l => l.Size) : 10) * 0.75;
            var removed = new HashSet<int>();
            for (int p = 0; p < order.Count; p++)
            {
                int a = order[p];
                if (removed.Contains(a)) continue;
                var candidates = new List<int>();
                for (int q = p - 1; q >= 0 && lines[a].Baseline - lines[order[q]].Baseline < window; q--) candidates.Add(order[q]);
                for (int q = p + 1; q < order.Count && lines[order[q]].Baseline - lines[a].Baseline < window; q++) candidates.Add(order[q]);
                foreach (var b in candidates)
                {
                    if (removed.Contains(b)) continue;
                    if (MergePieces(lines[a], lines[b], tables, pageWidth) is not { } line) continue;
                    lines[a] = line;
                    removed.Add(b);
                    merged = true;
                }
            }
            if (removed.Count > 0) lines = lines.Where((_, i) => !removed.Contains(i)).ToList();
        }
        return JoinAcrossInnerGaps(ReuniteByDrawingOrder(lines), InTable);
    }

    /// <summary>Two pieces on one baseline with a wide gap are one line when the lines above and below run across it.</summary>
    static List<LayoutLine> JoinAcrossInnerGaps(List<LayoutLine> input, Func<Rect, bool> inTable)
    {
        var lines = input.ToList();
        var removed = new HashSet<int>();
        var order = Enumerable.Range(0, lines.Count).Where(i => !lines[i].IsRotated).OrderBy(i => lines[i].MinX).ToList();
        foreach (var a in order)
        {
            if (removed.Contains(a)) continue;
            foreach (var b in order)
            {
                if (b == a || removed.Contains(b)) continue;
                var l = lines[a];
                var r = lines[b];
                double size = Math.Max(l.Size, r.Size);
                double gap = r.MinX - l.MaxX;
                if (!(gap > 0 && gap < size * 6 && Math.Abs(l.Baseline - r.Baseline) < size * 0.3 && Math.Abs(l.Size - r.Size) < size * 0.2 && !inTable(l.Rect) && !inTable(r.Rect))) continue;
                bool Spans(LayoutLine line) => Math.Abs(line.Size - size) < size * 0.2 && line.MinX <= l.MaxX + 1 && line.MaxX >= r.MinX - 1;
                bool above = Enumerable.Range(0, lines.Count).Any(k => !removed.Contains(k) && k != a && k != b && lines[k].Baseline > l.Baseline + size * 0.5 && lines[k].Baseline < l.Baseline + size * 1.8 && Spans(lines[k]));
                bool below = Enumerable.Range(0, lines.Count).Any(k => !removed.Contains(k) && k != a && k != b && lines[k].Baseline < l.Baseline - size * 0.5 && lines[k].Baseline > l.Baseline - size * 1.8 && Spans(lines[k]));
                if (!above || !below) continue;
                if (MakeLine([.. l.Chars, SpaceAfter(l.Chars[^1], l.MaxX, gap), .. r.Chars]) is { } line)
                {
                    lines[a] = line;
                    removed.Add(b);
                }
            }
        }
        return lines.Where((_, i) => !removed.Contains(i)).ToList();
    }

    /// <summary>A short stretch of formula drawn between two parts of a line is that line's.</summary>
    static List<LayoutLine> ReuniteByDrawingOrder(List<LayoutLine> input)
    {
        var lines = input.ToList();
        for (int round = 0; round < 3; round++)
        {
            var drawn = new List<(int Order, int Line, int Char, PageChar C)>();
            for (int l = 0; l < lines.Count; l++)
            {
                if (lines[l].IsRotated) continue;
                for (int i = 0; i < lines[l].Chars.Count; i++)
                {
                    var c = lines[l].Chars[i];
                    if (!c.IsSpace && c.Glyphs.Count > 0) drawn.Add((c.Glyphs[0], l, i, c));
                }
            }
            drawn.Sort((x, y) => x.Order.CompareTo(y.Order));
            var stretches = new List<(int Line, List<(int Order, int Line, int Char, PageChar C)> Items)>();
            foreach (var item in drawn)
            {
                if (stretches.Count > 0 && stretches[^1].Line == item.Line) stretches[^1].Items.Add(item);
                else stretches.Add((item.Line, [item]));
            }
            var movedChars = new Dictionary<int, List<PageChar>>();
            var taken = new Dictionary<int, HashSet<int>>();
            for (int s = 0; s < stretches.Count; s++)
            {
                int host = stretches[s].Line;
                double size = lines[host].Size;
                var last = stretches[s].Items[^1];
                int limit = Math.Max(s + 2, Math.Min(s + 5, stretches.Count));
                for (int e = s + 2; e < limit; e++)
                {
                    if (stretches[e].Line != host) continue;
                    var first = stretches[e].Items[0];
                    if (first.Order - last.Order > 40) break;
                    var between = stretches.GetRange(s + 1, e - s - 1);
                    bool ok = true;
                    foreach (var stretch in between)
                    {
                        var chars = stretch.Items.Select(i => i.C).ToList();
                        int math = chars.Count(c => c.IsMath), letters = chars.Count(c => StartsWithLetter(c.Text));
                        if (!(chars.Count <= 8 && stretch.Line != host && (math * 2 >= chars.Count || letters == 0)
                              && (!taken.TryGetValue(stretch.Line, out var t) || !stretch.Items.Any(i => t.Contains(i.Char)))
                              && chars.All(c => Math.Abs(c.Center.Y - lines[host].Baseline) < size * 2.2 && c.Rect.MidX > last.C.Rect.MinX - size * 3 && c.Rect.MidX < first.C.Rect.MaxX + size * 3)))
                        {
                            ok = false;
                            break;
                        }
                    }
                    if (!ok) break;
                    foreach (var stretch in between)
                        foreach (var item in stretch.Items)
                        {
                            var c = item.C.Clone();
                            c.IsMath = true;
                            (movedChars.TryGetValue(host, out var list) ? list : movedChars[host] = []).Add(c);
                            (taken.TryGetValue(stretch.Line, out var set) ? set : taken[stretch.Line] = []).Add(item.Char);
                        }
                    s = e - 1;
                    break;
                }
            }
            if (movedChars.Count == 0) break;
            var rebuilt = new List<LayoutLine>();
            for (int l = 0; l < lines.Count; l++)
            {
                var chars = lines[l].Chars.ToList();
                if (taken.TryGetValue(l, out var gone)) chars = chars.Where((_, i) => !gone.Contains(i)).ToList();
                if (movedChars.TryGetValue(l, out var add)) chars.AddRange(add);
                if (!movedChars.ContainsKey(l) && !taken.ContainsKey(l)) rebuilt.Add(lines[l]);
                else if (MakeLine(TrimSpaces(chars)) is { } line) rebuilt.Add(line);
            }
            lines = rebuilt;
        }
        return lines;
    }

    /// <summary>l and r as one line, when r is a piece of the same line to the right of l (or interleaved with it).</summary>
    static LayoutLine? MergePieces(LayoutLine l, LayoutLine r, List<Rect> tables, double pageWidth)
    {
        bool InTable(Rect rect) => tables.Any(t => t.InsetBy(-1, -2).Contains(rect.Center));
        static bool FormulaPiece(LayoutLine line, LayoutLine other) =>
            (line.VisibleCount <= 8 && (line.MathRatio >= 0.5 || line.Chars.Any(c => c.IsScript || c.Size < line.Size * 0.85)))
            || (line.VisibleCount <= 12 && line.Size < other.Size * 0.85);
        bool piece = FormulaPiece(l, r) || FormulaPiece(r, l);
        var host = l.VisibleCount >= r.VisibleCount ? l : r;
        bool small = Math.Min(l.Size, r.Size) < Math.Max(l.Size, r.Size) * 0.85;
        double baselineTolerance = piece ? host.Size * (small ? 0.95 : 0.7) : Math.Min(l.Size, r.Size) * 0.3;
        if (l.IsRotated || r.IsRotated || r.MinX < l.MinX || Math.Abs(l.Baseline - r.Baseline) >= baselineTolerance
            || !(piece || Math.Abs(l.Size - r.Size) < Math.Max(l.Size, r.Size) * 0.2)) return null;
        double gap = r.MinX - l.MaxX;
        if (InTable(l.Rect) || InTable(r.Rect)) return null;
        double lMain = l.Chars.Where(c => !c.IsSpace && c.Size >= l.Size * 0.85).Select(c => c.Rect.MaxX).DefaultIfEmpty(l.MaxX).Max();
        double rMain = r.Chars.Where(c => !c.IsSpace && c.Size >= r.Size * 0.85).Select(c => c.Rect.MinX).DefaultIfEmpty(r.MinX).Min();
        bool scriptsUnder = piece && small && rMain - lMain > -Math.Min(l.Size, r.Size) * 0.5;
        if (gap < -Math.Min(l.Size, r.Size) * 0.5 && !scriptsUnder)
        {
            if (!(Math.Abs(l.Baseline - r.Baseline) < Math.Min(l.Size, r.Size) * 0.3 && Math.Abs(l.Size - r.Size) < Math.Max(l.Size, r.Size) * 0.2)) return null;
            var lGlyphs = l.Chars.Where(c => !c.IsSpace && c.Size >= l.Size * 0.85).Select(c => c.Rect).ToList();
            int collisions = r.Chars.Count(c => !c.IsSpace && c.Size >= r.Size * 0.85
                && lGlyphs.Any(g => g.MinX < c.Rect.MaxX - c.Rect.W * 0.4 && g.MaxX > c.Rect.MinX + c.Rect.W * 0.4));
            if (!(collisions <= Math.Max(1, r.VisibleCount / 10) && r.MinX < l.MaxX && r.MaxX > l.MinX)) return null;
        }
        else if (!(rMain - lMain > -Math.Min(l.Size, r.Size) * 0.5 && gap < Math.Max(l.Size, r.Size) * 1.0)) return null;
        if (l.InkRect.W > pageWidth * 0.3 && r.InkRect.W > pageWidth * 0.3) return null;
        bool wordGap = gap > Math.Min(l.Size, r.Size) * 0.15;
        return MakeLine(wordGap ? [.. l.Chars, SpaceAfter(l.Chars[^1], l.MaxX, Math.Max(gap, 0)), .. r.Chars] : [.. l.Chars, .. r.Chars]);
    }

    // MARK: Reading order

    /// <summary>Lines in reading order: bands divided by lines across gutters, each band column by column.</summary>
    static List<LayoutLine> ReadingOrder(List<LayoutLine> lines)
    {
        var flat = Enumerable.Range(0, lines.Count).Where(i => !lines[i].IsRotated).ToList();
        var rotated = Enumerable.Range(0, lines.Count).Where(i => lines[i].IsRotated).ToList();
        int TopDown(int a, int b)
        {
            var la = lines[a];
            var lb = lines[b];
            if (Math.Abs(la.Baseline - lb.Baseline) > Math.Min(la.Size, lb.Size) * 0.3) return lb.Baseline.CompareTo(la.Baseline);
            return la.MinX.CompareTo(lb.MinX);
        }
        List<int> Sorted(IEnumerable<int> source) { var l = source.ToList(); l.Sort(TopDown); return l; }
        if (flat.Count <= 3) return Sorted(flat).Concat(rotated).Select(i => lines[i]).ToList();
        double minX = flat.Min(i => lines[i].MinX), maxX = flat.Max(i => lines[i].MaxX);
        var gutters = Gutters(flat.Select(i => lines[i]).ToList(), minX, maxX - minX);
        if (gutters.Count == 0) return Sorted(flat).Concat(rotated).Select(i => lines[i]).ToList();
        var spanning = new List<int>();
        var column = new Dictionary<int, int>();
        foreach (var k in flat)
        {
            var line = lines[k];
            bool crosses = gutters.Any(g => line.MinX < g.Lower - line.Size && line.MaxX > g.Upper + line.Size);
            if (crosses) spanning.Add(k);
            else
            {
                double center = (line.MinX + line.MaxX) / 2;
                column[k] = gutters.Count(g => (g.Lower + g.Upper) / 2 < center);
            }
        }
        spanning = Sorted(spanning);
        var separators = spanning.Select(k => lines[k].Rect.MidY).ToList();
        var cells = new Dictionary<(int, int), List<int>>();
        foreach (var (k, c) in column)
        {
            int band = separators.Count(s => s > lines[k].Rect.MidY);
            (cells.TryGetValue((band, c), out var list) ? list : cells[(band, c)] = []).Add(k);
        }
        var order = new List<int>();
        for (int band = 0; band <= spanning.Count; band++)
        {
            for (int c = 0; c <= gutters.Count; c++)
                if (cells.TryGetValue((band, c), out var list)) order.AddRange(Sorted(list));
            if (band < spanning.Count) order.Add(spanning[band]);
        }
        return order.Concat(rotated).Select(i => lines[i]).ToList();
    }

    /// <summary>Column gutters: strips no narrow line crosses, 5 pt to 15% of the width wide, with narrow lines on both sides.</summary>
    static List<Gap> Gutters(List<LayoutLine> lines, double minX, double width)
    {
        if (width <= 100) return [];
        var narrow = lines.Where(l => l.InkRect.W < width * 0.55).ToList();
        if (narrow.Count < 6) return [];
        int bins = (int)Math.Ceiling(width) + 1;
        var coverage = new int[bins];
        foreach (var line in narrow)
        {
            int a = Math.Max(0, (int)Math.Floor(line.MinX - minX)), b = Math.Min(bins - 1, (int)Math.Ceiling(line.MaxX - minX));
            for (int x = a; x <= b; x++) coverage[x]++;
        }
        int tolerance = Math.Max(0, narrow.Count / 60);
        var result = new List<Gap>();
        int pos = (int)(width * 0.15);
        while (pos < (int)(width * 0.85))
        {
            if (coverage[pos] > tolerance) { pos++; continue; }
            int lo = pos, hi = pos;
            while (lo > 0 && coverage[lo - 1] <= tolerance) lo--;
            while (hi + 1 < bins && coverage[hi + 1] <= tolerance) hi++;
            pos = hi + 1;
            var strip = new Gap(minX + lo, minX + hi + 1);
            if (strip.Upper - strip.Lower < 5 || strip.Upper - strip.Lower > width * 0.15) continue;
            var left = narrow.Where(l => l.MaxX <= strip.Lower + 1).ToList();
            var right = narrow.Where(l => l.MinX >= strip.Upper - 1).ToList();
            if (left.Count < 3 || right.Count < 3) continue;
            double l0 = left.Min(l => l.Rect.MinY), l1 = left.Max(l => l.Rect.MaxY);
            double r0 = right.Min(l => l.Rect.MinY), r1 = right.Max(l => l.Rect.MaxY);
            double overlap = Math.Min(l1, r1) - Math.Max(l0, r0);
            if (overlap <= Math.Min(l1 - l0, r1 - r0) * 0.3) continue;
            result.Add(strip);
        }
        return result;
    }

    /// <summary>Characters clearly smaller than the line's text are sub- or superscripts: part of a formula.</summary>
    static LayoutLine MarkScripts(LayoutLine input)
    {
        var line = input.Clone();
        var chars = line.Chars.Select(c => c.Clone()).ToList();
        for (int i = 0; i < chars.Count; i++)
            if (!chars[i].IsSpace && chars[i].Size < line.Size * 0.95 && (chars[i].IsScript || Math.Abs(chars[i].Baseline - line.Baseline) > line.Size * 0.12))
                chars[i].IsMath = true;
        for (int i = 0; i < chars.Count; i++)
        {
            if (chars[i].IsSpace || chars[i].IsMath || !StartsWithLetter(chars[i].Text)) continue;
            var next = i + 1 < chars.Count ? chars[i + 1] : null;
            if (next != null && next.IsMath && next.Size < line.Size * 0.95 && (next.IsScript || Math.Abs(next.Baseline - line.Baseline) > line.Size * 0.12)
                && next.Rect.MinX - chars[i].Rect.MaxX < line.Size * 0.3)
            {
                int start = i;
                while (start > 0 && i - start < 5 && !chars[start - 1].IsSpace && !chars[start - 1].IsMath && StartsWithLetter(chars[start - 1].Text)
                       && chars[start].Rect.MinX - chars[start - 1].Rect.MaxX < line.Size * 0.15) start--;
                bool isWord = start == 0 || chars[start - 1].IsSpace || chars[start - 1].IsMath || !StartsWithLetter(chars[start - 1].Text);
                if (isWord) for (int k = start; k <= i; k++) chars[k].IsMath = true;
            }
        }
        for (int i = 0; i < chars.Count; i++)
        {
            if (!chars[i].Text.EnumerateRunes().Any(r => r.Value is >= 0x02C6 and <= 0x02DD or >= 0x0300 and <= 0x036F or 0x00AF or 0x00A8)) continue;
            chars[i].IsMath = true;
            var accent = chars[i].Rect;
            for (int k = 0; k < chars.Count; k++)
            {
                if (k == i || chars[k].IsSpace || !StartsWithLetter(chars[k].Text)) continue;
                double overlap = Math.Min(chars[k].Rect.MaxX, accent.MaxX) - Math.Max(chars[k].Rect.MinX, accent.MinX);
                if (overlap > Math.Min(accent.W, chars[k].Rect.W) * 0.3) chars[k].IsMath = true;
            }
        }
        for (int i = 0; i + 1 < chars.Count; i++)
        {
            if (chars[i].IsMath || chars[i].IsSpace || !StartsWithLetter(chars[i].Text)) continue;
            var next = chars[i + 1];
            var before = i > 0 ? chars[i - 1] : null;
            bool alone = before == null || before.IsSpace || !StartsWithLetterOrDigit(before.Text) && before.Text.Length > 0;
            if (alone && next.IsMath && StartsWithLetter(next.Text) && Math.Abs(next.Size - chars[i].Size) < chars[i].Size * 0.1
                && next.Rect.MinX - chars[i].Rect.MaxX < chars[i].Size * 0.15) chars[i].IsMath = true;
        }
        for (int pass = 0; pass < 2; pass++)
        {
            int w = 0;
            while (w < chars.Count)
            {
                if (chars[w].IsSpace || chars[w].IsMath || !StartsWithLetter(chars[w].Text)) { w++; continue; }
                int e = w;
                while (e + 1 < chars.Count && !chars[e + 1].IsSpace && !chars[e + 1].IsMath && StartsWithLetter(chars[e + 1].Text)) e++;
                if (MathDetector.OperatorNames.Contains(string.Concat(chars.Skip(w).Take(e - w + 1).Select(c => c.Text))))
                {
                    var before = chars.Take(w).LastOrDefault(c => !c.IsSpace);
                    var after = chars.Skip(e + 1).FirstOrDefault(c => !c.IsSpace);
                    if (before?.IsMath == true || after?.IsMath == true || after?.Text is "(" or "[")
                        for (int k = w; k <= e; k++) chars[k].IsMath = true;
                }
                w = e + 1;
            }
        }
        const string operators = "=+-−–×·*/<>≤≥≈∈()[]{}|,";
        int idx = 0;
        while (idx < chars.Count)
        {
            if (!chars[idx].IsMath) { idx++; continue; }
            int j = idx + 1;
            while (j < chars.Count && !chars[j].IsMath && (chars[j].IsSpace || (chars[j].Text.Length == 1 && operators.Contains(chars[j].Text[0])))) j++;
            if (j < chars.Count && j > idx + 1 && chars[j].IsMath && (chars.Skip(idx + 1).Take(j - idx - 1).Any(c => !c.IsSpace) || j - idx <= 2))
                for (int k = idx + 1; k < j; k++) chars[k].IsMath = true;
            idx = j;
        }
        idx = 0;
        while (idx < chars.Count)
        {
            if (!chars[idx].IsMath) { idx++; continue; }
            int j = idx, depth = 0;
            while (j < chars.Count && chars[j].IsMath)
            {
                depth += chars[j].Text == "(" ? 1 : chars[j].Text == ")" ? -1 : 0;
                j++;
            }
            int extended = 0;
            if (depth == 0 && j < chars.Count && chars[j].Text == "(" && chars[j].Rect.MinX - chars[j - 1].Rect.MaxX < chars[j].Size * 0.2
                && chars.Skip(j).Take(8).Any(c => c.Text == ")"))
            {
                depth = 1;
                chars[j].IsMath = true;
                j++;
            }
            while (depth > 0 && j < chars.Count && !chars[j].IsSpace && extended < 8)
            {
                depth += chars[j].Text == "(" ? 1 : chars[j].Text == ")" ? -1 : 0;
                chars[j].IsMath = true;
                j++;
                extended++;
            }
            idx = j + 1;
        }
        BalanceBrackets(chars);
        line.Chars = chars;
        return line;
    }

    /// <summary>A bracket at the edge of a formula belongs to it only when its partner does too.</summary>
    static void BalanceBrackets(List<PageChar> chars)
    {
        var pairs = new[] { ("(", ")"), ("[", "]"), ("{", "}") };
        int i = 0;
        while (i < chars.Count)
        {
            if (!chars[i].IsMath || chars[i].IsSpace) { i++; continue; }
            int j = i;
            while (j + 1 < chars.Count && chars[j + 1].IsMath) j++;
            bool changed = true;
            while (changed && i <= j)
            {
                changed = false;
                var span = chars.Skip(i).Take(j - i + 1).Where(c => !c.IsSpace).Select(c => c.Text).ToList();
                foreach (var (open, close) in pairs)
                {
                    int opens = span.Count(t => t == open), closes = span.Count(t => t == close);
                    if (closes > opens && chars[j].Text == close) { chars[j].IsMath = false; j--; changed = true; }
                    else if (opens > closes && chars[i].Text == open) { chars[i].IsMath = false; i++; changed = true; }
                    while (i <= j && chars[j].IsSpace) { chars[j].IsMath = false; j--; }
                    while (i <= j && chars[i].IsSpace) { chars[i].IsMath = false; i++; }
                    if (changed) break;
                }
            }
            i = j + 2;
        }
    }

    static List<PageChar> TrimSpaces(List<PageChar> chars)
    {
        var result = new List<PageChar>();
        foreach (var c in chars)
        {
            if (c.IsSpace && (result.Count == 0 || result[^1].IsSpace)) continue;
            result.Add(c);
        }
        while (result.Count > 0 && result[^1].IsSpace) result.RemoveAt(result.Count - 1);
        return result;
    }

    /// <summary>Characters (left to right) with a space wherever one starts clear of everything before it by a word space.</summary>
    static List<PageChar> Respaced(List<PageChar> chars)
    {
        if (chars.Count <= 1) return chars;
        var gaps = new List<double>();
        for (int k = 0; k + 1 < chars.Count; k++)
        {
            var a = chars[k];
            var b = chars[k + 1];
            if (a.Run != b.Run || a.Run == null) continue;
            double gap = (b.Rect.MinX - a.Rect.MaxX) / Math.Max(a.Size, 1);
            if (gap > -0.2 && gap < 0.5) gaps.Add(gap);
        }
        gaps.Sort();
        double tracking = gaps.Count >= 4 && gaps[gaps.Count / 2] > 0.04 ? gaps[gaps.Count / 2] : 0;
        var result = new List<PageChar> { chars[0] };
        double reach = chars[0].Rect.MaxX;
        foreach (var c in chars.Skip(1))
        {
            var previous = result[^1];
            double gap = c.Rect.MinX - reach;
            if (gap > Math.Min(previous.Size, c.Size) * (0.15 + tracking))
            {
                var space = previous.Clone();
                space.Text = " ";
                space.IsSpace = true;
                space.IsMath = previous.IsMath && c.IsMath;
                space.Glyphs = [];
                space.Run = null;
                space.Ink = null;
                space.Link = null;
                space.Rect = new Rect(reach, previous.Rect.MinY, gap, previous.Rect.H);
                result.Add(space);
            }
            result.Add(c);
            reach = Math.Max(reach, c.Rect.MaxX);
        }
        return result;
    }

    public static LayoutLine? MakeLine(List<PageChar> unordered)
    {
        var chars = unordered;
        if (chars.Count(c => c.IsRotated) * 2 <= chars.Count)
            chars = Respaced(chars.Where(c => !c.IsSpace).Select((c, i) => (c, i)).OrderBy(x => x.c.Rect.MinX).ThenBy(x => x.i).Select(x => x.c).ToList());
        var visible = chars.Where(c => !c.IsSpace).ToList();
        if (visible.Count == 0) return null;
        var first = visible[0];
        var sizes = visible.Select(c => Math.Round(c.Size * 4) / 4).Distinct().OrderByDescending(s => s).ToList();
        double mainSize = sizes.Cast<double?>().FirstOrDefault(s => visible.Count(c => Math.Abs(c.Size - s!.Value) < s.Value * 0.1) * 4 >= visible.Count) ?? (sizes.Count > 0 ? sizes[^1] : first.Size);
        var reference = visible.Where(c => Math.Abs(c.Size - mainSize) < mainSize * 0.1).ToList();
        var ink = first.Rect;
        foreach (var c in visible.Skip(1)) ink = ink.Union(c.Rect);
        var sizeCounts = new Dictionary<double, int>();
        var fontCounts = new Dictionary<FontInfo, int>();
        foreach (var c in reference)
        {
            var key = Math.Round(c.Size * 4) / 4;
            sizeCounts[key] = sizeCounts.GetValueOrDefault(key) + 1;
            fontCounts[c.Font] = fontCounts.GetValueOrDefault(c.Font) + 1;
        }
        double size = sizeCounts.OrderByDescending(kv => kv.Value).ThenByDescending(kv => kv.Key).First().Key;
        var main = reference.Where(c => Math.Abs(c.Size - size) < size * 0.1).ToList();
        var baselines = (main.Count == 0 ? reference : main).Select(c => c.Baseline).OrderBy(b => b).ToList();
        var font = fontCounts.MaxBy(kv => kv.Value).Key;
        var colorCounts = new Dictionary<RGBColor, int>();
        foreach (var c in visible) if (StartsWithLetter(c.Text) && c.Link == null) colorCounts[c.Color] = colorCounts.GetValueOrDefault(c.Color) + 1;
        if (colorCounts.Count == 0) foreach (var c in visible) if (StartsWithLetter(c.Text)) colorCounts[c.Color] = colorCounts.GetValueOrDefault(c.Color) + 1;
        if (colorCounts.Count == 0) foreach (var c in visible) colorCounts[c.Color] = colorCounts.GetValueOrDefault(c.Color) + 1;
        var color = colorCounts.MaxBy(kv => kv.Value).Key;
        return new LayoutLine
        {
            Chars = chars, InkRect = ink, Baseline = baselines[baselines.Count / 2], Size = Math.Max(size, 1), Font = font, Color = color,
            IsRotated = visible.Count(c => c.IsRotated) * 2 > visible.Count,
        };
    }
}
