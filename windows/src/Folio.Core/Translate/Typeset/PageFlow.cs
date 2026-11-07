using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;

namespace Folio.Core.Translate.Typeset;

// Port of macos/.../FolioTranslate/Typeset/PageFlow.swift.

/// <summary>Line spacing of a page's running text: what follows one another in a column, with nothing fixed between,
/// is set as one stretch at one size and one spacing, from where the first starts to where the last ends.</summary>
public static class PageFlow
{
    public sealed class Entry
    {
        public int Block;
        public Rect Frame;
        public string Text = "";
        public List<FormulaSpan> Formulas = [];
        public Typesetter.Plan Plan = null!;
    }

    public readonly record struct Placement(double FirstBaseline, double Pitch, Rect Frame);

    /// <summary>A displayed formula going along with the text around it.</summary>
    public sealed record FormulaMove(List<int> Blocks, FormulaSpan Span, double Dy);

    public sealed class Outcome
    {
        /// <summary>By position in the entries.</summary>
        public Dictionary<int, Placement> Placements = [];
        public List<FormulaMove> Moves = [];
    }

    /// <summary>A translated block (<see cref="Index"/>), or the blocks of a displayed formula (<see cref="Formula"/>).</summary>
    public sealed record Member(int? Index, List<int>? Formula)
    {
        public static Member Text(int index) => new(index, null);
        public static Member Of(List<int> formula) => new(null, formula);
        public bool IsText => Index != null;
    }

    public static List<List<int>> Runs(List<int> translated, PageLayout layout) =>
        Flows(translated, layout).Select(f => f.Where(m => m.IsText).Select(m => m.Index!.Value).ToList()).ToList();

    public static List<List<Member>> Flows(List<int> translated, PageLayout layout)
    {
        var blocks = layout.Blocks;
        var measures = blocks.Where(b => b.Kind == BlockKind.Paragraph && b.Lines.Count >= 2).Select(b => b.Rect.W).OrderBy(w => w).ToList();
        double measure = measures.Count == 0 ? double.PositiveInfinity : measures[measures.Count / 2];
        bool IsShortLine(LayoutBlock block) => block.Kind == BlockKind.Paragraph && block.Lines.Count == 1 && block.Rect.W < measure * 0.6;
        // A single line with something right beside it on its baseline is a row of a table the rules did not reveal.
        bool IsRow(int index)
        {
            if (blocks[index].Lines.Count != 1 || blocks[index].Rect.W >= measure * 0.6) return false;
            var line = blocks[index].Lines[0];
            for (int k = 0; k < blocks.Count; k++)
            {
                if (k == index) continue;
                if (blocks[k].Lines.Any(o => !o.IsRotated && Math.Abs(o.Baseline - line.Baseline) < line.Size * 0.3
                        && (o.MinX >= line.MaxX && o.MinX - line.MaxX < line.Size * 8 || o.MaxX <= line.MinX && line.MinX - o.MaxX < line.Size * 8)))
                    return true;
            }
            return false;
        }
        var result = new List<List<Member>>();
        foreach (var index in translated)
        {
            if (IsRow(index)) continue;
            var block = blocks[index];
            if (!(block.Kind == BlockKind.Heading || (block.Kind == BlockKind.Paragraph && !block.IsCentered))) continue;
            bool joined = false;
            for (int k = result.Count - 1; k >= 0; k--)
            {
                if (LastText(result[k]) is not { } last || (IsShortLine(block) && IsShortLine(blocks[last]))) continue;
                if (Between(index, result[k], layout) is not { } formula) continue;
                if (formula.Count > 0) result[k].Add(Member.Of(formula));
                result[k].Add(Member.Text(index));
                joined = true;
                break;
            }
            if (!joined) result.Add([Member.Text(index)]);
        }
        // There has to be running text; and a single line on its own has no spacing to keep.
        return result.Where(flow =>
        {
            var texts = flow.Where(m => m.IsText).Select(m => m.Index!.Value).ToList();
            return texts.Any(t => blocks[t].Kind == BlockKind.Paragraph) && (texts.Count > 1 || blocks[texts[0]].Lines.Count > 1);
        }).ToList();
    }

    static int? LastText(List<Member> flow)
    {
        for (int i = flow.Count - 1; i >= 0; i--) if (flow[i].IsText) return flow[i].Index;
        return null;
    }

