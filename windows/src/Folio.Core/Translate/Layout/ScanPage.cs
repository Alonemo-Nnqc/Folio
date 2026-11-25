using System.Text;
using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Translate.Layout;

// Port of macos/.../FolioTranslate/Layout/ScanPage.swift and ScanMask.swift.

/// <summary>
/// A recognised scan as layout analysis needs it. The hidden text says which words are on the page and roughly where;
/// everything else is only in the picture: how large and how bold the type is, which lines stand upright, where rules and
/// drawings are, and which way round the page lies. All of it is measured from a render of the page, in a space where the
/// page lies upright and straight (<see cref="Transform"/>), so the analysis goes on as with any other page.
/// </summary>
public sealed partial class ScanPage
{
    /// <summary>The page's user space → the upright space everything below is in (identity for a page that lies straight already).</summary>
    public Affine Transform { get; private init; } = Affine.Identity;
    /// <summary>The visible part of the page in that space.</summary>
    public Rect Crop { get; private init; }
    /// <summary>The recognised words as characters, line by line, with the type sizes measured.</summary>
    public List<PageChar> Chars { get; private set; } = [];
    /// <summary>Rules, solid areas and drawings found in the picture.</summary>
    public List<GraphicMark> Marks { get; private set; } = [];
    /// <summary>Small pieces of ink no word was read in: a symbol of a table, part of a formula.</summary>
    public List<Rect> Bits { get; private set; } = [];
    /// <summary>Where the ink of each word is, by the run that wrote it.</summary>
    public Dictionary<int, Rect> Ink { get; } = [];
    List<Row> _rows = [];
    double _usual = 10;

    /// <summary>One word of the hidden text.</summary>
    internal sealed class Word
    {
        public int Run;
        public List<int> Glyphs = [];
        public string Text = "";
        public double X0, X1;
        /// <summary>The box it was read in.</summary>
        public double Bottom, Top;
        /// <summary>A space was written before it.</summary>
        public bool Spaced;
        /// <summary>Measured in the picture.</summary>
        public Rect? Ink;
        public double? Size, Baseline, Stroke;
        public bool Bold;
        public double Height => Top - Bottom;
        public double Mid => (Top + Bottom) / 2;
        int? _letters;
        public int Letters => _letters ??= Text.EnumerateRunes().Count(Rune.IsLetterOrDigit);
        int? _length;
        public int Length => _length ??= Text.EnumerateRunes().Count();

        /// <summary>The type size that makes the word's ink as tall as it is.</summary>
        public void Fit(double xHeight, double usual)
        {
            if (Ink is not { } ink || Letters * 2 < Length) return;
            var (low, high) = Extent(Text, xHeight);
            if (high - low <= 0.3) return;
            double size = ink.H / (high - low);
            if (size <= usual * 0.25 || size >= usual * 6) return;
            Size = size;
            Baseline = ink.MinY - low * size;
        }
    }

    /// <summary>Words on one row, left to right.</summary>
    internal sealed class Row
    {
        public List<Word> Words = [];
        public double Size, Baseline;
        public bool Measured, Upright;
        public double X0 => Words.Min(w => w.X0);
        public double X1 => Words.Max(w => w.X1);
        public int Letters => Words.Sum(w => w.Letters);
    }

    // MARK: Reading

    /// <summary>A render of the page as it is shown (crop box, /Rotate), and which way points of the page are on it.</summary>
    public sealed record Shown(ImageText.Bitmap Bitmap, Rect Crop, int Rotation)
    {
        /// <summary>User space → pixels of the bitmap.</summary>
        public Affine Map => OcrTextLayer.UserToImage(Crop, Rotation, Bitmap.Width);
        public double Scale => Math.Sqrt(Math.Abs(Map.A * Map.D - Map.B * Map.C));
    }

