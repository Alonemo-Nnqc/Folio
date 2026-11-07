using UglyToad.PdfPig.Fonts;

namespace Folio.Core.Translate.Pdf;

// Port of macos/.../FolioTranslate/PDF/ContentInterpreter.swift.

/// <summary>
/// Which content stream an operator belongs to: the page's own content (empty), or a form XObject reached through
/// Do operators at these indexes ([12] = the form drawn by op 12 of the page, [12, 3] = a form inside it).
/// </summary>
public sealed class StreamPath : IEquatable<StreamPath>
{
    public static readonly StreamPath Root = new([]);
    public IReadOnlyList<int> Indexes { get; }
    public StreamPath(IReadOnlyList<int> indexes) { Indexes = indexes; }
    public StreamPath Appending(int index) => new([.. Indexes, index]);
    public StreamPath? Parent => Indexes.Count == 0 ? null : new StreamPath(Indexes.Take(Indexes.Count - 1).ToList());
    public bool IsRoot => Indexes.Count == 0;
    public bool Equals(StreamPath? other) => other != null && Indexes.SequenceEqual(other.Indexes);
    public override bool Equals(object? obj) => Equals(obj as StreamPath);
    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var i in Indexes) h.Add(i);
        return h.ToHashCode();
    }
    public override string ToString() => "[" + string.Join(",", Indexes) + "]";
}

public readonly record struct OpLocation(StreamPath Stream, int Index);

/// <summary>One text-showing operator (Tj, TJ, ', ") and where it draws, in page space.</summary>
public sealed class TextRun
{
    public OpLocation Location;
    public Pt Origin, End;
    /// <summary>Em size in page space.</summary>
    public double FontSize;
    /// <summary>Baseline direction in radians (0 = left to right).</summary>
    public double Angle;
    public int RenderMode;
    /// <summary>Runs in the same chain are positioned relative to each other: removing one moves the later ones.</summary>
    public int Chain;
    public FontInfo Font = FontInfo.Unknown;
    public RGBColor Color;
    /// <summary>The glyphs it draws (indexes into the interpreter's glyphs).</summary>
    public int GlyphStart, GlyphEnd;

    public bool IsHorizontal => Math.Abs(Angle) < 0.02;
    public Rect Bounds
    {
        get
        {
            double minX = Math.Min(Origin.X, End.X), maxX = Math.Max(Origin.X, End.X);
            return new Rect(minX, Math.Min(Origin.Y, End.Y) - FontSize * 0.25, Math.Max(maxX - minX, 0.1), FontSize * 1.1);
        }
    }
    public Pt Midpoint => new((Origin.X + End.X) / 2, (Origin.Y + End.Y) / 2 + FontSize * 0.3);
}

/// <summary>One glyph drawn by a text operator: its code, font and the exact matrix it was drawn with.</summary>
public sealed class Glyph
{
    public int Run;
    public int Code;
    public int Length;
    public int Font;
    /// <summary>Glyph space (one unit = the font size) to page space: 1 Tf and this as Tm draw the glyph again.</summary>
    public Affine Matrix;
    /// <summary>Advance width in glyph space units.</summary>
    public double Width;
    /// <summary>Em size in page space.</summary>
    public double Size;
    public string? Text;
    public bool Reliable;
    public int RenderMode;
    public RGBColor Color;
    public int Element;
    public int Offset;
    public double? Adjustment;
    /// <summary>Glyphs of TeX's extension fonts hang from their origin: how far below it they reach, in ems.</summary>
    public double? Depth;
    public bool IsClipped;

    public Pt Origin => Pt.Zero.Applying(Matrix);
    public Pt End => new Pt(Width, 0).Applying(Matrix);
    public double Angle => Math.Atan2(Matrix.B, Matrix.A);
    public bool IsHorizontal => Math.Abs(Angle) < 0.02 && Matrix.A > 0;
    public bool IsVisible => RenderMode != 3 && RenderMode != 7 && !IsClipped;

