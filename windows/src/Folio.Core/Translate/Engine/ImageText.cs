using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Pdf;
using Folio.Core.Translate.Typeset;
using System.Globalization;
using System.Text;
using SkiaSharp;

namespace Folio.Core.Translate.Engine;

/// <summary>Text inside pictures (TRANS-40, optional), as the macOS engine does it (ImageText.swift): the words of a
/// page's pictures (read with OCR, across and sideways both ways, large pictures in tiles as well) and the labels of
/// figures drawn in vectors are translated and set back in place.
/// <list type="bullet">
/// <item>Reading: a line is cut where its ink leaves a gap far wider than a space (labels side by side), icons read as
/// characters (a check mark read as "/") or not read at all are left out of the words and keep their place, words read
/// apart are joined again, misreadings (a "!" inside a word, Chinese characters in an English paper) are left alone.</item>
/// <item>Taking the words out: only the strokes of the letters (not a box's edge or a line running past them), filled
/// from what is beside them.</item>
/// <item>Setting the translation: at the words' own size, measured from their ink (labels of one size keep one size), on
/// their baseline, in their colour, never past them; lines set together keep their edges or centres in line, a label
/// kept by an icon keeps that edge, a label alone keeps its centre.</item>
/// </list>
/// Rendering and OCR are the platform's (<see cref="Platform"/>: Windows.Data.Pdf and Windows.Media.Ocr in the app).</summary>
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

        /// <summary>Turned a quarter anticlockwise: text that read down the page reads across.</summary>
        public Bitmap TurnedCounterClockwise()
        {
            var output = new byte[Rgba.Length];
            for (int y = 0; y < Height; y++)
                for (int x = 0; x < Width; x++)
                {
                    int s = (y * Width + x) * 4, t = ((Width - 1 - x) * Height + y) * 4;
                    output[t] = Rgba[s]; output[t + 1] = Rgba[s + 1]; output[t + 2] = Rgba[s + 2]; output[t + 3] = 255;
                }
            return new Bitmap(output, Height, Width);
        }

        /// <summary>The part in rect (pixels).</summary>
        public Bitmap Cropped(Rect rect)
        {
            int x0 = Math.Max(0, (int)rect.MinX), y0 = Math.Max(0, (int)rect.MinY);
            int x1 = Math.Min(Width, (int)rect.MaxX), y1 = Math.Min(Height, (int)rect.MaxY);
            int w = Math.Max(0, x1 - x0), h = Math.Max(0, y1 - y0);
            var output = new byte[w * h * 4];
            for (int y = 0; y < h; y++) Buffer.BlockCopy(Rgba, ((y0 + y) * Width + x0) * 4, output, y * w * 4, w * 4);
            return new Bitmap(output, w, h);
        }

        /// <summary>Made smaller by a whole factor (each pixel the average of a square).</summary>
        public Bitmap Reduced(int factor)
        {
            if (factor <= 1) return this;
            int w = Width / factor, h = Height / factor;
            var output = new byte[w * h * 4];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    int r = 0, g = 0, b = 0;
                    for (int dy = 0; dy < factor; dy++)
                        for (int dx = 0; dx < factor; dx++)
                        {
                            int p = ((y * factor + dy) * Width + x * factor + dx) * 4;
                            r += Rgba[p]; g += Rgba[p + 1]; b += Rgba[p + 2];
                        }
                    int n = factor * factor, t = (y * w + x) * 4;
                    output[t] = (byte)(r / n); output[t + 1] = (byte)(g / n); output[t + 2] = (byte)(b / n); output[t + 3] = 255;
                }
            return new Bitmap(output, w, h);
        }
    }

    /// <summary>What the platform does: render region (page space) of page (1-based) of the file, whose crop box is given,
    /// at about scale pixels per point; read the words of a bitmap in a language (word boxes in pixels, from the top left);
    /// optionally, where the words of a text start (for breaking Chinese or Japanese between words).</summary>
    public sealed record Services(Func<string, int, Rect, Rect, double, Task<Bitmap?>> Render, Func<Bitmap, string, Task<List<OcrLine>>> Read)
    {
        public Func<string, string, HashSet<int>>? WordStarts { get; init; }
        /// <summary>Whether the OCR reads the language itself (not with another language's, which reads lines in part).</summary>
        public Func<string, bool>? ReadsLanguage { get; init; }
    }

    public static Services? Platform { get; set; }

    public enum Alignment { Left, Center, Right }

    /// <summary>A run of words: where (page space), what, its colour; the picture under it with the words taken out (or,
    /// for a label drawn as text, its glyphs); sideways (reading up, or down); how it stands with the lines of its group;
    /// its size and (across) baseline.</summary>
    public sealed record Line(int Page, Rect Rect, string Text, RGBColor Color, Bitmap? Patch, Rect PatchRect)
    {
        public bool Vertical { get; init; }
        public bool ReadsDown { get; init; }
        public Alignment Align { get; set; } = Alignment.Center;
        public int Group { get; set; }
        public List<int> Glyphs { get; init; } = [];
        public double? Size { get; set; }
        public double? Baseline { get; init; }
    }

    /// <summary>A run found: text, box (pixels from the top left, or page space for labels drawn as text), sideways; the
    /// edge an icon keeps it at; reading down the page (sideways).</summary>
    public sealed class Run(string text, Rect box, bool vertical)
    {
        public string Text { get; set; } = text;
        public Rect Box { get; set; } = box;
        public bool Vertical { get; set; } = vertical;
        public Alignment? Anchor { get; set; }
        public bool ReadsDown { get; set; }
        public double Score { get; set; }
    }

    /// <summary>A line as OCR read it: its words (text and pixel box from the top left) and the line's box.</summary>
    sealed record Reading(List<(string Text, Rect Box)> Words, Rect Line);

    public static bool IsCjk(string language) => language.StartsWith("zh") || language.StartsWith("ja") || language.StartsWith("ko");

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
        bool latin = !(IsCjk(language) || language is "ru" or "uk" or "el" or "ar" or "he" or "th");
        // Read with another language's OCR, lines come in part: half a label is better left alone.
        bool partial = !(services.ReadsLanguage?.Invoke(language) ?? true);
        var lines = new List<Line>();
        int group = 0;
        foreach (var picture in MergedPictures(pictures, media))
        {
            // The picture as it shows on the page, sharp enough to read small labels (3 pt labels: 24 pixels high).
            double scale = Math.Clamp(4000 / Math.Max(picture.W, picture.H), 2.5, 8);
            var bitmap = await services.Render(path, number, media, picture, scale);
            if (bitmap == null) continue;
            double sx = picture.W / bitmap.Width, sy = picture.H / bitmap.Height;
            var runs = new List<Run>();
            try { runs.AddRange((await Read(bitmap, services, language, latin, partial)).Where(r => r.Box.H < r.Box.W * 1.2 || r.Text.Length <= 1)); } catch { }
            // Sideways labels: read on the picture turned a quarter each way (whole: sideways labels are rarely the smallest),
            // where they lie across. The OCR reads only upright words: the way a label reads best is the way it reads.
            var sideways = new List<Run>();
            try
            {
                foreach (var run in await Read(bitmap.TurnedClockwise(), services, language, latin, partial, tiles: false))
                {
                    // Back to the picture: x' = h - 1 - y, y' = x.
                    var b = run.Box;
                    run.Box = new Rect(b.MinY, bitmap.Height - b.MaxX, b.H, b.W);
                    run.Vertical = true;
                    sideways.Add(run);
                }
                foreach (var run in await Read(bitmap.TurnedCounterClockwise(), services, language, latin, partial, tiles: false))
                {
                    // Back: x' = y, y' = w - 1 - x.
                    var b = run.Box;
                    run.Box = new Rect(bitmap.Width - b.MaxY, b.MinX, b.H, b.W);
                    run.Vertical = true;
                    run.ReadsDown = true;
                    sideways.Add(run);
                }
            }
            catch { }
            // Read both ways (an OCR that reads upside down): by the letters, else as most of the picture's labels read.
            var decided = sideways.Select(r => ReadsDownByInk(r, bitmap)).ToList();
            int down = decided.Count(d => d == true), up = decided.Count(d => d == false);
            bool? usual = down > up ? true : up > down ? false : null;
            // A picture's sideways labels nearly always read one way: when most say so, all of them.
            bool clear = Math.Max(down, up) >= (down + up) * 0.7;
            for (int k = 0; k < sideways.Count; k++)
                if ((clear ? usual ?? decided[k] : decided[k] ?? usual) is bool way && way == sideways[k].ReadsDown) sideways[k].Score += 0.5;
            foreach (var run in sideways.OrderByDescending(r => r.Score).ThenByDescending(r => r.Text.Count(char.IsLetter)))
            {
                if (run.Box.H <= run.Box.W * 1.5) continue;
                if (runs.Any(r => r.Box.Intersection(run.Box) is { IsNull: false } i && i.Area > run.Box.Area * 0.2)) continue;
                runs.Add(run);
            }
            // Words of one label read apart (or cut at a space a little wide) are one run again.
            runs = JoinedAcross(runs, bitmap);
            // In reading order: row by row, each row from the left.
            runs.Sort((a, b) => Math.Abs(a.Box.MidY - b.Box.MidY) < Math.Min(a.Box.H, b.Box.H) * 0.5 ? a.Box.MinX.CompareTo(b.Box.MinX) : a.Box.MidY.CompareTo(b.Box.MidY));
            Rect ToPage(Rect r) => new(picture.MinX + r.MinX * sx, picture.MaxY - r.MaxY * sy, r.W * sx, r.H * sy);
            var found = new List<(Run Run, Line Line)>();
            foreach (var run in runs.Where(r => IsWords(r.Text)))
            {
                var box = ToPage(run.Box);
                // Real text over the picture is translated with the page's own text, or kept.
                if (textBoxes.Any(t => t.Intersection(box) is { IsNull: false } i && i.Area > box.Area * 0.3)) continue;
                if (Erase(run, bitmap) is not { } erased) continue;
                // Text too small to read in print (the buttons of a screenshot): left as it is.
                if (erased.Size is { } measured && measured * sy < 1.7) continue;
                found.Add((run, new Line(number, box, run.Text, erased.Color, erased.Patch, ToPage(erased.Area))
                {
                    Vertical = run.Vertical, ReadsDown = run.ReadsDown, Size = erased.Size * sy,
                    Baseline = erased.Baseline is { } baseline ? picture.MaxY - baseline * sy : null,
                }));
            }
            // One size for words set at one size (measured sizes differ a little from label to label).
            foreach (bool vertical in new[] { false, true })
            {
                var sizes = Harmonized(found.Select(f => f.Line.Vertical == vertical ? f.Line.Size : null).ToList());
                for (int k = 0; k < found.Count; k++) if (sizes[k] != null) found[k].Line.Size = sizes[k];
            }
            // How the lines stand together.
            var placed = found.Select(f => f.Run).ToList();
            var arranged = Arrange(placed, (i, j) => Separated(placed[i].Box, placed[j].Box, bitmap));
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

    // Reading

    static async Task<List<Reading>> Observe(Bitmap bitmap, Services services, string language)
    {
        var result = new List<Reading>();
        foreach (var line in await services.Read(bitmap, language))
        {
            var words = line.Words.Where(w => !string.IsNullOrWhiteSpace(w.Text)).Select(w => (w.Text.Trim(), new Rect(w.X, w.Y, w.Width, w.Height))).ToList();
            if (words.Count == 0) continue;
            // Chinese or Japanese comes a character a word: characters close together are one word.
            var joined = new List<(string Text, Rect Box)>();
            foreach (var (text, box) in words)
            {
                if (joined.Count > 0 && !OcrTextLayer.NeedsSpace(joined[^1].Text, text) && box.MinX - joined[^1].Box.MaxX < box.H * 0.5)
                    joined[^1] = (joined[^1].Text + text, joined[^1].Box.Union(box));
                else joined.Add((text, box));
            }
            var lineBox = joined.Skip(1).Aggregate(joined[0].Box, (r, w) => r.Union(w.Box));
            result.Add(new Reading(joined, lineBox));
        }
        return result;
    }

    /// <summary>Runs of words read from the bitmap, pixel boxes from the top left. Large pictures are read in tiles
    /// (overlapping, so that a label cut at a tile's edge is whole in the next): OCR reads small labels better at full size,
    /// and reads only so many pixels. A line read in a tile wins; the whole picture's reading, made smaller, adds what the
    /// tiles missed (labels longer than the overlap).</summary>
    static async Task<List<Run>> Read(Bitmap bitmap, Services services, string language, bool latin, bool partial, bool tiles = true)
    {
        List<Run> Runs(List<Reading> readings) => readings.SelectMany(r => RunsIn(r, bitmap, latin, partial)).ToList();
        const double tile = 1400, overlap = 280;
        int reduce = (int)Math.Ceiling(Math.Max(bitmap.Width, bitmap.Height) / 2600.0);
        var wholeReadings = await Observe(bitmap.Reduced(reduce), services, language);
        var whole = Runs(wholeReadings.Select(r => new Reading(r.Words.Select(w => (w.Text, Scaled(w.Box, reduce))).ToList(), Scaled(r.Line, reduce))).ToList());
        if (!tiles || Math.Max(bitmap.Width, bitmap.Height) <= tile * 1.15) return whole;
        var frames = new List<Rect>();
        var all = new Rect(0, 0, bitmap.Width, bitmap.Height);
        for (double y = 0; y < bitmap.Height; y += tile - overlap)
        {
            for (double x = 0; x < bitmap.Width; x += tile - overlap)
            {
                var frame = new Rect(x, y, tile, tile).Intersection(all);
                if (!frame.IsNull && frame.W > overlap && (frame.H > overlap || y == 0)) frames.Add(frame);
                if (frame.MaxX >= bitmap.Width) break;
            }
            if (y + tile >= bitmap.Height) break;
        }
        // The tiles side by side (each reading is independent).
        var byTile = await Task.WhenAll(frames.Select(f => Observe(bitmap.Cropped(f), services, language)));
        var tiled = new List<Reading>();
        for (int t = 0; t < frames.Count; t++)
        {
            var frame = frames[t];
                foreach (var reading in byTile[t])
                {
                    var line = reading.Line.Offset(frame.MinX, frame.MinY);
                    // Cut by the tile's edge (not the picture's): read whole elsewhere. A word cut in half at the edge is left
                    // out of the line: a margin of more than a word's height.
                    double margin = Math.Max(3, line.H * 1.5);
                    if ((line.MinX < frame.MinX + margin && frame.MinX > 0) || (line.MaxX > frame.MaxX - margin && frame.MaxX < bitmap.Width)
                        || (line.MinY < frame.MinY + 3 && frame.MinY > 0) || (line.MaxY > frame.MaxY - 3 && frame.MaxY < bitmap.Height)) continue;
                    tiled.Add(new Reading(reading.Words.Select(w => (w.Text, w.Box.Offset(frame.MinX, frame.MinY))).ToList(), line));
                }
        }
        var accepted = new List<Run>();
        bool Overlapping(Run run) => accepted.Any(a => a.Box.Intersection(run.Box) is { IsNull: false } i && i.Area > Math.Min(a.Box.Area, run.Box.Area) * 0.3);
        foreach (var run in Runs(tiled).OrderByDescending(r => r.Text.Length))
        {
            if (Overlapping(run)) continue;
            // An icon the whole picture's reading saw beside these words.
            if (run.Anchor == null && whole.FirstOrDefault(w => w.Anchor != null && w.Box.Intersection(run.Box) is { IsNull: false } i && i.Area > run.Box.Area * 0.5) is { } seen)
                run.Anchor = seen.Anchor;
            // A character at an end the tile's reading left out ("(d)" read as "d)").
            if (whole.FirstOrDefault(w => w.Text.Length > run.Text.Length && w.Text.Length - run.Text.Length <= 2 && (w.Text.EndsWith(run.Text) || w.Text.StartsWith(run.Text))
                    && w.Box.Intersection(run.Box) is { IsNull: false } i && i.Area > run.Box.Area * 0.7) is { } fuller)
            {
                run.Text = fuller.Text;
                run.Box = run.Box.Union(fuller.Box);
            }
            accepted.Add(run);
        }
        foreach (var run in whole) if (!Overlapping(run)) accepted.Add(run);
        return accepted;
    }

    static Rect Scaled(Rect r, int factor) => factor <= 1 ? r : new Rect(r.MinX * factor, r.MinY * factor, r.W * factor, r.H * factor);

    const string Closing = "()[]{}\"'“”‘’.,:;!?…";

    /// <summary>A line read cut into runs where its ink leaves a wide gap (labels side by side read as one line), without the
    /// icons read as characters at its ends or between its words (a check mark read as "/", an arrow in a legend), and kept
    /// only when it reads as words. Each run's box is its own ink, across.</summary>
    static List<Run> RunsIn(Reading reading, Bitmap bitmap, bool latin, bool partial = false)
    {
        var line = reading.Line;
        var background = RingColor(bitmap, line);
        int top = Math.Max(0, (int)Math.Floor(line.MinY)), bottom = Math.Min(bitmap.Height, (int)Math.Ceiling(line.MaxY));
        if (bottom <= top) return [];
        bool Blank(int x)
        {
            if (x < 0 || x >= bitmap.Width) return true;
            for (int y = top; y < bottom; y++) if (Distance(bitmap.Pixel(x, y), background) > 0.3) return false;
            return true;
        }
        (int Lower, int Upper)? WidestGap(double from, double to)
        {
            int a = (int)Math.Round(from), b = (int)Math.Round(to);
            if (b <= a) return null;
            (int, int)? best = null;
            int? start = null;
            for (int x = a; x <= b; x++)
            {
                if (x < b && Blank(x)) start ??= x;
                else if (start is { } s)
                {
                    if (x - s > (best is { } bb ? bb.Item2 - bb.Item1 : 0)) best = (s, x);
                    start = null;
                }
            }
            return best;
        }
        // Markers read stuck to a word ("→Multi-scale", "figure)→"): words of their own.
        var words = new List<(string Text, Rect Box)>();
        foreach (var (token, box) in reading.Words)
        {
            var chars = token.EnumerateRunes().ToArray();
            int lead = 0, trail = chars.Length;
            while (lead < chars.Length - 1 && IsMarker(chars[lead])) lead++;
            while (trail > lead + 1 && IsMarker(chars[trail - 1])) trail--;
            double n = Math.Max(chars.Length, 1);
            Rect Part(int a, int b) => new(box.MinX + box.W * a / n, box.MinY, box.W * (b - a) / n, box.H);
            string Text(int a, int b) => string.Concat(chars[a..b].Select(r => r.ToString()));
            if (lead > 0) words.Add((Text(0, lead), Part(0, lead)));
            words.Add((Text(lead, trail), Part(lead, trail)));
            if (trail < chars.Length) words.Add((Text(trail, chars.Length), Part(trail, chars.Length)));
        }
        if (words.Count == 0) return [];
        double left = line.MinX, right = line.MaxX;
        bool IsIcon(int k, int other)
        {
            var token = words[k].Text;
            // Brackets and quotes are the text's own ("(d)" read as "( d)").
            if (!token.Any(char.IsLetterOrDigit)) return !token.All(c => Closing.Contains(c));
            if (token.Length != 1 || !char.IsLetter(token[0]) || token is "a" or "A" or "I") return false;
            return Distance(InkColor(bitmap, words[k].Box, background), InkColor(bitmap, words[other].Box, background)) > 0.45;
        }
        // Past an icon's ink, from x on, step ±1: where the words' ink starts. An icon in a colour of its own ends where that
        // colour does (an italic letter may lean into it); one in the words' colour at the blank after it.
        int? Past(int x, int step, Rect icon, Rect other)
        {
            var iconInk = InkColor(bitmap, icon, background);
            var wordInk = InkColor(bitmap, other, background);
            bool coloured = Distance(iconInk, wordInk) > 0.45;
            double near = Distance(iconInk, background) * 0.35;
            bool HasIcon(int x) { for (int y = top; y < bottom; y++) if (Distance(bitmap.Pixel(x, y), iconInk) < near) return true; return false; }
            bool sawIcon = false, sawBlank = false;
            for (; x >= 0 && x < bitmap.Width; x += step)
            {
                bool empty = Blank(x);
                if (coloured)
                {
                    if (!empty && HasIcon(x)) sawIcon = true;
                    else if (sawIcon && !empty) return x;
                }
                else
                {
                    if (!empty && sawBlank) return x;
                    if (!empty) sawIcon = true; else if (sawIcon) sawBlank = true;
                }
            }
            return null;
        }
        Alignment? anchor = null;
        while (words.Count > 1 && IsIcon(0, 1))
        {
            left = Past((int)Math.Min(line.MinX, words[0].Box.MinX), 1, words[0].Box, words[1].Box) is { } p ? p : words[1].Box.MinX;
            words.RemoveAt(0);
            anchor = Alignment.Left;
        }
        while (words.Count > 1 && IsIcon(words.Count - 1, words.Count - 2))
        {
            right = Past((int)Math.Max(line.MaxX, words[^1].Box.MaxX) - 1, -1, words[^1].Box, words[^2].Box) is { } p ? p + 1 : words[^2].Box.MaxX;
            words.RemoveAt(words.Count - 1);
            anchor ??= Alignment.Right;
        }
        // Cut where the gap between two words is far wider than a space: than about a quarter of the em, or than the line's
        // other spaces.
        double size = Em(Rect.FromCorners(left, line.MinY, Math.Max(right, left + 1), line.MaxY), bitmap);
        var gaps = Enumerable.Range(1, Math.Max(0, words.Count - 1)).Select(k => WidestGap(words[k - 1].Box.MidX, words[k].Box.MidX)).ToList();
        // An icon between words (an arrow in a legend) ends one label and starts another, which keeps its left edge.
        bool Between(int k) => k > 0 && k < words.Count - 1 && !words[k].Text.Any(char.IsLetterOrDigit) && !words[k].Text.All(c => (Closing + "&+=-–—/").Contains(c));
        var pieces = new List<(List<string> Words, double MinX, double MaxX, bool AfterIcon, bool BeforeIcon)> { ([words[0].Text], left, right, anchor == Alignment.Left, anchor == Alignment.Right) };
        for (int k = 1; k < words.Count;)
        {
            if (Between(k))
            {
                var last = pieces[^1];
                pieces[^1] = (last.Words, last.MinX, WidestGap(words[k - 1].Box.MidX, words[k].Box.MidX) is { } g ? g.Lower : words[k].Box.MinX, last.AfterIcon, true);
                double start = Past((int)words[k].Box.MinX, 1, words[k].Box, words[k + 1].Box) is { } p ? p : words[k + 1].Box.MinX;
                pieces.Add(([words[k + 1].Text], start, right, true, anchor == Alignment.Right));
                k += 2;
                continue;
            }
            double width = gaps[k - 1] is { } gap ? gap.Upper - gap.Lower : 0;
            var others = gaps.Where((_, i) => i != k - 1).Select(g => g is { } o ? (double)(o.Upper - o.Lower) : 0).Order().ToList();
            double? usual = others.Count == 0 ? null : others[others.Count / 2];
            if (gaps[k - 1] is { } cut && (width > size * 0.9 || (usual is { } u && width > Math.Max(u, 1) * 2.5 && width > size * 0.45)))
            {
                var last = pieces[^1];
                pieces[^1] = (last.Words, last.MinX, cut.Lower, last.AfterIcon, false);
                pieces.Add(([words[k].Text], cut.Upper, right, false, anchor == Alignment.Right));
            }
            else pieces[^1].Words.Add(words[k].Text);
            k++;
        }
        var result = new List<Run>();
        foreach (var piece in pieces)
        {
            // Just the ink across (OCR boxes may run wide).
            int minX = (int)Math.Floor(piece.MinX), maxX = (int)Math.Ceiling(piece.MaxX);
            while (minX < maxX && Blank(minX)) minX++;
            while (maxX > minX && Blank(maxX - 1)) maxX--;
            if (maxX <= minX) continue;
            Alignment? edge = null;
            // An icon at either end that was not read as a character: a small shape in a colour of its own, apart.
            int? IconAt(int start, int step)
            {
                int end = step > 0 ? maxX : minX - 1;
                int x = start;
                while (x != end && !Blank(x)) x += step;
                int shape = Math.Abs(x - start);
                int y = x;
                while (y != end && Blank(y)) y += step;
                if (shape == 0 || shape >= size * 1.3 || Math.Abs(y - x) < size * 0.15 || y == end) return null;
                // The shape may begin outside the box (only its edge read with the words): all of it.
                int outer = start;
                while (outer - step >= 0 && outer - step < bitmap.Width && Math.Abs(outer - step - start) < size * 1.3 && !Blank(outer - step)) outer -= step;
                var shapeBox = Rect.FromCorners(Math.Min(outer, x - step), line.MinY, Math.Min(outer, x - step) + Math.Abs(x - outer), line.MaxY);
                var rest = step > 0 ? Rect.FromCorners(y, line.MinY, maxX, line.MaxY) : Rect.FromCorners(minX, line.MinY, y + 1, line.MaxY);
                return Coloured(InkColor(bitmap, shapeBox, background), InkColor(bitmap, rest, background)) ? y : null;
            }
            if (IconAt(minX, 1) is { } s) { minX = s; edge = Alignment.Left; }
            if (IconAt(maxX - 1, -1) is { } e) { maxX = e + 1; edge ??= Alignment.Right; }
            // Or just outside it (read apart): the words keep that edge.
            bool IconBeside(int from, int step)
            {
                int x = from;
                while (Math.Abs(x - from) < (int)(size * 1.2) && x >= 0 && x < bitmap.Width && Blank(x)) x += step;
                if (Math.Abs(x - from) >= (int)(size * 1.2) || x < 0 || x >= bitmap.Width) return false;
                int start = x;
                while (Math.Abs(x - start) <= (int)(size * 1.3) && x >= 0 && x < bitmap.Width && !Blank(x)) x += step;
                if (Math.Abs(x - start) > (int)(size * 1.3) || x < 0 || x >= bitmap.Width) return false;
                var shape = Rect.FromCorners(Math.Min(start, x), line.MinY, Math.Max(start, x), line.MaxY);
                // An icon is about a letter wide (not a thin line), and no part of something larger (a box's edge).
                if (shape.W < size * 0.3) return false;
                foreach (int row in new[] { (int)(line.MinY - size * 0.45), (int)(line.MaxY + size * 0.45) })
                    for (int column = (int)shape.MinX; column < (int)shape.MaxX; column++)
                        if (Distance(bitmap.Pixel(column, row), background) > 0.3) return false;
                return Coloured(InkColor(bitmap, shape, background), InkColor(bitmap, Rect.FromCorners(minX, line.MinY, maxX, line.MaxY), background));
            }
            if (piece.AfterIcon) edge = Alignment.Left;
            if (edge == null && anchor == null && IconBeside(minX - 1, -1)) edge = Alignment.Left;
            // A long line set just after a shape (a legend's entry after its marker) keeps its start there.
            if (edge == null && anchor == null && maxX - minX > size * 5)
            {
                int r0 = (int)(line.MinY + line.H * 0.2), r1 = (int)(line.MaxY - line.H * 0.2);
                bool near = false;
                for (int x = Math.Max(0, minX - (int)(size * 0.6)); x < minX && !near; x++)
                    for (int y = r0; y < r1; y++) if (Distance(bitmap.Pixel(x, y), background) > 0.3) { near = true; break; }
                if (near) edge = Alignment.Left;
            }
            if (edge == null && anchor == null && IconBeside(maxX, 1)) edge = Alignment.Right;
            // Words just beside the run that were not read (within a wide space, no taller than the line, not an icon): the
            // line was read in part, and half a label is not translated.
            bool UnreadBeside(int from, int step)
            {
                int x = from;
                while (Math.Abs(x - from) < (int)(size * 0.6) && x >= 0 && x < bitmap.Width && Blank(x)) x += step;
                if (Math.Abs(x - from) >= (int)(size * 0.6) || x < 0 || x >= bitmap.Width) return false;
                foreach (int row in new[] { (int)(line.MinY - size * 0.45), (int)(line.MaxY + size * 0.45) })
                    if (Distance(bitmap.Pixel(x, row), background) > 0.3) return false;
                double x0 = step > 0 ? x : x - size * 0.3;
                return !Coloured(InkColor(bitmap, new Rect(x0, line.MinY, size * 0.3, line.H), background), InkColor(bitmap, Rect.FromCorners(minX, line.MinY, maxX, line.MaxY), background));
            }
            if (partial && ((!piece.AfterIcon && edge != Alignment.Left && UnreadBeside(minX - 1, -1)) || (!piece.BeforeIcon && edge != Alignment.Right && UnreadBeside(maxX, 1)))) continue;
            var text = string.Join(' ', piece.Words).Trim().TrimEnd(',', ';');
            if (!IsWords(text) || !IsReadable(text, latin)) continue;
            bool first = result.Count == 0 && piece.MinX == left, lastPiece = piece.MaxX == right;
            result.Add(new Run(text, Rect.FromCorners(minX, line.MinY, maxX, line.MaxY), false)
            {
                Anchor = edge ?? (anchor == Alignment.Left && first ? Alignment.Left : anchor == Alignment.Right && lastPiece ? Alignment.Right : null),
                Score = text.Count(char.IsLetter) / (double)Math.Max(text.Length, 1),
            });
        }
        return result;
    }

    /// <summary>A character that marks rather than spells: arrows, bullets, check marks and other symbols (not + = × % °).</summary>
    public static bool IsMarker(Rune r)
    {
        var s = r.ToString();
        if ("→←↑↓⇒⇐➔➜►▶▸•▪■●○◆◇★☆✓✔✗✘><*".Contains(s)) return true;
        if ("+=×±÷~%°".Contains(s)) return false;
        return Rune.GetUnicodeCategory(r) is UnicodeCategory.MathSymbol or UnicodeCategory.OtherSymbol;
    }

    /// <summary>A shape inked in a colour of its own (a red cross, a green check mark), not the words' colour a little
    /// lighter (a thin bracket's ink is greyer than the letters').</summary>
    static bool Coloured((double R, double G, double B) shape, (double R, double G, double B) words)
    {
        static double Chroma((double R, double G, double B) c) => Math.Max(c.R, Math.Max(c.G, c.B)) - Math.Min(c.R, Math.Min(c.G, c.B));
        return Distance(shape, words) > 0.45 && Chroma(shape) > 0.3 && Math.Abs(Chroma(shape) - Chroma(words)) > 0.2;
    }

    /// <summary>Words worth translating: more letters than digits, not two letters or an abbreviation alone.</summary>
    public static bool IsWords(string text)
    {
        int letters = text.Count(char.IsLetter), digits = text.Count(char.IsDigit);
        if (letters < 2 || letters <= digits) return false;
        // A word of two letters alone is a variable or an abbreviation (C₂ read as "Cz") more often than a word.
        if (!text.Contains(' ') && letters <= 2) return false;
        if (!text.Contains(' ') && letters <= 4 && text.Where(char.IsLetter).All(char.IsUpper)) return false;
        return true;
    }

    /// <summary>Words, not a misreading: at most a quarter of them have characters that words do not (a "!" inside one, a
    /// symbol), mix scripts (Latin letters with Chinese characters; in a Latin-script paper, Cyrillic or Chinese letters at
    /// all) or switch between letters and digits back and forth.</summary>
    public static bool IsReadable(string text, bool latinScript = true)
    {
        var tokens = text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0) return false;
        const string allowed = "-–—/&+%'’.,:;()[]·×°=<>~#_";
        int odd = 0;
        foreach (var token in tokens)
        {
            var core = token.Trim("()[]{}\"'“”‘’,.;:!?".ToCharArray());
            if (core.Length == 0) { odd++; continue; }
            var runes = core.EnumerateRunes().ToList();
            bool strange = runes.Any(r => !Rune.IsLetterOrDigit(r) && !allowed.Contains(r.ToString()));
            bool latinLetter = runes.Any(r => r.IsAscii && Rune.IsLetter(r));
            bool han = runes.Any(r => r.Value is >= 0x3040 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF);
            // In a paper in a Latin script, letters of another script than Latin or Greek (α, β) are misreadings.
            bool foreign = latinScript && runes.Any(r => Rune.IsLetter(r) && r.Value > 0x024F && r.Value is not (>= 0x0370 and <= 0x03FF) && r.Value is not (>= 0x1E00 and <= 0x1EFF));
            int switches = 0;
            bool? last = null;
            foreach (var r in runes.Where(Rune.IsLetterOrDigit))
            {
                bool digit = Rune.IsDigit(r);
                if (last is { } l && l != digit) switches++;
                last = digit;
            }
            // A word has two letters at least; a number, "a" or "I" stand alone too: a lone letter or a scrap of figures and
            // letters ("/T0", "e") is a misreading.
            int letterCount = runes.Count(Rune.IsLetter);
            bool number = runes.Any(Rune.IsDigit) && runes.All(r => Rune.IsDigit(r) || ".,%".Contains(r.ToString()));
            bool scrap = letterCount < 2 && !number && core is not ("a" or "A" or "I" or "&" or "+" or "-" or "×") && !han;
            // A short word with a capital after a small letter ("eO") or two marks inside ("eO/'") is not a word either.
            bool flipped = letterCount <= 4 && Enumerable.Range(1, Math.Max(0, core.Length - 1)).Any(i => char.IsUpper(core[i]) && char.IsLower(core[i - 1]));
            bool marks = core.Length <= 5 && core.Count(c => !char.IsLetterOrDigit(c)) >= 2;
            // Sizes such as 1x1, 3×3 or 10x10 are written so.
            bool dimension = System.Text.RegularExpressions.Regex.IsMatch(core, @"^\d+[x×]\d+[A-Za-z]*$");
            if (!dimension && (strange || (latinLetter && han) || foreign || switches >= 2 || scrap || flipped || marks)) odd++;
        }
        return odd * 4 <= tokens.Length;
    }

    static double Distance((double R, double G, double B) a, (double R, double G, double B) b) => Math.Abs(a.R - b.R) + Math.Abs(a.G - b.G) + Math.Abs(a.B - b.B);

    static (double R, double G, double B) Median(List<(double R, double G, double B)> colors)
    {
        if (colors.Count == 0) return (1, 1, 1);
        static double Mid(IEnumerable<double> v) { var s = v.OrderBy(x => x).ToList(); return s[s.Count / 2]; }
        return (Mid(colors.Select(c => c.R)), Mid(colors.Select(c => c.G)), Mid(colors.Select(c => c.B)));
    }

    /// <summary>The colour just around box: what the words stand on.</summary>
    static (double R, double G, double B) RingColor(Bitmap bitmap, Rect box)
    {
        var ring = new List<(double, double, double)>();
        int x0 = (int)box.MinX - 2, x1 = (int)box.MaxX + 2, y0 = (int)box.MinY - 2, y1 = (int)box.MaxY + 2;
        int step = Math.Max(1, (x1 - x0 + y1 - y0) / 160);
        for (int x = x0; x <= x1; x += step) { ring.Add(bitmap.Pixel(x, y0)); ring.Add(bitmap.Pixel(x, y1)); }
        for (int y = y0; y <= y1; y += step) { ring.Add(bitmap.Pixel(x0, y)); ring.Add(bitmap.Pixel(x1, y)); }
        return Median(ring);
    }

    /// <summary>The colour of the ink in box: its pixels most unlike the background.</summary>
    static (double R, double G, double B) InkColor(Bitmap bitmap, Rect box, (double R, double G, double B) background)
    {
        var pixels = new List<(double R, double G, double B)>();
        for (int y = (int)box.MinY; y < Math.Max((int)box.MaxY, (int)box.MinY + 1); y++)
            for (int x = (int)box.MinX; x < Math.Max((int)box.MaxX, (int)box.MinX + 1); x++) pixels.Add(bitmap.Pixel(x, y));
        var top = pixels.OrderByDescending(p => Distance(p, background)).Take(Math.Max(1, pixels.Count / 10)).ToList();
        return (top.Average(p => p.R), top.Average(p => p.G), top.Average(p => p.B));
    }

    /// <summary>Whether two runs, one above the other, have a line drawn between them (a box's edge: not one label).</summary>
    static bool Separated(Rect a, Rect b, Bitmap bitmap)
    {
        Rect upper = a.MinY < b.MinY ? a : b, lower = a.MinY < b.MinY ? b : a;
        int x0 = (int)Math.Max(a.MinX, b.MinX), x1 = (int)Math.Min(a.MaxX, b.MaxX);
        if (x1 - x0 < 4) return false;
        var background = RingColor(bitmap, upper);
        int from = (int)Math.Floor(upper.MaxY), to = (int)Math.Ceiling(lower.MinY);
        for (int y = from; y <= to; y++)
        {
            int ink = 0;
            for (int x = x0; x < x1; x++) if (Distance(bitmap.Pixel(x, y), background) > 0.3) ink++;
            if (ink > (x1 - x0) * 0.6) return true;
        }
        return false;
    }

    /// <summary>The words' em from their ink: the band the small letters fill is about half of it.</summary>
    static double Em(Rect box, Bitmap bitmap)
    {
        var background = RingColor(bitmap, box);
        int across = (int)box.H, along = (int)box.W;
        if (across <= 0 || along <= 0) return box.H;
        var counts = new int[across];
        for (int a = 0; a < across; a++)
            for (int b = 0; b < along; b += Math.Max(1, along / 300))
                if (Distance(bitmap.Pixel((int)box.MinX + b, (int)box.MinY + a), background) > 0.3) counts[a]++;
        int most = counts.Max();
        if (most == 0) return box.H;
        var dense = Enumerable.Range(0, across).Where(i => counts[i] >= most * 0.35).ToList();
        double band = dense[^1] - dense[0] + 1;
        return Math.Clamp(band / 0.48, box.H * 0.5, box.H * 1.5);
    }

    /// <summary>The widest blank between the words inside a run (0 when it has none).</summary>
    static double InnerSpace(Rect box, Bitmap bitmap)
    {
        var background = RingColor(bitmap, box);
        bool Blank(int x) { for (int y = (int)box.MinY; y < Math.Max((int)box.MaxY, (int)box.MinY + 1); y++) if (Distance(bitmap.Pixel(x, y), background) > 0.3) return false; return true; }
        int widest = 0, current = 0;
        bool inked = false;
        for (int x = (int)box.MinX; x < Math.Max((int)box.MaxX, (int)box.MinX + 1); x++)
        {
            if (Blank(x)) current++;
            else { if (inked) widest = Math.Max(widest, current); current = 0; inked = true; }
        }
        return widest;
    }

    /// <summary>Runs on one line, of one size, closer than a wide space: one run (OCR may read one label as two).</summary>
    static List<Run> JoinedAcross(List<Run> runs, Bitmap bitmap)
    {
        runs = [.. runs];
        for (bool merged = true; merged;)
        {
            merged = false;
            for (int i = 0; i < runs.Count && !merged; i++)
                for (int j = 0; j < runs.Count && !merged; j++)
                {
                    if (i == j || runs[i].Vertical || runs[j].Vertical) continue;
                    Rect a = runs[i].Box, b = runs[j].Box;
                    if (a.MinX >= b.MinX || Math.Abs(a.MidY - b.MidY) >= Math.Min(a.H, b.H) * 0.35 || Math.Max(a.H, b.H) >= Math.Min(a.H, b.H) * 1.3) continue;
                    double gap = b.MinX - a.MaxX, size = Em(a.Union(b), bitmap);
                    if (gap <= -size * 0.3 || gap >= size * 0.9) continue;
                    // Far wider than the spaces between their own words (a sixth of the em at least): two labels side by side.
                    double space = Math.Max(InnerSpace(a, bitmap), InnerSpace(b, bitmap));
                    if (space > size * 0.16 && gap > space * 2.5 && gap > size * 0.45) continue;
                    runs[i].Text += " " + runs[j].Text;
                    runs[i].Box = a.Union(b);
                    if (runs[j].Anchor == Alignment.Right) runs[i].Anchor = runs[i].Anchor == Alignment.Left ? null : Alignment.Right;
                    runs.RemoveAt(j);
                    merged = true;
                }
        }
        return runs;
    }

    /// <summary>Which way a sideways run of Latin letters reads: the tops of its letters face the side where more ink lies
    /// past the band of the small letters (ascenders outnumber descenders). Null when it cannot tell.</summary>
    static bool? ReadsDownByInk(Run run, Bitmap bitmap)
    {
        if (!run.Text.Any(c => char.IsAscii(c) && char.IsLetter(c))) return null;
        var box = run.Box;
        var background = RingColor(bitmap, box);
        int across = (int)box.W, along = (int)box.H;
        if (across <= 2 || along <= 2) return null;
        var counts = new int[across];
        for (int a = 0; a < across; a++)
            for (int b = 0; b < along; b++)
                if (Distance(bitmap.Pixel((int)box.MinX + a, (int)box.MinY + b), background) > 0.3) counts[a]++;
        int most = counts.Max();
        if (most == 0) return null;
        var dense = Enumerable.Range(0, across).Where(i => counts[i] >= most * 0.35).ToList();
        int leftInk = counts.Take(dense[0]).Sum(), rightInk = counts.Skip(dense[^1] + 1).Sum();
        if (Math.Max(leftInk, rightInk) <= Math.Min(leftInk, rightInk) * 3 / 2 + 2) return null;
        // Tops to the right: reading down the page.
        return rightInk > leftInk;
    }

    /// <summary>Sizes measured a little differently for words set at one size, made one: sizes in a run without a step of
    /// more than 8% (and within 30% of each other) take their median.</summary>
    public static List<double?> Harmonized(List<double?> sizes)
    {
        var known = Enumerable.Range(0, sizes.Count).Where(k => sizes[k] != null).OrderBy(k => sizes[k]!.Value).ToList();
        var result = new List<double?>(sizes);
        var cluster = new List<int>();
        void Close()
        {
            if (cluster.Count == 0) return;
            var values = cluster.Select(k => sizes[k]!.Value).ToList();
            double middle = values[values.Count / 2];
            foreach (var k in cluster) result[k] = middle;
            cluster.Clear();
        }
        foreach (var k in known)
        {
            if (cluster.Count > 0 && (sizes[k] > sizes[cluster[^1]] * 1.08 || sizes[k] > sizes[cluster[0]] * 1.3)) Close();
            cluster.Add(k);
        }
        Close();
        return result;
    }

    // Taking the words out

    /// <summary>The words' strokes (pixels unlike the background around them and like the words' ink, in shapes reaching
    /// into the words' box that are letters, not a line running through or along them) filled from what is beside them,
    /// across rows (or columns for words up the page); the words' size (from the band their small letters fill) and baseline.</summary>
    static (Bitmap Patch, Rect Area, RGBColor Color, double? Size, double? Baseline)? Erase(Run run, Bitmap bitmap)
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
        var background = Median(ring);
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
        // Only the shapes that reach into the words' box, and are letters: not a line running through or along them (a box's
        // edge, a dashed border), which stays.
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
            int x0 = pw, x1 = 0, y0 = ph, y1 = 0;
            while (stack.Count > 0)
            {
                int i = stack.Pop(), x = i % pw, y = i / pw;
                x0 = Math.Min(x0, x); x1 = Math.Max(x1, x); y0 = Math.Min(y0, y); y1 = Math.Max(y1, y);
                if (x >= bx0 && x < bx1 && y >= by0 && y < by1) touches = true;
                foreach (var (dx, dy) in new[] { (1, 0), (-1, 0), (0, 1), (0, -1) })
                {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || nx >= pw || ny < 0 || ny >= ph) continue;
                    int j = ny * pw + nx;
                    if (mask[j] && label[j] == 0) { label[j] = next; stack.Push(j); }
                }
            }
            var (a0, a1, extent) = run.Vertical ? (x0, x1, pw) : (y0, y1, ph);
            double extentAcross = a1 - a0 + 1, extentAlong = run.Vertical ? y1 - y0 + 1 : x1 - x0 + 1;
            bool crossing = a0 == 0 && a1 == extent - 1;
            bool rule = extentAcross <= Math.Max(2, thickness * 0.12) && extentAlong >= thickness * 1.5;
            // Mostly outside the words' box along the line (a bracket the reading left out, an icon): not theirs.
            var (l0, l1, b0, b1) = run.Vertical ? (y0, y1, by0, by1) : (x0, x1, bx0, bx1);
            bool outside = Math.Max(0, Math.Min(l1 + 1, b1) - Math.Max(l0, b0)) < extentAlong * 0.3;
            if (touches && !crossing && !rule && !outside) keep.Add(next);
            next++;
        }
        for (int i = 0; i < mask.Length; i++) if (mask[i] && !keep.Contains(label[i])) mask[i] = false;
        // The words' size from their ink: the band the small letters fill, about half the em (capitals and figures only:
        // the band they fill, seven tenths of it). Its lower edge is the baseline.
        double? size = null, baseline = null;
        var letters = run.Text.Where(char.IsLetter).ToList();
        double ratio = letters.Count(char.IsLower) * 10 >= letters.Count * 3 ? 0.48 : 0.70;
        static (int A, int B)? Band(int[] counts)
        {
            int most = counts.Length == 0 ? 0 : counts.Max();
            if (most == 0) return null;
            int peak = Array.IndexOf(counts, most), a = peak, b = peak;
            while (a > 0 && counts[a - 1] >= most * 0.35) a--;
            while (b < counts.Length - 1 && counts[b + 1] >= most * 0.35) b++;
            return (a, b);
        }
        if (!run.Vertical)
        {
            var counts = new int[ph];
            for (int y = 0; y < ph; y++) for (int x = Math.Max(0, bx0); x < Math.Min(pw, Math.Max(bx1, bx0 + 1)); x++) if (mask[y * pw + x]) counts[y]++;
            if (Band(counts) is { } rows)
            {
                size = Math.Clamp((rows.B - rows.A + 1) / ratio, box.H * 0.5, box.H * 1.5);
                baseline = py + rows.B + 1;
            }
        }
        else
        {
            var counts = new int[pw];
            for (int y = Math.Max(0, by0); y < Math.Min(ph, Math.Max(by1, by0 + 1)); y++) for (int x = 0; x < pw; x++) if (mask[y * pw + x]) counts[x]++;
            if (Band(counts) is { } columns) size = Math.Clamp((columns.B - columns.A + 1) / ratio, box.W * 0.5, box.W * 1.5);
        }
        // Grown a little: the soft edges of the strokes.
        int grow = Math.Max(1, (int)(thickness / 14));
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
        // Filled across from what is beside them; a colour still half ink (an edge left over) gives way to the background.
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
                if (Distance(a, background) > contrast * 0.5) a = background;
                if (Distance(b, background) > contrast * 0.5) b = background;
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
        return (new Bitmap(bytes, pw, ph), new Rect(px, py, pw, ph), new RGBColor(ink.R, ink.G, ink.B), size, baseline);
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
            runs.Add(new Run(text, rect, true) { ReadsDown = column[0].Down });
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
                    lines.Add(new Line(layout.Number, rect, spaced, line.Color, null, Rect.Null)
                        { Glyphs = chars.SelectMany(c => c.Glyphs).ToList(), Size = line.Size, Baseline = line.Baseline });
                }
                foreach (var c in line.Chars.Where(c => !c.IsRotated))
                {
                    var last = current.LastOrDefault(x => !x.IsSpace);
                    if (last != null && !c.IsSpace && c.Rect.MinX - last.Rect.MaxX > line.Size * 1.1) Flush();
                    current.Add(c);
                }
                Flush();
            }
        var arranged = Arrange(runs, yUp: true);
        for (int k = 0; k < lines.Count; k++)
        {
            lines[k].Align = arranged[k].Align;
            lines[k].Group = 1_000_000 + layout.Number * 10_000 + arranged[k].Group;
        }
        return lines;
    }

    // How the labels stand

    /// <summary>For each run: its group and how it is aligned. Runs form a group when they are set one under the other (or,
    /// sideways, side by side) as one label: about one size, close, overlapping with an edge or their centres in line, kept
    /// the same way (by an icon or not), and no line drawn between them (two boxes stacked). A group keeps whichever of its
    /// start edges, end edges or centres line up best, or the edge its icons keep. A run alone keeps its centre, or the edge
    /// an icon stood at.</summary>
    public static List<(int Group, Alignment Align)> Arrange(List<Run> runs, Func<int, int, bool>? separated = null, bool yUp = false)
    {
        var parent = Enumerable.Range(0, runs.Count).ToArray();
        int Root(int i) => parent[i] == i ? i : Root(parent[i]);
        static Rect Swap(Rect r, bool vertical) => vertical ? new Rect(r.MinY, r.MinX, r.H, r.W) : r;
        for (int i = 0; i < runs.Count; i++)
            for (int j = i + 1; j < runs.Count; j++)
            {
                if (runs[i].Vertical != runs[j].Vertical || runs[i].ReadsDown != runs[j].ReadsDown || runs[i].Anchor != runs[j].Anchor) continue;
                bool vertical = runs[i].Vertical;
                Rect a = Swap(runs[i].Box, vertical), b = Swap(runs[j].Box, vertical);
                double size = Math.Max(a.H, b.H), gap = Math.Max(a.MinY, b.MinY) - Math.Min(a.MaxY, b.MaxY);
                if (gap >= size * 0.7 || gap <= -size * 0.5 || size >= Math.Min(a.H, b.H) * 1.3 || Math.Min(a.MaxX, b.MaxX) - Math.Max(a.MinX, b.MinX) <= 0) continue;
                double lined = Math.Min(Math.Abs(a.MinX - b.MinX), Math.Min(Math.Abs(a.MidX - b.MidX), Math.Abs(a.MaxX - b.MaxX)));
                if (lined >= size * 0.6 || (!vertical && separated?.Invoke(i, j) == true)) continue;
                parent[Root(j)] = Root(i);
            }
        var result = new List<(int, Alignment)>(Enumerable.Repeat((0, Alignment.Center), runs.Count));
        foreach (var members in Enumerable.Range(0, runs.Count).GroupBy(Root))
        {
            var list = members.ToList();
            var first = runs[list[0]];
            var align = Alignment.Center;
            if (list.Count >= 2)
            {
                var boxes = list.Select(m => runs[m].Box).ToList();
                static double Spread(IEnumerable<double> v) => v.Max() - v.Min();
                // Where each line starts and ends along its reading: across, left to right; up the page, from the bottom;
                // down the page, from the top (pixel rows run down, page space up).
                bool fromLow = first.ReadsDown != yUp;
                var starts = boxes.Select(b => !first.Vertical ? b.MinX : fromLow ? b.MinY : -b.MaxY);
                var ends = boxes.Select(b => !first.Vertical ? b.MaxX : fromLow ? b.MaxY : -b.MinY);
                var middles = boxes.Select(b => !first.Vertical ? b.MidX : b.MidY);
                double tolerance = boxes.Max(b => first.Vertical ? b.W : b.H) * 0.15;
                double left = Spread(starts), center = Spread(middles), right = Spread(ends);
                align = center <= Math.Min(left, right) + tolerance ? Alignment.Center : left <= right ? Alignment.Left : Alignment.Right;
                if (first.Anchor is { } anchor) align = anchor;
            }
            else if (first.Anchor is { } anchor) align = anchor;
            foreach (var m in list) result[m] = (members.Key, align);
        }
        return result;
    }

    // Drawing

    static FontCatalog.Face FaceFor(string text, string language)
    {
        var face = IsCjk(language) ? FontCatalog.Script(language, false, false) ?? FontCatalog.Latin(false, false) : FontCatalog.Latin(false, false);
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

    /// <summary>The translations of a page's figures on a y-down canvas whose top is pageTop: first the patches (the words
    /// taken out), then the translations, each at the size of the words it replaces (as large as they look), narrowed or
    /// made smaller only when it would run past them; words of one size keep one size, a group's lines share theirs; each is
    /// aligned as the words were, on their line.</summary>
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
        bool cjk = IsCjk(language);
        static double Length(Line l) => l.Vertical ? l.Rect.H : l.Rect.W;
        static double Thickness(Line l) => l.Vertical ? l.Rect.W : l.Rect.H;
        double? Natural(Line l) => l.Size * (cjk ? 0.9 : 1);
        var faces = entries.Select(e => FaceFor(e.Translation, language)).ToList();
        var fits = entries.Select((e, k) => FitText(e.Translation, faces[k].Typeface, Length(e.Line), Thickness(e.Line), null, Natural(e.Line))).ToList();
        void Refit(IEnumerable<int> members, double size)
        {
            foreach (var m in members) fits[m] = FitText(entries[m].Translation, faces[m].Typeface, Length(entries[m].Line), Thickness(entries[m].Line), size, null);
        }
        // Words of one size: one size, the smallest any needs, unless one needs far less (it alone is made smaller).
        foreach (var members in Enumerable.Range(0, entries.Count).Where(k => entries[k].Line.Size != null)
                     .GroupBy(k => (entries[k].Line.Page, entries[k].Line.Vertical, (int)Math.Round(entries[k].Line.Size!.Value * 4))).Where(g => g.Count() > 1))
        {
            double target = Natural(entries[members.First()].Line)!.Value;
            var fitting = members.Where(m => fits[m].Size >= target * 0.8).ToList();
            if (fitting.Count > 0) Refit(fitting, fitting.Min(m => fits[m].Size));
        }
        // One size for a group: the smallest any of its lines needs.
        foreach (var members in Enumerable.Range(0, entries.Count).GroupBy(k => entries[k].Line.Group).Where(g => g.Count() > 1))
            Refit(members, members.Min(m => fits[m].Size));
        for (int k = 0; k < entries.Count; k++)
        {
            var (line, translation) = entries[k];
            if (translation.Length == 0) continue;
            var fit = fits[k];
            using var font = new SKFont(faces[k].Typeface, (float)fit.Size) { Subpixel = true, LinearMetrics = true, ScaleX = (float)fit.Squeeze };
            used?.UnionWith(font.GetGlyphs(translation));
            double ascent = -font.Metrics.Ascent, descent = font.Metrics.Descent;
            double room = Length(line) - fit.Width;
            double offset = line.Align switch { Alignment.Left => 0, Alignment.Right => room, _ => room / 2 };
            double rise = (Thickness(line) - (ascent + descent)) / 2 + descent;
            // On the words' line: Latin on their baseline; Chinese characters centred on their capitals.
            if (!line.Vertical && line.Baseline is { } baseline && line.Size is { } size)
                rise = cjk ? baseline + size * 0.35 - fit.Size * 0.38 - line.Rect.MinY : baseline - line.Rect.MinY;
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

/// <summary>The words of a figure as the translator gets them (TRANS-40), as on macOS (ImageTextUnits.swift): a label set
/// over several lines is one text, its translation shared out across the lines again, each line about as much as it held.
/// A centred block of lines is one label; lines set flush one under the other may be separate labels (a legend, two items
/// with check marks) and stay apart, unless a line starts in lower case or the one above ends with a hyphen or a word such
/// as "of" or "for".</summary>
public static class ImageTextUnits
{
    public sealed record Unit(string Text, List<int> Members);

    static readonly HashSet<string> Joiners = ["of", "and", "or", "for", "on", "in", "the", "to", "with", "a", "an", "by", "from", "at", "as", "via", "into"];

    public static bool Continues(string upper, string lower)
    {
        var first = lower.FirstOrDefault(c => !char.IsWhiteSpace(c));
        if (first == default) return false;
        if (char.IsLetter(first) && char.IsLower(first)) return true;
        if (upper.EndsWith('-')) return true;
        return Joiners.Contains(upper.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault()?.ToLowerInvariant() ?? "");
    }

    /// <summary>One word that is a name: a capital after small letters inside it (SnakeSAM, ResNet, PyTorch), or a word
    /// ending in figures (YOLOv8, ResNet50). Kept as it is (a translation service would turn SnakeSAM into a snake).</summary>
    public static bool IsName(string text)
    {
        if (text.Contains(' ') || text.Length < 3) return false;
        bool innerCapital = Enumerable.Range(1, text.Length - 1).Any(i => char.IsUpper(text[i]) && char.IsLower(text[i - 1]));
        return innerCapital || (char.IsLetter(text[0]) && char.IsDigit(text[^1]));
    }

    public static List<Unit> Units(List<ImageText.Line> lines)
    {
        var units = new List<Unit>();
        var placed = new HashSet<int>();
        for (int k = 0; k < lines.Count; k++)
        {
            if (placed.Contains(k)) continue;
            var line = lines[k];
            // The group's lines in reading order: across, top first; reading up the page, the left one first; down, the right.
            var group = Enumerable.Range(0, lines.Count)
                .Where(i => lines[i].Page == line.Page && lines[i].Group == line.Group && lines[i].Vertical == line.Vertical && !placed.Contains(i))
                .OrderBy(i => !line.Vertical ? -lines[i].Rect.MaxY : line.ReadsDown ? -lines[i].Rect.MidX : lines[i].Rect.MidX).ToList();
            var text = lines[group[0]].Text;
            var members = new List<int> { group[0] };
            foreach (var m in group.Skip(1))
            {
                var upper = lines[members[^1]].Text;
                // A centred block of lines is one label ("Prompt Class / Flag Embedding"), unless a line ends a sentence.
                bool centred = line.Align == ImageText.Alignment.Center && !(upper.Length > 0 && ".:;!?".Contains(upper[^1]));
                if (centred || Continues(upper, lines[m].Text))
                {
                    text = upper.EndsWith('-') && lines[m].Text.Length > 0 && char.IsLower(lines[m].Text[0]) ? text[..^1] + lines[m].Text : text + " " + lines[m].Text;
                    members.Add(m);
                }
                else
                {
                    units.Add(new Unit(text, members));
                    text = lines[m].Text;
                    members = [m];
                }
            }
            units.Add(new Unit(text, members));
            foreach (var m in group) placed.Add(m);
        }
        return units;
    }

    /// <summary>text cut into as many pieces as there are weights, each about its share of the whole, at places a line may
    /// break: between spaces, or (Chinese, Japanese, Korean) where words start (as the platform's word breaker finds them),
    /// never inside a Latin word or a number, nor before closing punctuation; after a comma or a pause preferred.</summary>
    public static List<string> Split(string text, List<double> weights, bool cjk, string? language = null)
    {
        if (weights.Count <= 1) return [text];
        var chars = text.ToCharArray();
        static double Width(char c) => c == ' ' ? 0.3 : c < 128 ? 0.55 : 1;
        var cumulative = new double[chars.Length + 1];
        for (int i = 0; i < chars.Length; i++) cumulative[i + 1] = cumulative[i] + Width(chars[i]);
        double total = cumulative[^1];
        static bool Latin(char c) => c < 128 && (char.IsLetterOrDigit(c) || c is '-' or '.' or '_');
        const string closing = "，。、；：！？）》」』】,.;:!?)]%", pauses = "，、；：,;:";
        var starts = cjk && language != null ? ImageText.Platform?.WordStarts?.Invoke(text, language) ?? [] : [];
        var breaks = new List<int>();
        var anywhere = new List<int>();
        for (int i = 1; i < chars.Length; i++)
        {
            char a = chars[i - 1], b = chars[i];
            if (char.IsLowSurrogate(b)) continue;
            if (cjk)
            {
                if (closing.Contains(b) || (Latin(a) && Latin(b)) || (a == ' ' && b == ' ')) continue;
                anywhere.Add(i);
                if (starts.Contains(i) || pauses.Contains(a) || a == ' ' || b == ' ') breaks.Add(i);
            }
            else if (a == ' ') breaks.Add(i);
        }
        if (cjk && breaks.Count < weights.Count - 1) breaks = anywhere;
        var shares = weights.Select(w => Math.Max(w, 0.01)).ToList();
        double sum = shares.Sum(), acc = 0;
        var cuts = new List<int>();
        for (int k = 0; k < weights.Count - 1; k++)
        {
            acc += shares[k];
            double target = total * acc / sum;
            int remaining = weights.Count - 2 - k;
            var candidates = breaks.Where(b => b > (cuts.Count > 0 ? cuts[^1] : 0)).ToList();
            if (candidates.Count <= remaining) break;
            double Cost(int i) => Math.Abs(cumulative[i] - target) - (pauses.Contains(chars[i - 1]) ? 0.8 : 0);
            cuts.Add(candidates.Take(candidates.Count - remaining).MinBy(Cost));
        }
        var pieces = new List<string>();
        int startAt = 0;
        foreach (var cut in cuts.Append(chars.Length))
        {
            pieces.Add(new string(chars, startAt, cut - startAt).Trim());
            startAt = cut;
        }
        // Not enough places to break: the rest of the lines get nothing (their words are taken out all the same).
        while (pieces.Count < weights.Count) pieces.Add("");
        return pieces;
    }
}