    /// <summary>Whether block <paramref name="index"/> can come next in <paramref name="flow"/>: the blocks of the
    /// displayed formula between them (none is fine), or null if it cannot.</summary>
    public static List<int>? Between(int index, List<Member> flow, PageLayout layout)
    {
        var blocks = layout.Blocks;
        if (LastText(flow) is not { } lastIndex) return null;
        LayoutBlock a = blocks[lastIndex], b = blocks[index];
        double size = a.Kind == BlockKind.Paragraph ? a.Size : b.Size;
        if (b.Kind == BlockKind.Paragraph)
        {
            LayoutBlock? body = null;
            for (int i = flow.Count - 1; i >= 0; i--)
                if (flow[i].IsText && blocks[flow[i].Index!.Value].Kind == BlockKind.Paragraph) { body = blocks[flow[i].Index!.Value]; break; }
            if (body != null && Math.Abs(body.Size - b.Size) >= body.Size * 0.06) return null;
        }
        double bottom = a.Lines[^1].Baseline, top = b.Lines[0].Baseline;
        double drop = bottom - top;
        if (drop <= 0) return null;
        if (Math.Min(a.Rect.MaxX, b.Rect.MaxX) - Math.Max(a.Rect.MinX, b.Rect.MinX) <= Math.Min(a.Rect.W, b.Rect.W) * 0.5) return null;
        if (a.Kind == BlockKind.Paragraph && b.Kind == BlockKind.Paragraph && Math.Abs(a.Rect.MinX - b.Rect.MinX) >= size * 2.5) return null;

        double xLow = Math.Min(a.Rect.MinX, b.Rect.MinX) - 1, xHigh = Math.Max(a.Rect.MaxX, b.Rect.MaxX) + 1;
        var formula = Enumerable.Range(0, blocks.Count).Where(k =>
        {
            if (blocks[k].Kind != BlockKind.Formula) return false;
            var c = blocks[k].Rect.Center;
            return c.Y < bottom && c.Y > top && c.X > xLow && c.X < xHigh;
        }).ToList();
        double formulaHeight = 0;
        if (formula.Count > 0)
        {
            var baselines = formula.SelectMany(k => blocks[k].Lines.Select(l => l.Baseline)).ToList();
            formulaHeight = baselines.Max() - baselines.Min();
        }
        bool bothText = a.Kind == BlockKind.Paragraph && b.Kind == BlockKind.Paragraph && formula.Count == 0;
        if (drop - formulaHeight >= size * (bothText ? 2.8 : 6)) return null;

        var members = new List<int>();
        foreach (var m in flow) { if (m.IsText) members.Add(m.Index!.Value); else members.AddRange(m.Formula!); }
        members.Add(index);
        members.AddRange(formula);
        var rects = members.Select(k => blocks[k].Rect).ToList();
        var union = rects.Skip(1).Aggregate(rects[0], (r, x) => r.Union(x));
        double flowTop = top;
        foreach (var m in flow) if (m.IsText) { flowTop = blocks[m.Index!.Value].Lines[0].Baseline; break; }
        double flowBottom = b.Lines[^1].Baseline;
        var inner = new Rect(union.MinX + 1, flowBottom, Math.Max(union.W - 2, 1), Math.Max(flowTop - flowBottom, 1));
        bool InTheWay(Rect rect)
        {
            var shared = rect.Intersection(inner);
            return !shared.IsNull && shared.W > 1 && shared.H > size * 0.2;
        }
        for (int k = 0; k < blocks.Count; k++) if (!members.Contains(k) && InTheWay(blocks[k].Rect)) return null;
        foreach (var region in layout.Tables.Concat(layout.Figures)) if (InTheWay(region)) return null;
        var moving = members.Where(k => blocks[k].Kind == BlockKind.Formula).Select(k => blocks[k].Rect).ToList();
        var textRects = members.Where(k => blocks[k].Kind != BlockKind.Formula).Select(k => blocks[k].Rect).ToList();
        foreach (var graphic in layout.Graphics)
        {
            if (!InTheWay(graphic)) continue;
            if (graphic.Contains(union)) continue;
            if (textRects.Any(r => r.InsetBy(-1, -size * 0.3).Contains(graphic))) continue;
            if (graphic.H < 4 && moving.Any(r => r.InsetBy(-1, -size * 0.8).Contains(graphic))) continue;
            return null;
        }
        return formula;
    }