    /// <summary>The em box on the baseline (hanging glyphs: from their depth to just above the origin).</summary>
    public Rect Box
    {
        get
        {
            double bottom = Depth is { } d ? -d : -0.22, top = Depth == null ? 0.98 : 0.04;
            double w = Math.Max(Width, 0.02);
            double em = Size / Math.Max(Math.Sqrt(Matrix.C * Matrix.C + Matrix.D * Matrix.D), 1e-9);
            return Rect.Bounds(new[] { new Pt(0, bottom * em), new Pt(w, bottom * em), new Pt(0, top * em), new Pt(w, top * em) }.Select(p => p.Applying(Matrix)));
        }
    }
}

/// <summary>Something painted that is not text.</summary>
public sealed class GraphicMark
{
    public enum MarkKind { Image, Fill, Stroke, Shading }
    public MarkKind Kind;
    public Rect Rect;
    public bool IsWhite;
    public OpLocation Location;
    public bool HasCurves;
    public int SegmentCount;
    /// <summary>The operators that built and painted it (path construction … paint), in Location.Stream.</summary>
    public int OpStart, OpEnd;
    public RGBColor Color = RGBColor.Black;
    public double LineWidth;
}

/// <summary>A content stream the interpreter visited.</summary>
public sealed class InterpretedStream
{
    public byte[] Source = [];
    public List<ContentOp> Ops = [];
    /// <summary>The form's stream (null for the page).</summary>
    public PStream? Form;
    public PDict? Resources;
}

/// <summary>
/// Runs a page's content streams through the graphics and text state machine (PDF 32000-1 §8–9) without rendering,
/// collecting where each text operator draws and the bounds of images and paths.
/// </summary>
public sealed class ContentInterpreter
{
    public List<TextRun> Runs { get; } = [];
    public List<Glyph> Glyphs { get; } = [];
    public List<GraphicMark> Marks { get; } = [];
    public Dictionary<StreamPath, InterpretedStream> Streams { get; } = [];
    public List<FontMetrics> Fonts { get; } = [];
    /// <summary>The image XObject of each image mark drawn with Do, and the matrix it was drawn with.</summary>
    public Dictionary<int, (PStream Stream, Affine Matrix)> Images { get; } = [];
    /// <summary>Small filled shapes: the matrix their path was drawn with.</summary>
    public Dictionary<int, Affine> Paths { get; } = [];
    readonly Dictionary<long, int> _fontCache = [];
    int _chainCounter;

    sealed class GState
    {
        public Affine Ctm;
        public Rect? Clip;
        public bool FillWhite;
        public double CharSpacing, WordSpacing, HScale = 1, Leading;
        public int? Font;
        public double FontSize;
        public RGBColor FillColor = RGBColor.Black, StrokeColor = RGBColor.Black;
        public double LineWidth = 1, Rise;
        public int Render;
        public GState Copy() => (GState)MemberwiseClone();
    }

    /// <summary>Interprets the page. pageTransform maps the page's user space to the space positions are reported in.</summary>
    public void Run(PDict page, Affine? pageTransform = null)
    {
        var source = page.Contents();
        var ops = ContentLexer.Parse(source);
        var resources = page.Resources;
        Streams[StreamPath.Root] = new InterpretedStream { Source = source, Ops = ops, Resources = resources };
        var state = new GState { Ctm = pageTransform ?? Affine.Identity };
        Interpret(ops, StreamPath.Root, resources, state, 0);
    }

    public static readonly HashSet<string> PathConstruction = ["m", "l", "c", "v", "y", "re", "h"];

