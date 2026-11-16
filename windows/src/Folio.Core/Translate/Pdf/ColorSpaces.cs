using UglyToad.PdfPig.Tokens;

namespace Folio.Core.Translate.Pdf;

/// <summary>
/// A colour space as far as the engine needs one: to know what colour the numbers a page paints with show
/// (PDF 32000-1 §8.6). <c>1 scn</c> is black in a Separation "Black" space and white in a gray one; reading every colour
/// as gray, RGB or CMYK by its number of components drew translations in white. The same as the macOS engine.
/// </summary>
public abstract record PdfColorSpace
{
    public sealed record Gray : PdfColorSpace;
    public sealed record Rgb : PdfColorSpace;
    public sealed record Cmyk : PdfColorSpace;
    public sealed record Lab : PdfColorSpace;
    public sealed record Indexed(PdfColorSpace Base, int High, byte[] Table) : PdfColorSpace;
    /// <summary>Separation and DeviceN: tints, through the space's function, into its alternate space.</summary>
    public sealed record Tint(string[] Names, PdfColorSpace Alternate, PdfFunction? Function) : PdfColorSpace;
    /// <summary>Coloured patterns carry no numbers; uncoloured ones paint with their base space's.</summary>
    public sealed record Pattern(PdfColorSpace? Base) : PdfColorSpace;

    public static readonly PdfColorSpace DeviceGray = new Gray(), DeviceRgb = new Rgb(), DeviceCmyk = new Cmyk();

    public int Components => this switch
    {
        Gray or Indexed => 1,
        Rgb or Lab => 3,
        Cmyk => 4,
        Tint t => Math.Max(t.Names.Length, 1),
        Pattern p => p.Base?.Components ?? 0,
        _ => 1,
    };

    /// <summary>The colour a space starts with when it is chosen (cs).</summary>
    public double[] Initial => this switch
    {
        Gray or Indexed => [0],
        Rgb or Lab => [0, 0, 0],
        Cmyk => [0, 0, 0, 1],
        Tint t => Enumerable.Repeat(1.0, Math.Max(t.Names.Length, 1)).ToArray(),
        _ => [],
    };

    static double Clamp(double v) => Math.Min(Math.Max(v, 0), 1);

    /// <summary>The colour the numbers show, in RGB.</summary>
    public RGBColor ToRgb(IReadOnlyList<double> n)
    {
        double At(int i, double fallback = 0) => i < n.Count ? n[i] : fallback;
        switch (this)
        {
            case Gray:
                { var v = Clamp(At(0)); return new RGBColor(v, v, v); }
            case Rgb:
                return new RGBColor(Clamp(At(0)), Clamp(At(1)), Clamp(At(2)));
            case Cmyk:
                {
                    double c = Clamp(At(0)), m = Clamp(At(1)), y = Clamp(At(2)), k = Clamp(At(3, 1));
                    return new RGBColor((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k));
                }
            case Lab:
                return LabToRgb(At(0), At(1), At(2));
            case Indexed ix:
                {
                    int index = Math.Min(Math.Max((int)Math.Round(At(0)), 0), ix.High);
                    int count = ix.Base.Components;
                    if (count <= 0 || (index + 1) * count > ix.Table.Length) return RGBColor.Black;
                    var values = Enumerable.Range(0, count).Select(k => ix.Table[index * count + k] / 255.0).ToArray();
                    if (ix.Base is Lab) return ix.Base.ToRgb([values[0] * 100, values[1] * 255 - 128, values[2] * 255 - 128]);
                    return ix.Base.ToRgb(values);
                }
            case Tint t:
                {
                    var tints = n.Count == 0 ? Initial : n.ToArray();
                    if (t.Names.Length == 1 && t.Names[0] == "None") return new RGBColor(1, 1, 1);
                    if (t.Function is { } f)
                    {
                        var output = f.Evaluate(tints);
                        if (t.Alternate.Components > 0 && output.Length >= t.Alternate.Components) return t.Alternate.ToRgb(output);
                    }
                    // No function to follow: the more ink, the darker (right for Black and All, close enough for a spot colour).
                    double ink = Clamp(tints.Length > 0 ? tints.Max() : 1);
                    return new RGBColor(1 - ink, 1 - ink, 1 - ink);
                }
            case Pattern p:
                return p.Base is { } b && n.Count > 0 ? b.ToRgb(n) : RGBColor.Black;
            default:
                return RGBColor.Black;
        }
    }

