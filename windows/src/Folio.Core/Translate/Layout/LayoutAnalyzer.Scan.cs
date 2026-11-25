using System.Text;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Translate.Layout;

// Port of macos/.../FolioTranslate/Layout/LayoutAnalyzer+Scan.swift: what only scans need. Their recognised text says nothing
// of fonts, so formulas and running heads are told by what they say and where they stand.
public sealed partial class LayoutAnalyzer
{
    /// <summary>The lines of the page being analysed, and the bits of a scan's picture no word was read in.</summary>
    List<LayoutLine> _pageLines = [];
    List<Rect> _pageBits = [];
    /// <summary>What scans have at the head and foot of several pages.</summary>
    HashSet<string> _runningLines = [];

    // MARK: Running heads

    /// <summary>A line at the head or foot without its numbers and whatever recognition makes of the spaces.</summary>
    public static string RunningKey(string text)
    {
        var key = new StringBuilder();
        foreach (var c in text.ToLowerInvariant())
        {
            if (char.IsNumber(c)) { if (key.Length == 0 || key[^1] != '#') key.Append('#'); }
            else if (char.IsLetter(c)) key.Append(c);
        }
        return key.ToString();
    }

    static bool IsAtEdge(LayoutLine line, Rect page) => line.Rect.MinY > page.MaxY - page.H * 0.13 || line.Rect.MaxY < page.MinY + page.H * 0.11;

    /// <summary>The lines several scanned pages have at their head or foot ("Team # 2505199", "Page 3 of 25").</summary>
    static HashSet<string> RunningLines(List<(Rect Crop, List<LayoutLine> Lines)> pages)
    {
        var counts = new Dictionary<string, int>();
        foreach (var (crop, lines) in pages)
            foreach (var key in lines.Where(l => !l.IsRotated && IsAtEdge(l, crop) && l.WordCount <= 16).Select(l => RunningKey(l.Text)).Where(k => k.Length >= 3).ToHashSet())
                counts[key] = counts.GetValueOrDefault(key) + 1;
        return counts.Where(kv => kv.Value >= 2 && kv.Value * 4 >= pages.Count).Select(kv => kv.Key).ToHashSet();
    }

    bool IsRunningLine(LayoutLine line, Rect page)
    {
        if (_runningLines.Count == 0 || !IsAtEdge(line, page)) return false;
        var key = RunningKey(line.Text);
        // (A letter or two may be read differently on one page.)
        return _runningLines.Contains(key) || (key.Length >= 5 && _runningLines.Any(r => Math.Abs(r.Length - key.Length) <= 2 && Distance(r, key) <= 2));
    }

    /// <summary>How many letters one has to change, add or leave out to get from one text to the other.</summary>
    public static int Distance(string a, string b)
    {
        var row = Enumerable.Range(0, b.Length + 1).ToArray();
        for (int i = 0; i < a.Length; i++)
        {
            int last = row[0];
            row[0] = i + 1;
            for (int j = 0; j < b.Length; j++)
            {
                int next = row[j + 1];
                row[j + 1] = a[i] == b[j] ? last : Math.Min(last, Math.Min(next, row[j])) + 1;
                last = next;
            }
        }
        return row[^1];
    }

    /// <summary>Lines at the very top of a scanned page with nothing of the text right under them: what a publisher prints over it.</summary>
    static bool IsTopNote(LayoutLine line, Rect page, List<LayoutLine> lines)
    {
        double top = page.MaxY - page.H * 0.065;
        if (line.Rect.MinY <= top) return false;
        // The lines under it, one by one, to where the group ends.
        var last = line;
        for (int k = 0; k < 6; k++)
        {
            var next = lines.Where(other =>
            {
                double drop = last.Baseline - other.Baseline;
                return drop > last.Size * 0.5 && drop < last.Size * 2 && other.MinX < last.MaxX && other.MaxX > last.MinX;
            }).MaxBy(l => l.Baseline);
            if (next == null) return true;
            if (next.Rect.MinY <= top) return false;
            last = next;
        }
        return false;
    }

    // MARK: Figures

