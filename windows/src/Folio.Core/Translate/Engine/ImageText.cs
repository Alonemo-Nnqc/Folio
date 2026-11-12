using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;
using Folio.Core.Translate.Typeset;
using System.Text;
using SkiaSharp;

namespace Folio.Core.Translate.Engine;

/// <summary>Text inside pictures (TRANS-40, optional), as the macOS engine does it (ImageText.swift): the words of a
/// page's pictures (read with OCR, across and up the page) and the labels of figures drawn in vectors (the figure's own
/// text, sideways text gathered into columns) are translated and set back in place: only the words leave the picture
/// (strokes touching their box, filled from what is beside them; a label drawn as text loses its glyphs), the
/// translation keeps their colour, is never longer than they were, and keeps how the labels stood — lines one under the
/// other keep their edges or centres in line and share one size, a label alone keeps its centre. Rendering and OCR are
/// the platform's (<see cref="Platform"/>: Windows.Data.Pdf and Windows.Media.Ocr in the app).</summary>
public static class ImageText
{
    /// <summary>A part of a page rendered: RGBA, rows from the top.</summary>
    public sealed record Bitmap(byte[] Rgba, int Width, int Height)
    {
        public (double R, double G, double B) Pixel(int x, int y)
        {
            x = Math.Clamp(x, 0, Width - 1); y = Math.Clamp(y, 0, Height - 1);
            int p = (y * Width + x) * 4;
            return (Rgba[p] / 255.0, Rgba[p + 1] / 255.0, Rgba[p + 2] / 255.0);
        }

        /// <summary>Turned a quarter clockwise: text that read up the page reads across.</summary>
        public Bitmap TurnedClockwise()
        {
            var output = new byte[Rgba.Length];
            for (int y = 0; y < Height; y++)
                for (int x = 0; x < Width; x++)
                {
                    int s = (y * Width + x) * 4, t = (x * Height + (Height - 1 - y)) * 4;
                    output[t] = Rgba[s]; output[t + 1] = Rgba[s + 1]; output[t + 2] = Rgba[s + 2]; output[t + 3] = 255;
                }
            return new Bitmap(output, Height, Width);
        }
    }

    /// <summary>What the platform does: render region (page space) of page (1-based) of the file, whose crop box is given,
    /// at about scale pixels per point; read the words of a bitmap in a language (word boxes in pixels, from the top left).</summary>
    public sealed record Services(Func<string, int, Rect, Rect, double, Task<Bitmap?>> Render, Func<Bitmap, string, Task<List<OcrLine>>> Read);

    public static Services? Platform { get; set; }

    public enum Alignment { Left, Center, Right }

    /// <summary>A run of words: where (page space), what, its colour; the picture under it with the words taken out (or,
    /// for a label drawn as text, its glyphs); sideways (reading up, or down); how it stands with the lines of its group.</summary>
    public sealed record Line(int Page, Rect Rect, string Text, RGBColor Color, Bitmap? Patch, Rect PatchRect)
    {
        public bool Vertical { get; init; }
        public bool ReadsDown { get; init; }
        public Alignment Align { get; set; } = Alignment.Center;
        public int Group { get; set; }
        public List<int> Glyphs { get; init; } = [];
        public double? Size { get; init; }
    }

    /// <summary>A run found: text, box (pixels from the top left, or page space for labels drawn as text), sideways.</summary>
    public sealed record Run(string Text, Rect Box, bool Vertical);