    /// <summary>The page the interpreter (run in the page's own space) is of, and the interpreter in the upright space.</summary>
    public static (ScanPage Scan, ContentInterpreter Interpreter) Read(PDict page, ContentInterpreter interpreter, Shown? shown)
    {
        var crop = PdfComposer.Geometry(page).CropBox;
        var (quarter, tilt) = TurnOf(interpreter);
        var (transform, upright) = Space(crop, quarter + tilt);
        if (tilt == 0 && shown != null && Raster.Render(shown, upright, transform, Math.Min(1.5, 1000 / Math.Max(upright.W, upright.H))) is { } small)
        {
            // Text written level over lines that are not: an earlier recognition.
            double skew = small.Skew();
            if (skew != 0) (transform, upright) = Space(crop, quarter + skew);
        }
        var placed = interpreter;
        if (transform != Affine.Identity)
        {
            placed = new ContentInterpreter();
            placed.Run(page, transform);
            placed.MarkRecognizedScan();
        }
        var raster = shown == null ? null : Raster.Render(shown, upright, transform, Math.Min(3, 2400 / Math.Max(Math.Max(upright.W, upright.H), 1)));
        return (new ScanPage(placed, upright, transform, raster), placed);
    }

    /// <summary>Which way the hidden text runs: quarter turns, and how much off them (radians).</summary>
    internal static (double Quarter, double Skew) TurnOf(ContentInterpreter interpreter)
    {
        var counts = new int[4];
        var angles = new List<double>();
        foreach (var glyph in interpreter.Glyphs)
        {
            if (glyph.RenderMode != 3 || glyph.IsClipped) continue;
            int q = (int)Math.Round(glyph.Angle / (Math.PI / 2), MidpointRounding.AwayFromZero);
            counts[((q % 4) + 4) % 4]++;
            angles.Add(glyph.Angle);
        }
        int best = 0;
        for (int k = 1; k < 4; k++) if (counts[k] > counts[best]) best = k;
        if (counts[best] == 0) return (0, 0);
        double quarter = best * Math.PI / 2;
        var off = angles.Select(a => Math.IEEERemainder(a - quarter, 2 * Math.PI)).Where(a => Math.Abs(a) < Math.PI / 4).OrderBy(a => a).ToList();
        double skew = off[off.Count / 2];
        return (Math.IEEERemainder(quarter, 2 * Math.PI), Math.Abs(skew) < 0.003 ? 0 : skew);
    }

    /// <summary>The space a page turned by angle is upright in. Pages that claim to be metres large (one point per pixel of the
    /// scan) come down to the size of a sheet, so that distances mean what they do on other pages.</summary>
    internal static (Affine, Rect) Space(Rect crop, double angle)
    {
        double longSide = Math.Max(crop.W, crop.H);
        double scale = longSide > 1300 ? 842 / longSide : 1;
        if (Math.Abs(angle) < 1e-6 && scale == 1) return (Affine.Identity, crop);
        int quarter = (int)Math.Round(angle / (Math.PI / 2), MidpointRounding.AwayFromZero);
        var (w, h) = quarter % 2 == 0 ? (crop.W, crop.H) : (crop.H, crop.W);
        var upright = new Rect(0, 0, w * scale, h * scale);
        var transform = Affine.Translation(-crop.MidX, -crop.MidY).Concatenating(Affine.Rotation(-angle))
            .Concatenating(Affine.Scale(scale, scale)).Concatenating(Affine.Translation(upright.MidX, upright.MidY));
        return (transform, upright);
    }

    ScanPage(ContentInterpreter interpreter, Rect crop, Affine transform, Raster? raster)
    {
        Crop = crop;
        Transform = transform;
        _rows = RowsOf(interpreter);
        if (_rows.Count == 0) return;
        _usual = Median(_rows.SelectMany(r => r.Words).Select(w => w.Height)) ?? 10;
        if (raster != null)
        {
            var mask = raster.Mask();
            foreach (var word in _rows.SelectMany(r => r.Words)) mask.Measure(word, _usual);
            Fit(XHeight(XRatios(_rows)));
            var (rules, uprights) = mask.Rules(_rows.SelectMany(r => r.Words).ToList());
            _rows = Joined(_rows, mask, uprights);
            (Marks, Bits) = mask.Drawings(_rows, rules, uprights, crop);
        }
        foreach (var word in _rows.SelectMany(r => r.Words))
            if (word.Ink is { } rect) Ink[word.Run] = Ink.TryGetValue(word.Run, out var known) ? known.Union(rect) : rect;
    }

    void Fit(double xHeight)
    {
        foreach (var row in _rows)
        {
            foreach (var word in row.Words) word.Fit(xHeight, _usual);
            Place(row);
        }
    }