    sealed class Stretch
    {
        public List<Member> Members = [];
        public double FontSize, FirstBaseline;
        public List<double> Clearances = [];
        public Dictionary<int, double> Breaks = [];
        public double MinPitch, MaxPitch, FullHeight, RoomHeight;
        public Rect Frame;
        public List<int> Counts = [];

        public double Extra => Breaks.Values.Sum();
        public double FillPitch => Typesetter.Pitch(FullHeight - Extra, Clearances, MinPitch, MaxPitch);
        public double RoomPitch => Typesetter.Pitch(RoomHeight - Extra, Clearances, MinPitch, MaxPitch);
        public bool Fits => Clearances.Sum(c => Math.Max(MinPitch, c)) + Extra <= RoomHeight + 0.5;
        public Stretch Copy() => (Stretch)MemberwiseClone();
    }

    /// <summary>Sets the running text of a page. <paramref name="entries"/> get their plans for the size each stretch
    /// ends up at; the result says where each of them goes, and which formulas move.</summary>
    public static Outcome LayOut(List<Entry> entries, PageLayout layout, Typesetter typesetter)
    {
        var positions = new Dictionary<int, int>();
        for (int i = 0; i < entries.Count; i++) positions.TryAdd(entries[i].Block, i);
        var flows = Flows(entries.Select(e => e.Block).ToList(), layout);
        var stretches = flows.Select(f => MakeStretch(f, entries, positions, layout, typesetter)).ToList();

        var ratios = stretches.Where(s => s.Clearances.Count > 0)
            .SelectMany(s => Enumerable.Repeat(s.FillPitch / s.FontSize, s.Clearances.Count)).OrderBy(r => r).ToList();
        double? common = null;
        if (ratios.Count > 0)
        {
            double median = ratios[ratios.Count / 2];
            var withLines = stretches.Where(s => s.Clearances.Count > 0).ToList();
            double tightest = withLines.Count > 0 ? withLines.Min(s => s.RoomPitch / s.FontSize) : median;
            common = Math.Max(median * 0.85, Math.Min(median, tightest * 1.12));
        }
        // What comes next starts where it starts: the last line stops a line above it, not closer.
        if (common is { } c0)
        {
            for (int k = 0; k < stretches.Count; k++)
            {
                if (NextBaseline(stretches[k], layout) is not { } below) continue;
                var s = stretches[k];
                double lowest = below + c0 * s.FontSize;
                var limited = s.Copy();
                limited.FullHeight = Math.Min(s.FullHeight, s.FirstBaseline - lowest);
                limited.RoomHeight = Math.Min(s.RoomHeight, s.FirstBaseline - lowest);
                double needed = s.Clearances.Sum(c => Math.Max(c0 * s.FontSize * 0.9, c)) + s.Extra;
                if (limited.RoomHeight >= needed) stretches[k] = limited;
            }
        }

        var outcome = new Outcome();
        foreach (var s in stretches)
        {
            double pitch = s.FillPitch;
            if (common is { } c) pitch = Math.Min(Math.Max(pitch, c * s.FontSize * 0.96), c * s.FontSize * 1.04);
            pitch = Math.Max(Math.Min(pitch, s.RoomPitch), s.MinPitch);
            double used = s.Clearances.Sum(x => Math.Max(pitch, x)) + s.Extra;
            double share = s.Breaks.Count == 0 ? 0 : Math.Max(0, Math.Min((s.FullHeight - used) / s.Breaks.Count, pitch * 0.7));
            double baseline = s.FirstBaseline;
            int gap = 0;
            for (int n = 0; n < s.Members.Count; n++)
            {
                var member = s.Members[n];
                if (member.IsText) outcome.Placements[positions[member.Index!.Value]] = new Placement(baseline, pitch, s.Frame);
                else outcome.Moves.Add(Move(member.Formula!, baseline, layout));
                for (int r = 0; r < Math.Max(s.Counts[n] - 1, 0); r++)
                {
                    baseline -= Math.Max(pitch, s.Clearances[gap]);
                    gap++;
                }
                if (gap < s.Clearances.Count)
                {
                    baseline -= Math.Max(pitch, s.Clearances[gap]) + (s.Breaks.TryGetValue(gap, out var extra) ? extra + share : 0);
                    gap++;
                }
            }
        }
        return outcome;
    }

