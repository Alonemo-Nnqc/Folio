using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Pdf;

namespace Folio.Core.Translate.Layout;

// Port of macos/.../FolioTranslate/Layout/ScanMask.swift.

public sealed partial class ScanPage
{
    /// <summary>A page as grey levels, the top row first, in the upright space.</summary>
    internal sealed class Raster(int width, int height, byte[] pixels, double scale, Rect crop)
    {
        /// <summary>The page in the upright space, from a render of it as it is shown.</summary>
        public static Raster? Render(Shown shown, Rect crop, Affine transform, double scale)
        {
            // No finer than what there is.
            scale = Math.Min(scale, Math.Max(shown.Scale / Math.Max(Math.Sqrt(Math.Abs(transform.A * transform.D - transform.B * transform.C)), 1e-9), 0.2));
            int width = (int)(crop.W * scale), height = (int)(crop.H * scale);
            if (width <= 8 || height <= 8 || (long)width * height >= 40_000_000) return null;
            // Pixels here → points of the upright space → the page's user space → pixels of the render.
            var map = new Affine(1 / scale, 0, 0, -1 / scale, crop.MinX, crop.MaxY).Concatenating(transform.Inverted()).Concatenating(shown.Map);
            var source = shown.Bitmap;
            int sw = source.Width, sh = source.Height;
            var grey = new byte[sw * sh];
            for (int k = 0; k < grey.Length; k++)
                grey[k] = (byte)((source.Rgba[k * 4] * 299 + source.Rgba[k * 4 + 1] * 587 + source.Rgba[k * 4 + 2] * 114) / 1000);
            var pixels = new byte[width * height];
            // Made smaller: the mean of a few places in each pixel.
            int parts = Math.Clamp((int)Math.Round(Math.Sqrt(Math.Abs(map.A * map.D - map.B * map.C))), 1, 4);
            Parallel.For(0, height, y =>
            {
                for (int x = 0; x < width; x++)
                {
                    double sum = 0;
                    for (int j = 0; j < parts; j++)
                        for (int i = 0; i < parts; i++)
                        {
                            double px = x + (i + 0.5) / parts, py = y + (j + 0.5) / parts;
                            double u = map.A * px + map.C * py + map.Tx - 0.5, v = map.B * px + map.D * py + map.Ty - 0.5;
                            int u0 = (int)Math.Floor(u), v0 = (int)Math.Floor(v);
                            if (u0 < -1 || v0 < -1 || u0 >= sw || v0 >= sh) { sum += 255; continue; }
                            double fu = u - u0, fv = v - v0;
                            int ua = Math.Max(u0, 0), ub = Math.Min(u0 + 1, sw - 1), va = Math.Max(v0, 0) * sw, vb = Math.Min(v0 + 1, sh - 1) * sw;
                            sum += (grey[va + ua] * (1 - fu) + grey[va + ub] * fu) * (1 - fv) + (grey[vb + ua] * (1 - fu) + grey[vb + ub] * fu) * fv;
                        }
                    pixels[y * width + x] = (byte)Math.Clamp(sum / (parts * parts) + 0.5, 0, 255);
                }
            });
            return new Raster(width, height, pixels, scale, crop);
        }