    /// <summary>Makes the characters of the pages of one document: what is the same type on one page is the same on all of them.</summary>
    public static void Finish(IReadOnlyList<(ScanPage Scan, ContentInterpreter Interpreter)> pages)
    {
        double height = XHeight(pages.SelectMany(p => XRatios(p.Scan._rows)).ToList());
        foreach (var (scan, _) in pages)
        {
            scan.Fit(height);
            Even(scan._rows);
        }
        Settle(pages.Select(p => p.Scan._rows).ToList());
        foreach (var (scan, interpreter) in pages)
        {
            MarkBold(scan._rows);
            scan.Chars = Characters(scan._rows, interpreter);
            scan._rows = [];
        }
    }

    // MARK: Type

    const string LowLetters = "acemnorsuvwxzαεικνοπστυω", Tails = "gpqyγημρφχψ";

    /// <summary>How tall a word's ink is, in ems from the baseline, when small letters are xHeight tall.</summary>
    internal static (double Bottom, double Top) Extent(string text, double xHeight)
    {
        double bottom = 1, top = -1;
        foreach (var rune in text.EnumerateRunes())
        {
            (double, double) part;
            char c = rune.Value < 0x10000 ? (char)rune.Value : '\0';
            if (OcrTextLayer.IsCjk(rune.Value)) part = (-0.1, 0.84);
            else if (c != 0 && LowLetters.Contains(c)) part = (-0.01, xHeight);
            else if (c != 0 && Tails.Contains(c)) part = (-0.215, xHeight);
            else if (c == 't') part = (-0.01, 0.6);
            else if (Rune.IsLetter(rune) || Rune.IsNumber(rune)) part = (c is 'j' or 'Q' ? -0.2 : -0.01, Rune.IsUpper(rune) || Rune.IsNumber(rune) ? 0.67 : 0.69);
            else part = PageChar.VerticalExtent(rune.ToString());
            bottom = Math.Min(bottom, part.Item1);
            top = Math.Max(top, part.Item2);
        }
        return (bottom, top);
    }

    /// <summary>How tall small letters are beside tall ones, on each row that has words with and without them.</summary>
    static List<double> XRatios(List<Row> rows)
    {
        var ratios = new List<double>();
        foreach (var row in rows)
        {
            if (row.Upright) continue;
            var small = new List<double>();
            var tall = new List<double>();
            foreach (var word in row.Words)
            {
                if (word.Length < 2 || word.Ink is not { } ink) continue;
                if (word.Text.All(c => LowLetters.Contains(c))) small.Add(ink.H);
                if (word.Text.All(c => LowLetters.Contains(c) || "bdfhkl".Contains(c)) && word.Text.Any(c => "bdfhkl".Contains(c))) tall.Add(ink.H);
            }
            if (Median(small) is { } s && Median(tall) is { } t && t > 0) ratios.Add(s / t);
        }
        return ratios;
    }

    /// <summary>How tall small letters are, in ems.</summary>
    static double XHeight(List<double> ratios) =>
        ratios.Count >= 4 && Median(ratios) is { } ratio ? Math.Clamp(ratio, 0.6, 0.82) * 0.7 - 0.01 : 0.46;

    internal static double? Median(IEnumerable<double> values)
    {
        var sorted = values.OrderBy(v => v).ToList();
        return sorted.Count == 0 ? null : sorted[sorted.Count / 2];
    }

    // MARK: Words and rows