    /// <summary>The drawings over the captions "Figure 3" of a scan: from the caption up to the text above it, what is there is
    /// labels, symbols and lines. (A chart of a few thin lines and dots is no drawing one could tell by its ink.)</summary>
    List<Rect> CaptionedFigures(List<LayoutLine> lines, List<GraphicMark> marks, List<Rect> bits, List<Rect> tables)
    {
        var found = new List<Rect>();
        var flat = lines.Where(l => !l.IsRotated).ToList();
        if (flat.Count == 0) return found;
        double minX = flat.Min(l => l.MinX), width = flat.Max(l => l.MaxX) - minX;
        var edges = ColumnEdges(flat, Gutters(flat, minX, width));
        var prose = flat.Where(l => l.Size >= BodySize * 0.85 && SentenceWords(l.Text) >= 5).ToList();
        foreach (var caption in flat)
        {
            if (!IsCaptionStart(caption.Text) || !Regex.IsMatch(caption.Text, @"^\s*(fig|图|chart|scheme)", RegexOptions.IgnoreCase)) continue;
            // As wide as the caption, when that is as wide as a column; else as the sentences around it are.
            double mid = (caption.MinX + caption.MaxX) / 2;
            var around = prose.Where(l => l.MinX < mid && l.MaxX > mid).ToList();
            var column = caption.InkRect.W > width * 0.38 && (around.Count == 0 || around.Any(l => Math.Abs(l.InkRect.W - caption.InkRect.W) < caption.InkRect.W * 0.08)) ? (Lo: caption.MinX, Hi: caption.MaxX)
                : around.Count == 0 ? edges(mid) : (Lo: around.Min(l => l.MinX), Hi: around.Max(l => l.MaxX));
            double lo = Math.Min(column.Lo, caption.MinX), hi = Math.Max(column.Hi, caption.MaxX);
            double top = double.PositiveInfinity;
            bool underTable = false;
            foreach (var line in flat)
            {
                if (line.Baseline <= caption.Baseline + caption.Size * 0.6) continue;
                double overlap = Math.Min(line.MaxX, hi) - Math.Max(line.MinX, lo);
                if (overlap <= Math.Min(line.InkRect.W, hi - lo) * 0.3) continue;
                bool full = line.Size >= BodySize * 0.95;
                int words = SentenceWords(line.Text);
                bool starts = full && line.MinX < lo + line.Size * 3 && line.MinX > lo - line.Size && line.WordCount >= 2 && words >= 1;
                bool wide = full && line.MinX < lo - line.Size * 2;
                if (wide || (words >= 6 && line.Size >= BodySize * 0.88) || starts || IsCaptionStart(line.Text) || (full && ContinuesText(line, flat)) || (full && IsEquationNumber(line.Text)))
                    if (line.Rect.MinY < top)
                    {
                        top = line.Rect.MinY;
                        underTable = IsCaptionStart(line.Text) && Regex.IsMatch(line.Text, @"^\s*(tab|表)", RegexOptions.IgnoreCase);
                    }
            }
            if (double.IsInfinity(top) || top - caption.Rect.MaxY <= BodySize * 4 || top - caption.Rect.MaxY >= 700) continue;
            var area = new Rect(lo, caption.Rect.MaxY, hi - lo, top - caption.Rect.MaxY);
            var inner = area.InsetBy(-2, 1);
            var rect = Rect.Null;
            foreach (var r in flat.Select(l => l.Rect).Concat(bits).Concat(marks.Select(m => m.Rect)))
                if (r.W < (hi - lo) * 1.2 && inner.Contains(r.Center)) rect = rect.Union(r);
            rect = rect.Intersection(area.InsetBy(-4, 0));
            // (Boxes joined by lines look like a table; under a figure's caption they are a drawing, unless a table's caption is over them.)
            if (underTable && tables.Any(t => t.Intersection(rect).Area > rect.Area * 0.2)) continue;
            if (!rect.IsNull && rect.H > BodySize * 4 && rect.W > BodySize * 6) found.Add(rect);
        }
        return found;
    }

    // MARK: Lists