    /// <summary>The space a cs operand names: a device space, or one in the resources' ColorSpace dictionary.</summary>
    public static PdfColorSpace Named(string name, PDict? resources)
    {
        if (Device(name) is { } device) return device;
        if (resources?.Dict("ColorSpace") is { } spaces && spaces.RawObject(name) is { } raw && Parse(resources.Source, raw, 0) is { } space)
            return space;
        return DeviceGray;
    }

    static PdfColorSpace? Device(string name) => name switch
    {
        "DeviceGray" or "G" or "CalGray" => DeviceGray,
        "DeviceRGB" or "RGB" or "CalRGB" => DeviceRgb,
        "DeviceCMYK" or "CMYK" => DeviceCmyk,
        "Pattern" => new Pattern(null),
        _ => null,
    };

    public static PdfColorSpace? Parse(PdfSource source, IToken raw, int depth)
    {
        if (depth > 6) return null;
        var token = source.Resolve(raw);
        if (token is NameToken name) return Device(name.Data);
        if (source.WrapArray(raw) is not { Count: > 0 } array || array.Name(0) is not { } family) return null;
        PdfColorSpace? Element(int i) => array.Raw(i) is { } r ? Parse(source, r, depth + 1) : null;
        switch (family)
        {
            case "CalGray": return DeviceGray;
            case "CalRGB": return DeviceRgb;
            case "Lab": return new Lab();
            case "ICCBased":
                {
                    if (array.Stream(1) is not { } stream) return DeviceRgb;
                    if (stream.Dict.RawObject("Alternate") is { } alt && Parse(source, alt, depth + 1) is { } alternate) return alternate;
                    return (int)(stream.Dict.Number("N") ?? 3) switch { 1 => DeviceGray, 4 => DeviceCmyk, _ => DeviceRgb };
                }
            case "Indexed" or "I":
                {
                    if (Element(1) is not { } baseSpace) return null;
                    int high = (int)(array.Number(2) ?? 0);
                    byte[] table = array.Object(3) switch
                    {
                        StringToken s => s.GetBytes(),
                        HexToken h => h.Bytes.ToArray(),
                        StreamToken => array.Stream(3)?.Data ?? [],
                        _ => [],
                    };
                    return new Indexed(baseSpace, high, table);
                }
            case "Separation":
                return new Tint([array.Name(1) ?? ""], Element(2) ?? DeviceGray,
                    array.Raw(3) is { } f ? PdfFunction.Parse(source, f, 0) : null);
            case "DeviceN":
                {
                    var names = array.Array(1) is { } list ? Enumerable.Range(0, list.Count).Select(i => list.Name(i) ?? "").ToArray() : [];
                    return new Tint(names, Element(2) ?? DeviceGray, array.Raw(3) is { } tint ? PdfFunction.Parse(source, tint, 0) : null);
                }
            case "Pattern":
                return new Pattern(Element(1));
            default:
                return Device(family);
        }
    }

    /// <summary>CIE L*a*b* (D50) to sRGB, near enough to tell dark from light.</summary>
    static RGBColor LabToRgb(double l, double a, double b)
    {
        double fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
        static double F(double t) => t * t * t > 0.008856 ? t * t * t : (t - 16.0 / 116) / 7.787;
        double x = 0.9642 * F(fx), y = F(fy), z = 0.8249 * F(fz);
        double r = 3.1339 * x - 1.6169 * y - 0.4906 * z;
        double g = -0.9788 * x + 1.9161 * y + 0.0335 * z;
        double bl = 0.0719 * x - 0.2290 * y + 1.4052 * z;
        static double Gamma(double v)
        {
            var c = Clamp(v);
            return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.Pow(c, 1 / 2.4) - 0.055;
        }
        return new RGBColor(Gamma(r), Gamma(g), Gamma(bl));
    }
}

/// <summary>A PDF function (§7.10): sampled, exponential, stitching or PostScript calculator.</summary>
public abstract record PdfFunction
{
    public sealed record Sampled(double[] Domain, double[] Range, int[] Size, int Bits, double[] Encode, double[] Decode, byte[] Samples) : PdfFunction;
    public sealed record Exponential(double[] Domain, double[] C0, double[] C1, double N) : PdfFunction;
    public sealed record Stitching(double[] Domain, PdfFunction[] Functions, double[] Bounds, double[] Encode) : PdfFunction;
    public sealed record Calculator(double[] Domain, double[] Range, List<PostScriptCalculator.Token> Program) : PdfFunction;
    public sealed record Several(PdfFunction[] Parts) : PdfFunction;