        /// <summary>Ink (1) and paper (0): what is clearly darker than the paper around it. A page with light words on dark is read
        /// the other way round; a pale watermark is paper.</summary>
        public InkMask Mask()
        {
            int block = Math.Max(8, (int)(32 * scale));
            int cols = (width + block - 1) / block, rows = (height + block - 1) / block;
            var ground = new double[cols * rows];
            void Grounds(bool invert)
            {
                for (int by = 0; by < rows; by++)
                    for (int bx = 0; bx < cols; bx++)
                    {
                        var histogram = new int[256];
                        int n = 0;
                        for (int y = by * block; y < Math.Min(height, (by + 1) * block); y += 2)
                            for (int x = bx * block; x < Math.Min(width, (bx + 1) * block); x += 2)
                            {
                                int v = pixels[y * width + x];
                                histogram[invert ? 255 - v : v]++;
                                n++;
                            }
                        int left = n / 10, level = 255;
                        while (level > 0)
                        {
                            left -= histogram[level];
                            if (left < 0) break;
                            level--;
                        }
                        ground[by * cols + bx] = level;
                    }
            }
            Grounds(false);
            // Mostly dark paper: the middle of all the page's pixels says so.
            var whole = new int[256];
            int total = 0;
            for (int k = 0; k < pixels.Length; k += 7) { whole[pixels[k]]++; total++; }
            int rest = total / 2, middle = 0;
            while (middle < 255)
            {
                rest -= whole[middle];
                if (rest <= 0) break;
                middle++;
            }
            bool inverted = middle < 110;
            if (inverted) Grounds(true);
            var levels = new double[cols * rows];
            for (int by = 0; by < rows; by++)
                for (int bx = 0; bx < cols; bx++)
                {
                    double best = 0;
                    for (int y = Math.Max(0, by - 1); y <= Math.Min(rows - 1, by + 1); y++)
                        for (int x = Math.Max(0, bx - 1); x <= Math.Min(cols - 1, bx + 1); x++) best = Math.Max(best, ground[y * cols + x]);
                    levels[by * cols + bx] = best;
                }
            var ink = new byte[width * height];
            var faint = new byte[width * height];
            Parallel.For(0, height, y =>
            {
                int by = y / block;
                for (int x = 0; x < width; x++)
                {
                    int v = pixels[y * width + x];
                    double light = (inverted ? 255 - v : v) / Math.Max(levels[by * cols + x / block], 60);
                    if (light < 0.72) ink[y * width + x] = 1;
                    if (light < 0.9) faint[y * width + x] = 1;
                }
            });
            return new InkMask(width, height, ink, faint, scale, crop);
        }

        /// <summary>How far the lines of the page tilt (radians, counter-clockwise up), when the rows of ink say so clearly.</summary>
        public double Skew()
        {
            var mask = Mask();
            int count = mask.Ink.Sum(b => b), step = Math.Max(1, count / 40_000), n = 0;
            var points = new List<(double X, double Y)>();
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                    if (mask.Ink[y * width + x] == 1 && ++n % step == 0) points.Add((x - width / 2.0, y));
            if (points.Count <= 500) return 0;
            double Score(double angle)
            {
                double t = Math.Tan(angle);
                var bins = new double[height + width];
                foreach (var (x, y) in points)
                {
                    int b = (int)(y + x * t) + width / 2;
                    if (b >= 0 && b < bins.Length) bins[b]++;
                }
                double sum = 0;
                for (int k = 0; k + 1 < bins.Length; k++) sum += (bins[k] - bins[k + 1]) * (bins[k] - bins[k + 1]);
                return sum;
            }
            double level = Score(0), best = 0, bestScore = level;
            void Try(double angle)
            {
                double s = Score(angle);
                if (s > bestScore) { best = angle; bestScore = s; }
            }
            for (int k = -16; k <= 16; k++) if (k != 0) Try(k * 0.2 * Math.PI / 180);
            double around = best;
            for (int k = -3; k <= 3; k++) Try(around + k * 0.05 * Math.PI / 180);
            return Math.Abs(best) >= 0.3 * Math.PI / 180 && bestScore > level * 1.15 ? best : 0;
        }
    }

    /// <summary>Where a page has ink.</summary>
    internal sealed class InkMask(int width, int height, byte[] ink, byte[] faint, double scale, Rect crop)
    {
        public byte[] Ink => ink;

        int Px(double x) => (int)Math.Floor((x - crop.MinX) * scale);
        int Py(double y) => (int)Math.Floor((crop.MaxY - y) * scale);
        /// <summary>Pixels (columns, rows: both ends in) as a rectangle of the page.</summary>
        Rect RectOf(int x0, int y0, int x1, int y1) =>
            new(crop.MinX + x0 / scale, crop.MaxY - (y1 + 1) / scale, (x1 - x0 + 1) / scale, (y1 - y0 + 1) / scale);

        // MARK: Words