    void Interpret(List<ContentOp> ops, StreamPath path, PDict? resources, GState initial, int depth)
    {
        var gs = initial.Copy();
        var stack = new Stack<GState>();
        var tm = Affine.Identity;
        var tlm = Affine.Identity;
        var pathPoints = new List<Pt>();
        bool pathCurves = false, pendingClip = false;
        int pathSegments = 0;
        int? pathStart = null;

        void NewChain() => _chainCounter++;
        void AddPoint(double x, double y) => pathPoints.Add(new Pt(x, y).Applying(gs.Ctm));

        void Paint(GraphicMark.MarkKind? kind, int index)
        {
            int start = pathStart ?? index;
            try
            {
                if (pathPoints.Count == 0) return;
                var rect = Rect.Bounds(pathPoints);
                if (pendingClip) gs.Clip = gs.Clip is { } c ? c.Intersection(rect) : rect;
                if (kind == null) return;
                if (gs.Clip is { } clip)
                {
                    var clipped = rect.InsetBy(-0.01, -0.01).Intersection(clip);
                    if (clipped.IsNull) return;
                    rect = clipped;
                }
                double scale = Math.Sqrt(Math.Abs(gs.Ctm.A * gs.Ctm.D - gs.Ctm.B * gs.Ctm.C));
                if (kind == GraphicMark.MarkKind.Fill && rect.W < 40 && rect.H < 40) Paths[Marks.Count] = gs.Ctm;
                Marks.Add(new GraphicMark
                {
                    Kind = kind.Value, Rect = rect, IsWhite = kind == GraphicMark.MarkKind.Fill && gs.FillWhite,
                    Location = new OpLocation(path, index), HasCurves = pathCurves, SegmentCount = pathSegments, OpStart = start, OpEnd = index,
                    Color = kind == GraphicMark.MarkKind.Stroke ? gs.StrokeColor : gs.FillColor,
                    LineWidth = kind == GraphicMark.MarkKind.Stroke ? Math.Max(gs.LineWidth, 0) * scale : 0,
                });
            }
            finally
            {
                pathPoints = [];
                pathCurves = false;
                pathSegments = 0;
                pathStart = null;
                pendingClip = false;
            }
        }

        static RGBColor ColorOf(List<ContentOperand> operands)
        {
            var n = operands.Select(o => o.AsNumber).Where(x => x != null).Select(x => x!.Value).ToList();
            return n.Count switch
            {
                1 => new RGBColor(n[0], n[0], n[0]),
                3 => new RGBColor(n[0], n[1], n[2]),
                4 => new RGBColor((1 - n[0]) * (1 - n[3]), (1 - n[1]) * (1 - n[3]), (1 - n[2]) * (1 - n[3])),
                _ => RGBColor.Black,
            };
        }

        void SetFillColor(List<ContentOperand> operands)
        {
            gs.FillColor = ColorOf(operands);
            bool any = operands.Any(o => o.AsNumber != null);
            gs.FillWhite = any && gs.FillColor.R >= 0.99 && gs.FillColor.G >= 0.99 && gs.FillColor.B >= 0.99;
        }

        void Show(int index, List<ContentOperand> elements)
        {
            var trm = tm.Concatenating(gs.Ctm);
            var origin = new Pt(0, gs.Rise).Applying(trm);
            var metrics = gs.Font is { } fi ? Fonts[fi] : null;
            double fs = gs.FontSize, th = gs.HScale;
            int runIndex = Runs.Count;
            int first = Glyphs.Count;
            var glyphToText = new Affine(fs * th, 0, 0, fs, 0, gs.Rise);
            double emScale = metrics?.EmScale ?? 1;
            double tx = 0;
            for (int e = 0; e < elements.Count; e++)
            {
                switch (elements[e])
                {
                    case ContentOperand.Str s:
                        int offset = 0;
                        var codes = metrics?.Encoding.Codes(s.Value) ?? s.Value.Select(b => ((int)b, 1)).ToList();
                        foreach (var (code, length) in codes)
                        {
                            double w0 = metrics?.Width(code) ?? 0.5;
                            double space = length == 1 && code == 32 ? gs.WordSpacing : 0;
                            double displacement = (w0 * fs + gs.CharSpacing + space) * th;
                            var matrix = glyphToText.Concatenating(Affine.Translation(tx, 0)).Concatenating(trm);
                            double up = Math.Sqrt(matrix.C * matrix.C + matrix.D * matrix.D) * emScale;
                            var decoded = metrics?.Encoding.Text(code);
                            var glyph = new Glyph
                            {
                                Run = runIndex, Code = code, Length = length, Font = gs.Font ?? -1, Matrix = matrix, Width = w0, Size = up,
                                Text = decoded?.Text, Reliable = decoded?.Reliable ?? false, RenderMode = gs.Render,
                                Color = gs.Render == 1 ? gs.StrokeColor : gs.FillColor, Element = e, Offset = offset,
                                Adjustment = fs * th != 0 ? -displacement / (fs * th) * 1000 : null, Depth = metrics?.HangingDepth(code),
                            };
                            if (gs.Clip is { } clip)
                            {
                                var middle = new Pt(w0 / 2, 0.3).Applying(matrix);
                                glyph.IsClipped = !clip.InsetBy(-1, -1).Contains(middle);
                            }
                            Glyphs.Add(glyph);
                            tx += displacement;
                            offset += length;
                        }
                        break;
                    case ContentOperand.Number adjust:
                        tx -= adjust.Value / 1000 * fs * th;
                        break;
                }
            }
            var end = new Pt(tx, gs.Rise).Applying(trm);
            var linear = trm with { Tx = 0, Ty = 0 };
            var upVector = new Pt(0, fs * emScale).Applying(linear);
            var right = new Pt(1, 0).Applying(linear);
            Runs.Add(new TextRun
            {
                Location = new OpLocation(path, index), Origin = origin, End = end, FontSize = Math.Sqrt(upVector.X * upVector.X + upVector.Y * upVector.Y),
                Angle = Math.Atan2(right.Y, right.X), RenderMode = gs.Render, Chain = _chainCounter, Font = metrics?.Info ?? FontInfo.Unknown,
                Color = gs.FillColor, GlyphStart = first, GlyphEnd = Glyphs.Count,
            });
            tm = Affine.Translation(tx, 0).Concatenating(tm);
        }

        void NextLine()
        {
            tlm = Affine.Translation(0, -gs.Leading).Concatenating(tlm);
            tm = tlm;
            NewChain();
        }

        for (int index = 0; index < ops.Count; index++)
        {
            var op = ops[index];
            var o = op.Operands;
            double Num(int i) => i < o.Count ? o[i].AsNumber ?? 0 : 0;
            if (pathStart == null && PathConstruction.Contains(op.Name)) pathStart = index;
            switch (op.Name)
            {
                case "q": stack.Push(gs.Copy()); break;
                case "Q": if (stack.Count > 0) gs = stack.Pop(); break;
                case "cm": gs.Ctm = new Affine(Num(0), Num(1), Num(2), Num(3), Num(4), Num(5)).Concatenating(gs.Ctm); break;
                case "g" or "rg" or "k" or "sc" or "scn": SetFillColor(o); break;
                case "G" or "RG" or "K" or "SC" or "SCN": gs.StrokeColor = ColorOf(o); break;
                case "cs": gs.FillWhite = false; gs.FillColor = RGBColor.Black; break;
                case "CS": gs.StrokeColor = RGBColor.Black; break;
                case "w": gs.LineWidth = Num(0); break;
                case "m": AddPoint(Num(0), Num(1)); break;
                case "l": AddPoint(Num(0), Num(1)); pathSegments++; break;
                case "c": AddPoint(Num(0), Num(1)); AddPoint(Num(2), Num(3)); AddPoint(Num(4), Num(5)); pathCurves = true; pathSegments++; break;
                case "v" or "y": AddPoint(Num(0), Num(1)); AddPoint(Num(2), Num(3)); pathCurves = true; pathSegments++; break;
                case "re":
                    double x = Num(0), y = Num(1), w = Num(2), h = Num(3);
                    AddPoint(x, y); AddPoint(x + w, y); AddPoint(x + w, y + h); AddPoint(x, y + h);
                    pathSegments += 4;
                    break;
                case "h": break;
                case "W" or "W*": pendingClip = true; break;
                case "S" or "s": Paint(GraphicMark.MarkKind.Stroke, index); break;
                case "f" or "F" or "f*" or "B" or "B*" or "b" or "b*": Paint(GraphicMark.MarkKind.Fill, index); break;
                case "n": Paint(null, index); break;
                case "sh":
                    if (gs.Clip is { } shClip)
                        Marks.Add(new GraphicMark { Kind = GraphicMark.MarkKind.Shading, Rect = shClip, Location = new OpLocation(path, index), OpStart = index, OpEnd = index });
                    break;
                case "Do":
                    if (o.FirstOrDefault()?.AsName is not { } xname || resources?.Dict("XObject")?.Stream(xname) is not { } stream) break;
                    var subtype = stream.Dict.Name("Subtype");
                    if (subtype == "Image") AddImageMark(gs.Ctm, gs.Clip, new OpLocation(path, index), stream);
                    else if (subtype == "Form" && depth < 12)
                    {
                        var formPath = path.Appending(index);
                        var formSource = stream.Data;
                        var formOps = ContentLexer.Parse(formSource);
                        var formResources = stream.Dict.Dict("Resources") ?? resources;
                        Streams[formPath] = new InterpretedStream { Source = formSource, Ops = formOps, Form = stream, Resources = formResources };
                        var inner = gs.Copy();
                        if (stream.Dict.Matrix("Matrix") is { } matrix) inner.Ctm = matrix.Concatenating(gs.Ctm);
                        if (stream.Dict.Rect("BBox") is { } bbox)
                        {
                            var box = bbox.Applying(inner.Ctm);
                            inner.Clip = inner.Clip is { } ic ? ic.Intersection(box) : box;
                        }
                        NewChain();
                        Interpret(formOps, formPath, formResources, inner, depth + 1);
                        NewChain();
                    }
                    break;
                case "BI": AddImageMark(gs.Ctm, gs.Clip, new OpLocation(path, index), null); break;
                case "BT": tm = Affine.Identity; tlm = Affine.Identity; NewChain(); break;
                case "ET": NewChain(); break;
                case "Tc": gs.CharSpacing = Num(0); break;
                case "Tw": gs.WordSpacing = Num(0); break;
                case "Tz": gs.HScale = Num(0) / 100; break;
                case "TL": gs.Leading = Num(0); break;
                case "Ts": gs.Rise = Num(0); break;
                case "Tr": gs.Render = (int)Num(0); break;
                case "Tf":
                    gs.FontSize = Num(1);
                    gs.Font = o.FirstOrDefault()?.AsName is { } fname ? FontNamed(fname, resources) : null;
                    break;
                case "Td":
                    tlm = Affine.Translation(Num(0), Num(1)).Concatenating(tlm); tm = tlm; NewChain();
                    break;
                case "TD":
                    gs.Leading = -Num(1);
                    tlm = Affine.Translation(Num(0), Num(1)).Concatenating(tlm); tm = tlm; NewChain();
                    break;
                case "Tm":
                    tlm = new Affine(Num(0), Num(1), Num(2), Num(3), Num(4), Num(5)); tm = tlm; NewChain();
                    break;
                case "T*": NextLine(); break;
                case "Tj": if (o.Count > 0) Show(index, [o[0]]); break;
                case "'": NextLine(); if (o.Count > 0) Show(index, [o[^1]]); break;
                case "\"":
                    gs.WordSpacing = Num(0); gs.CharSpacing = Num(1);
                    NextLine();
                    if (o.Count > 0) Show(index, [o[^1]]);
                    break;
                case "TJ": if (o.FirstOrDefault() is ContentOperand.Array elements) Show(index, elements.Items); break;
            }
        }
    }