    public static PdfFunction? Parse(PdfSource source, IToken raw, int depth)
    {
        if (depth > 6) return null;
        if (source.WrapArray(raw) is { } array)
        {
            var parts = Enumerable.Range(0, array.Count).Select(i => array.Raw(i) is { } r ? Parse(source, r, depth + 1) : null).OfType<PdfFunction>().ToArray();
            return parts.Length == 0 ? null : new Several(parts);
        }
        var stream = source.WrapStream(raw);
        var dict = stream?.Dict ?? source.WrapDict(raw);
        if (dict == null) return null;
        double[] Numbers(string key) => dict.Array(key)?.Numbers().ToArray() ?? [];
        var domain = Numbers("Domain");
        switch ((int)(dict.Number("FunctionType") ?? -1))
        {
            case 0:
                {
                    if (stream == null) return null;
                    var size = Numbers("Size").Select(v => Math.Max((int)v, 1)).ToArray();
                    var range = Numbers("Range");
                    if (size.Length == 0 || range.Length < 2) return null;
                    var encode = Numbers("Encode");
                    var decode = Numbers("Decode");
                    return new Sampled(domain, range, size, (int)(dict.Number("BitsPerSample") ?? 8),
                        encode.Length == 0 ? size.SelectMany(s => new double[] { 0, s - 1 }).ToArray() : encode,
                        decode.Length == 0 ? range : decode, stream.Data);
                }
            case 2:
                {
                    var c0 = Numbers("C0");
                    var c1 = Numbers("C1");
                    return new Exponential(domain, c0.Length == 0 ? [0] : c0, c1.Length == 0 ? [1] : c1, dict.Number("N") ?? 1);
                }
            case 3:
                {
                    if (dict.Array("Functions") is not { } list) return null;
                    var functions = Enumerable.Range(0, list.Count).Select(i => list.Raw(i) is { } r ? Parse(source, r, depth + 1) : null).ToArray();
                    if (functions.Length == 0 || functions.Any(f => f == null)) return null;
                    return new Stitching(domain, functions!, Numbers("Bounds"), Numbers("Encode"));
                }
            case 4:
                {
                    if (stream == null || PostScriptCalculator.Parse(stream.Data) is not { } program) return null;
                    return new Calculator(domain, Numbers("Range"), program);
                }
            default:
                return null;
        }
    }

    static double[] Clip(IReadOnlyList<double> values, double[] bounds) =>
        values.Select((v, i) => 2 * i + 1 < bounds.Length ? Math.Min(Math.Max(v, bounds[2 * i]), bounds[2 * i + 1]) : v).ToArray();

    static double Interpolate(double x, double x0, double x1, double y0, double y1) => x1 == x0 ? y0 : y0 + (x - x0) * (y1 - y0) / (x1 - x0);

    static double At(double[] a, int i, double fallback) => i >= 0 && i < a.Length ? a[i] : fallback;