    /// <summary>A short line with something as short on its row, read or not: a row of a table without rules, or of a list of
    /// symbols and what they mean.</summary>
    bool IsRowOfList(LayoutLine line)
    {
        // As far as the sentences over and under it reach: what stands in the next column is no part of the row.
        double mid = (line.MinX + line.MaxX) / 2;
        var prose = _pageLines.Where(l => l.MinX < mid && l.MaxX > mid && l.InkRect.W > line.InkRect.W && SentenceWords(l.Text) >= 4).ToList();
        var edge = _columnOf?.Invoke(mid) ?? (line.MinX, line.MaxX);
        double lo = prose.Count > 0 ? prose.Min(l => l.MinX) : edge.Lo, hi = prose.Count > 0 ? prose.Max(l => l.MaxX) : edge.Hi;
        if (line.InkRect.W >= (hi - lo) * 0.75) return false;
        bool OnRow(double y) => y > line.Baseline - line.Size * 0.3 && y < line.Baseline + line.Size * 0.9;
        return _pageLines.Any(other => OnRow(other.Baseline + other.Size * 0.3) && other.VisibleCount <= 14 && other.MinX > lo - line.Size && other.MaxX < hi + line.Size
                   && (other.MaxX < line.MinX - line.Size * 0.8 || other.MinX > line.MaxX + line.Size * 0.8))
            || _pageBits.Any(b => OnRow(b.MidY) && b.W < line.Size * 4 && b.H > line.Size * 0.25
                   && b.MaxX < line.MinX - line.Size * 0.8 && b.MaxX > Math.Max(line.MinX - line.Size * 16, lo - line.Size));
    }

    static string Unpunctuated(string token) => token.Trim().Trim([.. token.Where(c => char.IsPunctuation(c))]);

    /// <summary>A cell with a word in it, not a symbol misread as a few letters.</summary>
    static bool IsReadCell(string text)
    {
        var tokens = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Select(Unpunctuated).ToList();
        if (Engine.StandardCells.IsKnown(text) || tokens.Any(t => t.EnumerateRunes().Any(r => OcrTextLayer.IsCjk(r.Value)))) return true;
        return tokens.Any(w => (w.Length >= 4 && w.All(c => char.IsLetter(c) || c == '-')) || (w.Length == 3 && char.IsUpper(w[0]) && w.Skip(1).All(char.IsLower)));
    }

    // MARK: Formulas

    const string MathSigns = "=+×÷·∙*/^_<>≤≥≈≠≡∝∞∑∏∫√∂∇∈∉⊂⊆∪∩∀∃→←↔⇒|±−∼~{}";

    /// <summary>Words a sentence is made of: three or more letters in lower case that are no function's name; Chinese counts by the
    /// two characters.</summary>
    public static int SentenceWords(string text)
    {
        int count = 0, han = 0;
        foreach (var token in text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var word = Unpunctuated(token);
            int letters = word.EnumerateRunes().Count(r => OcrTextLayer.IsCjk(r.Value) && Rune.IsLetter(r) && r.Value is not (>= 0xFF00 and <= 0xFFEF));
            if (letters > 0) han += letters;
            else if (word.Length >= 3 && word.All(c => char.IsLetter(c) || c is '-' or '\'' or '’') && !word.Skip(1).Any(char.IsUpper)
                     && word.ToLowerInvariant().Any(c => "aeiouy".Contains(c)) && !MathDetector.OperatorNames.Contains(word)) count++;
        }
        // (One or two among Latin letters are signs misread.)
        return count + (han >= 4 || (count == 0 && han >= 2 && text.EnumerateRunes().Count() <= han + 2) ? han / 2 : 0);
    }

    static bool IsEquationNumber(string text) => Regex.IsMatch(text.Trim(), @"^[(（]\s?\d{1,3}([.\-]\d{1,2})?[a-z]?\s?[)）]$");

