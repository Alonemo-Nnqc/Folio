using System.Globalization;
using System.Text;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Tokens;

namespace Folio.Core;

/// <summary>The reader's six markup colours (the macOS AnnotationColor), as sRGB components.</summary>
public static class AnnotationColors
{
    public static readonly (string Key, string Title, double R, double G, double B)[] All =
    [
        ("yellow", "黄色", 1.00, 0.85, 0.20), ("green", "绿色", 0.45, 0.85, 0.40), ("blue", "蓝色", 0.40, 0.70, 1.00),
        ("pink", "粉色", 1.00, 0.55, 0.75), ("purple", "紫色", 0.75, 0.55, 1.00), ("red", "红色", 1.00, 0.35, 0.35),
    ];

    public static (double R, double G, double B) Rgb(string key)
    {
        var c = All.FirstOrDefault(c => c.Key == key, All[0]);
        return (c.R, c.G, c.B);
    }

    public static string Hex(string key)
    {
        var (r, g, b) = Rgb(key);
        return $"#{(int)(r * 255):X2}{(int)(g * 255):X2}{(int)(b * 255):X2}";
    }
}

/// <summary>A new annotation, in PDF user space of its page (origin bottom-left).</summary>
public sealed record NewAnnotation(
    int Page,
    /// <summary>Highlight, Underline, StrikeOut, Text (sticky note), FreeText or Ink.</summary>
    string Subtype,
    string Color,
    /// <summary>Quadrilaterals for markup: x1 y1 x2 y2 x3 y3 x4 y4 (upper-left, upper-right, lower-left, lower-right).</summary>
    IReadOnlyList<double[]>? Quads = null,
    /// <summary>Rectangle for notes and text boxes: left, bottom, right, top.</summary>
    double[]? Rect = null,
    /// <summary>Strokes for ink: x y x y …</summary>
    IReadOnlyList<double[]>? Strokes = null,
    string? Contents = null,
    string? Author = null);

/// <summary>
/// Writes annotations into a PDF by incremental update: the original bytes stay untouched and new objects, a new
/// version of the page dictionary and a cross-reference section are appended — what Preview and Acrobat do, so other
/// readers (and the macOS app) see the annotations. Appearance streams are included for markup and ink.
/// </summary>
public static class AnnotationWriter
{
    sealed record PageInfo(long Number, int Generation, DictionaryToken Dictionary, List<IToken> Annots);

    public static void Add(string path, IReadOnlyList<NewAnnotation> annotations)
    {
        if (annotations.Count == 0) return;
        Update(path, (pages, nextObject, write) =>
        {
            var changed = new Dictionary<int, List<IToken>>();
            foreach (var a in annotations)
            {
                var page = pages(a.Page);
                var (obj, appearance) = Build(a, nextObject);
                if (appearance != null) write(appearance.Value.Number, appearance.Value.Body);
                write(obj.Number, obj.Body);
                if (!changed.TryGetValue(a.Page, out var annots)) changed[a.Page] = annots = [.. page.Annots];
                annots.Add(new IndirectReferenceToken(new IndirectReference(obj.Number, 0)));
            }
            return changed;
        });
    }

    /// <summary>Removes the annotation with the given /NM name (Folio's own) from a page.</summary>
    public static bool Remove(string path, int page, string name)
    {
        bool removed = false;
        Update(path, (pages, _, _) =>
        {
            var info = pages(page);
            var kept = new List<IToken>();
            using var doc = PdfDocument.Open(path);
            foreach (var token in info.Annots)
            {
                if (token is IndirectReferenceToken r && doc.Structure.GetObject(r.Data).Data is DictionaryToken d
                    && d.TryGet(NameToken.Nm, out StringToken? nm) && nm.Data == name) { removed = true; continue; }
                kept.Add(token);
            }
            return removed ? new Dictionary<int, List<IToken>> { [page] = kept } : [];
        });
        return removed;
    }

    delegate Dictionary<int, List<IToken>> Edit(Func<int, PageInfo> page, Func<long> nextObject, Action<long, string> write);