    /// <summary>The hidden text as rows of words, as it was written.</summary>
    static List<Row> RowsOf(ContentInterpreter interpreter)
    {
        var rows = new List<Row>();
        var current = new List<Word>();
        bool spaced = false;
        void Flush()
        {
            if (current.Count > 0) rows.Add(new Row { Words = current });
            current = [];
        }
        Word? word = null;
        int lastRun = -1;
        void Close()
        {
            if (word is not { } w) return;
            word = null;
            if (w.Text.Length == 0 || w.X1 <= w.X0 || w.Height <= 0.5) return;
            if (current.Count > 0)
            {
                var p = current[^1];
                double h = Math.Min(p.Height, w.Height), gap = w.X0 - p.X1;
                bool level = Math.Abs(p.Mid - w.Mid) < Math.Max(p.Height, w.Height) * 0.35;
                // (A comma of Chinese takes the room of a character.)
                if (!level || gap < -h * 0.8 || gap > h * (w.Spaced ? 1.5 : EndsCjk(p.Text) ? 1.2 : 0.6)) Flush();
            }
            current.Add(w);
        }
        for (int g = 0; g < interpreter.Glyphs.Count; g++)
        {
            var glyph = interpreter.Glyphs[g];
            if (glyph.RenderMode != 3 || glyph.IsClipped || glyph.Size <= 0.5 || glyph.Size >= 2000) continue;
            var text = glyph.Text ?? "";
            if (string.IsNullOrWhiteSpace(text))
            {
                Close();
                spaced = true;
                continue;
            }
            bool cjk = text.EnumerateRunes().Any(r => OcrTextLayer.IsCjk(r.Value));
            if (glyph.Run != lastRun || cjk) Close();
            lastRun = glyph.Run;
            double x0 = Math.Min(glyph.Origin.X, glyph.End.X), x1 = Math.Max(glyph.Origin.X, glyph.End.X), y = (glyph.Origin.Y + glyph.End.Y) / 2;
            // Across the line for text that stands upright in this space.
            bool sideways = Math.Abs(glyph.Angle) > 0.3;
            var box = glyph.Box;
            if (word == null)
            {
                word = new Word
                {
                    Run = glyph.Run, Glyphs = [g], Text = text, X0 = sideways ? box.MinX : x0, X1 = sideways ? box.MaxX : x1,
                    Bottom = sideways ? box.MinY : y - glyph.Size * 0.2, Top = sideways ? box.MaxY : y + glyph.Size * 0.8, Spaced = spaced,
                };
                spaced = false;
            }
            else
            {
                word.Glyphs.Add(g);
                word.Text += text;
                word.X0 = Math.Min(word.X0, sideways ? box.MinX : x0);
                word.X1 = Math.Max(word.X1, sideways ? box.MaxX : x1);
                if (sideways) { word.Bottom = Math.Min(word.Bottom, box.MinY); word.Top = Math.Max(word.Top, box.MaxY); }
            }
        }
        Close();
        Flush();
        // Text written level over lines that tilt: each line's box is as high as the whole tilt. The words are put back on
        // their line, which goes through the middle of the box.
        foreach (var row in rows)
        {
            double angle = Median(row.Words.SelectMany(w => w.Glyphs).Select(g => interpreter.Glyphs[g].Angle))!.Value;
            if (Math.Abs(angle) > 0.3) { row.Upright = true; continue; }
            if (Math.Abs(angle) <= 0.003) continue;
            double middle = row.Words.Average(w => w.Mid), height = row.Words[0].Height;
            double real = Math.Max(height - Math.Abs(Math.Tan(angle)) * (row.X1 - row.X0), height * 0.3);
            foreach (var w in row.Words) { w.Bottom = middle - real / 2; w.Top = middle + real / 2; }
        }
        // Words that stand: far too many letters for the width of a box that high.
        double usual = Median(rows.Select(r => r.Words[0].Height)) ?? 0;
        foreach (var row in rows)
            if (!row.Upright && row.Words.Sum(w => w.Length) >= 3 && row.Words[0].Height > usual * 2 && row.X1 - row.X0 < row.Words[0].Height * 0.8) row.Upright = true;
        return rows;
    }

