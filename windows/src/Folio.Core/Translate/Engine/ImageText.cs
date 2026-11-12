using Folio.Core.Translate.Pdf;
using Folio.Core.Translate.Typeset;
using SkiaSharp;

namespace Folio.Core.Translate.Engine;

/// <summary>Text inside pictures (TRANS-40, optional), as the macOS engine does it (ImageText.swift): each picture of a
/// page (pictures side by side read as one) is rendered and read with OCR; every run of words becomes a segment to
/// translate, and the translation is set back over the picture in the words' own box — the words taken out of the
/// picture (their pixels filled from what is beside them, so lines and shapes behind them stay), the translation in
/// their colour, as large as fits. Numbers, abbreviations and text the page draws as real text are left alone.
/// Rendering and OCR are the platform's (<see cref="Platform"/>: Windows.Data.Pdf and Windows.Media.Ocr in the app).</summary>
public static class ImageText
{
    /// <summary>A part of a page rendered: RGBA, rows from the top.</summary>
    public sealed record Bitmap(byte[] Rgba, int Width, int Height);

    /// <summary>What the platform does: render region (page space) of page (1-based) of the file, whose crop box is given,
    /// at about scale pixels per point; read the words of a bitmap in a language (word boxes in pixels, from the top left).</summary>
    public sealed record Services(Func<string, int, Rect, Rect, double, Task<Bitmap?>> Render, Func<Bitmap, string, Task<List<OcrLine>>> Read);

    public static Services? Platform { get; set; }

    public sealed record Line(int Page, Rect Rect, string Text, RGBColor Color, Bitmap? Patch, Rect PatchRect);

    /// <summary>The runs of words in the pictures of page number.</summary>
    public static async Task<List<Line>> Recognize(string path, PdfSource source, int number, string language)
    {
        var services = Platform;
        if (services == null || number < 1 || number > source.Pages.Count) return [];
        var page = source.Pages[number - 1];
        var geometry = PdfComposer.Geometry(page);
        if (geometry.Rotation % 360 != 0) return [];
        var interpreter = new ContentInterpreter();
        interpreter.Run(page);
        var media = geometry.CropBox;
        var textBoxes = interpreter.Glyphs.Where(g => g.IsVisible && (g.Text?.Any(char.IsLetterOrDigit) ?? false)).Select(g => g.Box).ToList();
        // Pictures side by side (a figure made of many) are read as one, with a little room around.
        var pictures = new List<Rect>();
        foreach (var (_, image) in interpreter.Images)
        {
            var corners = new[] { new Pt(0, 0), new Pt(1, 0), new Pt(0, 1), new Pt(1, 1) }.Select(p => p.Applying(image.Matrix));
            var rect = Rect.Bounds(corners).Intersection(media);
            if (rect.IsNull || rect.W < 24 || rect.H < 12 || rect.Area >= media.Area * 0.8) continue;
            pictures.Add(rect);
        }
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
        var lines = new List<Line>();
        foreach (var picture in pictures.Where(p => p.W >= 48 && p.H >= 24).Select(p => p.InsetBy(-18, -6).Intersection(media)))
        {
            double scale = Math.Clamp(2000 / Math.Max(picture.W, picture.H), 2, 3.5);
            var bitmap = await services.Render(path, number, media, picture, scale);
            if (bitmap == null) continue;
            List<OcrLine> read;
            try { read = await services.Read(bitmap, language); } catch { continue; }
            double sx = picture.W / bitmap.Width, sy = picture.H / bitmap.Height;
            Rect ToPage(double x, double y, double w, double h) => new(picture.MinX + x * sx, picture.MaxY - (y + h) * sy, w * sx, h * sy);
            foreach (var line in read)
            {
                // Words far apart on one line (labels side by side) are set apart.
                var groups = new List<(string Text, Rect Box)>();
                foreach (var word in line.Words)
                {
                    var box = ToPage(word.X, word.Y, word.Width, word.Height);
                    if (groups.Count > 0 && box.MinX - groups[^1].Box.MaxX < Math.Max(groups[^1].Box.H, box.H) * 1.1)
                        groups[^1] = (Join(groups[^1].Text, word.Text), groups[^1].Box.Union(box));
                    else groups.Add((word.Text, box));
                }
                foreach (var (text, box) in groups)
                {
                    if (!IsWords(text)) continue;
                    // Real text over the picture is translated with the page's own text, or kept.
                    if (textBoxes.Any(t => t.Intersection(box) is { IsNull: false } i && i.Area > box.Area * 0.3)) continue;
                    if (Erase(text, box, picture, bitmap, number) is { } found) lines.Add(found);
                }
            }
        }
        return lines;
    }

