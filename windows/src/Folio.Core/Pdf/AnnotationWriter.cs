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
        return $"#{(int)Math.Round(r * 255):X2}{(int)Math.Round(g * 255):X2}{(int)Math.Round(b * 255):X2}";
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

/// <summary>What the eraser did to one ink annotation: its tracks over the page (x y x y …, page coordinates) and the
/// eraser's radius in page points.</summary>
public sealed record InkErasure(int Page, long ObjectNumber, IReadOnlyList<double[]> Paths, double Radius);

/// <summary>
/// Writes annotations into a PDF by incremental update: the original bytes stay untouched and new objects, a new
/// version of the page dictionary and a cross-reference section are appended — what Preview and Acrobat do, so other
/// readers (and the macOS app) see the annotations. Appearance streams are included for markup and ink.
/// </summary>
public static partial class AnnotationWriter
{
    sealed record PageInfo(long Number, int Generation, DictionaryToken Dictionary, List<IToken> Annots);

    /// <summary>Appends annotations; returns their object numbers, in order.</summary>
    public static List<long> Add(string path, IReadOnlyList<NewAnnotation> annotations)
    {
        var numbers = new List<long>();
        if (annotations.Count == 0) return numbers;
        Update(path, (_, pages, nextObject, write) =>
        {
            var changed = new Dictionary<int, List<IToken>>();
            foreach (var a in annotations)
            {
                var page = pages(a.Page);
                var (obj, appearance) = Build(a, nextObject);
                if (appearance != null) write(appearance.Value.Number, appearance.Value.Body);
                write(obj.Number, obj.Body);
                numbers.Add(obj.Number);
                if (!changed.TryGetValue(a.Page, out var annots)) changed[a.Page] = annots = [.. page.Annots];
                annots.Add(new IndirectReferenceToken(new IndirectReference(obj.Number, 0)));
            }
            return changed;
        });
        return numbers;
    }

    /// <summary>Removes an annotation from a page, by its object number (the annotation stays in the file's history,
    /// as with any incremental update, but is no longer on the page). A note's popup goes with it.</summary>
    public static bool Remove(string path, int page, long objectNumber)
    {
        bool removed = false;
        Update(path, (document, pages, _, _) =>
        {
            var info = pages(page);
            var kept = new List<IToken>();
            foreach (var token in info.Annots)
            {
                if (token is IndirectReferenceToken r)
                {
                    if (r.Data.ObjectNumber == objectNumber) { removed = true; continue; }
                    if (document.Structure.GetObject(r.Data).Data is DictionaryToken d && d.TryGet(NameToken.Create("Parent"), out IndirectReferenceToken? parent)
                        && parent.Data.ObjectNumber == objectNumber) continue;
                }
                kept.Add(token);
            }
            return removed ? new Dictionary<int, List<IToken>> { [page] = kept } : [];
        });
        return removed;
    }

