using System.Globalization;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Translate.Layout;

public sealed partial class LayoutAnalyzer
{
    // MARK: Regions

    /// <summary>Tables from their rules: horizontal rules of (nearly) the same extent, two or more stacked.</summary>
    static List<Rect> TableFrames(List<Rect> rules, List<LayoutLine> lines)
    {
        var groups = new List<List<Rect>>();
        foreach (var rule in rules.OrderByDescending(r => r.MaxY))
        {
            var g = groups.FirstOrDefault(group => Math.Abs(group[0].MinX - rule.MinX) < 12 && Math.Abs(group[0].MaxX - rule.MaxX) < 12);
            if (g != null) g.Add(rule); else groups.Add([rule]);
        }
        var frames = new List<Rect>();
        foreach (var group in groups.Where(g => g.Count >= 2))
        {
            bool Separated(Rect upper, Rect lower) => lines.Any(line =>
            {
                var c = line.Rect.Center;
                return c.Y < upper.MinY && c.Y > lower.MaxY && c.X > upper.MinX - 4 && c.X < upper.MaxX + 4 && (IsCaptionStart(line.Text) || ProseWords(line) >= 6);
            });
            int start = 0;
            for (int k = 1; k <= group.Count; k++)
            {
                if (k == group.Count || group[k - 1].MinY - group[k].MaxY > 400 || Separated(group[k - 1], group[k]))
                {
                    if (k - start >= 2)
                    {
                        var top = group[start];
                        var bottom = group[k - 1];
                        var frame = new Rect(Math.Min(top.MinX, bottom.MinX), bottom.MinY, Math.Max(top.MaxX, bottom.MaxX) - Math.Min(top.MinX, bottom.MinX), top.MaxY - bottom.MinY);
                        if (frame.H > 8) frames.Add(frame);
                    }
                    start = k;
                }
            }
        }
        var merged = new List<Rect>();
        foreach (var frame in frames.OrderByDescending(f => f.Area))
        {
            int k = merged.FindIndex(m => m.InsetBy(-2, -2).Intersects(frame));
            if (k >= 0) merged[k] = merged[k].Union(frame); else merged.Add(frame);
        }
        return merged;
    }

    /// <summary>A caption caught between a table's rules is not part of the table.</summary>
    static Rect TrimCaptions(Rect frame, List<LayoutLine> lines)
    {
        foreach (var line in lines)
        {
            if (!IsCaptionStart(line.Text) || IsAlgorithmStart(line.Text) || !frame.Contains(line.Rect.Center)) continue;
            if (line.Rect.MidY < frame.MidY)
                frame = new Rect(frame.MinX, line.Rect.MaxY + 1, frame.W, Math.Max(frame.MaxY - line.Rect.MaxY - 1, 0));
            else
            {
                var last = line;
                while (lines.FirstOrDefault(next =>
                {
                    double drop = last.Baseline - next.Baseline;
                    return drop > last.Size * 0.5 && drop < last.Size * 1.7 && Math.Abs(next.Size - last.Size) < last.Size * 0.1
                           && next.MinX < last.MaxX && next.MaxX > last.MinX && !IsCaptionStart(next.Text);
                }) is { } next) last = next;
                frame = new Rect(frame.MinX, frame.MinY, frame.W, Math.Max(last.Rect.MinY - 1 - frame.MinY, 0));
            }
        }
        return frame;
    }

    /// <summary>Rules around running text do not make a table: tables have several cells per row and short lines.</summary>
    bool IsTable(Rect frame, List<LayoutLine> lines, List<GraphicMark> marks)
    {
        var inside = lines.Where(l => frame.InsetBy(-1, -2).Contains(l.Rect.Center)).ToList();
        if (inside.Count < 2) return false;
        if (inside.Any(l => l.Size >= BodySize * 1.4 && TextWords(l) >= 2)) return false;
        var bars = marks.Where(m => m.Kind == GraphicMark.MarkKind.Fill && !m.IsWhite && frame.InsetBy(-1, -1).Contains(m.Rect.Center)
                                    && m.Rect.H > BodySize * 2.2 && m.Rect.W > 3 && m.Rect.W < frame.W * 0.3).ToList();
        if (bars.Count >= 3) return false;
        int chars = inside.Sum(l => l.VisibleCount);
        int math = inside.Sum(l => l.Chars.Count(c => c.IsMath && c.Text.Length > 0 && !char.IsDigit(c.Text[0]) && !".,×·-−".Contains(c.Text[0])));
        if (math > chars * 0.4) return false;
        int prose = inside.Where(l => TextWords(l) >= 6).Sum(l => l.VisibleCount);
        if (prose > chars * 0.5) return false;
        var rows = new Dictionary<double, int>();
        foreach (var line in inside)
        {
            var key = Math.Round(line.Baseline / 3);
            rows[key] = rows.GetValueOrDefault(key) + 1 + ColumnGaps(line);
        }
        int wide = rows.Values.Count(v => v >= 2);
        return wide >= 2 || (inside.Count >= 6 && wide >= 1);
    }

