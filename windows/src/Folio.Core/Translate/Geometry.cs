namespace Folio.Core.Translate;

// CoreGraphics' geometry with the same semantics, so the engine ported from macOS computes the same numbers.

public readonly record struct Pt(double X, double Y)
{
    public static readonly Pt Zero = new(0, 0);
    public Pt Applying(in Affine t) => new(t.A * X + t.C * Y + t.Tx, t.B * X + t.D * Y + t.Ty);
    public static double Distance(Pt a, Pt b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));
}

public readonly record struct Size2(double Width, double Height);

/// <summary>CGAffineTransform: [a b 0; c d 0; tx ty 1], points as row vectors.</summary>
public readonly record struct Affine(double A, double B, double C, double D, double Tx, double Ty)
{
    public static readonly Affine Identity = new(1, 0, 0, 1, 0, 0);
    public static Affine Translation(double x, double y) => new(1, 0, 0, 1, x, y);
    public static Affine Scale(double x, double y) => new(x, 0, 0, y, 0, 0);
    public static Affine Rotation(double angle) => new(Math.Cos(angle), Math.Sin(angle), -Math.Sin(angle), Math.Cos(angle), 0, 0);

    /// <summary>this, then t2 (CGAffineTransformConcat(self, t2)).</summary>
    public Affine Concatenating(in Affine t2) => new(
        A * t2.A + B * t2.C, A * t2.B + B * t2.D,
        C * t2.A + D * t2.C, C * t2.B + D * t2.D,
        Tx * t2.A + Ty * t2.C + t2.Tx, Tx * t2.B + Ty * t2.D + t2.Ty);

    public Affine Inverted()
    {
        double det = A * D - B * C;
        if (Math.Abs(det) < 1e-300) return this;
        double ia = D / det, ib = -B / det, ic = -C / det, id = A / det;
        return new Affine(ia, ib, ic, id, -(Tx * ia + Ty * ic), -(Tx * ib + Ty * id));
    }

    public Affine Translated(double x, double y) => Translation(x, y).Concatenating(this);
    public Affine Scaled(double x, double y) => Scale(x, y).Concatenating(this);
    public bool IsIdentity => this == Identity;
}

/// <summary>CGRect, including the null rectangle (result of an empty intersection).</summary>
public readonly record struct Rect(double X, double Y, double Width, double Height)
{
    public static readonly Rect Null = new(double.PositiveInfinity, double.PositiveInfinity, 0, 0);
    public static readonly Rect ZeroRect = new(0, 0, 0, 0);

    public bool IsNull => double.IsPositiveInfinity(X) || double.IsPositiveInfinity(Y);
    public bool IsEmpty => IsNull || Width == 0 || Height == 0;
    public bool IsInfinite => double.IsInfinity(Width) || double.IsInfinity(Height);

    Rect Standardized => Width >= 0 && Height >= 0 ? this : new Rect(Math.Min(X, X + Width), Math.Min(Y, Y + Height), Math.Abs(Width), Math.Abs(Height));
    public double MinX => Standardized.X;
    public double MinY => Standardized.Y;
    public double MaxX => Standardized.X + Standardized.Width;
    public double MaxY => Standardized.Y + Standardized.Height;
    public double MidX => (MinX + MaxX) / 2;
    public double MidY => (MinY + MaxY) / 2;
    public Pt Center => new(MidX, MidY);
    public double W => Math.Abs(Width);
    public double H => Math.Abs(Height);

    public static Rect FromCorners(double minX, double minY, double maxX, double maxY) => new(minX, minY, maxX - minX, maxY - minY);

    public Rect Intersection(Rect r)
    {
        if (IsNull || r.IsNull) return Null;
        double x1 = Math.Max(MinX, r.MinX), y1 = Math.Max(MinY, r.MinY);
        double x2 = Math.Min(MaxX, r.MaxX), y2 = Math.Min(MaxY, r.MaxY);
        if (x2 < x1 || y2 < y1) return Null;
        return new Rect(x1, y1, x2 - x1, y2 - y1);
    }

    public Rect Union(Rect r)
    {
        if (IsNull) return r;
        if (r.IsNull) return this;
        return FromCorners(Math.Min(MinX, r.MinX), Math.Min(MinY, r.MinY), Math.Max(MaxX, r.MaxX), Math.Max(MaxY, r.MaxY));
    }

    public bool Intersects(Rect r)
    {
        if (IsNull || r.IsNull) return false;
        var i = Intersection(r);
        return !i.IsNull && !(i.Width == 0 && i.Height == 0 && (W > 0 || r.W > 0) && false) && !i.IsNull;
    }

    public Rect InsetBy(double dx, double dy)
    {
        if (IsNull) return Null;
        var s = Standardized;
        var r = new Rect(s.X + dx, s.Y + dy, s.Width - 2 * dx, s.Height - 2 * dy);
        return r.Width < 0 || r.Height < 0 ? Null : r;
    }

    public Rect Offset(double dx, double dy) => IsNull ? Null : new Rect(MinX + dx, MinY + dy, W, H);

    public bool Contains(Pt p) => !IsNull && p.X >= MinX && p.X < MaxX && p.Y >= MinY && p.Y < MaxY;

    public bool Contains(Rect r) => !IsNull && !r.IsNull && r.MinX >= MinX && r.MaxX <= MaxX && r.MinY >= MinY && r.MaxY <= MaxY;

    /// <summary>The bounding box of the transformed rectangle (CGRectApplyAffineTransform).</summary>
    public Rect Applying(in Affine t)
    {
        if (IsNull) return Null;
        var p1 = new Pt(MinX, MinY).Applying(t);
        var p2 = new Pt(MaxX, MinY).Applying(t);
        var p3 = new Pt(MinX, MaxY).Applying(t);
        var p4 = new Pt(MaxX, MaxY).Applying(t);
        double minX = Math.Min(Math.Min(p1.X, p2.X), Math.Min(p3.X, p4.X)), maxX = Math.Max(Math.Max(p1.X, p2.X), Math.Max(p3.X, p4.X));
        double minY = Math.Min(Math.Min(p1.Y, p2.Y), Math.Min(p3.Y, p4.Y)), maxY = Math.Max(Math.Max(p1.Y, p2.Y), Math.Max(p3.Y, p4.Y));
        return FromCorners(minX, minY, maxX, maxY);
    }

    public static Rect Bounds(IEnumerable<Pt> points)
    {
        double minX = double.PositiveInfinity, minY = double.PositiveInfinity, maxX = double.NegativeInfinity, maxY = double.NegativeInfinity;
        foreach (var p in points)
        {
            minX = Math.Min(minX, p.X); maxX = Math.Max(maxX, p.X);
            minY = Math.Min(minY, p.Y); maxY = Math.Max(maxY, p.Y);
        }
        return new Rect(minX, minY, maxX - minX, maxY - minY);
    }
}

public readonly record struct RGBColor(double R, double G, double B)
{
    public static readonly RGBColor Black = new(0, 0, 0);
}