    /// <summary>Changes an annotation in place: colour, text (null leaves it, empty clears it) and position.</summary>
    public static bool Modify(string path, int page, long objectNumber, string? color = null, string? contents = null, double dx = 0, double dy = 0)
    {
        bool modified = false;
        Update(path, (document, pages, next, write) =>
        {
            var info = pages(page);
            var reference = info.Annots.OfType<IndirectReferenceToken>().FirstOrDefault(r => r.Data.ObjectNumber == objectNumber);
            if (reference == null || document.Structure.GetObject(reference.Data).Data is not DictionaryToken dict) return [];
            var entries = dict.Data.ToDictionary(kv => kv.Key, kv => kv.Value);
            IToken Resolve(IToken t) => t is IndirectReferenceToken r ? document.Structure.GetObject(r.Data).Data : t;
            double[] Numbers(string key) => entries.TryGetValue(key, out var t) && Resolve(t) is ArrayToken a ? a.Data.Select(Resolve).OfType<NumericToken>().Select(n => n.Double).ToArray() : [];
            var subtype = entries.TryGetValue("Subtype", out var st) && Resolve(st) is NameToken stn ? stn.Data : "";
            if (dx != 0 || dy != 0)
            {
                var rect = Numbers("Rect");
                if (rect.Length == 4) entries["Rect"] = Array(rect[0] + dx, rect[1] + dy, rect[2] + dx, rect[3] + dy);
                var quads = Numbers("QuadPoints");
                if (quads.Length > 0) entries["QuadPoints"] = Array(quads.Select((v, i) => v + (i % 2 == 0 ? dx : dy)).ToArray());
                if (entries.TryGetValue("InkList", out var inkRaw) && Resolve(inkRaw) is ArrayToken ink)
                    entries["InkList"] = new ArrayToken(ink.Data.Select(Resolve).OfType<ArrayToken>()
                        .Select(s => (IToken)Array(s.Data.Select(Resolve).OfType<NumericToken>().Select((n, i) => n.Double + (i % 2 == 0 ? dx : dy)).ToArray())).ToList());
            }
            if (color != null)
            {
                var (r, g, b) = AnnotationColors.Rgb(color);
                entries["C"] = Array(r, g, b);
            }
            if (contents != null)
            {
                if (contents.Length == 0) entries.Remove("Contents");
                else entries["Contents"] = new HexToken(Convert.ToHexString(new byte[] { 0xFE, 0xFF }.Concat(Encoding.BigEndianUnicode.GetBytes(contents)).ToArray()).ToCharArray());
                // A text box's picture holds its text: readers draw it afresh without one.
                if (subtype == "FreeText") entries.Remove("AP");
            }
            entries["M"] = new StringToken(PdfDate(DateTime.Now));
            if (subtype is "Highlight" or "Underline" or "StrikeOut" or "Ink" && (color != null || dx != 0 || dy != 0))
            {
                var c = Numbers("C");
                var (r, g, b) = c.Length == 3 ? (c[0], c[1], c[2]) : (1.0, 0.85, 0.2);
                var rect = Numbers("Rect");
                var flat = Numbers("QuadPoints");
                var quads = Enumerable.Range(0, flat.Length / 8).Select(i => flat.Skip(i * 8).Take(8).ToArray()).ToList();
                var strokes = entries.TryGetValue("InkList", out var inkToken) && Resolve(inkToken) is ArrayToken inkList
                    ? inkList.Data.Select(Resolve).OfType<ArrayToken>().Select(s => s.Data.Select(Resolve).OfType<NumericToken>().Select(n => n.Double).ToArray()).ToList() : [];
                var stream = Appearance(subtype, quads, strokes, r, g, b);
                if (rect.Length == 4 && stream != null)
                {
                    long ap = next();
                    write(ap, AppearanceObject(subtype, rect, stream));
                    entries["AP"] = new DictionaryToken(new Dictionary<NameToken, IToken> { [NameToken.Create("N")] = new IndirectReferenceToken(new IndirectReference(ap, 0)) });
                }
            }
            var body = new StringBuilder("<<");
            foreach (var (key, value) in entries) body.Append('/').Append(EscapeName(key)).Append(' ').Append(Serialize(value)).Append(' ');
            body.Append(">>");
            write(objectNumber, body.ToString());
            modified = true;
            return [];
        });
        return modified;
    }