    static void Update(string path, Edit edit)
    {
        var original = File.ReadAllBytes(path);
        long startXref = FindStartXref(original);
        PdfDocument document = PdfDocument.Open(original);
        var trailer = document.Structure.CrossReferenceTable.Trailer;
        if (trailer.EncryptionToken != null) throw new InvalidOperationException(Loc.S("这个 PDF 已加密，无法写入批注"));
        long size = trailer.Size;
        var pageInfos = new Dictionary<int, PageInfo>();
        PageInfo PageAt(int number)
        {
            if (pageInfos.TryGetValue(number, out var info)) return info;
            var node = PageNodes(document)[number - 1];
            var dictionary = node.Dictionary;
            var annots = new List<IToken>();
            if (dictionary.TryGet(NameToken.Annots, out var raw))
            {
                var resolved = raw is IndirectReferenceToken r ? document.Structure.GetObject(r.Data).Data : raw;
                if (resolved is ArrayToken array) annots.AddRange(array.Data);
            }
            return pageInfos[number] = new PageInfo(node.Reference.ObjectNumber, node.Reference.Generation, dictionary, annots);
        }
        var body = new MemoryStream();
        var offsets = new List<(long Number, int Generation, long Offset)>();
        long next = size;
        long NextObject() => next++;
        void Write(long number, string content) => WriteObject(body, original.Length, offsets, number, 0, content);
        Dictionary<int, List<IToken>> changed;
        try
        {
            changed = edit(PageAt, NextObject, Write);
            foreach (var (number, annots) in changed)
            {
                var page = PageAt(number);
                var entries = page.Dictionary.Data.Where(kv => kv.Key != "Annots").Select(kv => (kv.Key, kv.Value)).ToList();
                entries.Add(("Annots", new ArrayToken(annots)));
                var dict = new StringBuilder("<<");
                foreach (var (key, value) in entries) dict.Append('/').Append(EscapeName(key)).Append(' ').Append(Serialize(value)).Append(' ');
                dict.Append(">>");
                WriteObject(body, original.Length, offsets, page.Number, page.Generation, dict.ToString());
            }
        }
        finally { document.Dispose(); }
        if (changed.Count == 0) return;

        // Cross-reference section and trailer for the update.
        long xrefOffset = original.Length + body.Length;
        var xref = new StringBuilder("xref\n");
        foreach (var (number, generation, offset) in offsets.OrderBy(o => o.Number))
            xref.Append(CultureInfo.InvariantCulture, $"{number} 1\n{offset:D10} {generation:D5} n\r\n");
        xref.Append("trailer\n<<");
        xref.Append(CultureInfo.InvariantCulture, $"/Size {Math.Max(size, next)} /Root {Serialize(new IndirectReferenceToken(trailer.Root))} /Prev {startXref}");
        if (trailer.Info is { } info) xref.Append(" /Info ").Append(Serialize(info));
        if (trailer.Identifier is { Count: > 0 } ids) xref.Append(" /ID [").Append(string.Join(' ', ids.Select(Serialize))).Append(']');
        xref.Append(CultureInfo.InvariantCulture, $">>\nstartxref\n{xrefOffset}\n%%EOF\n");

        // Write next to the file and swap, so a crash never leaves half a PDF.
        var temp = path + ".folio-tmp";
        using (var output = File.Create(temp))
        {
            output.Write(original);
            if (original.Length > 0 && original[^1] != '\n') { }
            body.Position = 0;
            body.CopyTo(output);
            output.Write(Encoding.ASCII.GetBytes(xref.ToString()));
        }
        File.Move(temp, path, overwrite: true);
    }

    /// <summary>The page tree's leaves in page order: (object reference, page dictionary).</summary>
    static List<(IndirectReference Reference, DictionaryToken Dictionary)> PageNodes(PdfDocument document)
    {
        var result = new List<(IndirectReference, DictionaryToken)>();
        var root = (DictionaryToken)document.Structure.GetObject(document.Structure.CrossReferenceTable.Trailer.Root).Data;
        void Walk(IndirectReference reference, int depth)
        {
            if (depth > 64 || document.Structure.GetObject(reference).Data is not DictionaryToken node) return;
            bool isPage = node.TryGet(NameToken.Type, out NameToken? type) && type.Data == "Page";
            if (isPage || !node.ContainsKey(NameToken.Kids)) { result.Add((reference, node)); return; }
            var kids = node.Data["Kids"] is IndirectReferenceToken kr ? document.Structure.GetObject(kr.Data).Data : node.Data["Kids"];
            foreach (var kid in (kids as ArrayToken)?.Data ?? []) if (kid is IndirectReferenceToken k) Walk(k.Data, depth + 1);
        }
        if (root.Data["Pages"] is IndirectReferenceToken pages) Walk(pages.Data, 0);
        return result;
    }