    /// <summary>The words in the pictures of page number and the labels of its figures drawn in vectors.</summary>
    public static async Task<List<Line>> Recognize(string path, PdfSource source, int number, string language, PageLayout? layout = null)
    {
        if (number < 1 || number > source.Pages.Count) return [];
        var page = source.Pages[number - 1];
        var geometry = PdfComposer.Geometry(page);
        if (geometry.Rotation % 360 != 0) return [];
        var interpreter = new ContentInterpreter();
        interpreter.Run(page);
        var vector = layout != null ? VectorLabels(layout, interpreter) : [];
        var services = Platform;
        if (services == null) return vector;
        var media = geometry.CropBox;
        var textBoxes = interpreter.Glyphs.Where(g => g.IsVisible && (g.Text?.Any(char.IsLetterOrDigit) ?? false)).Select(g => g.Box).ToList();
        var pictures = new List<Rect>();
        foreach (var (_, image) in interpreter.Images)
        {
            var corners = new[] { new Pt(0, 0), new Pt(1, 0), new Pt(0, 1), new Pt(1, 1) }.Select(p => p.Applying(image.Matrix));
            var rect = Rect.Bounds(corners).Intersection(media);
            if (rect.IsNull || rect.W < 24 || rect.H < 12 || rect.Area >= media.Area * 0.8) continue;
            pictures.Add(rect);
        }
        var lines = new List<Line>();
        int group = 0;
        foreach (var picture in MergedPictures(pictures, media))
        {
            double scale = Math.Clamp(2400 / Math.Max(picture.W, picture.H), 2.5, 4);
            var bitmap = await services.Render(path, number, media, picture, scale);
            if (bitmap == null) continue;
            var runs = new List<Run>();
            try { runs.AddRange(Runs(await services.Read(bitmap, language)).Select(r => new Run(r.Text, r.Box, false))); } catch { }
            // Sideways labels: read on the picture turned a quarter, where they lie across.
            try
            {
                var turned = bitmap.TurnedClockwise();
                foreach (var (text, box) in Runs(await services.Read(turned, language)))
                {
                    // Back to the picture: x' = h - 1 - y, y' = x.
                    var original = new Rect(box.MinY, bitmap.Height - box.MaxX, box.H, box.W);
                    if (original.H <= original.W * 1.5) continue;
                    if (runs.Any(r => r.Box.Intersection(original) is { IsNull: false } i && i.Area > original.Area * 0.2)) continue;
                    runs.Add(new Run(text, original, true));
                }
            }
            catch { }
            double sx = picture.W / bitmap.Width, sy = picture.H / bitmap.Height;
            Rect ToPage(Rect r) => new(picture.MinX + r.MinX * sx, picture.MaxY - r.MaxY * sy, r.W * sx, r.H * sy);
            var found = new List<(Run Run, Line Line)>();
            foreach (var run in runs.Where(r => IsWords(r.Text)))
            {
                var box = ToPage(run.Box);
                if (textBoxes.Any(t => t.Intersection(box) is { IsNull: false } i && i.Area > box.Area * 0.3)) continue;
                if (Erase(run, bitmap) is not { } erased) continue;
                found.Add((run, new Line(number, box, run.Text, erased.Color, erased.Patch, ToPage(erased.Area)) { Vertical = run.Vertical }));
            }
            var arranged = Arrange(found.Select(f => f.Run).ToList());
            for (int k = 0; k < found.Count; k++)
            {
                found[k].Line.Align = arranged[k].Align;
                found[k].Line.Group = group + arranged[k].Group;
                lines.Add(found[k].Line);
            }
            group += found.Count + 1;
        }
        // Words read from a picture under a label drawn as text: the label's.
        lines.RemoveAll(l => vector.Any(v => v.Rect.Intersection(l.Rect) is { IsNull: false } i && i.Area > l.Rect.Area * 0.3));
        return [.. lines, .. vector];
    }

    /// <summary>Pictures side by side (a figure made of many) as one, with a little room around.</summary>
    static List<Rect> MergedPictures(List<Rect> rects, Rect media)
    {
        var pictures = new List<Rect>(rects);
        for (bool merged = true; merged;)
        {
            merged = false;
            for (int i = 0; i < pictures.Count && !merged; i++)
                for (int j = i + 1; j < pictures.Count; j++)
                {
                    if (pictures[i].InsetBy(-14, -14).Intersection(pictures[j]).IsNull) continue;
                    pictures[i] = pictures[i].Union(pictures[j]);
                    pictures.RemoveAt(j);
                    merged = true;
                    break;
                }
        }
        return pictures.Where(p => p.W >= 48 && p.H >= 24).Select(p => p.InsetBy(-18, -6).Intersection(media)).Where(p => !p.IsNull).ToList();
    }