        /// <summary>Finds the word's ink in its box, and how thick its strokes are.</summary>
        public void Measure(Word word, double usual)
        {
            int x0 = Math.Max(0, Px(word.X0)), x1 = Math.Min(width - 1, Px(word.X1));
            int top = Py(word.Top), bottom = Py(word.Bottom);
            if (x1 <= x0 || bottom <= top) return;
            int h = bottom - top;
            int y0 = Math.Max(0, top - h / 3), y1 = Math.Min(height - 1, bottom + h / 3);
            if (y1 <= y0) return;
            var profile = new int[y1 - y0 + 1];
            for (int y = y0; y <= y1; y++)
            {
                int n = 0, row = y * width;
                for (int x = x0; x <= x1; x++) n += ink[row + x];
                profile[y - y0] = n;
            }
            // The row with the most ink in the box, and on from it both ways to where the paper begins (the dot of an i is
            // a little way off).
            int solid = word.Letters >= 3 ? (x1 - x0 + 1) * 93 / 100 : int.MaxValue;
            int middle = -1;
            for (int y = Math.Max(top, y0); y <= Math.Min(bottom, y1); y++)
                if (profile[y - y0] <= solid && (middle < 0 || profile[y - y0] > profile[middle - y0])) middle = y;
            if (middle < 0 || profile[middle - y0] == 0) return;
            int gapAllowed = Math.Max(1, (int)(Math.Min(usual, h / scale) * 0.14 * scale));
            int Reach(int step)
            {
                int y = middle, last = middle, gap = 0;
                while (y + step >= y0 && y + step <= y1)
                {
                    y += step;
                    // A rule, or the edge of a filled box, right under or over the word.
                    if (profile[y - y0] > solid && Math.Abs(y - middle) > h / 6) break;
                    if (profile[y - y0] > 0) { last = y; gap = 0; }
                    else if (++gap > (y >= top && y <= bottom ? gapAllowed : 1)) break;
                }
                return last;
            }
            int a = Reach(-1), b = Reach(1);
            // Touching the line above or below: no further than the box.
            if (a == y0) a = Math.Max(a, top);
            if (b == y1) b = Math.Min(b, bottom);
            if (b <= a) return;
            word.Ink = RectOf(x0, a, x1, b);
            // Strokes: ink over half its outline.
            int area = 0, edges = 0;
            for (int y = a; y <= b; y++)
            {
                int row = y * width;
                for (int x = x0; x <= x1; x++)
                {
                    if (ink[row + x] != 1) continue;
                    area++;
                    if (x == 0 || ink[row + x - 1] == 0) edges++;
                    if (x + 1 >= width || ink[row + x + 1] == 0) edges++;
                    if (y == 0 || ink[row - width + x] == 0) edges++;
                    if (y + 1 >= height || ink[row + width + x] == 0) edges++;
                }
            }
            if (edges > 0) word.Stroke = 2.0 * area / edges / scale;
        }

        /// <summary>The share of the columns of a rectangle with ink in them.</summary>
        public double ColumnsFilled(Rect rect)
        {
            int x0 = Math.Max(0, Px(rect.MinX)), x1 = Math.Min(width - 1, Px(rect.MaxX));
            int y0 = Math.Max(0, Py(rect.MaxY)), y1 = Math.Min(height - 1, Py(rect.MinY));
            if (x1 <= x0 || y1 <= y0) return 0;
            int filled = 0;
            for (int x = x0; x <= x1; x++)
                for (int y = y0; y <= y1; y++)
                    if (ink[y * width + x] == 1) { filled++; break; }
            return (double)filled / (x1 - x0 + 1);
        }

        // MARK: Rules