    static void WriteObject(MemoryStream body, long baseOffset, List<(long, int, long)> offsets, long number, int generation, string content)
    {
        var bytes = Encoding.Latin1.GetBytes($"\n{number} {generation} obj\n{content}\nendobj\n");
        offsets.Add((number, generation, baseOffset + body.Length + 1));
        body.Write(bytes);
    }

    static long FindStartXref(byte[] data)
    {
        var tail = Encoding.Latin1.GetString(data, Math.Max(0, data.Length - 2048), Math.Min(2048, data.Length));
        int i = tail.LastIndexOf("startxref", StringComparison.Ordinal);
        if (i < 0) throw new InvalidDataException("startxref not found");
        var digits = new string(tail[(i + 9)..].SkipWhile(char.IsWhiteSpace).TakeWhile(char.IsDigit).ToArray());
        return long.Parse(digits, CultureInfo.InvariantCulture);
    }

    static ((long Number, string Body) Annotation, (long Number, string Body)? Appearance) Build(NewAnnotation a, Func<long> next)
    {
        var (r, g, b) = AnnotationColors.Rgb(a.Color);
        string color = $"[{N(r)} {N(g)} {N(b)}]";
        long number = next();
        var name = Guid.NewGuid().ToString("N");
        var date = PdfDate(DateTime.Now);
        double[] rect;
        string extra = "";
        string? stream = null;
        switch (a.Subtype)
        {
            case "Highlight" or "Underline" or "StrikeOut":
            {
                var quads = a.Quads ?? [];
                rect = Bounds(quads.SelectMany(q => Pairs(q)));
                extra = $"/QuadPoints [{string.Join(' ', quads.SelectMany(q => q).Select(N))}]";
                var sb = new StringBuilder();
                if (a.Subtype == "Highlight")
                {
                    sb.Append($"/GS0 gs {N(r)} {N(g)} {N(b)} rg ");
                    foreach (var q in quads) sb.Append($"{N(q[0])} {N(q[1])} m {N(q[2])} {N(q[3])} l {N(q[6])} {N(q[7])} l {N(q[4])} {N(q[5])} l h f ");
                }
                else
                {
                    sb.Append($"{N(r)} {N(g)} {N(b)} RG ");
                    foreach (var q in quads)
                    {
                        double height = Math.Abs(q[1] - q[5]);
                        double y = a.Subtype == "Underline" ? Math.Min(q[5], q[7]) + height * 0.08 : (q[1] + q[5]) / 2;
                        sb.Append($"{N(Math.Max(0.6, height * 0.07))} w {N(q[4])} {N(y)} m {N(q[6])} {N(y)} l S ");
                    }
                }
                stream = sb.ToString();
                break;
            }
            case "Ink":
            {
                var strokes = a.Strokes ?? [];
                rect = Bounds(strokes.SelectMany(s => Pairs(s)), pad: 2);
                extra = $"/InkList [{string.Join(' ', strokes.Select(s => "[" + string.Join(' ', s.Select(N)) + "]"))}] /BS << /W 2 >>";
                var sb = new StringBuilder($"{N(r)} {N(g)} {N(b)} RG 2 w 1 J 1 j ");
                foreach (var s in strokes)
                {
                    for (int i = 0; i + 1 < s.Length; i += 2) sb.Append($"{N(s[i])} {N(s[i + 1])} {(i == 0 ? "m" : "l")} ");
                    sb.Append("S ");
                }
                stream = sb.ToString();
                break;
            }
            case "FreeText":
                rect = a.Rect ?? [0, 0, 200, 40];
                extra = $"/DA (/Helv 12 Tf 0 g) /IT /FreeTextTypeWriter /BS << /W 0 >> /IC {color}";
                break;
            default:
                rect = a.Rect ?? [0, 0, 20, 20];
                extra = "/Name /Comment /Open false";
                break;
        }
        (long, string)? appearance = null;
        string ap = "";
        if (stream != null)
        {
            long apNumber = next();
            var gs = a.Subtype == "Highlight" ? "/Resources << /ExtGState << /GS0 << /BM /Multiply /CA 0.5 /ca 0.5 >> >> >> " : "";
            var bytes = Encoding.ASCII.GetBytes(stream);
            appearance = (apNumber, $"<< /Type /XObject /Subtype /Form /BBox [{string.Join(' ', rect.Select(N))}] {gs}/Length {bytes.Length} >>\nstream\n{stream}\nendstream");
            ap = $"/AP << /N {apNumber} 0 R >>";
        }
        var subtype = a.Subtype == "Note" ? "Text" : a.Subtype;
        var body = new StringBuilder($"<< /Type /Annot /Subtype /{subtype} /Rect [{string.Join(' ', rect.Select(N))}] /C {color} /F 4 /NM {Str(name)} /M ({date}) /CreationDate ({date}) ");
        if (a.Subtype == "Highlight") body.Append("/CA 0.5 ");
        if (a.Contents is { Length: > 0 } contents) body.Append("/Contents ").Append(Str(contents)).Append(' ');
        if (a.Author is { Length: > 0 } author) body.Append("/T ").Append(Str(author)).Append(' ');
        body.Append(extra).Append(' ').Append(ap).Append(" >>");
        return ((number, body.ToString()), appearance);
    }