    /// <summary>Runs of an OCR result: words far apart on one line (labels side by side) are runs of their own.</summary>
    static List<(string Text, Rect Box)> Runs(List<OcrLine> read)
    {
        var result = new List<(string, Rect)>();
        foreach (var line in read)
        {
            var groups = new List<(string Text, Rect Box)>();
            foreach (var word in line.Words)
            {
                var box = new Rect(word.X, word.Y, word.Width, word.Height);
                if (groups.Count > 0 && box.MinX - groups[^1].Box.MaxX < Math.Max(groups[^1].Box.H, box.H) * 1.1)
                    groups[^1] = (OcrTextLayer.NeedsSpace(groups[^1].Text, word.Text) ? groups[^1].Text + " " + word.Text : groups[^1].Text + word.Text, groups[^1].Box.Union(box));
                else groups.Add((word.Text, box));
            }
            if (groups.Count == 0) continue;
            // One height for the runs of a line: the line's.
            double top = groups.Min(g => g.Box.MinY), bottom = groups.Max(g => g.Box.MaxY);
            result.AddRange(groups.Select(g => (g.Text.Trim(), Rect.FromCorners(g.Box.MinX, top, g.Box.MaxX, bottom))));
        }
        return result;
    }

    /// <summary>Words worth translating: two letters at least, more letters than digits, not an abbreviation alone.</summary>
    public static bool IsWords(string text)
    {
        int letters = text.Count(char.IsLetter), digits = text.Count(char.IsDigit);
        if (letters < 2 || letters <= digits) return false;
        if (!text.Contains(' ') && letters <= 4 && text.Where(char.IsLetter).All(char.IsUpper)) return false;
        return true;
    }

    // Taking the words out