    /// <summary>Pieces of one line (recognition cuts lines at formulas and wide gaps) as one row: next to each other, or with
    /// something in between that was not read.</summary>
    static List<Row> Joined(List<Row> rows, InkMask mask, List<Rect> uprights)
    {
        foreach (var row in rows) Place(row);
        var parent = Enumerable.Range(0, rows.Count).ToArray();
        int Find(int x) { while (parent[x] != x) x = parent[x]; return x; }
        var order = Enumerable.Range(0, rows.Count).Where(r => !rows[r].Upright).OrderBy(r => rows[r].X0).ToList();
        for (int n = 0; n < order.Count; n++)
        {
            int a = order[n], b = -1;
            // The nearest piece to the right on the row.
            for (int m = n + 1; m < order.Count; m++)
            {
                int k = order[m];
                double s = Math.Min(rows[a].Size, rows[k].Size);
                if (Math.Abs(rows[a].Baseline - rows[k].Baseline) < s * 0.35 && rows[k].X0 > rows[a].X1 - s * 1.6 && rows[k].X1 > rows[a].X1) { b = k; break; }
            }
            if (b < 0) continue;
            double size = Math.Min(rows[a].Size, rows[b].Size), large = Math.Max(rows[a].Size, rows[b].Size);
            if (large >= size * 1.4) continue;
            double x0 = rows[a].X1, x1 = rows[b].X0;
            double y0 = rows[a].Baseline - size * 0.25, y1 = y0 + size * 1.1, width = x1 - x0;
            double lo = Math.Min(x0, x1), hi = Math.Max(x0, x1);
            if (uprights.Any(u => u.MidX > lo - 1 && u.MidX < hi + 1 && u.MinY < (y0 + y1) / 2 && u.MaxY > (y0 + y1) / 2)) continue;
            double filled = width > 0 ? mask.ColumnsFilled(Rect.FromCorners(x0, y0, x1, y1)) : 1;
            // ("Figure 1." stands apart from its caption.)
            bool label = Math.Abs(width) < size * 2 && rows[a].Words.Count <= 2
                && System.Text.RegularExpressions.Regex.IsMatch(string.Join(" ", rows[a].Words.Select(w => w.Text)), @"^(Figure|Fig\.?|FIGURE|FIG\.?|Table|TABLE|图|表)\s*\d{1,2}\s*[.:：]?$");
            if (label || Math.Abs(width) < size * (EndsCjk(rows[a].Words[^1].Text) ? 1.1 : 0.45) || (width < 0) || (width < size * 7 && filled > 0.45)) parent[Find(b)] = Find(a);
        }
        var result = new List<Row>();
        var index = new Dictionary<int, Row>();
        for (int r = 0; r < rows.Count; r++)
        {
            int root = Find(r);
            if (index.TryGetValue(root, out var row))
            {
                rows[r].Words[0].Spaced = true;
                row.Words = [.. row.Words.Concat(rows[r].Words).OrderBy(w => w.X0)];
            }
            else
            {
                index[root] = rows[r];
                result.Add(rows[r]);
            }
        }
        foreach (var row in result) Place(row);
        return result;
    }

    static bool EndsCjk(string text) => text.Length > 0 && OcrTextLayer.IsCjk(text[^1]);

    static double? Weighted(IEnumerable<(double Value, int Weight)> values)
    {
        var sorted = values.OrderBy(v => v.Value).ToList();
        if (sorted.Count == 0) return null;
        int half = sorted.Sum(v => v.Weight) / 2, sum = 0;
        foreach (var (value, weight) in sorted)
        {
            sum += weight;
            if (sum > half) return value;
        }
        return sorted[^1].Value;
    }

    /// <summary>The row's type size and baseline: what most of its letters say.</summary>
    static void Place(Row row)
    {
        var sized = row.Words.Where(w => w.Size != null).ToList();
        if (Weighted(sized.Select(w => (w.Size!.Value, w.Letters))) is { } size)
        {
            row.Size = size;
            row.Measured = sized.Sum(w => w.Letters) >= 3;
            row.Baseline = Weighted(row.Words.Where(w => w.Baseline != null).Select(w => (w.Baseline!.Value, w.Letters))) ?? row.Words[0].Bottom + row.Words[0].Height * 0.22;
        }
        else
        {
            row.Size = Median(row.Words.Select(w => w.Height))!.Value * 0.92;
            row.Measured = false;
            row.Baseline = row.Words[0].Bottom + row.Words[0].Height * 0.2;
        }
    }

    /// <summary>The lines of one paragraph have one size: those right under each other, as far apart and starting or ending at the
    /// same place, take the size in their middle.</summary>
    static void Even(List<Row> rows)
    {
        var order = rows.Where(r => !r.Upright && r.Measured).OrderByDescending(r => r.Baseline).ToList();
        var taken = new HashSet<Row>();
        var spans = order.ToDictionary(r => r, r => (r.X0, r.X1));
        foreach (var first in order)
        {
            if (taken.Contains(first)) continue;
            var chain = new List<Row> { first };
            double? pitch = null;
            while (true)
            {
                var last = chain[^1];
                var (lx0, lx1) = spans[last];
                Row? next = null;
                foreach (var r in order)
                {
                    double drop = last.Baseline - r.Baseline;
                    if (taken.Contains(r) || drop <= last.Size * 0.8 || drop >= last.Size * 1.7 || Math.Abs(r.Size / last.Size - 1) >= 0.2) continue;
                    if (pitch is { } p && Math.Abs(drop - p) > p * 0.12) continue;
                    var (x0, x1) = spans[r];
                    if (!(Math.Abs(x0 - lx0) < last.Size * 0.5 || (Math.Abs(x1 - lx1) < last.Size * 0.5 && x0 < lx1))) continue;
                    if (next == null || r.Baseline > next.Baseline) next = r;
                }
                if (next == null) break;
                pitch ??= last.Baseline - next.Baseline;
                chain.Add(next);
            }
            taken.UnionWith(chain);
            if (chain.Count < 3) continue;
            double middle = Median(chain.Select(r => r.Size))!.Value;
            foreach (var r in chain) if (Math.Abs(r.Size / middle - 1) < 0.13) r.Size = middle;
        }
    }