    static (double Top, double Bottom, double Above, double Below) Extent(List<int> list, PageLayout layout)
    {
        var lines = list.SelectMany(i => layout.Blocks[i].Lines).ToList();
        double top = lines.Max(l => l.Baseline), bottom = lines.Min(l => l.Baseline);
        var chars = lines.SelectMany(l => l.Chars).Where(ch => !ch.IsSpace).ToList();
        double inkTop = chars.Count > 0 ? chars.Max(ch => ch.InkBox.MaxY) : top;
        double inkBottom = chars.Count > 0 ? chars.Min(ch => ch.InkBox.MinY) : bottom;
        return (top, bottom, Math.Max(inkTop - top, 0), Math.Max(bottom - inkBottom, 0));
    }

    static FormulaMove Move(List<int> list, double baseline, PageLayout layout)
    {
        var lines = list.SelectMany(i => layout.Blocks[i].Lines).ToList();
        var chars = lines.SelectMany(l => l.Chars).Where(ch => !ch.IsSpace).ToList();
        var extent = Extent(list, layout);
        Rect rect = chars[0].GlyphBox, ink = chars[0].InkBox;
        foreach (var ch in chars.Skip(1))
        {
            rect = rect.Union(ch.GlyphBox);
            ink = ink.Union(ch.InkBox);
        }
        var span = new FormulaSpan
        {
            Rect = rect, Baseline = extent.Top, Runs = chars.Where(ch => ch.Run != null).Select(ch => ch.Run!.Value).ToHashSet(),
            Size = lines[0].Size, Glyphs = chars.SelectMany(ch => ch.Glyphs).OrderBy(g => g).ToList(), Ink = ink,
        };
        return new FormulaMove(list, span, baseline - extent.Top);
    }

    static double? NextBaseline(Stretch s, PageLayout layout)
    {
        if (LastText(s.Members) is not { } lastIndex) return null;
        var last = layout.Blocks[lastIndex];
        var own = new HashSet<int>();
        foreach (var m in s.Members) { if (m.IsText) own.Add(m.Index!.Value); else own.UnionWith(m.Formula!); }
        double bottom = last.Lines[^1].Baseline;
        LayoutBlock? nearest = null;
        for (int k = 0; k < layout.Blocks.Count; k++)
        {
            var block = layout.Blocks[k];
            if (own.Contains(k) || block.Lines.Count == 0 || block.Lines[0].IsRotated || block.Lines[0].Baseline >= bottom) continue;
            if (Math.Min(block.Rect.MaxX, last.Rect.MaxX) - Math.Max(block.Rect.MinX, last.Rect.MinX) <= Math.Min(block.Rect.W, last.Rect.W) * 0.5) continue;
            if (nearest == null || block.Lines[0].Baseline > nearest.Lines[0].Baseline) nearest = block;
        }
        if (nearest == null || nearest.Kind is not (BlockKind.Paragraph or BlockKind.Heading or BlockKind.Caption or BlockKind.Reference)) return null;
        return nearest.Lines[0].Baseline;
    }