    /// <summary>The eraser (READER-30): cuts what the eraser's tracks (x y x y …, page coordinates) passed over out of ink
    /// annotations, all in one update (one undo step). An annotation with nothing left goes from its page; the others keep
    /// their colour, line width and opacity and get a new picture. Returns the object numbers changed and removed.</summary>
    public static (List<long> Changed, List<long> Removed) EraseInk(string path, IReadOnlyList<InkErasure> erasures)
    {
        var changed = new List<long>();
        var removed = new List<long>();
        if (erasures.Count == 0) return (changed, removed);
        Update(path, (document, pages, next, write) =>
        {
            IToken Resolve(IToken t) => t is IndirectReferenceToken r ? document.Structure.GetObject(r.Data).Data : t;
            var kept = new Dictionary<int, List<IToken>>();
            foreach (var erasure in erasures)
            {
                var info = pages(erasure.Page);
                var reference = info.Annots.OfType<IndirectReferenceToken>().FirstOrDefault(r => r.Data.ObjectNumber == erasure.ObjectNumber);
                if (reference == null || document.Structure.GetObject(reference.Data).Data is not DictionaryToken dict) continue;
                var entries = dict.Data.ToDictionary(kv => kv.Key, kv => kv.Value);
                double[] Numbers(IToken? token) => token != null && Resolve(token) is ArrayToken a ? a.Data.Select(Resolve).OfType<NumericToken>().Select(n => n.Double).ToArray() : [];
                if (!entries.TryGetValue("Subtype", out var st) || Resolve(st) is not NameToken { Data: "Ink" }) continue;
                if (!entries.TryGetValue("InkList", out var inkRaw) || Resolve(inkRaw) is not ArrayToken inkList) continue;
                var strokes = inkList.Data.Select(Resolve).OfType<ArrayToken>().Select(s => Numbers(s)).ToList();
                double width = InkWidth(entries, Resolve);
                var left = InkEraser.Erase(strokes, erasure.Paths, erasure.Radius + width / 2);
                if (left == null) continue;
                if (left.Count == 0)
                {
                    // Nothing left: off the page, with its popup.
                    var list = kept.TryGetValue(erasure.Page, out var current) ? current : [.. info.Annots];
                    list.RemoveAll(token => token is IndirectReferenceToken r && (r.Data.ObjectNumber == erasure.ObjectNumber
                        || document.Structure.GetObject(r.Data).Data is DictionaryToken d && d.TryGet(NameToken.Create("Parent"), out IndirectReferenceToken? parent)
                            && parent.Data.ObjectNumber == erasure.ObjectNumber));
                    kept[erasure.Page] = list;
                    removed.Add(erasure.ObjectNumber);
                    continue;
                }
                double pad = width / 2 + 1;
                var rect = Bounds(left.SelectMany(s => Pairs(s)), pad);
                double opacity = entries.TryGetValue("CA", out var ca) && Resolve(ca) is NumericToken n ? Math.Clamp(n.Double, 0, 1) : 1;
                var stream = InkStream(left, Numbers(entries.GetValueOrDefault("C")), width, opacity);
                long ap = next();
                var gs = opacity < 1 ? $"/Resources << /ExtGState << /GS0 << /CA {N(opacity)} /ca {N(opacity)} >> >> >> " : "";
                write(ap, $"<< /Type /XObject /Subtype /Form /BBox [{string.Join(' ', rect.Select(N))}] {gs}/Length {Encoding.ASCII.GetByteCount(stream)} >>\nstream\n{stream}\nendstream");
                entries["InkList"] = new ArrayToken(left.Select(s => (IToken)Array(s.Select(v => Math.Round(v, 3)).ToArray())).ToList());
                entries["Rect"] = Array(rect);
                entries["AP"] = new DictionaryToken(new Dictionary<NameToken, IToken> { [NameToken.Create("N")] = new IndirectReferenceToken(new IndirectReference(ap, 0)) });
                entries["M"] = new StringToken(PdfDate(DateTime.Now));
                var body = new StringBuilder("<<");
                foreach (var (key, value) in entries) body.Append('/').Append(EscapeName(key)).Append(' ').Append(Serialize(value)).Append(' ');
                body.Append(">>");
                write(erasure.ObjectNumber, body.ToString());
                changed.Add(erasure.ObjectNumber);
            }
            return kept;
        });
        return (changed, removed);
    }

    /// <summary>An ink annotation's line width: /BS /W, else the third number of /Border, else 1 (the PDF default).</summary>
    static double InkWidth(Dictionary<string, IToken> entries, Func<IToken, IToken> resolve)
    {
        if (entries.TryGetValue("BS", out var bs) && resolve(bs) is DictionaryToken style && style.TryGet(NameToken.Create("W"), out var w) && resolve(w) is NumericToken width)
            return Math.Max(0, width.Double);
        if (entries.TryGetValue("Border", out var border) && resolve(border) is ArrayToken array && array.Data.Count >= 3 && resolve(array.Data[2]) is NumericToken bw)
            return Math.Max(0, bw.Double);
        return 1;
    }

    /// <summary>The picture of erased ink: its strokes in its own colour (gray, RGB or CMYK), width and opacity.</summary>
    static string InkStream(IReadOnlyList<double[]> strokes, double[] color, double width, double opacity)
    {
        var sb = new StringBuilder();
        if (opacity < 1) sb.Append("/GS0 gs ");
        sb.Append(color.Length switch
        {
            1 => $"{N(color[0])} G ",
            3 => $"{N(color[0])} {N(color[1])} {N(color[2])} RG ",
            4 => $"{N(color[0])} {N(color[1])} {N(color[2])} {N(color[3])} K ",
            _ => "0 G ",
        });
        sb.Append(CultureInfo.InvariantCulture, $"{N(width)} w 1 J 1 j ");
        foreach (var s in strokes)
        {
            for (int i = 0; i + 1 < s.Length; i += 2) sb.Append(CultureInfo.InvariantCulture, $"{N(s[i])} {N(s[i + 1])} {(i == 0 ? "m" : "l")} ");
            sb.Append("S ");
        }
        return sb.ToString();
    }