    /// <summary>The sizes of the document's type: rows within a tenth of each other share the size most of their letters have; a
    /// few stray letters take the size of the text around them.</summary>
    static void Settle(List<List<Row>> pages)
    {
        var rest = pages.SelectMany(p => p).Where(r => !r.Upright && r.Measured).Select(r => (Row: r, r.Size, r.Letters)).ToList();
        var sizes = new List<(double Size, int Letters)>();
        while (rest.Count > 0)
        {
            var steps = new SortedDictionary<int, int>();
            foreach (var entry in rest)
            {
                int step = (int)Math.Round(Math.Log(entry.Size) * 100, MidpointRounding.AwayFromZero);
                steps[step] = steps.GetValueOrDefault(step) + entry.Letters;
            }
            int best = 0, count = -1;
            foreach (var step in steps.Keys)
            {
                int n = 0;
                for (int k = -7; k <= 7; k++) n += steps.GetValueOrDefault(step + k) * (8 - Math.Abs(k));
                if (n > count) { count = n; best = step; }
            }
            double centre = Math.Exp(best / 100.0);
            var members = rest.Where(e => e.Size >= centre * 0.89 && e.Size <= centre * 1.12).ToList();
            int total = members.Sum(m => m.Letters);
            // What is left beside a size with far more letters, close to it, is that size measured badly.
            int near = sizes.FindIndex(s => s.Letters > total * 12 && total < 60 && Math.Abs(centre / s.Size - 1) < (total < 8 ? 0.2 : 0.14));
            if (near < 0) sizes.Add((centre, total));
            foreach (var m in members) m.Row.Size = near < 0 ? centre : sizes[near].Size;
            rest.RemoveAll(e => e.Size >= centre * 0.89 && e.Size <= centre * 1.12);
        }
        foreach (var rows in pages)
        {
            var measured = rows.Where(r => r.Measured && !r.Upright).ToList();
            foreach (var row in rows)
            {
                if (row.Upright || row.Measured) continue;
                // Too little to measure: like the closest text.
                var near = measured.Where(r => r.X0 < row.X1 + 60 && r.X1 > row.X0 - 60).MinBy(r => Math.Abs(r.Baseline - row.Baseline));
                if (near != null && Math.Abs(near.Baseline - row.Baseline) < near.Size * 3 && row.Size < near.Size * 1.6 && row.Size > near.Size * 0.6) row.Size = near.Size;
                else if (sizes.Count > 0 && sizes.MinBy(s => Math.Abs(s.Size / row.Size - 1)) is var size && Math.Abs(size.Size / row.Size - 1) < 0.25) row.Size = size.Size;
            }
        }
    }