    void AddImageMark(Affine ctm, Rect? clip, OpLocation location, PStream? stream)
    {
        var rect = new Rect(0, 0, 1, 1).Applying(ctm);
        if (clip is { } c) rect = rect.Intersection(c);
        if (rect.IsNull || rect.W <= 0.5 || rect.H <= 0.5) return;
        if (stream != null) Images[Marks.Count] = (stream, ctm);
        Marks.Add(new GraphicMark { Kind = GraphicMark.MarkKind.Image, Rect = rect, Location = location, OpStart = location.Index, OpEnd = location.Index });
    }

    int? FontNamed(string name, PDict? resources)
    {
        if (resources?.Dict("Font")?.Dict(name) is not { } dict) return null;
        var key = dict.Key;
        if (_fontCache.TryGetValue(key, out var cached)) return cached;
        Fonts.Add(new FontMetrics(dict));
        _fontCache[key] = Fonts.Count - 1;
        return Fonts.Count - 1;
    }

    public static Rect Bounds(IEnumerable<Pt> points) => Rect.Bounds(points);
}

/// <summary>What a font needs for following its glyphs: how strings split into codes, advance widths and text.</summary>
public sealed class FontMetrics
{
    public PDict Dict { get; }
    public FontInfo Info { get; }
    public FontEncoding Encoding { get; }
    /// <summary>Type 3 fonts: the em of glyph space in text space units; 1 for others.</summary>
    public double EmScale { get; }
    public bool Hanging { get; }
    readonly bool _hangingRadical;
    readonly double _descent;
    readonly Dictionary<int, double> _widths = [];
    readonly double _defaultWidth;