    static int ColumnGaps(LayoutLine line)
    {
        var visible = line.Chars.Where(c => !c.IsSpace).ToList();
        int count = 0;
        for (int i = 0; i + 1 < visible.Count; i++) if (visible[i + 1].Rect.MinX - visible[i].Rect.MaxX > line.Size * 0.8) count++;
        return count;
    }

    /// <summary>Areas covered by drawings: images, curves, filled shapes and their axes, plus the short labels around them.</summary>
    List<Rect> FigureRegions(List<GraphicMark> marks, List<LayoutLine> lines, List<Rect> tables, Rect page)
    {
        var seeds = new List<Rect>();
        var minor = new List<Rect>();
        foreach (var mark in marks)
        {
            var r = mark.Rect;
            if (tables.Any(t => t.InsetBy(-2, -2).Contains(r.Center))) continue;
            bool thin = r.W < 2.5 || r.H < 2.5;
            bool boxy = !mark.HasCurves && mark.SegmentCount <= 5;
            switch (mark.Kind)
            {
                case GraphicMark.MarkKind.Image:
                    if (r.W > 4 && r.H > 4) seeds.Add(r);
                    break;
                case GraphicMark.MarkKind.Shading:
                    if (!IsBackground(r, lines, true)) seeds.Add(r);
                    break;
                default:
                    if (thin) { if (r.W < page.W * 0.6) minor.Add(r); }
                    else if (!IsBackground(r, lines, boxy)) seeds.Add(r);
                    else if (boxy && TextInside(r, lines) < 40) minor.Add(r);
                    break;
            }
        }
        if (seeds.Count == 0) return [];
        var all = seeds.Concat(minor).ToList();
        var parent = Enumerable.Range(0, all.Count).ToArray();
        int Find(int x)
        {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        var sorted = Enumerable.Range(0, all.Count).OrderBy(i => all[i].MinX).ToList();
        for (int n = 0; n < sorted.Count; n++)
        {
            int a = sorted[n];
            var ra = all[a].InsetBy(-4, -4);
            for (int m = n + 1; m < sorted.Count; m++)
            {
                int b = sorted[m];
                if (all[b].MinX > ra.MaxX) break;
                if (ra.Intersects(all[b])) parent[Find(a)] = Find(b);
            }
        }
        var clusters = new Dictionary<int, (Rect Rect, int Seeds)>();
        for (int i = 0; i < all.Count; i++)
        {
            int root = Find(i);
            var entry = clusters.TryGetValue(root, out var e) ? e : (all[i], 0);
            clusters[root] = (entry.Item1.Union(all[i]), entry.Item2 + (i < seeds.Count ? 1 : 0));
        }
        var regions = clusters.Values.Where(c => c.Seeds > 0 && c.Rect.Area > 150).Select(c => c.Rect).ToList();
        foreach (var mark in clusters.Values.Where(c => c.Seeds > 0 && c.Rect.Area <= 150).Select(c => c.Rect))
        {
            int k = regions.FindIndex(r => r.Area > 2000 && r.InsetBy(-30, -30).Intersects(mark));
            if (k >= 0) regions[k] = regions[k].Union(mark);
        }
        double reach = BodySize * 1.4;
        for (int round = 0; round < 3; round++)
        {
            bool changed = false;
            for (int k = 0; k < regions.Count; k++)
            {
                foreach (var line in lines)
                {
                    var r = line.Rect;
                    if (regions[k].Contains(r) || IsCaptionStart(line.Text) || (ContinuesText(line, lines) && !regions[k].Contains(r.Center))) continue;
                    bool inside = regions[k].Contains(r.Center);
                    bool near = regions[k].InsetBy(-reach, -reach).Intersects(r);
                    bool boxed = line.WordCount <= 4 && marks.Any(m => m.Kind != GraphicMark.MarkKind.Image && !m.IsWhite && m.Rect.Intersection(r).Area > r.Area * 0.25 && m.Rect.H > line.Size);
                    bool within = r.MinX >= regions[k].MinX - 2 && r.MaxX <= regions[k].MaxX + 2;
                    bool small = boxed || (line.Size < BodySize * 0.96 && (line.WordCount <= 4 || (within && (line.WordCount <= 6 || (line.Size < BodySize * 0.9 && line.WordCount <= 8)))));
                    int kk = k;
                    bool bridging = near && line.WordCount <= 4 && Enumerable.Range(0, regions.Count).Any(j =>
                        j != kk && regions[j].InsetBy(-reach, -reach).Intersects(r) && Math.Min(regions[j].MaxY, regions[kk].MaxY) > Math.Max(regions[j].MinY, regions[kk].MinY));
                    bool title = line.WordCount <= 4 && r.MinX >= regions[k].MinX - 2 && r.MaxX <= regions[k].MaxX + 2 && !EndsParagraph(line, lines);
                    if (inside || bridging || (near && (small || title)))
                    {
                        var grown = regions[k].Union(r);
                        if (grown != regions[k])
                        {
                            regions[k] = grown;
                            changed = true;
                        }
                    }
                }
            }
            if (!changed) break;
        }
        regions.RemoveAll(region => lines.Count(l => region.Contains(l.Rect.Center) && l.WordCount >= 8 && Math.Abs(l.Size - BodySize) < 0.6) >= 3);
        var merged = new List<Rect>();
        foreach (var region in regions.OrderByDescending(r => r.Area))
        {
            int k = merged.FindIndex(m => m.Intersects(region));
            if (k >= 0) merged[k] = merged[k].Union(region); else merged.Add(region);
        }
        return merged;
    }

    /// <summary>Column gutters of a table: strips at least half an em wide that no glyph touches, text on both sides in two rows.</summary>
    static List<Gap> ColumnGutters(Rect table, List<LayoutLine> lines)
    {
        var inside = lines.Where(l => table.InsetBy(-1, -2).Contains(l.Rect.Center)).ToList();
        var glyphs = inside.SelectMany(l => l.Chars.Where(c => !c.IsSpace)).ToList();
        if (glyphs.Count <= 10 || table.W <= 20) return [];
        double size = glyphs.Select(g => g.Size).OrderBy(s => s).ElementAt(glyphs.Count / 2);
        const double step = 0.5;
        int bins = (int)Math.Ceiling(table.W / step) + 1;
        var covered = new bool[bins];
        foreach (var c in glyphs)
        {
            int a = Math.Max(0, (int)Math.Floor((c.Rect.MinX - table.MinX) / step) + 1);
            int b = Math.Min(bins - 1, (int)Math.Ceiling((c.Rect.MaxX - table.MinX) / step) - 1);
            for (int x = a; x <= b; x++) covered[x] = true;
        }
        var result = new List<Gap>();
        int pos = 0;
        while (pos < bins)
        {
            if (covered[pos]) { pos++; continue; }
            int e = pos;
            while (e + 1 < bins && !covered[e + 1]) e++;
            var strip = new Gap(table.MinX + pos * step, table.MinX + (e + 1) * step);
            pos = e + 1;
            if (strip.Upper - strip.Lower < size * 0.5) continue;
            int rows = inside.Count(line => line.Chars.Any(c => !c.IsSpace && c.Rect.MaxX <= strip.Lower + 0.5) && line.Chars.Any(c => !c.IsSpace && c.Rect.MinX >= strip.Upper - 0.5));
            if (rows >= 2) result.Add(strip);
        }
        return result;
    }

    static bool ContinuesText(LayoutLine line, List<LayoutLine> lines) => lines.Any(other =>
    {
        double drop = other.Baseline - line.Baseline;
        return drop > line.Size * 0.5 && drop < line.Size * 1.7 && Math.Abs(other.Size - line.Size) < line.Size * 0.1
               && other.WordCount >= 6 && line.MinX < other.MaxX && line.MaxX > other.MinX && Math.Abs(other.MinX - line.MinX) < line.Size * 2;
    });

    static bool EndsParagraph(LayoutLine line, List<LayoutLine> lines) => lines.Any(other =>
    {
        double drop = other.Baseline - line.Baseline;
        return drop > 0 && drop < line.Size * 1.7 && Math.Abs(other.MinX - line.MinX) < line.Size * 1.5 && other.InkRect.W > line.Size * 15;
    });

    static bool IsBackground(Rect rect, List<LayoutLine> lines, bool boxy) => TextInside(rect, lines) >= (boxy ? 3 : 40);

    static int TextInside(Rect rect, List<LayoutLine> lines) =>
        lines.Where(l => rect.InsetBy(-1, -1).Contains(l.Rect.Center)).Sum(l => l.VisibleCount);

    // MARK: Line roles

    bool IsMarginal(LayoutLine line, Rect page, List<LayoutLine> lines)
    {
        double top = page.MaxY - page.H * 0.065, bottom = page.MinY + page.H * 0.06;
        if (!(line.Rect.MinY > top || line.Rect.MaxY < bottom)) return false;
        if (line.WordCount >= 4 && Math.Abs(line.Size - BodySize) < BodySize * 0.12)
        {
            bool continues = lines.Any(other =>
            {
                double distance = Math.Abs(other.Baseline - line.Baseline);
                return distance > line.Size * 0.5 && distance < line.Size * 1.6 && Math.Abs(other.Size - line.Size) < line.Size * 0.1
                       && other.MinX < line.MaxX && other.MaxX > line.MinX && other.Rect.MinY <= top && other.Rect.MaxY >= bottom;
            });
            if (continues) return false;
        }
        var text = line.Text.Trim();
        bool numeric = Regex.IsMatch(text, @"^[\divxlcIVXLC\-–—/ ]+$");
        return numeric || line.Size < BodySize * 0.95 || line.WordCount <= 12;
    }

    bool IsDisplayMath(LayoutLine line)
    {
        double ratio = line.MathRatio;
        var text = line.Text;
        bool numbered = Regex.IsMatch(text, @"\(\d+[a-z]?\)\s*$");
        if (numbered && (ratio >= 0.2 || text.Contains('='))) return true;
        var trimmed = text.Trim();
        if (ratio >= 0.7 && TextWords(line) <= 1 && Regex.IsMatch(text, @"^\s*(where|with|for|and|or|s\.t\.|subject to|if)\b") && trimmed.Length > 0
            && (",.;)".Contains(trimmed[^1]) || char.IsDigit(trimmed[^1]))) return true;
        if (line.Chars.FirstOrDefault(c => !c.IsSpace) is { } first && !first.IsMath && StartsLower(first.Text) && TextWords(line) >= 1) return false;
        int words = TextWords(line);
        if (words >= 2 && ratio < 0.85) return false;
        return ratio >= 0.55 && line.WordCount <= 12;
    }

    /// <summary>Words in lower case of three or more letters.</summary>
    static int ProseWords(LayoutLine line) => line.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(word =>
    {
        var letters = word.Trim(PunctuationChars);
        return Text.Graphemes(letters) >= 3 && letters.All(char.IsLower);
    });

    static readonly char[] PunctuationChars = Enumerable.Range(0x21, 0x5E).Select(i => (char)i).Where(c => char.IsPunctuation(c)).Concat("“”‘’—–…·•").ToArray();

    /// <summary>Words of three or more letters outside formulas.</summary>
    static int TextWords(LayoutLine line)
    {
        int count = 0, run = 0;
        foreach (var c in line.Chars)
        {
            if (!c.IsMath && !c.IsSpace && c.Text.Length > 0 && c.Text.EnumerateRunes().All(System.Text.Rune.IsLetter)) run++;
            else
            {
                if (run >= 3) count++;
                run = 0;
            }
        }
        return count + (run >= 3 ? 1 : 0);
    }

    // MARK: Blocks

    bool CanJoin(LayoutBlock block, LayoutLine line)
    {
        if (block.Lines.Count == 0) return false;
        var last = block.Lines[^1];
        double size = block.Size;
        if (Math.Abs(line.Size - size) > size * 0.16) return false;
        double drop = last.Baseline - line.Baseline;
        if (drop <= size * 0.4) return false;
        double maxPitch = block.Lines.Count >= 2 ? Math.Min(block.Pitch * 1.35 + 0.5, size * 2.0) : size * 1.9;
        if (drop > maxPitch) return false;
        var r = block.Rect;
        double overlap = Math.Min(r.MaxX, line.MaxX) - Math.Max(r.MinX, line.MinX);
        if (overlap < Math.Min(r.W, line.InkRect.W) * 0.5) return false;
        if (_pageRules.Any(rule => rule.MidY < last.Baseline - last.Size * 0.2 && rule.MidY > line.Baseline + line.Size * 0.6
                && Math.Min(rule.MaxX, Math.Min(last.MaxX, line.MaxX)) - Math.Max(rule.MinX, Math.Max(last.MinX, line.MinX)) > Math.Min(last.InkRect.W, line.InkRect.W) * 0.3))
            return false;
        if (block.Lines.Count >= 2 && (line.MinX < r.MinX - size * 2 || line.MaxX > r.MaxX + size * 2)) return false;
        if (IsCaptionStart(line.Text)) return false;
        if (IsReferencesHeading(last.Text) || IsReferencesHeading(line.Text)) return false;
        if (last.Font.IsBold && line.Font.IsBold && Math.Abs(last.Size - line.Size) < size * 0.06 && drop <= size * 1.45 && last.InkRect.W > size * 18 && !IsListItem(line.Text))
            return true;
        bool lastHeading = IsHeadingLike(last), lineHeading = IsHeadingLike(line);
        if (lastHeading || lineHeading)
        {
            bool sameStyle = lastHeading == lineHeading && last.Font.IsBold == line.Font.IsBold && Math.Abs(last.Size - line.Size) < last.Size * 0.06;
            bool numbered = Regex.IsMatch(line.Text, @"^\s*((\d{1,2}(\.\d+)*\.?)|([IVX]+\.)|([A-Z]\.))\s+\p{Lu}");
            if (!sameStyle || numbered || drop > size * 1.45) return false;
            return true;
        }
        var lastTrim = last.Text.Trim();
        if (!last.Font.IsBold && line.Chars.FirstOrDefault(c => !c.IsSpace) is { } opening && opening.Font.IsBold && !opening.IsMath
            && line.Chars.Take(12).Count(c => !c.IsSpace && c.Font.IsBold) >= 6 && lastTrim.Length > 0 && ".:?!。".Contains(lastTrim[^1]))
            return false;
        if (IsListItem(line.Text))
        {
            var t = line.Text.Trim();
            bool bullet = t.Length > 0 && "•▪◦●○■□‣∙·-–—*�".Contains(t[0]);
            if (bullet || last.MaxX < r.MaxX - size * 2) return false;
        }
        var bc = block.Color;
        if (Math.Abs(line.Color.R - bc.R) + Math.Abs(line.Color.G - bc.G) + Math.Abs(line.Color.B - bc.B) > 0.6 && (TextWords(line) >= 3 || IsHeadingLike(line)))
            return false;
        if (_columnOf != null)
        {
            var column = _columnOf((line.MinX + line.MaxX) / 2);
            double width = Math.Min(column.Hi - column.Lo, _typicalWidth);
            var opening2 = line.Chars.FirstOrDefault(c => !c.IsSpace);
            bool startsAnew = opening2 != null && (opening2.IsMath || opening2.IsScript || (opening2.Text.Length > 0 && (char.IsUpper(opening2.Text[0]) || char.IsDigit(opening2.Text[0]))));
            bool goesOn = Regex.IsMatch(last.Text, @"(,|-|\b(and|or|of|the|for|to|with|in|on|by|a|an))\s*$");
            bool ragged = Math.Abs(last.MaxX - line.MaxX) > size * 0.4;
            bool listLike = _currentPage == 1 || size < BodySize * 0.96;
            if (listLike && !IsCaptionStart(block.Lines[0].Text) && width > 0 && last.InkRect.W < width * 0.6 && line.InkRect.W < width * 0.6 && ragged && startsAnew && !goesOn)
                return false;
        }
        double left = block.Lines.Count > 1 ? block.Lines.Skip(1).Min(l => l.MinX) : last.MinX;
        bool hanging = block.Lines.Count == 1 && IsListItem(last.Text);
        bool centred = Math.Abs((line.MinX + line.MaxX) / 2 - r.MidX) < size * 0.6 && line.MaxX < r.MaxX - size * 0.8;
        if (!hanging && !centred && line.MinX > left + size * 0.8 && last.MaxX > r.MaxX - size * 2) return false;
        if (block.Lines.Count >= 2 && last.MaxX < r.MaxX - size * 4 && lastTrim.Length > 0 && ".:?!。".Contains(lastTrim[^1])) return false;
        return true;
    }
}