    /// <summary>Words set in bold: strokes clearly thicker, for their size, than most of the page's. A short word goes with the
    /// words beside it.</summary>
    static void MarkBold(List<Row> rows)
    {
        static double? Weight(Word word, Row row) => word.Letters >= 3 && word.Stroke is { } stroke && row.Size > 0 ? stroke / row.Size : null;
        var values = rows.Where(r => !r.Upright).SelectMany(r => r.Words.Select(w => (Weight: Weight(w, r), w.Letters))).Where(v => v.Weight != null)
            .Select(v => (v.Weight!.Value, v.Letters)).ToList();
        // (Pages are scanned one by one, lighter or darker: each is its own measure.)
        if (values.Sum(v => v.Letters) < 120) return;
        double usual = Weighted(values)!.Value;
        foreach (var row in rows)
        {
            if (row.Upright) continue;
            // The whole row first: heavier altogether, with hardly a word that is not.
            var weights = row.Words.Select(w => Weight(w, row)).ToList();
            double total = 0;
            int letters = 0, heavy = 0;
            for (int k = 0; k < weights.Count; k++)
            {
                if (weights[k] is not { } w) continue;
                total += w * row.Words[k].Letters;
                letters += row.Words[k].Letters;
                if (w > usual * 1.08) heavy += row.Words[k].Letters;
            }
            if (letters < 3) continue;
            if (total / letters > usual * (letters < 6 ? 1.5 : letters < 12 ? 1.25 : 1.17) && heavy * 10 >= letters * 8)
            {
                foreach (var w in row.Words) w.Bold = true;
                continue;
            }
            var marks = weights.Select(w => w is { } v ? v > usual * (letters < 6 ? 1.6 : 1.26) : (bool?)null).ToList();
            for (int k = 0; k < marks.Count; k++)
            {
                if (marks[k] is { } mark) { row.Words[k].Bold = mark; continue; }
                bool? before = marks.Take(k).LastOrDefault(m => m != null), after = marks.Skip(k + 1).FirstOrDefault(m => m != null);
                row.Words[k].Bold = (before == true && after != false) || (before == null && after == true);
            }
        }
    }

    /// <summary>The characters of the rows, with the sizes and baselines measured.</summary>
    static List<PageChar> Characters(List<Row> rows, ContentInterpreter interpreter)
    {
        var chars = new List<PageChar>();
        foreach (var row in rows)
        {
            Word? previous = null;
            foreach (var word in row.Words)
            {
                if (previous != null && chars.Count > 0)
                {
                    var last = chars[^1];
                    bool needed = word.Spaced && OcrTextLayer.NeedsSpace(previous.Text, word.Text);
                    if (needed || word.X0 - previous.X1 > row.Size * 0.6)
                    {
                        // Words read edge to edge, or over each other's edges, give way to the space between them.
                        double missing = row.Size * 0.25 - (word.X0 - last.Rect.MaxX);
                        if (missing > 0) last.Rect = new Rect(last.Rect.MinX, last.Rect.MinY, Math.Max(0.1, last.Rect.W - Math.Min(missing, last.Rect.W * 0.6)), last.Rect.H);
                        var space = last.Clone();
                        space.Text = " ";
                        space.IsSpace = true;
                        space.Glyphs = [];
                        space.Run = null;
                        space.Rect = new Rect(last.Rect.MaxX, last.Rect.MinY, Math.Max(word.X0 - last.Rect.MaxX, 0.1), last.Rect.H);
                        chars.Add(space);
                    }
                }
                var font = word.Bold ? FontInfo.Unknown with { IsBold = true } : FontInfo.Unknown;
                // (Pieces of a line read twice over the same place: one after the other.)
                double end = chars.Count == 0 || chars[^1].IsNewline ? double.NegativeInfinity : chars[^1].Rect.MaxX;
                double from = Math.Min(Math.Max(word.X0, end), word.X0 + (word.X1 - word.X0) * 0.8), stretch = (word.X1 - from) / Math.Max(word.X1 - word.X0, 0.01);
                foreach (var g in word.Glyphs)
                {
                    var glyph = interpreter.Glyphs[g];
                    double x0 = from + (Math.Min(glyph.Origin.X, glyph.End.X) - word.X0) * stretch, x1 = from + (Math.Max(glyph.Origin.X, glyph.End.X) - word.X0) * stretch;
                    chars.Add(new PageChar
                    {
                        Text = glyph.Text ?? "", Rect = row.Upright ? glyph.Box : new Rect(x0, row.Baseline - row.Size * 0.22, Math.Max(x1 - x0, 0.1), row.Size * 1.2),
                        Size = row.Size, Baseline = row.Baseline, Font = font, Color = RGBColor.Black, Run = glyph.Run, IsRotated = row.Upright, Glyphs = [g],
                    });
                }
                previous = word;
            }
            if (chars.Count > 0)
            {
                var br = chars[^1].Clone();
                br.Text = "\n";
                br.IsNewline = true;
                br.Glyphs = [];
                br.Run = null;
                chars.Add(br);
            }
        }
        return chars;
    }
}