        /// <summary>Level and upright rules, and solid areas long enough to look like them at first (thick ones keep their size).</summary>
        public (List<Rect> Rules, List<Rect> Uprights) Rules(List<Word> words)
        {
            var inWords = words.Where(w => w.Ink != null).Select(w => w.Ink!.Value).ToList();
            bool Free(Rect r) => !inWords.Any(w => w.InsetBy(-1, -1).Contains(r) && r.W < w.W * 0.95 + 1);
            var level = Strokes(height, width, (int)(16 * scale), (row, x) => ink[row * width + x] == 1)
                .Select(s => RectOf(s.Start, s.First, s.End, s.Last)).ToList();
            var up = Strokes(width, height, (int)(12 * scale), (column, y) => ink[y * width + column] == 1)
                .Select(s => RectOf(s.First, s.Start, s.Last, s.End)).ToList();
            // Hairlines too pale for ink: long, thin, and level.
            var hair = Strokes(height, width, (int)(60 * scale), (row, x) => faint[row * width + x] == 1)
                .Select(s => RectOf(s.Start, s.First, s.End, s.Last))
                .Where(r => r.H < 2.2 && !level.Any(l => l.InsetBy(-2, -2).Intersects(r))).ToList();
            // A filled area full of grain shows as many upright strokes side by side; a grid's lines are apart.
            var posts = up.Where(r => r.W > 3.2 || up.Count(o => o != r && Math.Abs(o.MidX - r.MidX) < 5 && Math.Min(o.MaxY, r.MaxY) - Math.Max(o.MinY, r.MinY) > r.H * 0.6) < 2);
            return (level.Concat(hair).Where(Free).ToList(), posts.Where(Free).ToList());
        }

        sealed class Stroke { public int Start, End, First, Last; }

        /// <summary>Unbroken runs of ink along one direction, next to each other ones together.</summary>
        List<Stroke> Strokes(int count, int along, int least, Func<int, int, bool> at)
        {
            var open = new List<Stroke>();
            var done = new List<Stroke>();
            // A rule tilting by a pixel or a nick in it breaks a run in two: short pieces join along the rule too.
            int joint = Math.Max(1, (int)(scale * 0.7));
            var all = new List<(int, int)>[count];
            Parallel.For(0, count, line =>
            {
                var runs = new List<(int, int)>();
                int start = -1, lastInk = -10;
                for (int x = 0; x < along; x++)
                {
                    if (at(line, x))
                    {
                        if (start < 0) start = x;
                        lastInk = x;
                    }
                    else if (start >= 0 && x - lastInk > joint)
                    {
                        if (lastInk - start + 1 >= least) runs.Add((start, lastInk));
                        start = -1;
                    }
                }
                if (start >= 0 && lastInk - start + 1 >= least) runs.Add((start, lastInk));
                all[line] = runs;
            });
            for (int line = 0; line < count; line++)
            {
                foreach (var (from, to) in all[line])
                {
                    if (open.Find(o => o.Start <= to + 3 && o.End >= from - 3) is { } known)
                    {
                        known.Start = Math.Min(known.Start, from);
                        known.End = Math.Max(known.End, to);
                        known.Last = line;
                    }
                    else open.Add(new Stroke { Start = from, End = to, First = line, Last = line });
                }
                done.AddRange(open.Where(o => o.Last < line - 1));
                open.RemoveAll(o => o.Last < line - 1);
            }
            done.AddRange(open);
            return done;
        }

        // MARK: Drawings