    public FontMetrics(PDict dict)
    {
        Dict = dict;
        var subtype = dict.Name("Subtype");
        Info = new FontInfo(dict);
        Encoding = new FontEncoding(dict);
        var descriptor = dict.Dict("FontDescriptor");
        var ascent = descriptor?.Number("Ascent");
        var fontDescent = descriptor?.Number("Descent");
        var bboxBottom = descriptor?.Rect("FontBBox")?.MinY;
        bool simpleType1 = subtype is "Type1" or "MMType1";
        var fontName = Info.Name.ToLowerInvariant();
        bool extensionFont = new[] { "cmex", "lmex", "txex", "pxex", "blex", "mtex", "esint", "eurmex", "fourier-ex" }.Any(fontName.Contains);
        Hanging = simpleType1 && (extensionFont || ((ascent is { } a && a <= 150) && (bboxBottom is { } b && b <= -1000)));
        _hangingRadical = simpleType1 && new[] { "cmsy", "cmbsy", "lmsy", "txsy", "pxsy", "mtsy", "rmsy", "bmsy" }.Any(fontName.Contains);
        _descent = Math.Min(Math.Max(-(fontDescent ?? -600) / 1000, 0.3), 1.5);
        double em = 1;
        if (subtype == "Type0")
        {
            double dw = 1000;
            if (dict.Array("DescendantFonts")?.Dict(0) is { } cid)
            {
                dw = cid.Number("DW") ?? 1000;
                if (cid.Array("W") is { } w) _widths = CidWidths(w);
            }
            _defaultWidth = dw / 1000;
        }
        else
        {
            double scale = 1.0 / 1000;
            if (subtype == "Type3" && dict.Array("FontMatrix") is { } fm) scale = fm.Numbers().FirstOrDefault(scale);
            int first = (int)(dict.Number("FirstChar") ?? 0);
            if (dict.Array("Widths") is { } widths)
            {
                var values = widths.Numbers();
                for (int i = 0; i < values.Count; i++) _widths[first + i] = values[i] * scale;
            }
            if (_widths.Count == 0 && subtype != "Type3") _widths = SystemWidths(dict, Encoding);
            double missing = 0.5;
            if (descriptor?.Number("MissingWidth") is { } mw && mw > 0) missing = mw * scale;
            else if (_widths.Count > 0)
            {
                var nonZero = _widths.Values.Where(v => v > 0).ToList();
                if (nonZero.Count > 0) missing = nonZero.Average();
            }
            _defaultWidth = missing;
            if (subtype == "Type3")
            {
                var advances = _widths.Values.Where(v => v > 0).OrderBy(v => v).ToList();
                if (advances.Count > 0)
                {
                    double estimate = advances[advances.Count / 2] * 2;
                    if (estimate is < 0.5 or > 2) em = estimate;
                }
            }
        }
        EmScale = em;
    }