    static ArrayToken Array(params double[] values) => new(values.Select(v => (IToken)new NumericToken(v)).ToList());

    /// <summary>Takes the file back to its earlier length: every annotation change appends, so this undoes them.</summary>
    public static byte[] TruncateTo(string path, long length)
    {
        var data = File.ReadAllBytes(path);
        if (length < 0 || length > data.Length) throw new InvalidDataException("The file changed.");
        var tail = data[(int)length..];
        Swap(path, output => output.Write(data, 0, (int)length));
        return tail;
    }

    /// <summary>Puts back what <see cref="TruncateTo"/> took away.</summary>
    public static void Append(string path, byte[] tail)
    {
        var data = File.ReadAllBytes(path);
        Swap(path, output => { output.Write(data); output.Write(tail); });
    }

    /// <summary>Writes next to the file and swaps, so a crash never leaves half a PDF.</summary>
    static void Swap(string path, Action<Stream> write)
    {
        var temp = path + ".folio-tmp";
        using (var output = File.Create(temp)) write(output);
        for (int attempt = 0; ; attempt++)
        {
            // The reader or a sync client may have the file open for a moment.
            try { File.Move(temp, path, overwrite: true); return; }
            catch (Exception e) when (attempt < 10 && e is IOException or UnauthorizedAccessException) { Thread.Sleep(60); }
        }
    }

    delegate Dictionary<int, List<IToken>> Edit(PdfDocument document, Func<int, PageInfo> page, Func<long> nextObject, Action<long, string> write);

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
            changed = edit(document, PageAt, NextObject, Write);
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
        if (changed.Count == 0 && offsets.Count == 0) return;

        // Cross-reference section and trailer for the update: a table, or a stream when the file's own is a stream (a
        // table after a stream is more than some readers, Core Graphics among them, accept).
        string trailerEntries()
        {
            var t = new StringBuilder();
            t.Append(CultureInfo.InvariantCulture, $"/Root {Serialize(new IndirectReferenceToken(trailer.Root))} /Prev {startXref}");
            if (trailer.Info is { } info) t.Append(" /Info ").Append(Serialize(info));
            if (trailer.Identifier is { Count: > 0 } ids) t.Append(" /ID [").Append(string.Join(' ', ids.Select(Serialize))).Append(']');
            return t.ToString();
        }
        byte[] xrefBytes;
        long xrefOffset;
        if (IsXrefStream(original, startXref))
        {
            long number = next++;
            xrefOffset = original.Length + body.Length + 1;
            var rows = offsets.Append((number, 0, xrefOffset)).OrderBy(o => o.Item1).ToList();
            var data = new MemoryStream();
            foreach (var (_, generation, offset) in rows)
            {
                data.WriteByte(1);
                data.Write([(byte)(offset >> 24), (byte)(offset >> 16), (byte)(offset >> 8), (byte)offset]);
                data.Write([(byte)(generation >> 8), (byte)generation]);
            }
            var index = string.Join(' ', rows.Select(r => $"{r.Item1} 1"));
            var head = $"\n{number} 0 obj\n<</Type /XRef /Size {Math.Max(size, next)} {trailerEntries()} /Index [{index}] /W [1 4 2] /Length {data.Length}>>\nstream\n";
            xrefBytes = [.. Encoding.Latin1.GetBytes(head), .. data.ToArray(), .. Encoding.ASCII.GetBytes($"\nendstream\nendobj\nstartxref\n{xrefOffset}\n%%EOF\n")];
        }
        else
        {
            xrefOffset = original.Length + body.Length;
            var xref = new StringBuilder("xref\n");
            foreach (var (number, generation, offset) in offsets.OrderBy(o => o.Number))
                xref.Append(CultureInfo.InvariantCulture, $"{number} 1\n{offset:D10} {generation:D5} n\r\n");
            xref.Append("trailer\n<<");
            xref.Append(CultureInfo.InvariantCulture, $"/Size {Math.Max(size, next)} ").Append(trailerEntries());
            xref.Append(CultureInfo.InvariantCulture, $">>\nstartxref\n{xrefOffset}\n%%EOF\n");
            xrefBytes = Encoding.ASCII.GetBytes(xref.ToString());
        }