    public double[] Evaluate(IReadOnlyList<double> input)
    {
        switch (this)
        {
            case Several s:
                return s.Parts.SelectMany(p => p.Evaluate(input).Take(1)).ToArray();
            case Exponential e:
                {
                    double x = Clip(input.Take(1).ToArray(), e.Domain).FirstOrDefault();
                    double p = x <= 0 && e.N < 1 ? 0 : Math.Pow(x, e.N);
                    return e.C0.Zip(e.C1, (a, b) => a + p * (b - a)).ToArray();
                }
            case Stitching st:
                {
                    double x = Clip(input.Take(1).ToArray(), st.Domain).FirstOrDefault();
                    double lo = At(st.Domain, 0, 0), hi = At(st.Domain, 1, 1);
                    int k = 0;
                    while (k < st.Bounds.Length && x >= st.Bounds[k]) k++;
                    k = Math.Min(k, st.Functions.Length - 1);
                    double a = k == 0 ? lo : st.Bounds[k - 1], b = k < st.Bounds.Length ? st.Bounds[k] : hi;
                    return st.Functions[k].Evaluate([Interpolate(x, a, b, At(st.Encode, 2 * k, 0), At(st.Encode, 2 * k + 1, 1))]);
                }
            case Calculator c:
                {
                    var output = PostScriptCalculator.Run(c.Program, Clip(input, c.Domain));
                    return Clip(output.Skip(Math.Max(output.Count - Math.Max(c.Range.Length / 2, 1), 0)).ToArray(), c.Range);
                }
            case Sampled sm:
                {
                    int outputs = sm.Range.Length / 2;
                    var x = Clip(input.Take(sm.Size.Length).ToArray(), sm.Domain);
                    // The nearest sample in each input dimension (exact for the tint ramps colour spaces hold, close otherwise).
                    int offset = 0, stride = 1;
                    for (int i = 0; i < x.Length && i < sm.Size.Length; i++)
                    {
                        double e = Interpolate(x[i], At(sm.Domain, 2 * i, 0), At(sm.Domain, 2 * i + 1, 1), At(sm.Encode, 2 * i, 0), At(sm.Encode, 2 * i + 1, sm.Size[i] - 1));
                        offset += Math.Min(Math.Max((int)Math.Round(e), 0), sm.Size[i] - 1) * stride;
                        stride *= sm.Size[i];
                    }
                    double max = Math.Pow(2, Math.Min(sm.Bits, 32)) - 1;
                    return Enumerable.Range(0, outputs).Select(j =>
                        Interpolate(Sample(sm.Samples, offset * outputs + j, sm.Bits), 0, max,
                            At(sm.Decode, 2 * j, sm.Range[2 * j]), At(sm.Decode, 2 * j + 1, sm.Range[2 * j + 1]))).ToArray();
                }
            default:
                return [];
        }
    }

    static double Sample(byte[] data, int index, int bits)
    {
        long bit = (long)index * bits, value = 0;
        for (int b = 0; b < bits; b++)
        {
            long position = bit + b, at = position / 8;
            if (at >= data.Length) return 0;
            value = value << 1 | (uint)(data[at] >> (int)(7 - position % 8) & 1);
        }
        return value;
    }
}

/// <summary>PostScript calculator functions (§7.10.5): numbers, operators and <c>{ } if</c> / <c>{ } { } ifelse</c>.</summary>
public static class PostScriptCalculator
{
    public abstract record Token
    {
        public sealed record Num(double Value) : Token;
        public sealed record Op(string Name) : Token;
        public sealed record Block(List<Token> Body) : Token;
    }