    static Stretch MakeStretch(List<Member> members, List<Entry> entries, Dictionary<int, int> positions, PageLayout layout, Typesetter typesetter)
    {
        var texts = members.Where(m => m.IsText).Select(m => m.Index!.Value).ToList();
        var blocks = texts.Select(t => layout.Blocks[t]).ToList();
        var frames = texts.Select(t => entries[positions[t]].Frame).ToList();
        double bottom = frames[^1].MinY;
        var body = blocks.Where(b => b.Kind == BlockKind.Paragraph).ToList();
        double left = body.Min(b => b.Rect.MinX), right = body.Max(b => b.Rect.MaxX);
        var planFrames = new List<Rect>();
        for (int n = 0; n < blocks.Count; n++)
        {
            var block = blocks[n];
            bool wide = block.Kind == BlockKind.Paragraph && block.Lines.Count == 1;
            double x = wide ? left : frames[n].MinX;
            double width = wide ? right - left : block.Kind == BlockKind.Heading ? frames[n].W : block.Rect.W;
            double top = n == 0 ? frames[0].MaxY : block.Rect.MaxY + block.Size;
            planFrames.Add(new Rect(x, bottom, width, Math.Max(top - bottom, 1)));
        }
        var area = planFrames.Skip(1).Aggregate(planFrames[0], (r, f) => r.Union(f));
        area = new Rect(area.MinX, area.MinY, area.W, Math.Max(frames[0].MaxY - bottom, 1));
        double scale = 1.0;
        while (true)
        {
            var plans = new List<Typesetter.Plan>();
            for (int n = 0; n < texts.Count; n++)
            {
                var entry = entries[positions[texts[n]]];
                double? indent = blocks[n].Kind == BlockKind.Paragraph && blocks[n].Lines.Count == 1 ? Math.Max(0, blocks[n].Rect.MinX - left) : null;
                plans.Add(typesetter.MakePlan(entry.Text, blocks[n], entry.Formulas, planFrames[n], scale, indent));
            }
            double smallest = plans.Min(p => p.Scale);
            // A formula too wide for its line at this size: the whole stretch goes to that size.
            if (smallest < scale - 0.001)
            {
                scale = smallest;
                continue;
            }
            var bodyPlans = plans.Where((_, i) => blocks[i].Kind == BlockKind.Paragraph).ToList();
            double fontSize = bodyPlans[0].FontSize;
            var pitches = body.Where(b => b.Lines.Count > 1).Select(b => b.Pitch).OrderBy(p => p).ToList();
            double linePitch = pitches.Count == 0 ? body[0].Size * 1.2 : pitches[pitches.Count / 2];

            var clearances = new List<double>();
            var breaks = new Dictionary<int, double>();
            var counts = new List<int>();
            (double Below, double SourceBottom, double Height)? previous = null;
            int textIndex = 0;
            foreach (var member in members)
            {
                double above, below, sourceTop, sourceBottom, height;
                Typesetter.Plan? plan = null;
                if (member.IsText)
                {
                    var p = plans[textIndex];
                    var formulas = entries[positions[texts[textIndex]]].Formulas;
                    plan = p;
                    above = p.Lines.Count > 0 ? typesetter.Reach(p.Lines[0].Line, formulas, p.Scale).Above : 0;
                    below = p.Lines.Count > 0 ? typesetter.Reach(p.Lines[^1].Line, formulas, p.Scale).Below : 0;
                    sourceTop = blocks[textIndex].Lines[0].Baseline;
                    sourceBottom = blocks[textIndex].Lines[^1].Baseline;
                    height = 0;
                    counts.Add(p.Lines.Count);
                    textIndex++;
                }
                else
                {
                    var e = Extent(member.Formula!, layout);
                    above = e.Above;
                    below = e.Below;
                    sourceTop = e.Top;
                    sourceBottom = e.Bottom;
                    height = e.Top - e.Bottom;
                    counts.Add(1);
                }
                if (previous is { } prev)
                {
                    clearances.Add(prev.Below + above + fontSize * 0.04);
                    double extra = Math.Min(Math.Max(0, prev.SourceBottom - sourceTop - linePitch), body[0].Size * 3);
                    breaks[clearances.Count - 1] = (extra < body[0].Size * 0.1 ? 0 : extra) + prev.Height;
                }
                if (plan != null) clearances.AddRange(plan.Clearances);
                previous = (below, sourceBottom, height);
            }
            var first = plans[0];
            double deepest = plans.Count > 0 ? typesetter.Depth(plans[^1]) : 0;
            var s = new Stretch
            {
                Members = members, FontSize = fontSize, FirstBaseline = first.FirstBaseline, Clearances = clearances, Breaks = breaks,
                MinPitch = bodyPlans.Max(p => p.MinPitch), MaxPitch = fontSize * 1.85,
                FullHeight = first.FirstBaseline - blocks[^1].Lines[^1].Baseline,
                RoomHeight = first.FirstBaseline - bottom - Math.Max(fontSize * 0.22, deepest), Frame = area, Counts = counts,
            };
            if (s.Fits || scale < 0.45)
            {
                for (int n = 0; n < texts.Count; n++)
                {
                    var entry = entries[positions[texts[n]]];
                    entry.Plan = plans[n].Copy();
                    entry.Plan.Fits = s.Fits;
                    entry.Frame = planFrames[n];
                }
                return s;
            }
            scale -= scale > 0.7 ? 0.04 : 0.05;
        }
    }
}