    /// <summary>Advance of a code in glyph space units (1 = the font size).</summary>
    public double Width(int code) => _widths.TryGetValue(Encoding.Cid(code), out var w) ? w : _defaultWidth;

    /// <summary>How far below its origin a glyph of a hanging font reaches, in ems.</summary>
    public double? HangingDepth(int code)
    {
        if (_hangingRadical && (Encoding.Names.GetValueOrDefault(code) == "radical" || Encoding.Text(code)?.Text == "√")) return 0.96;
        if (!Hanging) return null;
        var name = Encoding.Names.GetValueOrDefault(code) ?? "";
        if (name.StartsWith("hatwide") || name.StartsWith("tildewide") || name.StartsWith("circumflex") || name.StartsWith("tilde")) return null;
        foreach (var (suffix, depth) in new[] { ("Bigg", 2.96), ("bigg", 2.36), ("Big", 1.76), ("big", 1.16) })
            if (name.EndsWith(suffix, StringComparison.Ordinal)) return depth;
        bool integral = name.StartsWith("integral") || name.StartsWith("contintegral") || name.StartsWith("contourintegral");
        if (name.EndsWith("display", StringComparison.Ordinal)) return integral ? 2.22 : 1.4;
        if (name.EndsWith("text", StringComparison.Ordinal)) return integral ? 1.11 : 1.0;
        return _descent;
    }