    static double Distance((double R, double G, double B) a, (double R, double G, double B) b) => Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B);

    /// <summary>The words' strokes (pixels unlike the background around them and like the words' ink, in shapes reaching
    /// into the words' box) filled from what is beside them, across rows (or columns for words up the page).</summary>
    static (Bitmap Patch, Rect Area, RGBColor Color)? Erase(Run run, Bitmap bitmap)
    {
        var box = run.Box;
        double thickness = run.Vertical ? box.W : box.H, along = thickness * 0.3, across = thickness * 0.12;
        var area = box.InsetBy(-(run.Vertical ? across : along), -(run.Vertical ? along : across)).Intersection(new Rect(0, 0, bitmap.Width, bitmap.Height));
        if (area.IsNull) return null;
        int px = (int)Math.Floor(area.MinX), py = (int)Math.Floor(area.MinY);
        int pw = (int)Math.Ceiling(area.MaxX) - px, ph = (int)Math.Ceiling(area.MaxY) - py;
        if (pw <= 2 || ph <= 2 || pw * ph > 4_000_000) return null;
        var ring = new List<(double R, double G, double B)>();
        int step = Math.Max(1, (pw + ph) / 160);
        for (int x = px; x <= px + pw; x += step) { ring.Add(bitmap.Pixel(x, py - 2)); ring.Add(bitmap.Pixel(x, py + ph + 1)); }
        for (int y = py; y <= py + ph; y += step) { ring.Add(bitmap.Pixel(px - 2, y)); ring.Add(bitmap.Pixel(px + pw + 1, y)); }
        double Mid(IEnumerable<double> v) { var s = v.OrderBy(x => x).ToList(); return s[s.Count / 2]; }
        var background = (R: Mid(ring.Select(c => c.R)), G: Mid(ring.Select(c => c.G)), B: Mid(ring.Select(c => c.B)));
        var colors = new (double R, double G, double B)[pw * ph];
        for (int y = 0; y < ph; y++) for (int x = 0; x < pw; x++) colors[y * pw + x] = bitmap.Pixel(px + x, py + y);
        int bx0 = (int)box.MinX - px, by0 = (int)box.MinY - py, bx1 = (int)box.MaxX - px, by1 = (int)box.MaxY - py;
        var inside = new List<(double R, double G, double B)>();
        for (int y = Math.Max(0, by0); y < Math.Min(ph, Math.Max(by1, by0 + 1)); y++)
            for (int x = Math.Max(0, bx0); x < Math.Min(pw, Math.Max(bx1, bx0 + 1)); x++) inside.Add(colors[y * pw + x]);
        if (inside.Count == 0) return null;
        var darkest = inside.OrderByDescending(c => Distance(c, background)).Take(Math.Max(1, inside.Count / 10)).ToList();
        var ink = (R: darkest.Average(c => c.R), G: darkest.Average(c => c.G), B: darkest.Average(c => c.B));
        double contrast = Distance(ink, background);
        if (contrast <= 0.12) return null;
        var mask = new bool[pw * ph];
        for (int i = 0; i < mask.Length; i++)
            mask[i] = Distance(colors[i], background) > contrast * 0.28 && Distance(colors[i], ink) < Distance(colors[i], background) * 1.6;
        // Only the shapes that reach into the words' box.
        var label = new int[pw * ph];
        var keep = new HashSet<int> { 0 };
        int next = 1;
        var stack = new Stack<int>();
        for (int start = 0; start < mask.Length; start++)
        {
            if (!mask[start] || label[start] != 0) continue;
            label[start] = next;
            stack.Push(start);
            bool touches = false;
            while (stack.Count > 0)
            {
                int i = stack.Pop(), x = i % pw, y = i / pw;
                if (x >= bx0 && x < bx1 && y >= by0 && y < by1) touches = true;
                foreach (var (dx, dy) in new[] { (1, 0), (-1, 0), (0, 1), (0, -1) })
                {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || nx >= pw || ny < 0 || ny >= ph) continue;
                    int j = ny * pw + nx;
                    if (mask[j] && label[j] == 0) { label[j] = next; stack.Push(j); }
                }
            }
            if (touches) keep.Add(next);
            next++;
        }
        for (int i = 0; i < mask.Length; i++) if (mask[i] && !keep.Contains(label[i])) mask[i] = false;
        int grow = Math.Max(1, (int)(thickness / 18));
        var grown = new bool[pw * ph];
        for (int y = 0; y < ph; y++)
            for (int x = 0; x < pw; x++)
            {
                if (!mask[y * pw + x]) continue;
                for (int dy = -grow; dy <= grow; dy++)
                    for (int dx = -grow; dx <= grow; dx++)
                    {
                        int nx = x + dx, ny = y + dy;
                        if (nx >= 0 && nx < pw && ny >= 0 && ny < ph) grown[ny * pw + nx] = true;
                    }
            }
        var filled = ((double R, double G, double B)[])colors.Clone();
        int lineCount = run.Vertical ? pw : ph, length = run.Vertical ? ph : pw;
        int Index(int line, int k) => run.Vertical ? k * pw + line : line * pw + k;
        for (int line = 0; line < lineCount; line++)
        {
            int k = 0;
            while (k < length)
            {
                if (!grown[Index(line, k)]) { k++; continue; }
                int end = k;
                while (end < length && grown[Index(line, end)]) end++;
                var a = k > 0 ? colors[Index(line, k - 1)] : background;
                var b = end < length ? colors[Index(line, end)] : background;
                for (int m = k; m < end; m++)
                {
                    double t = (m - k + 1.0) / (end - k + 1.0);
                    filled[Index(line, m)] = (a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t);
                }
                k = end;
            }
        }
        var bytes = new byte[pw * ph * 4];
        for (int i = 0; i < filled.Length; i++)
        {
            bytes[i * 4] = (byte)Math.Clamp(filled[i].R * 255, 0, 255);
            bytes[i * 4 + 1] = (byte)Math.Clamp(filled[i].G * 255, 0, 255);
            bytes[i * 4 + 2] = (byte)Math.Clamp(filled[i].B * 255, 0, 255);
            bytes[i * 4 + 3] = 255;
        }
        return (new Bitmap(bytes, pw, ph), new Rect(px, py, pw, ph), new RGBColor(ink.R, ink.G, ink.B));
    }

    // Labels drawn as text

    /// <summary>The labels of figures drawn in vectors: lines of the figure's own text cut where words stand far apart, and
    /// sideways characters gathered into columns, reading up or down as their glyphs are turned.</summary>
    public static List<Line> VectorLabels(PageLayout layout, ContentInterpreter interpreter)
    {
        var runs = new List<Run>();
        var lines = new List<Line>();
        var figures = layout.Figures.Select(f => f.InsetBy(-12, -12)).ToList();
        var inFigure = layout.Blocks.Where(b => !b.Translate && (b.Kind == BlockKind.Figure
            || figures.Any(f => !f.Intersection(b.Rect).IsNull) && b.Kind != BlockKind.Paragraph)).ToList();
        var sideways = new List<(PageChar Char, bool Down)>();
        foreach (var block in inFigure)
            foreach (var line in block.Lines)
                foreach (var c in line.Chars.Where(c => !c.IsSpace && (c.IsRotated || line.IsRotated)))
                {
                    if (c.Glyphs.Count == 0 || c.Glyphs[0] >= interpreter.Glyphs.Count) continue;
                    var m = interpreter.Glyphs[c.Glyphs[0]].Matrix;
                    double angle = Math.Atan2(m.B, m.A);
                    if (Math.Abs(Math.Abs(angle) - Math.PI / 2) >= 0.2) continue;
                    sideways.Add((c, angle < 0));
                }
        var columns = new List<List<(PageChar Char, bool Down)>>();
        foreach (var item in sideways.OrderBy(i => i.Down ? -i.Char.Rect.MidY : i.Char.Rect.MidY))
        {
            int k = columns.FindLastIndex(column =>
            {
                var last = column[^1];
                double gap = item.Down ? last.Char.Rect.MinY - item.Char.Rect.MaxY : item.Char.Rect.MinY - last.Char.Rect.MaxY;
                return last.Down == item.Down && Math.Abs(last.Char.Rect.MidX - item.Char.Rect.MidX) < item.Char.Size * 0.6 && gap < item.Char.Size * 1.1 && gap > -item.Char.Size;
            });
            if (k >= 0) columns[k].Add(item); else columns.Add([item]);
        }
        foreach (var column in columns)
        {
            var text = "";
            for (int k = 0; k < column.Count; k++)
            {
                if (k > 0)
                {
                    var last = column[k - 1].Char;
                    double gap = column[k].Down ? last.Rect.MinY - column[k].Char.Rect.MaxY : column[k].Char.Rect.MinY - last.Rect.MaxY;
                    if (gap > column[k].Char.Size * 0.18) text += " ";
                }
                text += column[k].Char.Text;
            }
            if (!IsWords(text)) continue;
            var ink = column.Skip(1).Aggregate(column[0].Char.Rect, (r, c) => r.Union(c.Char.Rect));
            double size = column.Max(c => c.Char.Size);
            var rect = new Rect(ink.MidX - size * 0.51, ink.MinY, size * 1.02, ink.H);
            runs.Add(new Run(text, rect, true));
            lines.Add(new Line(layout.Number, rect, text, column[0].Char.Color, null, Rect.Null)
                { Vertical = true, ReadsDown = column[0].Down, Glyphs = column.SelectMany(c => c.Char.Glyphs).ToList(), Size = size });
        }
        foreach (var block in inFigure)
            foreach (var line in block.Lines.Where(l => !l.IsRotated))
            {
                var current = new List<PageChar>();
                void Flush()
                {
                    var chars = current.Where(c => !c.IsSpace).ToList();
                    current = [];
                    if (chars.Count == 0) return;
                    var spaced = "";
                    for (int k = 0; k < chars.Count; k++)
                    {
                        if (k > 0 && chars[k].Rect.MinX - chars[k - 1].Rect.MaxX > line.Size * 0.18) spaced += " ";
                        spaced += chars[k].Text;
                    }
                    if (!IsWords(spaced)) return;
                    var ink = chars.Skip(1).Aggregate(chars[0].Rect, (r, c) => r.Union(c.Rect));
                    var rect = new Rect(ink.MinX, line.Baseline - line.Size * 0.24, ink.W, line.Size * 1.02);
                    runs.Add(new Run(spaced, rect, false));
                    lines.Add(new Line(layout.Number, rect, spaced, line.Color, null, Rect.Null) { Glyphs = chars.SelectMany(c => c.Glyphs).ToList(), Size = line.Size });
                }
                foreach (var c in line.Chars.Where(c => !c.IsRotated))
                {
                    var last = current.LastOrDefault(x => !x.IsSpace);
                    if (last != null && !c.IsSpace && c.Rect.MinX - last.Rect.MaxX > line.Size * 1.1) Flush();
                    current.Add(c);
                }
                Flush();
            }
        var arranged = Arrange(runs);
        for (int k = 0; k < lines.Count; k++)
        {
            lines[k].Align = arranged[k].Align;
            lines[k].Group = 1_000_000 + layout.Number * 10_000 + arranged[k].Group;
        }
        return lines;
    }

    // How the labels stand

    /// <summary>Each run's group (runs one under the other, of about one size, overlapping across) and the group's
    /// alignment: left edges, right edges or centres in line, whichever lines up best; a run alone keeps its centre.</summary>
    public static List<(int Group, Alignment Align)> Arrange(List<Run> runs)
    {
        var parent = Enumerable.Range(0, runs.Count).ToArray();
        int Root(int i) => parent[i] == i ? i : Root(parent[i]);
        for (int i = 0; i < runs.Count; i++)
            for (int j = i + 1; j < runs.Count; j++)
            {
                if (runs[i].Vertical || runs[j].Vertical) continue;
                Rect a = runs[i].Box, b = runs[j].Box;
                double gap = Math.Max(a.MinY, b.MinY) - Math.Min(a.MaxY, b.MaxY), size = Math.Max(a.H, b.H);
                if (gap >= size * 0.8 || Math.Max(a.H, b.H) >= Math.Min(a.H, b.H) * 1.4 || Math.Min(a.MaxX, b.MaxX) - Math.Max(a.MinX, b.MinX) <= -size * 0.2) continue;
                parent[Root(j)] = Root(i);
            }
        var result = new List<(int, Alignment)>(Enumerable.Repeat((0, Alignment.Center), runs.Count));
        foreach (var members in Enumerable.Range(0, runs.Count).GroupBy(Root))
        {
            var align = Alignment.Center;
            var list = members.ToList();
            if (list.Count >= 2)
            {
                double Spread(IEnumerable<double> v) => v.Max() - v.Min();
                double left = Spread(list.Select(m => runs[m].Box.MinX)), center = Spread(list.Select(m => runs[m].Box.MidX)), right = Spread(list.Select(m => runs[m].Box.MaxX));
                align = left <= center && left <= right ? Alignment.Left : center <= right ? Alignment.Center : Alignment.Right;
            }
            foreach (var m in list) result[m] = (members.Key, align);
        }
        return result;
    }

    // Drawing

    static FontCatalog.Face FaceFor(string text, string language)
    {
        bool cjk = language.StartsWith("zh") || language.StartsWith("ja") || language.StartsWith("ko");
        var face = cjk ? FontCatalog.Script(language, false, false) ?? FontCatalog.Latin(false, false) : FontCatalog.Latin(false, false);
        bool Covers(FontCatalog.Face f) => text.EnumerateRunes().All(r => Rune.IsWhiteSpace(r) || f.Typeface.ContainsGlyph(r.Value));
        if (Covers(face)) return face;
        var missing = text.EnumerateRunes().First(r => !Rune.IsWhiteSpace(r) && !face.Typeface.ContainsGlyph(r.Value));
        var fallback = FontCatalog.Fallback(missing.Value, false, language);
        return Covers(fallback) ? fallback : face;
    }

    sealed record Fit(double Size, double Squeeze, double Width);

    static Fit FitText(string text, SKTypeface face, double length, double thickness, double? given, double? natural)
    {
        double Measure(double size) { using var font = new SKFont(face, (float)Math.Max(size, 1)) { Subpixel = true, LinearMetrics = true }; return font.MeasureText(text); }
        double size = given ?? natural ?? thickness * 0.82;
        double width = Measure(size);
        if (given == null && width > length)
        {
            size = Math.Max(thickness * 0.5, size * length / Math.Max(width, 0.01));
            width = Measure(size);
        }
        double squeeze = width > length ? Math.Max(0.75, length / width) : 1;
        if (width * squeeze > length)
        {
            size *= length / (width * squeeze);
            width = Measure(size);
            squeeze = width > length ? length / width : 1;
        }
        return new Fit(size, squeeze, width * squeeze);
    }

    /// <summary>The translations of a page's figures on a y-down canvas whose top is pageTop: first the patches, then the
    /// translations, a group's lines at one size, each aligned as the words were.</summary>
    public static void Draw(List<(Line Line, string Translation)> entries, string language, SKCanvas canvas, double pageTop, HashSet<ushort>? used)
    {
        foreach (var (line, _) in entries)
        {
            if (line.Patch is not { } patch) continue;
            var info = new SKImageInfo(patch.Width, patch.Height, SKColorType.Rgba8888, SKAlphaType.Opaque);
            using var image = SKImage.FromPixelCopy(info, patch.Rgba);
            var r = line.PatchRect;
            canvas.DrawImage(image, new SKRect((float)r.MinX, (float)(pageTop - r.MaxY), (float)r.MaxX, (float)(pageTop - r.MinY)),
                new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.None));
        }
        static double Length(Line l) => l.Vertical ? l.Rect.H : l.Rect.W;
        static double Thickness(Line l) => l.Vertical ? l.Rect.W : l.Rect.H;
        var faces = entries.Select(e => FaceFor(e.Translation, language)).ToList();
        var fits = entries.Select((e, k) => FitText(e.Translation, faces[k].Typeface, Length(e.Line), Thickness(e.Line), null, e.Line.Size)).ToList();
        foreach (var members in Enumerable.Range(0, entries.Count).GroupBy(k => entries[k].Line.Group).Where(g => g.Count() > 1))
        {
            double size = members.Min(m => fits[m].Size);
            foreach (var m in members) fits[m] = FitText(entries[m].Translation, faces[m].Typeface, Length(entries[m].Line), Thickness(entries[m].Line), size, null);
        }
        for (int k = 0; k < entries.Count; k++)
        {
            var (line, translation) = entries[k];
            var fit = fits[k];
            using var font = new SKFont(faces[k].Typeface, (float)fit.Size) { Subpixel = true, LinearMetrics = true, ScaleX = (float)fit.Squeeze };
            used?.UnionWith(font.GetGlyphs(translation));
            double ascent = -font.Metrics.Ascent, descent = font.Metrics.Descent;
            double room = Length(line) - fit.Width;
            double offset = line.Align switch { Alignment.Left => 0, Alignment.Right => room, _ => room / 2 };
            double rise = (Thickness(line) - (ascent + descent)) / 2 + descent;
            var c = line.Color;
            using var paint = new SKPaint { Color = new SKColor((byte)Math.Round(c.R * 255), (byte)Math.Round(c.G * 255), (byte)Math.Round(c.B * 255)), IsAntialias = true };
            canvas.Save();
            // Page space (y up) on a y-down canvas: a point (x, y) is (x, pageTop - y).
            if (line.Vertical && line.ReadsDown)
            {
                canvas.Translate((float)(line.Rect.MinX + rise), (float)(pageTop - (line.Rect.MaxY - offset)));
                canvas.RotateDegrees(90);
            }
            else if (line.Vertical)
            {
                canvas.Translate((float)(line.Rect.MaxX - rise), (float)(pageTop - (line.Rect.MinY + offset)));
                canvas.RotateDegrees(-90);
            }
            else canvas.Translate((float)(line.Rect.MinX + offset), (float)(pageTop - (line.Rect.MinY + rise)));
            canvas.DrawText(translation, 0, 0, font, paint);
            canvas.Restore();
        }
    }
}
