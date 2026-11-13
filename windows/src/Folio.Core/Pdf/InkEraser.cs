namespace Folio.Core;

/// <summary>
/// Geometry of the reader's eraser (READER-30): cuts away the parts of ink strokes the eraser passed over.
/// The eraser's track is a chain of capsules (each segment of the track widened by the radius). Every stroke is a
/// polyline; for each of its segments the stretch inside any capsule is computed exactly (a capsule is convex, so it
/// meets a line in one interval) and removed, and the stroke is cut where it enters and leaves. What remains of a cut
/// stroke is kept as separate strokes; pieces shorter than the minimum length are dropped; untouched strokes stay as
/// they were. The macOS app has the same algorithm (FolioCore <c>InkEraser</c>); the reader page has a copy for its
/// preview (viewer.js).
/// </summary>
public static class InkEraser
{
    /// <summary>The eraser's sizes (the setting <c>readerEraserSize</c>, shared with the macOS app): diameters in page points.</summary>
    public static readonly IReadOnlyDictionary<string, double> Diameters = new Dictionary<string, double>
    {
        ["small"] = 8, ["medium"] = 16, ["large"] = 32,
    };

    /// <summary>Pieces of cut strokes shorter than this (page points) are dropped: they would show as specks.</summary>
    public const double DefaultMinimumLength = 1;

    const double Epsilon = 1e-9;

    /// <summary>The strokes (x y x y …, page coordinates) after erasing along <paramref name="path"/> (x y x y …), or null
    /// when the eraser touched none of them. An empty list means everything was erased. <paramref name="radius"/> is how far
    /// from the track is erased: the eraser's radius plus half the stroke's line width.</summary>
    public static List<double[]>? Erase(IReadOnlyList<double[]> strokes, double[] path, double radius, double minimumLength = DefaultMinimumLength)
    {
        var track = Points(path);
        if (track.Count == 0 || radius <= 0) return null;
        var capsules = track.Count == 1 ? [(track[0], track[0])] : track.Zip(track.Skip(1)).ToList();
        var (l, b, r, t) = Bounds(track);
        l -= radius; b -= radius; r += radius; t += radius;
        var result = new List<double[]>();
        bool changed = false;
        foreach (var flat in strokes)
        {
            var stroke = Points(flat);
            if (stroke.Count == 0) { result.Add(flat); continue; }
            var (sl, sb, sr, st) = Bounds(stroke);
            var pieces = sr < l || sl > r || st < b || sb > t ? null : Cut(stroke, capsules, radius, minimumLength);
            if (pieces == null) { result.Add(flat); continue; }
            changed = true;
            result.AddRange(pieces.Select(Flatten));
        }
        return changed ? result : null;
    }

    /// <summary>Erases along several tracks in turn (the eraser left the page and came back).</summary>
    public static List<double[]>? Erase(IReadOnlyList<double[]> strokes, IEnumerable<double[]> paths, double radius, double minimumLength = DefaultMinimumLength)
    {
        List<double[]>? current = null;
        foreach (var path in paths)
        {
            if (Erase(current ?? strokes, path, radius, minimumLength) is { } next) current = next;
        }
        return current;
    }

    public static double Length(IReadOnlyList<(double X, double Y)> stroke)
    {
        double total = 0;
        for (int i = 0; i + 1 < stroke.Count; i++) total += Hypot(stroke[i + 1].X - stroke[i].X, stroke[i + 1].Y - stroke[i].Y);
        return total;
    }

    /// <summary>The pieces left of one stroke, or null when no capsule touches it.</summary>
    static List<List<(double X, double Y)>>? Cut(List<(double X, double Y)> stroke, List<((double X, double Y), (double X, double Y))> capsules, double radius, double minimumLength)
    {
        if (stroke.Count == 1)
            return capsules.Any(c => Distance(stroke[0], c.Item1, c.Item2) <= radius) ? [] : null;
        var pieces = new List<List<(double X, double Y)>>();
        var current = new List<(double X, double Y)>();
        bool touched = false;
        void Flush()
        {
            if (current.Count > 1) pieces.Add(current);
            current = [];
        }
        for (int i = 0; i + 1 < stroke.Count; i++)
        {
            var a = stroke[i];
            var b = stroke[i + 1];
            var removed = Merge(capsules.Select(c => Interval(a, b, c.Item1, c.Item2, radius)).Where(i => i.HasValue).Select(i => i!.Value));
            if (removed.Count == 0)
            {
                if (current.Count == 0) current.Add(a);
                current.Add(b);
                continue;
            }
            touched = true;
            double segmentLength = Hypot(b.X - a.X, b.Y - a.Y);
            var kept = Complement(removed).Where(k => (k.High - k.Low) * segmentLength > 1e-6).ToList();
            bool startsAtA = kept.Count > 0 && kept[0].Low <= Epsilon;
            if (!startsAtA) Flush();
            for (int k = 0; k < kept.Count; k++)
            {
                var (low, high) = kept[k];
                var start = low <= Epsilon ? a : Lerp(a, b, low);
                var end = high >= 1 - Epsilon ? b : Lerp(a, b, high);
                if (k == 0 && startsAtA && current.Count > 0) current.Add(end);
                else { Flush(); current = [start, end]; }
                if (high < 1 - Epsilon) Flush();
            }
        }
        Flush();
        if (!touched) return null;
        return pieces.Where(p => Length(p) >= minimumLength).ToList();
    }