    static string Join(string a, string b) => OcrTextLayer.NeedsSpace(a, b) ? a + " " + b : a + b;

    /// <summary>Words worth translating: two letters at least, more letters than digits, not an abbreviation alone.</summary>
    public static bool IsWords(string text)
    {
        int letters = text.Count(char.IsLetter), digits = text.Count(char.IsDigit);
        if (letters < 2 || letters <= digits) return false;
        if (!text.Contains(' ') && letters <= 4 && text.Where(char.IsLetter).All(char.IsUpper)) return false;
        return true;
    }

    /// <summary>The words' pixels found against the background around them and filled across each row from what is
    /// beside them; their colour taken from the pixels most unlike the background.</summary>
    static Line? Erase(string text, Rect box, Rect picture, Bitmap bitmap, int number)
    {
        double scale = bitmap.Width / picture.W;
        double pad = box.H * 0.18;
        var area = box.InsetBy(-box.H * 0.4, -pad * 0.6).Intersection(picture);
        if (area.IsNull) return null;
        int px = (int)Math.Floor((area.MinX - picture.MinX) * scale), py = (int)Math.Floor((picture.MaxY - area.MaxY) * scale);
        int pw = (int)Math.Ceiling(area.W * scale), ph = (int)Math.Ceiling(area.H * scale);
        if (pw <= 2 || ph <= 2 || pw * ph > 4_000_000) return null;
        (double R, double G, double B) Pixel(int x, int y)
        {
            x = Math.Clamp(x, 0, bitmap.Width - 1); y = Math.Clamp(y, 0, bitmap.Height - 1);
            int p = (y * bitmap.Width + x) * 4;
            return (bitmap.Rgba[p] / 255.0, bitmap.Rgba[p + 1] / 255.0, bitmap.Rgba[p + 2] / 255.0);
        }
        static double Distance((double R, double G, double B) a, (double R, double G, double B) b) => Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B);
        var ring = new List<(double R, double G, double B)>();
        int step = Math.Max(1, (pw + ph) / 160);
        for (int x = px; x <= px + pw; x += step) { ring.Add(Pixel(x, py - 2)); ring.Add(Pixel(x, py + ph + 1)); }
        for (int y = py; y <= py + ph; y += step) { ring.Add(Pixel(px - 2, y)); ring.Add(Pixel(px + pw + 1, y)); }
        double Mid(IEnumerable<double> v) { var s = v.OrderBy(x => x).ToList(); return s[s.Count / 2]; }
        var background = (R: Mid(ring.Select(c => c.R)), G: Mid(ring.Select(c => c.G)), B: Mid(ring.Select(c => c.B)));
        var colors = new (double R, double G, double B)[pw * ph];
        for (int y = 0; y < ph; y++) for (int x = 0; x < pw; x++) colors[y * pw + x] = Pixel(px + x, py + y);
        var darkest = colors.OrderByDescending(c => Distance(c, background)).Take(Math.Max(1, colors.Length / 12)).ToList();
        var ink = (R: darkest.Average(c => c.R), G: darkest.Average(c => c.G), B: darkest.Average(c => c.B));
        double threshold = Math.Max(0.15, Distance(ink, background) * 0.3);
        var mask = new bool[pw * ph];
        for (int i = 0; i < mask.Length; i++) mask[i] = Distance(colors[i], background) > threshold;
        int grow = Math.Max(1, ph / 14);
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
        var bytes = new byte[pw * ph * 4];
        void Put(int index, (double R, double G, double B) c)
        {
            bytes[index * 4] = (byte)Math.Clamp(c.R * 255, 0, 255);
            bytes[index * 4 + 1] = (byte)Math.Clamp(c.G * 255, 0, 255);
            bytes[index * 4 + 2] = (byte)Math.Clamp(c.B * 255, 0, 255);
            bytes[index * 4 + 3] = 255;
        }
        for (int y = 0; y < ph; y++)
        {
            int x = 0;
            while (x < pw)
            {
                if (!grown[y * pw + x]) { Put(y * pw + x, colors[y * pw + x]); x++; continue; }
                int end = x;
                while (end < pw && grown[y * pw + end]) end++;
                var left = x > 0 ? colors[y * pw + x - 1] : background;
                var right = end < pw ? colors[y * pw + end] : background;
                for (int k = x; k < end; k++)
                {
                    double t = (k - x + 1.0) / (end - x + 1.0);
                    Put(y * pw + k, (left.R + (right.R - left.R) * t, left.G + (right.G - left.G) * t, left.B + (right.B - left.B) * t));
                }
                x = end;
            }
        }
        var patchRect = new Rect(picture.MinX + px / scale, picture.MaxY - (py + ph) / scale, pw / scale, ph / scale);
        return new Line(number, box, text, new RGBColor(ink.R, ink.G, ink.B), new Bitmap(bytes, pw, ph), patchRect);
    }

    /// <summary>The translation of a line drawn over the picture on a y-down canvas whose top is pageTop: the words
    /// taken out, the translation in their colour from the box's left edge, as large as the box allows (narrowed a
    /// little rather than made tiny).</summary>
    public static void Draw(Line line, string translation, string language, SKCanvas canvas, double pageTop, HashSet<ushort>? used)
    {
        if (line.Patch is { } patch)
        {
            var info = new SKImageInfo(patch.Width, patch.Height, SKColorType.Rgba8888, SKAlphaType.Opaque);
            using var image = SKImage.FromPixelCopy(info, patch.Rgba);
            var r = line.PatchRect;
            canvas.DrawImage(image, new SKRect((float)r.MinX, (float)(pageTop - r.MaxY), (float)r.MaxX, (float)(pageTop - r.MinY)),
                new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.None));
        }
        var box = line.Rect;
        bool cjk = language.StartsWith("zh") || language.StartsWith("ja") || language.StartsWith("ko");
        var face = cjk ? FontCatalog.Script(language, false, false) ?? FontCatalog.Latin(false, false) : FontCatalog.Latin(false, false);
        if (!translation.EnumerateRunes().All(rune => face.Typeface.ContainsGlyph(rune.Value)))
            face = FontCatalog.Fallback(translation.EnumerateRunes().First(rune => !face.Typeface.ContainsGlyph(rune.Value)).Value, false, language);
        double full = box.H * 0.82, size = full;
        using var font = new SKFont(face.Typeface, (float)size) { Subpixel = true, LinearMetrics = true };
        double width = font.MeasureText(translation);
        if (width > box.W)
        {
            size = Math.Max(full * 0.62, size * box.W / width);
            font.Size = (float)size;
            width = font.MeasureText(translation);
        }
        double squeeze = width > box.W ? Math.Max(0.7, box.W / width) : 1;
        font.ScaleX = (float)squeeze;
        var metrics = font.Metrics;
        double ascent = -metrics.Ascent, descent = metrics.Descent;
        double baseline = box.MinY + (box.H - (ascent + descent)) / 2 + descent;
        used?.UnionWith(font.GetGlyphs(translation));
        var c = line.Color;
        using var paint = new SKPaint { Color = new SKColor((byte)Math.Round(c.R * 255), (byte)Math.Round(c.G * 255), (byte)Math.Round(c.B * 255)), IsAntialias = true };
        canvas.DrawText(translation, (float)box.MinX, (float)(pageTop - baseline), font, paint);
    }
}