    static Dictionary<int, double> CidWidths(PArray array)
    {
        var result = new Dictionary<int, double>();
        int i = 0;
        while (i < array.Count)
        {
            if (array.Number(i) is not { } first) break;
            if (array.Array(i + 1) is { } list)
            {
                var values = list.Numbers();
                for (int offset = 0; offset < values.Count; offset++) result[(int)first + offset] = values[offset] / 1000;
                i += 2;
            }
            else if (array.Number(i + 1) is { } last && array.Number(i + 2) is { } w)
            {
                if (last - first <= 65535 && last >= first)
                    for (int c = (int)first; c <= (int)last; c++) result[c] = w / 1000;
                i += 3;
            }
            else break;
        }
        return result;
    }

    /// <summary>Fonts without Widths (the standard 14, not embedded): the standard metrics of that font.</summary>
    static Dictionary<int, double> SystemWidths(PDict dict, FontEncoding encoding)
    {
        var name = dict.Name("BaseFont") ?? "Times-Roman";
        int plus = name.IndexOf('+');
        if (plus >= 0) name = name[(plus + 1)..];
        if (name.StartsWith("courier", StringComparison.OrdinalIgnoreCase)) return Enumerable.Range(0, 256).ToDictionary(c => c, _ => 0.6);
        var metrics = Standard14Metrics.For(name);
        var result = new Dictionary<int, double>();
        if (metrics == null) return result;
        for (int code = 32; code <= 255; code++)
        {
            if (encoding.Text(code)?.Text is not { Length: 1 } text) continue;
            if (metrics.TryGetValue(text[0], out var w)) result[code] = w / 1000;
        }
        return result;
    }
}