    static IEnumerable<(double X, double Y)> Pairs(double[] values)
    {
        for (int i = 0; i + 1 < values.Length; i += 2) yield return (values[i], values[i + 1]);
    }

    static double[] Bounds(IEnumerable<(double X, double Y)> points, double pad = 0)
    {
        var list = points.ToList();
        if (list.Count == 0) return [0, 0, 0, 0];
        return [list.Min(p => p.X) - pad, list.Min(p => p.Y) - pad, list.Max(p => p.X) + pad, list.Max(p => p.Y) + pad];
    }

    static string N(double v) => Math.Round(v, 3).ToString("0.###", CultureInfo.InvariantCulture);

    static string PdfDate(DateTime d)
    {
        var offset = TimeZoneInfo.Local.GetUtcOffset(d);
        return $"D:{d:yyyyMMddHHmmss}{(offset < TimeSpan.Zero ? "-" : "+")}{Math.Abs(offset.Hours):00}'{Math.Abs(offset.Minutes):00}'";
    }

    /// <summary>A text string: PDFDocEncoding-safe ASCII as a literal, anything else as UTF-16BE hex.</summary>
    static string Str(string s)
    {
        if (s.All(c => c is >= ' ' and <= '~'))
            return "(" + s.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)") + ")";
        var bytes = new List<byte> { 0xFE, 0xFF };
        bytes.AddRange(Encoding.BigEndianUnicode.GetBytes(s));
        return "<" + Convert.ToHexString(bytes.ToArray()) + ">";
    }

    static string EscapeName(string name)
    {
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(name))
            sb.Append(b is > 0x20 and < 0x7F and not (byte)'#' and not (byte)'/' and not (byte)'(' and not (byte)')' and not (byte)'<' and not (byte)'>' and not (byte)'[' and not (byte)']' and not (byte)'{' and not (byte)'}' and not (byte)'%'
                ? ((char)b).ToString() : $"#{b:X2}");
        return sb.ToString();
    }

    /// <summary>Writes a PdfPig token back as PDF syntax (dictionaries of the page being updated).</summary>
    static string Serialize(IToken token) => token switch
    {
        NameToken n => "/" + EscapeName(n.Data),
        NumericToken n => n.Data.ToString(CultureInfo.InvariantCulture),
        BooleanToken b => b.Data ? "true" : "false",
        NullToken => "null",
        IndirectReferenceToken r => $"{r.Data.ObjectNumber} {r.Data.Generation} R",
        HexToken h => "<" + Convert.ToHexString(h.Bytes.ToArray()) + ">",
        StringToken s => "<" + Convert.ToHexString(s.GetBytes()) + ">",
        ArrayToken a => "[" + string.Join(' ', a.Data.Select(Serialize)) + "]",
        DictionaryToken d => "<<" + string.Concat(d.Data.Select(kv => $"/{EscapeName(kv.Key)} {Serialize(kv.Value)} ")) + ">>",
        _ => throw new NotSupportedException(token.GetType().Name),
    };
}