    public static List<Token>? Parse(byte[] data)
    {
        var text = System.Text.Encoding.Latin1.GetString(data);
        var words = new List<string>();
        var current = new System.Text.StringBuilder();
        foreach (var ch in text)
        {
            if (ch is '{' or '}')
            {
                if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
                words.Add(ch.ToString());
            }
            else if (char.IsWhiteSpace(ch))
            {
                if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
            }
            else current.Append(ch);
        }
        if (current.Length > 0) words.Add(current.ToString());
        int index = 0;
        List<Token>? Block()
        {
            var output = new List<Token>();
            while (index < words.Count)
            {
                var w = words[index++];
                if (w == "{") { if (Block() is not { } inner) return null; output.Add(new Token.Block(inner)); }
                else if (w == "}") return output;
                else output.Add(double.TryParse(w, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? new Token.Num(v) : new Token.Op(w));
            }
            return output;
        }
        // The program is one outer block.
        return Block() is [Token.Block { Body: var program }] ? program : null;
    }

    public static List<double> Run(List<Token> program, IReadOnlyList<double> input)
    {
        var stack = new List<double>(input);
        int steps = 0;
        double Pop() { if (stack.Count == 0) return 0; var v = stack[^1]; stack.RemoveAt(stack.Count - 1); return v; }
        void Push(double v) => stack.Add(v);
        void Exec(List<Token> tokens)
        {
            for (int i = 0; i < tokens.Count && steps < 10_000; i++)
            {
                steps++;
                switch (tokens[i])
                {
                    case Token.Num n: Push(n.Value); break;
                    case Token.Block a:
                        if (i + 2 < tokens.Count && tokens[i + 1] is Token.Block b && tokens[i + 2] is Token.Op { Name: "ifelse" })
                        {
                            Exec(Pop() != 0 ? a.Body : b.Body);
                            i += 2;
                        }
                        else if (i + 1 < tokens.Count && tokens[i + 1] is Token.Op { Name: "if" })
                        {
                            if (Pop() != 0) Exec(a.Body);
                            i += 1;
                        }
                        break;
                    case Token.Op op: Apply(op.Name); break;
                }
            }
        }
        void Apply(string name)
        {
            double a, b;
            switch (name)
            {
                case "add": b = Pop(); a = Pop(); Push(a + b); break;
                case "sub": b = Pop(); a = Pop(); Push(a - b); break;
                case "mul": b = Pop(); a = Pop(); Push(a * b); break;
                case "div": b = Pop(); a = Pop(); Push(b == 0 ? 0 : a / b); break;
                case "idiv": b = Pop(); a = Pop(); Push((int)b == 0 ? 0 : (int)a / (int)b); break;
                case "mod": b = Pop(); a = Pop(); Push((int)b == 0 ? 0 : (int)a % (int)b); break;
                case "neg": Push(-Pop()); break;
                case "abs": Push(Math.Abs(Pop())); break;
                case "ceiling": Push(Math.Ceiling(Pop())); break;
                case "floor": Push(Math.Floor(Pop())); break;
                case "round": Push(Math.Round(Pop(), MidpointRounding.AwayFromZero)); break;
                case "truncate" or "cvi": Push(Math.Truncate(Pop())); break;
                case "cvr": break;
                case "sqrt": Push(Math.Sqrt(Pop())); break;
                case "sin": Push(Math.Sin(Pop() * Math.PI / 180)); break;
                case "cos": Push(Math.Cos(Pop() * Math.PI / 180)); break;
                case "atan": b = Pop(); a = Pop(); { var d = Math.Atan2(a, b) * 180 / Math.PI; Push(d < 0 ? d + 360 : d); } break;
                case "exp": b = Pop(); a = Pop(); Push(Math.Pow(a, b)); break;
                case "ln": Push(Math.Log(Math.Max(Pop(), 1e-12))); break;
                case "log": Push(Math.Log10(Math.Max(Pop(), 1e-12))); break;
                case "pop": Pop(); break;
                case "exch": b = Pop(); a = Pop(); Push(b); Push(a); break;
                case "dup": a = Pop(); Push(a); Push(a); break;
                case "copy":
                    {
                        int n = (int)Pop();
                        if (n > 0 && n <= stack.Count) stack.AddRange(stack.GetRange(stack.Count - n, n));
                        break;
                    }
                case "index":
                    {
                        int n = (int)Pop();
                        Push(n >= 0 && n < stack.Count ? stack[stack.Count - 1 - n] : 0);
                        break;
                    }
                case "roll":
                    {
                        int j = (int)Pop(), n = (int)Pop();
                        if (n <= 0 || n > stack.Count) break;
                        var part = stack.GetRange(stack.Count - n, n);
                        stack.RemoveRange(stack.Count - n, n);
                        int shift = ((j % n) + n) % n;
                        stack.AddRange(part.Skip(n - shift).Concat(part.Take(n - shift)));
                        break;
                    }
                case "eq": b = Pop(); a = Pop(); Push(a == b ? 1 : 0); break;
                case "ne": b = Pop(); a = Pop(); Push(a != b ? 1 : 0); break;
                case "gt": b = Pop(); a = Pop(); Push(a > b ? 1 : 0); break;
                case "ge": b = Pop(); a = Pop(); Push(a >= b ? 1 : 0); break;
                case "lt": b = Pop(); a = Pop(); Push(a < b ? 1 : 0); break;
                case "le": b = Pop(); a = Pop(); Push(a <= b ? 1 : 0); break;
                case "and": b = Pop(); a = Pop(); Push(a != 0 && b != 0 ? 1 : 0); break;
                case "or": b = Pop(); a = Pop(); Push(a != 0 || b != 0 ? 1 : 0); break;
                case "xor": b = Pop(); a = Pop(); Push((a != 0) != (b != 0) ? 1 : 0); break;
                case "not": Push(Pop() == 0 ? 1 : 0); break;
                case "true": Push(1); break;
                case "false": Push(0); break;
                case "bitshift": { int s = (int)Pop(), v = (int)Pop(); Push(s >= 0 ? v << s : v >> -s); } break;
            }
        }
        Exec(program);
        return stack;
    }
}