    static (double X, double Y) Lerp((double X, double Y) a, (double X, double Y) b, double t) => (a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t);

    static List<(double Low, double High)> Merge(IEnumerable<(double Low, double High)> intervals)
    {
        var result = new List<(double Low, double High)>();
        foreach (var next in intervals.OrderBy(i => i.Low))
        {
            if (result.Count > 0 && next.Low <= result[^1].High) result[^1] = (result[^1].Low, Math.Max(result[^1].High, next.High));
            else result.Add(next);
        }
        return result;
    }

    static List<(double Low, double High)> Complement(List<(double Low, double High)> removed)
    {
        var result = new List<(double Low, double High)>();
        double start = 0;
        foreach (var (low, high) in removed)
        {
            if (low > start) result.Add((start, low));
            start = Math.Max(start, high);
        }
        if (start < 1) result.Add((start, 1));
        return result;
    }

    /// <summary>The part (as parameters 0…1 of a→b) of the segment a→b within <paramref name="r"/> of the segment c→d, or null.</summary>
    public static (double Low, double High)? Interval((double X, double Y) a, (double X, double Y) b, (double X, double Y) c, (double X, double Y) d, double r)
    {
        double dx = b.X - a.X, dy = b.Y - a.Y;
        // A segment of no length (a repeated point) is all in or all out.
        if (dx * dx + dy * dy < 1e-18) return Distance(a, c, d) <= r ? (0, 1) : null;
        // The capsule is the union of the discs at its ends and the band along it; being convex, it meets the line in one
        // interval, the span of what the three parts give.
        double low = double.PositiveInfinity, high = double.NegativeInfinity;
        foreach (var centre in new[] { c, d })
            if (Disc(a, dx, dy, centre, r) is { } disc) { low = Math.Min(low, disc.Item1); high = Math.Max(high, disc.Item2); }
        if (Band(a, dx, dy, c, d, r) is { } band) { low = Math.Min(low, band.Item1); high = Math.Max(high, band.Item2); }
        double lower = Math.Max(low, 0), upper = Math.Min(high, 1);
        return lower <= upper ? (lower, upper) : null;
    }

    static (double, double)? Disc((double X, double Y) a, double dx, double dy, (double X, double Y) centre, double r)
    {
        double fx = a.X - centre.X, fy = a.Y - centre.Y;
        double qa = dx * dx + dy * dy, qb = 2 * (fx * dx + fy * dy), qc = fx * fx + fy * fy - r * r;
        double discriminant = qb * qb - 4 * qa * qc;
        if (discriminant < 0) return null;
        double root = Math.Sqrt(discriminant);
        return ((-qb - root) / (2 * qa), (-qb + root) / (2 * qa));
    }

    static (double, double)? Band((double X, double Y) a, double dx, double dy, (double X, double Y) c, (double X, double Y) d, double r)
    {
        double ex = d.X - c.X, ey = d.Y - c.Y;
        double length = Math.Sqrt(ex * ex + ey * ey);
        if (length <= 1e-9) return null;
        double ux = ex / length, uy = ey / length;
        double fx = a.X - c.X, fy = a.Y - c.Y;
        // Along the eraser segment: 0 ≤ s ≤ length; across it: |h| ≤ r. Both are linear in t.
        double s0 = fx * ux + fy * uy, s1 = dx * ux + dy * uy;
        double h0 = fx * uy - fy * ux, h1 = dx * uy - dy * ux;
        if (Linear(s0, s1, 0, length) is not { } along || Linear(h0, h1, -r, r) is not { } across) return null;
        double lower = Math.Max(along.Item1, across.Item1), upper = Math.Min(along.Item2, across.Item2);
        return lower <= upper ? (lower, upper) : null;
    }

    static (double, double)? Linear(double v0, double v1, double low, double high)
    {
        if (Math.Abs(v1) < 1e-12) return v0 >= low && v0 <= high ? (-1e12, 1e12) : null;
        double t1 = (low - v0) / v1, t2 = (high - v0) / v1;
        return (Math.Min(t1, t2), Math.Max(t1, t2));
    }

    /// <summary>Distance from a point to the segment c→d.</summary>
    public static double Distance((double X, double Y) p, (double X, double Y) c, (double X, double Y) d)
    {
        double ex = d.X - c.X, ey = d.Y - c.Y;
        double lengthSquared = ex * ex + ey * ey;
        double t = lengthSquared > 0 ? Math.Clamp(((p.X - c.X) * ex + (p.Y - c.Y) * ey) / lengthSquared, 0, 1) : 0;
        return Hypot(p.X - (c.X + t * ex), p.Y - (c.Y + t * ey));
    }

    static double Hypot(double x, double y) => Math.Sqrt(x * x + y * y);

    static List<(double X, double Y)> Points(double[] flat)
    {
        var list = new List<(double X, double Y)>(flat.Length / 2);
        for (int i = 0; i + 1 < flat.Length; i += 2) list.Add((flat[i], flat[i + 1]));
        return list;
    }

    static double[] Flatten(List<(double X, double Y)> points) => points.SelectMany(p => new[] { p.X, p.Y }).ToArray();

    static (double L, double B, double R, double T) Bounds(List<(double X, double Y)> points) =>
        (points.Min(p => p.X), points.Min(p => p.Y), points.Max(p => p.X), points.Max(p => p.Y));
}