        Swap(path, output =>
        {
            output.Write(original);
            body.Position = 0;
            body.CopyTo(output);
            output.Write(xrefBytes);
        });
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

    /// <summary>Whether the cross-reference section at offset is a stream ("12 0 obj <</Type /XRef …").</summary>
    static bool IsXrefStream(byte[] data, long offset)
    {
        if (offset < 0 || offset >= data.Length) return false;
        var head = Encoding.Latin1.GetString(data, (int)offset, (int)Math.Min(64, data.Length - offset)).TrimStart();
        return !head.StartsWith("xref", StringComparison.Ordinal) && head.Contains(" obj", StringComparison.Ordinal);
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
                stream = Appearance(a.Subtype, quads, [], r, g, b);
                break;
            }
            case "Ink":
            {
                var strokes = a.Strokes ?? [];
                rect = Bounds(strokes.SelectMany(s => Pairs(s)), pad: 2);
                extra = $"/InkList [{string.Join(' ', strokes.Select(s => "[" + string.Join(' ', s.Select(N)) + "]"))}] /BS << /W 2 >>";
                stream = Appearance("Ink", [], strokes, r, g, b);
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
            appearance = (apNumber, AppearanceObject(a.Subtype, rect, stream));
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

    /// <summary>The drawing of a markup or ink annotation in page coordinates.</summary>
    static string? Appearance(string subtype, IReadOnlyList<double[]> quads, IReadOnlyList<double[]> strokes, double r, double g, double b)
    {
        var sb = new StringBuilder();
        switch (subtype)
        {
            case "Highlight":
                sb.Append(CultureInfo.InvariantCulture, $"/GS0 gs {N(r)} {N(g)} {N(b)} rg ");
                foreach (var q in quads) sb.Append(CultureInfo.InvariantCulture, $"{N(q[0])} {N(q[1])} m {N(q[2])} {N(q[3])} l {N(q[6])} {N(q[7])} l {N(q[4])} {N(q[5])} l h f ");
                break;
            case "Underline" or "StrikeOut":
                sb.Append(CultureInfo.InvariantCulture, $"{N(r)} {N(g)} {N(b)} RG ");
                foreach (var q in quads)
                {
                    double height = Math.Abs(q[1] - q[5]);
                    double y = subtype == "Underline" ? Math.Min(q[5], q[7]) + height * 0.08 : (q[1] + q[5]) / 2;
                    sb.Append(CultureInfo.InvariantCulture, $"{N(Math.Max(0.6, height * 0.07))} w {N(q[4])} {N(y)} m {N(q[6])} {N(y)} l S ");
                }
                break;
            case "Ink":
                sb.Append(CultureInfo.InvariantCulture, $"{N(r)} {N(g)} {N(b)} RG 2 w 1 J 1 j ");
                foreach (var s in strokes)
                {
                    for (int i = 0; i + 1 < s.Length; i += 2) sb.Append(CultureInfo.InvariantCulture, $"{N(s[i])} {N(s[i + 1])} {(i == 0 ? "m" : "l")} ");
                    sb.Append("S ");
                }
                break;
            default:
                return null;
        }
        return sb.ToString();
    }

    static string AppearanceObject(string subtype, double[] rect, string stream)
    {
        // The form's coordinates are the page's: BBox = Rect, and Matrix stays the identity.
        var gs = subtype == "Highlight" ? "/Resources << /ExtGState << /GS0 << /BM /Multiply /CA 0.5 /ca 0.5 >> >> >> " : "";
        return $"<< /Type /XObject /Subtype /Form /BBox [{string.Join(' ', rect.Select(N))}] {gs}/Length {Encoding.ASCII.GetByteCount(stream)} >>\nstream\n{stream}\nendstream";
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
        StringToken s => s.Data.All(c => c is >= ' ' and <= '~') ? Str(s.Data) : "<" + Convert.ToHexString(s.GetBytes()) + ">",
        ArrayToken a => "[" + string.Join(' ', a.Data.Select(Serialize)) + "]",
        DictionaryToken d => "<<" + string.Concat(d.Data.Select(kv => $"/{EscapeName(kv.Key)} {Serialize(kv.Value)} ")) + ">>",
        _ => throw new NotSupportedException(token.GetType().Name),
    };
}