        /// <summary>The rules as marks, and the drawings: ink that is neither words nor rules, in pieces too large to be the bits a
        /// recognition leaves out of a line.</summary>
        public (List<GraphicMark> Marks, List<Rect> Bits) Drawings(List<Row> rows, List<Rect> rules, List<Rect> uprights, Rect page)
        {
            var marks = new List<GraphicMark>();
            var bits = new List<Rect>();
            void Add(GraphicMark.MarkKind kind, Rect rect) => marks.Add(MakeMark(kind, rect, marks.Count));
            // The dark edge a scanner leaves around the page says nothing.
            var edge = page.InsetBy(page.W * 0.012, page.H * 0.012);
            const double thin = 3.2;
            foreach (var rule in rules) if (rule.H <= thin && rule.Intersects(edge) && edge.Contains(new Pt(edge.MidX, rule.MidY))) Add(GraphicMark.MarkKind.Fill, rule);
            foreach (var rule in uprights) if (rule.W <= thin && edge.Contains(new Pt(rule.MidX, edge.MidY))) Add(GraphicMark.MarkKind.Fill, rule);

            // Ink left over on a coarse grid.
            int cell = Math.Max(2, (int)(2 * scale));
            int cols = width / cell + 1, lines = height / cell + 1;
            var left = (byte[])ink.Clone();
            void Clear(Rect r, double dx, double dy)
            {
                int x0 = Math.Max(0, Px(r.MinX - dx)), x1 = Math.Min(width - 1, Px(r.MaxX + dx));
                int y0 = Math.Max(0, Py(r.MaxY + dy)), y1 = Math.Min(height - 1, Py(r.MinY - dy));
                if (x1 < x0 || y1 < y0) return;
                for (int y = y0; y <= y1; y++) Array.Clear(left, y * width + x0, x1 - x0 + 1);
            }
            foreach (var rule in rules) if (rule.H <= thin) Clear(rule, 0.5, 0.5);
            foreach (var rule in uprights) if (rule.W <= thin) Clear(rule, 0.5, 0.5);
            foreach (var row in rows)
            {
                foreach (var word in row.Words) Clear(word.Ink ?? new Rect(word.X0, word.Bottom, word.X1 - word.X0, word.Height), row.Size * 0.22, row.Size * 0.12);
                // A line of running text is words from end to end, whatever was not read in it.
                if (!row.Upright && row.Letters >= 24) Clear(new Rect(row.X0, row.Baseline - row.Size * 0.25, row.X1 - row.X0, row.Size * 1.05), row.Size * 0.3, row.Size * 0.1);
            }
            var grid = new bool[cols * lines];
            int least = Math.Max(2, cell * cell / 12);
            for (int cy = 0; cy < lines; cy++)
                for (int cx = 0; cx < cols; cx++)
                {
                    int n = 0;
                    for (int y = cy * cell; y < Math.Min(height, (cy + 1) * cell); y++)
                        for (int x = cx * cell; x < Math.Min(width, (cx + 1) * cell); x++) n += left[y * width + x];
                    if (n >= least) grid[cy * cols + cx] = true;
                }
            // Cells within two of each other go together.
            var seen = new bool[grid.Length];
            var stack = new Stack<int>();
            for (int start = 0; start < grid.Length; start++)
            {
                if (!grid[start] || seen[start]) continue;
                stack.Push(start);
                seen[start] = true;
                int x0 = cols, x1 = 0, y0 = lines, y1 = 0, count = 0;
                while (stack.TryPop(out int k))
                {
                    int cx = k % cols, cy = k / cols;
                    count++;
                    x0 = Math.Min(x0, cx); x1 = Math.Max(x1, cx); y0 = Math.Min(y0, cy); y1 = Math.Max(y1, cy);
                    for (int ny = Math.Max(0, cy - 2); ny <= Math.Min(lines - 1, cy + 2); ny++)
                        for (int nx = Math.Max(0, cx - 2); nx <= Math.Min(cols - 1, cx + 2); nx++)
                        {
                            int j = ny * cols + nx;
                            if (grid[j] && !seen[j]) { seen[j] = true; stack.Push(j); }
                        }
                }
                var r = RectOf(x0 * cell, y0 * cell, Math.Min(width - 1, (x1 + 1) * cell - 1), Math.Min(height - 1, (y1 + 1) * cell - 1));
                if (r.W < 24 || r.H < 24 || count < 24)
                {
                    if (count >= 2 && r.W < 80 && r.H < 60 && bits.Count < 2000) bits.Add(r);
                    continue;
                }
                // The edge of the scan, all around or along a side.
                if (r.W > page.W * 0.95 && r.H > page.H * 0.95 && (double)count * cell * cell / scale / scale < r.W * r.H * 0.1) continue;
                if (!edge.Contains(r.Center)) continue;
                Add(GraphicMark.MarkKind.Image, r);
            }
            return (marks, bits);
        }
    }

    /// <summary>Something found in the picture, as a mark of the page.</summary>
    internal static GraphicMark MakeMark(GraphicMark.MarkKind kind, Rect rect, int index) =>
        new() { Kind = kind, Rect = rect, Location = new OpLocation(FoundInPicture, index), SegmentCount = 4 };

    static readonly StreamPath FoundInPicture = StreamPath.Root.Appending(-1);
}