/// <summary>Advance widths of the standard 14 fonts (Times, Helvetica …) by character, from PdfPig's AFM data.</summary>
static class Standard14Metrics
{
    static readonly Dictionary<string, Dictionary<char, double>?> Cache = [];

    public static Dictionary<char, double>? For(string baseFont)
    {
        lock (Cache)
        {
            if (Cache.TryGetValue(baseFont, out var cached)) return cached;
            Dictionary<char, double>? result = null;
            try
            {
                var standard = baseFont.Replace(",", "-") switch
                {
                    var n when n.StartsWith("Arial", StringComparison.OrdinalIgnoreCase) => n.Contains("Bold") ? "Helvetica-Bold" : "Helvetica",
                    var n when n.StartsWith("TimesNewRoman", StringComparison.OrdinalIgnoreCase) => n.Contains("Bold") ? "Times-Bold" : n.Contains("Italic") ? "Times-Italic" : "Times-Roman",
                    var n => n,
                };
                var afm = UglyToad.PdfPig.Fonts.Standard14Fonts.Standard14.GetAdobeFontMetrics(standard);
                if (afm != null)
                {
                    result = [];
                    foreach (var (glyphName, metric) in afm.CharacterMetrics)
                        if (GlyphNames.Unicode(glyphName) is { Length: 1 } ch) result[ch[0]] = metric.Width.X;
                }
            }
            catch { }
            return Cache[baseFont] = result;
        }
    }
}

/// <summary>What the layout needs to know about a font: its name and style.</summary>
public sealed record FontInfo(string Name, bool IsBold, bool IsItalic, bool IsMonospace, bool IsSerif, bool IsSymbolic)
{
    public static readonly FontInfo Unknown = new("", false, false, false, true, false);

    public FontInfo(PDict dict) : this("", false, false, false, true, false)
    {
        var @base = dict.Name("BaseFont") ?? "";
        var descriptor = dict.Dict("FontDescriptor");
        if (dict.Name("Subtype") == "Type0" && dict.Array("DescendantFonts")?.Dict(0) is { } cid)
        {
            descriptor = cid.Dict("FontDescriptor") ?? descriptor;
            if (@base.Length == 0) @base = cid.Name("BaseFont") ?? "";
        }
        int plus = @base.IndexOf('+');
        if (plus == 6) @base = @base[(plus + 1)..];
        int flags = (int)(descriptor?.Number("Flags") ?? 0);
        double weight = descriptor?.Number("FontWeight") ?? 0;
        var lower = @base.ToLowerInvariant();
        Name = @base;
        IsMonospace = (flags & 1) != 0 || new[] { "mono", "courier", "cmtt", "consol", "menlo", "inconsolata", "lmtt", "sfmono", "typewriter" }.Any(lower.Contains);
        string[] sans = ["sans", "helvetica", "arial", "gothic", "frutiger", "myriad", "calibri", "segoe", "roboto", "opensans",
                         "lato", "verdana", "tahoma", "futura", "avenir", "gill", "univers", "pingfang", "heiti", "hei", "cmss", "lmss"];
        IsSerif = !sans.Any(lower.Contains) || ((flags & 2) != 0 && !lower.Contains("sans"));
        IsSymbolic = (flags & 4) != 0 && (flags & 32) == 0;
        IsItalic = (flags & 64) != 0 || new[] { "italic", "ital", "oblique", "-it", "cmti", "cmmi", "slanted", "-sl", "kursiv" }.Any(lower.Contains);
        double stem = descriptor?.Number("StemV") ?? 0;
        IsBold = (flags & 262144) != 0 || weight >= 600 || (stem >= 130 && !IsMonospace)
                 || new[] { "bold", "black", "heavy", "semibold", "cmbx", "-bd", "demi", "medi", "sfbx", "sfsx", "cmssbx", "ptmb", "phvb", "pplb" }.Any(lower.Contains);
    }
}