    /// <summary>The lines of a scan's displayed formulas: signs and letters with hardly any words, and the pieces of them standing
    /// above, below and beside (limits, numerators, cases). They stay as they are in the picture.</summary>
    HashSet<int> ScanFormulas(List<LayoutLine> lines, List<GraphicMark> marks, List<Rect> bits, Func<double, (double Lo, double Hi)> column)
    {
        var found = new HashSet<int>();
        var flat = Enumerable.Range(0, lines.Count).Where(k => !lines[k].IsRotated).ToList();
        var text = lines.Select(l => l.Text.Trim()).ToList();
        var words = text.Select(SentenceWords).ToList();
        // Where the text a line stands among starts (formulas come apart in pieces that would look like columns).
        var prose = flat.Where(k => words[k] >= 5).Select(k => lines[k]).ToList();
        double Left(LayoutLine line)
        {
            double mid = (line.MinX + line.MaxX) / 2;
            var around = prose.Where(l => l.MinX < mid && l.MaxX > mid).ToList();
            return around.Count > 0 ? around.Min(l => l.MinX) : column(mid).Lo;
        }
        double Right(LayoutLine line)
        {
            double mid = (line.MinX + line.MaxX) / 2;
            var around = prose.Where(l => l.MinX < mid && l.MaxX > mid).ToList();
            return around.Count > 0 ? around.Max(l => l.MaxX) : column(mid).Hi;
        }
        // What a formula has besides letters: fraction bars, braces, signs nobody read.
        var pieces = bits.Where(b => b.H > 1.2 || b.W > 4).Concat(marks.Where(m => m.Kind != GraphicMark.MarkKind.Image && Math.Max(m.Rect.W, m.Rect.H) < 160).Select(m => m.Rect)).ToList();
        bool Built(LayoutLine line)
        {
            var around = line.Rect.InsetBy(-line.Size * 1.2, -line.Size * 0.25);
            return pieces.Any(p => p.Intersects(around));
        }
        foreach (var k in flat)
        {
            var line = lines[k];
            if (IsListItem(text[k]) && words[k] > 0) continue;
            int signs = text[k].Count(c => MathSigns.Contains(c));
            // Displayed: set in from where the column's text starts.
            bool set = line.MinX > Left(line) + line.Size * 1.2;
            bool number = Regex.IsMatch(text[k], @"[(（]\s?\d{1,3}([.\-]\d{1,2})?[a-z]?\s?[)）]$");
            bool beside = flat.Any(j => j != k && lines[j].MinX > line.MaxX && IsEquationNumber(text[j])
                && lines[j].Baseline + lines[j].Size * 0.3 > line.Rect.MinY - line.Size * 0.2 && lines[j].Baseline + lines[j].Size * 0.3 < line.Rect.MaxY + line.Size * 0.2);
            bool equals = text[k].Any(c => c is '=' or '≤' or '≥' or '≈');
            if (set && IsEquationNumber(text[k])) { found.Add(k); continue; }
            // "y = ax + b (3)", "Med = …"
            if (equals && (words[k] <= 1 || (words[k] <= 3 && set && (number || beside)))) { found.Add(k); continue; }
            if (set && beside && (words[k] <= 2 || (signs >= 1 && words[k] <= 4))) { found.Add(k); continue; }
            if (set && number && signs >= 1 && words[k] <= 3) { found.Add(k); continue; }
            if (set && signs >= 2 && words[k] == 0) { found.Add(k); continue; }
            // Set in from both sides.
            if (!set || line.MaxX >= Right(line) - line.Size * 1.2 || IsCaptionStart(text[k])) continue;
            var tokens = text[k].Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words[k] <= 3 && tokens.Take(3).Any(t => t.Any(c => c is '=' or '≤' or '≥')) && words[k] * 5 <= line.VisibleCount) { found.Add(k); continue; }
            if (tokens.Length > 0 && MathDetector.OperatorNames.Contains(Unpunctuated(tokens[0])) && words[k] <= 2 && Built(line)) { found.Add(k); continue; }
            if (words[k] == 0 && text[k].Any(char.IsLetter) && (tokens.Length <= 3 || signs >= 1 || text[k].Any(char.IsNumber)) && Built(line)) found.Add(k);
        }
        if (found.Count == 0) return found;
        // Pieces around them.
        bool grew = true;
        while (grew)
        {
            grew = false;
            foreach (var k in flat)
            {
                var line = lines[k];
                if (found.Contains(k) || words[k] > 1 || line.WordCount > 6 || line.VisibleCount > 32 || IsListItem(text[k])) continue;
                if (line.MinX <= Left(line) + line.Size * 1.2) continue;
                bool near = found.Any(j =>
                {
                    var other = lines[j];
                    double reach = Math.Max(other.Size, line.Size);
                    double apart = Math.Max(other.Rect.MinY - line.Rect.MaxY, line.Rect.MinY - other.Rect.MaxY);
                    double aside = Math.Max(other.MinX - line.MaxX, line.MinX - other.MaxX);
                    return apart < reach * 0.6 && aside < reach * 2.5;
                });
                // The heading or caption right under a formula is no piece of it.
                if (near && !line.Font.IsBold && !IsCaptionStart(text[k])) { found.Add(k); grew = true; }
            }
        }
        return found;
    }
}
