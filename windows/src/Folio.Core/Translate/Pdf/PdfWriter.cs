using System.Globalization;
using System.Text;
using Folio.Core.Translate.Layout;
using UglyToad.PdfPig.Tokens;

namespace Folio.Core.Translate.Pdf;

// Ports of macos/.../FolioTranslate/PDF/PDFWriter.swift, PDFCopier.swift, ContentEditor.swift and PDFComposer.swift.

/// <summary>A PDF object as written to a new file.</summary>
public abstract record PdfValue
{
    public sealed record NullV : PdfValue;
    public sealed record BoolV(bool Value) : PdfValue;
    public sealed record IntV(long Value) : PdfValue;
    public sealed record RealV(double Value) : PdfValue;
    public sealed record NameV(string Value) : PdfValue;
    public sealed record StringV(byte[] Value) : PdfValue;
    public sealed record ArrayV(List<PdfValue> Items) : PdfValue;
    public sealed record DictV(Dictionary<string, PdfValue> Entries) : PdfValue;
    public sealed record RefV(int Number) : PdfValue;

    public static readonly PdfValue Null = new NullV();
    public static PdfValue Int(long v) => new IntV(v);
    public static PdfValue Real(double v) => new RealV(v);
    public static PdfValue Name(string v) => new NameV(v);
    public static PdfValue Str(byte[] v) => new StringV(v);
    public static PdfValue Array(IEnumerable<PdfValue> v) => new ArrayV(v.ToList());
    public static PdfValue Dict(Dictionary<string, PdfValue> v) => new DictV(v);
    public static PdfValue Ref(int n) => new RefV(n);
    public static PdfValue RectValue(Rect r) => Array([Real(r.MinX), Real(r.MinY), Real(r.MaxX), Real(r.MaxY)]);
    public static PdfValue MatrixValue(Affine t) => Array([Real(t.A), Real(t.B), Real(t.C), Real(t.D), Real(t.Tx), Real(t.Ty)]);

    public Dictionary<string, PdfValue>? DictValue => this is DictV d ? d.Entries : null;

    public void Serialize(Stream output)
    {
        switch (this)
        {
            case NullV: Write(output, "null"); break;
            case BoolV b: Write(output, b.Value ? "true" : "false"); break;
            case IntV i: Write(output, i.Value.ToString(CultureInfo.InvariantCulture)); break;
            case RealV r: Write(output, Format(r.Value)); break;
            case NameV n: AppendName(n.Value, output); break;
            case StringV s: AppendString(s.Value, output); break;
            case ArrayV a:
                output.WriteByte((byte)'[');
                for (int k = 0; k < a.Items.Count; k++)
                {
                    if (k > 0) output.WriteByte((byte)' ');
                    a.Items[k].Serialize(output);
                }
                output.WriteByte((byte)']');
                break;
            case DictV d:
                Write(output, "<<");
                foreach (var key in d.Entries.Keys.OrderBy(k => k, StringComparer.Ordinal))
                {
                    AppendName(key, output);
                    output.WriteByte((byte)' ');
                    d.Entries[key].Serialize(output);
                }
                Write(output, ">>");
                break;
            case RefV r: Write(output, $"{r.Number} 0 R"); break;
        }
    }

    static void Write(Stream s, string text) => s.Write(Encoding.ASCII.GetBytes(text));

    /// <summary>Plain decimal notation (PDF has no exponents), at most 4 decimals.</summary>
    public static string Format(double value)
    {
        if (!double.IsFinite(value)) return "0";
        if (value == Math.Round(value) && Math.Abs(value) < 1e15) return ((long)value).ToString(CultureInfo.InvariantCulture);
        var s = value.ToString("F4", CultureInfo.InvariantCulture).TrimEnd('0').TrimEnd('.');
        return s == "-0" ? "0" : s;
    }

    public static void AppendName(string name, Stream output)
    {
        output.WriteByte((byte)'/');
        foreach (var b in Encoding.UTF8.GetBytes(name))
        {
            bool delimiter = "()<>[]{}/%#".Contains((char)b);
            if (b < 33 || b > 126 || delimiter) Write(output, $"#{b:X2}");
            else output.WriteByte(b);
        }
    }

    public static void AppendString(byte[] data, Stream output)
    {
        output.WriteByte((byte)'(');
        foreach (var b in data)
        {
            switch (b)
            {
                case (byte)'(' or (byte)')' or (byte)'\\': output.WriteByte((byte)'\\'); output.WriteByte(b); break;
                case 13: Write(output, "\\r"); break;
                default: output.WriteByte(b); break;
            }
        }
        output.WriteByte((byte)')');
    }
}

/// <summary>Writes a new PDF file object by object. Objects are numbered from 1; streams are Flate-compressed.</summary>
public sealed class PdfWriter
{
    readonly List<byte[]?> _bodies = [];
    public int Count => _bodies.Count;
    /// <summary>Objects are numbered from Offset + 1 (an incremental update numbers its objects after the file's).</summary>
    public int Offset { get; init; }

    public int Reserve() { _bodies.Add(null); return _bodies.Count + Offset; }

    /// <summary>The objects written, by number (an incremental update writes them after the file).</summary>
    public IEnumerable<(int Number, byte[] Body)> Objects => _bodies.Select((b, i) => (i + 1 + Offset, b ?? "null"u8.ToArray()));

    public void Set(int number, PdfValue value)
    {
        var ms = new MemoryStream();
        value.Serialize(ms);
        _bodies[number - 1 - Offset] = ms.ToArray();
    }

    public int Add(PdfValue value)
    {
        int n = Reserve();
        Set(n, value);
        return n;
    }

    /// <summary>A stream object. Encoded data already carries its filter in dict; otherwise the data is compressed here.</summary>
    public void SetStream(int number, Dictionary<string, PdfValue> dict, byte[] data, bool compress = true)
    {
        var d = new Dictionary<string, PdfValue>(dict);
        var payload = data;
        if (compress && data.Length > 64)
        {
            payload = Filters.Deflate(data);
            d["Filter"] = PdfValue.Name("FlateDecode");
        }
        d["Length"] = PdfValue.Int(payload.Length);
        var body = new MemoryStream();
        PdfValue.Dict(d).Serialize(body);
        body.Write("\nstream\n"u8);
        body.Write(payload);
        body.Write("\nendstream"u8);
        _bodies[number - 1 - Offset] = body.ToArray();
    }

    public void SetRaw(int number, byte[] body) => _bodies[number - 1 - Offset] = body;
    public byte[]? Raw(int number) => _bodies[number - 1 - Offset];

    public int AddStream(Dictionary<string, PdfValue> dict, byte[] data, bool compress = true)
    {
        int n = Reserve();
        SetStream(n, dict, data, compress);
        return n;
    }

    /// <summary>The complete file. Unset objects are written as null.</summary>
    public byte[] Finish(int root, int? info)
    {
        var output = new MemoryStream();
        output.Write("%PDF-1.7\n%"u8);
        output.Write([0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);
        var offsets = new List<long>(_bodies.Count);
        for (int i = 0; i < _bodies.Count; i++)
        {
            offsets.Add(output.Length);
            output.Write(Encoding.ASCII.GetBytes($"{i + 1} 0 obj\n"));
            output.Write(_bodies[i] ?? "null"u8.ToArray());
            output.Write("\nendobj\n"u8);
        }
        long xref = output.Length;
        var table = new StringBuilder($"xref\n0 {_bodies.Count + 1}\n0000000000 65535 f \n");
        foreach (var offset in offsets) table.Append(offset.ToString("D10", CultureInfo.InvariantCulture)).Append(" 00000 n \n");
        output.Write(Encoding.ASCII.GetBytes(table.ToString()));
        var trailer = new Dictionary<string, PdfValue> { ["Size"] = PdfValue.Int(_bodies.Count + 1), ["Root"] = PdfValue.Ref(root) };
        if (info is { } i2) trailer["Info"] = PdfValue.Ref(i2);
        output.Write("trailer\n"u8);
        PdfValue.Dict(trailer).Serialize(output);
        output.Write(Encoding.ASCII.GetBytes($"\nstartxref\n{xref}\n%%EOF\n"));
        return output.ToArray();
    }
}

/// <summary>Encoded stream data by source stream, kept across documents written from the same source.</summary>
public sealed class StreamDataCache
{
    public sealed record Entry(byte[] Payload, string? Filter);
    readonly Dictionary<long, Entry> _entries = [];
    public Entry? Get(long key) { lock (_entries) return _entries.GetValueOrDefault(key); }
    public void Store(Entry entry, long key) { lock (_entries) _entries[key] = entry; }
}

/// <summary>
/// Copies objects of a parsed document into a PdfWriter. Every dictionary and stream becomes an indirect object
/// (written once, cycles terminate); arrays are copied inline. Stream data comes out decoded and is compressed again
/// (JPEG / JPEG 2000 images stay as they are).
/// </summary>
public sealed class PdfCopier(PdfWriter writer, PdfSource source)
{
    public PdfWriter Writer { get; } = writer;
    public PdfSource Source { get; } = source;
    public StreamDataCache? StreamCache { get; set; }
    /// <summary>New data for a stream (decoded), or null to copy it as it is: subsets of embedded fonts, for example.</summary>
    public Func<PStream, byte[]?>? Transform { get; set; }
    readonly Dictionary<long, int> _copied = [];
    /// <summary>Output page object for each source page dictionary; page references elsewhere point at it.</summary>
    public Dictionary<long, int> PageMap { get; } = [];
    /// <summary>Writing an incremental update of the source itself: its objects are referred to where they are, not
    /// copied.</summary>
    public bool InPlace { get; init; }

    public PdfValue Copy(IToken? raw)
    {
        var token = Source.Resolve(raw);
        switch (token)
        {
            case null or NullToken: return PdfValue.Null;
            case BooleanToken b: return new PdfValue.BoolV(b.Data);
            case NumericToken n: return n.Double == Math.Floor(n.Double) && Math.Abs(n.Double) < 1e15 ? PdfValue.Int((long)n.Double) : PdfValue.Real(n.Double);
            case NameToken n: return PdfValue.Name(n.Data);
            case StringToken s: return PdfValue.Str(s.GetBytes());
            case HexToken h: return PdfValue.Str(h.Bytes.ToArray());
            case ArrayToken a: return PdfValue.Array(a.Data.Select(Copy));
            case StreamToken: return Source.WrapStream(raw) is { } stream ? Copy(stream) : PdfValue.Null;
            case DictionaryToken: return Source.WrapDict(raw) is { } dict ? Copy(dict) : PdfValue.Null;
            default: return PdfValue.Null;
        }
    }

    /// <summary>The dictionary as an indirect object. Pages become references to their output page (or null).</summary>
    public PdfValue Copy(PDict dictionary)
    {
        if (InPlace && dictionary.Reference is { } own) return PdfValue.Ref((int)own.ObjectNumber);
        var key = dictionary.Key;
        if (PageMap.TryGetValue(key, out var page)) return PdfValue.Ref(page);
        if (_copied.TryGetValue(key, out var number)) return PdfValue.Ref(number);
        var type = dictionary.Name("Type");
        if (type is "Page" or "Pages") return PdfValue.Null;
        number = Writer.Reserve();
        _copied[key] = number;
        Writer.Set(number, PdfValue.Dict(Entries(dictionary)));
        return PdfValue.Ref(number);
    }

    public Dictionary<string, PdfValue> Entries(PDict dictionary, IReadOnlySet<string>? skip = null)
    {
        var result = new Dictionary<string, PdfValue>();
        foreach (var (name, raw) in dictionary.Entries)
            if (skip == null || !skip.Contains(name)) result[name] = Copy(raw);
        return result;
    }

    static readonly HashSet<string> StreamSkip = ["Length", "Filter", "DecodeParms", "F", "FFilter", "FDecodeParms", "DL"];

    public PdfValue Copy(PStream stream)
    {
        if (InPlace && stream.Reference is { } own) return PdfValue.Ref((int)own.ObjectNumber);
        var key = stream.Key;
        if (_copied.TryGetValue(key, out var existing)) return PdfValue.Ref(existing);
        int number = Writer.Reserve();
        _copied[key] = number;
        var dict = Entries(stream.Dict, StreamSkip);
        if (StreamCache?.Get(key) is { } cached)
        {
            if (cached.Filter is { } f) dict["Filter"] = PdfValue.Name(f);
            Writer.SetStream(number, dict, cached.Payload, compress: false);
            return PdfValue.Ref(number);
        }
        var data = stream.Data;
        var format = stream.Format;
        if (format != StreamFormat.Jpeg && format != StreamFormat.Jpeg2000 && Transform?.Invoke(stream) is { } replaced)
        {
            data = replaced;
            if (dict.ContainsKey("Length1")) dict["Length1"] = PdfValue.Int(data.Length);
        }
        switch (format)
        {
            case StreamFormat.Jpeg:
                dict["Filter"] = PdfValue.Name("DCTDecode");
                Writer.SetStream(number, dict, data, compress: false);
                break;
            case StreamFormat.Jpeg2000:
                dict["Filter"] = PdfValue.Name("JPXDecode");
                Writer.SetStream(number, dict, data, compress: false);
                break;
            case StreamFormat.Encoded:
            {
                var remaining = stream.Remaining;
                dict["Filter"] = remaining.Count == 1 ? PdfValue.Name(remaining[0].Filter) : PdfValue.Array(remaining.Select(r => PdfValue.Name(r.Filter)));
                if (remaining.Any(r => r.Parms != null))
                    dict["DecodeParms"] = remaining.Count == 1 ? Copy(remaining[0].Parms!)
                        : PdfValue.Array(remaining.Select(r => r.Parms is { } p ? Copy(p) : PdfValue.Null));
                Writer.SetStream(number, dict, data, compress: false);
                break;
            }
            default:
                Writer.SetStream(number, dict, data);
                break;
        }
        if (StreamCache != null && format != StreamFormat.Encoded && Writer.Raw(number) is { } body && Payload(body) is { } payload)
        {
            string? filter = format switch
            {
                StreamFormat.Jpeg => "DCTDecode",
                StreamFormat.Jpeg2000 => "JPXDecode",
                _ => payload.Length == data.Length ? null : "FlateDecode",
            };
            StreamCache.Store(new StreamDataCache.Entry(payload, filter), key);
        }
        return PdfValue.Ref(number);
    }

    /// <summary>The bytes between "\nstream\n" and "\nendstream" of a serialized stream object.</summary>
    public static byte[]? Payload(byte[] body)
    {
        int start = body.AsSpan().IndexOf("\nstream\n"u8);
        int end = body.AsSpan().LastIndexOf("\nendstream"u8);
        if (start < 0 || end < 0 || start + 8 > end) return null;
        return body[(start + 8)..end];
    }
}

/// <summary>What to do with one operator when a content stream is rewritten.</summary>
public abstract record EditAction
{
    /// <summary>Leave it out (a ' or " keeps its move to the next line).</summary>
    public sealed record Drop : EditAction;
    /// <summary>Draw it invisibly (3 Tr), so text after it keeps its position; Restore is the mode to switch back to.</summary>
    public sealed record Hide(int Restore) : EditAction;
    /// <summary>Write these operators instead (a show operator with some glyphs taken out).</summary>
    public sealed record Replace(byte[] Data) : EditAction
    {
        public bool Equals(Replace? other) => other != null && Data.AsSpan().SequenceEqual(other.Data);
        public override int GetHashCode() => Data.Length;
    }

    public static readonly EditAction DropAction = new Drop();
}

/// <summary>Rewrites interpreted content streams with some operators removed; edited forms are written again.</summary>
public sealed class ContentEditor(Dictionary<StreamPath, InterpretedStream> streams, Dictionary<OpLocation, EditAction> edits, PdfCopier copier, string namePrefix = "FolioE")
{
    HashSet<StreamPath> EditedStreams()
    {
        var result = new HashSet<StreamPath>();
        foreach (var location in edits.Keys)
        {
            StreamPath? path = location.Stream;
            while (path != null)
            {
                result.Add(path);
                path = path.Parent;
            }
        }
        return result;
    }

    /// <summary>The page's new content and the resources it needs: the page's own resources plus the rewritten forms.</summary>
    public (byte[] Content, Dictionary<string, PdfValue> Resources) PageContent()
    {
        var touched = EditedStreams();
        int counter = 0;
        var (data, extra) = Rewrite(StreamPath.Root, touched, ref counter);
        return (data, Resources(streams.GetValueOrDefault(StreamPath.Root)?.Resources, extra));
    }

    public Dictionary<string, PdfValue> Resources(PDict? source, Dictionary<string, PdfValue> extra)
    {
        var result = source != null ? copier.Entries(source) : [];
        if (extra.Count == 0) return result;
        var xobjects = source?.Dict("XObject") is { } x ? copier.Entries(x) : new Dictionary<string, PdfValue>();
        foreach (var (k, v) in extra) xobjects[k] = v;
        result["XObject"] = PdfValue.Dict(xobjects);
        return result;
    }

    static readonly HashSet<string> FormSkip = ["Length", "Filter", "DecodeParms", "Resources"];

    (byte[], Dictionary<string, PdfValue>) Rewrite(StreamPath path, HashSet<StreamPath> touched, ref int counter)
    {
        if (!streams.TryGetValue(path, out var stream)) return ([], []);
        var output = new MemoryStream(stream.Source.Length);
        var extra = new Dictionary<string, PdfValue>();
        for (int index = 0; index < stream.Ops.Count; index++)
        {
            var op = stream.Ops[index];
            var location = new OpLocation(path, index);
            if (edits.TryGetValue(location, out var action))
            {
                switch (action)
                {
                    case EditAction.Drop:
                        if (op.Name == "'") output.Write("T*\n"u8);
                        else if (op.Name == "\"" && op.Operands.Count == 3)
                            output.Write(Encoding.ASCII.GetBytes($"{PdfValue.Format(op.Operands[0].AsNumber ?? 0)} Tw {PdfValue.Format(op.Operands[1].AsNumber ?? 0)} Tc T*\n"));
                        break;
                    case EditAction.Hide hide:
                        output.Write("3 Tr\n"u8);
                        output.Write(stream.Source, op.Start, op.Length);
                        output.Write(Encoding.ASCII.GetBytes($"\n{hide.Restore} Tr\n"));
                        break;
                    case EditAction.Replace replace:
                        output.Write(replace.Data);
                        output.WriteByte(0x0A);
                        break;
                }
                continue;
            }
            var formPath = path.Appending(index);
            if (op.Name == "Do" && touched.Contains(formPath) && streams.TryGetValue(formPath, out var form) && form.Form is { } formStream)
            {
                var (content, innerExtra) = Rewrite(formPath, touched, ref counter);
                var dict = copier.Entries(formStream.Dict, FormSkip);
                dict["Resources"] = PdfValue.Dict(Resources(form.Resources, innerExtra));
                int number = copier.Writer.AddStream(dict, content);
                counter++;
                var name = $"{namePrefix}{counter}";
                extra[name] = PdfValue.Ref(number);
                output.Write(Encoding.ASCII.GetBytes($"/{name} Do\n"));
                continue;
            }
            output.Write(stream.Source, op.Start, op.Length);
            output.WriteByte(0x0A);
        }
        return (output.ToArray(), extra);
    }
}

/// <summary>
/// Builds a new PDF out of pages of an existing one: each output page draws form XObjects made from source pages
/// (edited or not) and from other documents' pages, plus its own content. Links, named destinations and the
/// outline of the source are carried over, pointing at the output pages.
/// </summary>
public sealed class PdfComposer
{
    public PdfSource Source { get; }
    public PdfWriter Writer { get; } = new();
    public PdfCopier Copier { get; }
    readonly int _pagesNode;
    readonly List<int> _kids = [];
    readonly Dictionary<int, int> _reserved = [];
    readonly Dictionary<PdfSource, PdfCopier> _foreign = [];
    readonly Dictionary<int, int> _plainForms = [];

    public PdfComposer(PdfSource source, StreamDataCache? cache = null)
    {
        Source = source;
        Copier = new PdfCopier(Writer, source) { StreamCache = cache };
        _pagesNode = Writer.Reserve();
    }

    public sealed record PageGeometry(Rect MediaBox, Rect CropBox, int Rotation);

    public static PageGeometry Geometry(PDict page)
    {
        var media = page.InheritedRect("MediaBox") ?? new Rect(0, 0, 612, 792);
        var crop = (page.InheritedRect("CropBox") ?? media).Intersection(media);
        if (crop.IsNull || crop.W < 1) crop = media;
        int rotation = (int)(page.Source.Resolve(page.Inherited("Rotate")) is NumericToken n ? n.Int : 0);
        rotation = ((rotation % 360) + 360) % 360 / 90 * 90;
        return new PageGeometry(media, crop, rotation);
    }

    PDict? SourcePage(int number) => number >= 1 && number <= Source.Pages.Count ? Source.Pages[number - 1] : null;

    public PageGeometry? GeometryOfSourcePage(int number) => SourcePage(number) is { } p ? Geometry(p) : null;

    public int ReserveOutputPage(int number)
    {
        if (_reserved.TryGetValue(number, out var existing)) return existing;
        int obj = Writer.Reserve();
        _reserved[number] = obj;
        if (SourcePage(number) is { } dict) Copier.PageMap[dict.Key] = obj;
        return obj;
    }

    /// <summary>A form XObject showing source page number (1-based), rewritten with edits when there are any.</summary>
    public int? PageForm(int number, ContentInterpreter? interpreter = null, Dictionary<OpLocation, EditAction>? edits = null, string namePrefix = "FolioE")
    {
        edits ??= [];
        if (edits.Count == 0 && _plainForms.TryGetValue(number, out var cached)) return cached;
        if (SourcePage(number) is not { } dict) return null;
        var media = Geometry(dict).MediaBox;
        byte[] content;
        Dictionary<string, PdfValue> resources;
        if (edits.Count == 0 || interpreter == null)
        {
            content = dict.Contents();
            resources = dict.Resources is { } r ? Copier.Entries(r) : [];
        }
        else (content, resources) = new ContentEditor(interpreter.Streams, edits, Copier, namePrefix).PageContent();
        var form = new Dictionary<string, PdfValue>
        {
            ["Type"] = PdfValue.Name("XObject"), ["Subtype"] = PdfValue.Name("Form"), ["BBox"] = PdfValue.RectValue(media), ["Resources"] = PdfValue.Dict(resources),
        };
        if (dict.RawObject("Group") is { } group) form["Group"] = Copier.Copy(group);
        int obj = Writer.AddStream(form, [.. "q\n"u8, .. content, .. "\nQ\n"u8]);
        if (edits.Count == 0) _plainForms[number] = obj;
        return obj;
    }

    /// <summary>A form XObject showing page number of another document (for example text drawn for the translation).</summary>
    public int? ForeignPageForm(PdfSource document, int number, Func<PStream, byte[]?>? transform = null)
    {
        if (!_foreign.TryGetValue(document, out var foreign)) _foreign[document] = foreign = new PdfCopier(Writer, document) { Transform = transform };
        if (number < 1 || number > document.Pages.Count) return null;
        var dict = document.Pages[number - 1];
        var media = Geometry(dict).MediaBox;
        var resources = dict.Resources is { } r ? foreign.Entries(r) : [];
        return Writer.AddStream(new Dictionary<string, PdfValue>
        {
            ["Type"] = PdfValue.Name("XObject"), ["Subtype"] = PdfValue.Name("Form"), ["BBox"] = PdfValue.RectValue(media), ["Resources"] = PdfValue.Dict(resources),
        }, [.. "q\n"u8, .. dict.Contents(), .. "\nQ\n"u8]);
    }

    static readonly HashSet<string> LinkSkip = ["P", "Parent", "StructParent", "Popup"];

    /// <summary>Link annotations of a source page, moved by offset; placement says where links of moved words went.</summary>
    public List<PdfValue> Links(int number, Pt offset = default, Dictionary<int, List<Rect>>? placement = null)
    {
        if (SourcePage(number) is not { } dict) return [];
        var result = new List<PdfValue>();
        var annotations = PageLinks.Annotations(dict);
        for (int index = 0; index < annotations.Count; index++)
        {
            var annot = annotations[index];
            if (!Reachable(annot)) continue;
            var entries = Copier.Entries(annot, LinkSkip);
            if (placement?.GetValueOrDefault(index) is { } places)
            {
                entries.Remove("QuadPoints");
                foreach (var rect in places)
                {
                    entries["Rect"] = PdfValue.RectValue(rect.Offset(offset.X, offset.Y));
                    result.Add(PdfValue.Ref(Writer.Add(PdfValue.Dict(new Dictionary<string, PdfValue>(entries)))));
                }
                continue;
            }
            if (offset != Pt.Zero)
            {
                if (annot.Rect("Rect") is { } rect) entries["Rect"] = PdfValue.RectValue(rect.Offset(offset.X, offset.Y));
                if (annot.Array("QuadPoints") is { } quads)
                    entries["QuadPoints"] = PdfValue.Array(quads.Numbers().Select((v, i) => PdfValue.Real(v + (i % 2 == 0 ? offset.X : offset.Y))));
            }
            result.Add(PdfValue.Ref(Writer.Add(PdfValue.Dict(entries))));
        }
        return result;
    }

    bool Reachable(PDict annot)
    {
        if (_reserved.Count >= Source.Pages.Count) return true;
        var target = annot.RawObject("Dest");
        if (target == null && annot.Dict("A") is { } action)
        {
            if (action.Name("S") != "GoTo") return true;
            target = action.RawObject("D");
        }
        if (target == null || PdfDestinations.Page(Source, target) is not { } page) return true;
        return Copier.PageMap.ContainsKey(page.Key);
    }

    public int AddPage(Rect mediaBox, byte[] content, Dictionary<string, int> xobjects, int? obj = null, Rect? cropBox = null, int rotation = 0,
                       Dictionary<string, PdfValue>? fonts = null, List<PdfValue>? annotations = null)
    {
        int page = obj ?? Writer.Reserve();
        int contents = Writer.AddStream([], content);
        var resources = new Dictionary<string, PdfValue> { ["XObject"] = PdfValue.Dict(xobjects.ToDictionary(kv => kv.Key, kv => PdfValue.Ref(kv.Value))) };
        if (fonts is { Count: > 0 }) resources["Font"] = PdfValue.Dict(fonts);
        var dict = new Dictionary<string, PdfValue>
        {
            ["Type"] = PdfValue.Name("Page"), ["Parent"] = PdfValue.Ref(_pagesNode), ["MediaBox"] = PdfValue.RectValue(mediaBox),
            ["Contents"] = PdfValue.Ref(contents), ["Resources"] = PdfValue.Dict(resources),
        };
        if (cropBox is { } crop && crop != mediaBox) dict["CropBox"] = PdfValue.RectValue(crop);
        if (rotation % 360 != 0) dict["Rotate"] = PdfValue.Int(rotation);
        if (annotations is { Count: > 0 }) dict["Annots"] = PdfValue.Array(annotations);
        Writer.Set(page, PdfValue.Dict(dict));
        _kids.Add(page);
        return page;
    }

    public byte[] Finish(string? title = null)
    {
        Writer.Set(_pagesNode, PdfValue.Dict(new()
        {
            ["Type"] = PdfValue.Name("Pages"), ["Kids"] = PdfValue.Array(_kids.Select(PdfValue.Ref)), ["Count"] = PdfValue.Int(_kids.Count),
        }));
        var catalog = new Dictionary<string, PdfValue> { ["Type"] = PdfValue.Name("Catalog"), ["Pages"] = PdfValue.Ref(_pagesNode) };
        if (Source.Catalog is { } root)
        {
            if (root.Dict("Outlines") is { } outlines) catalog["Outlines"] = Copier.Copy(outlines);
            if (root.Dict("Dests") is { } dests) catalog["Dests"] = Copier.Copy(dests);
            if (root.Dict("Names")?.Dict("Dests") is { } named) catalog["Names"] = PdfValue.Dict(new() { ["Dests"] = Copier.Copy(named) });
            if (root.RawObject("OCProperties") is { } oc) catalog["OCProperties"] = Copier.Copy(oc);
            if (root.Name("PageMode") == "UseOutlines") catalog["PageMode"] = PdfValue.Name("UseOutlines");
        }
        int rootObj = Writer.Add(PdfValue.Dict(catalog));
        var info = new Dictionary<string, PdfValue> { ["Producer"] = PdfValue.Str(PdfText("Folio")) };
        if (title != null) info["Title"] = PdfValue.Str(PdfText(title));
        int infoObj = Writer.Add(PdfValue.Dict(info));
        return Writer.Finish(rootObj, infoObj);
    }

    /// <summary>A PDF text string: UTF-16BE with a byte order mark.</summary>
    public static byte[] PdfText(string text) => [0xFE, 0xFF, .. Encoding.BigEndianUnicode.GetBytes(text)];
}

/// <summary>Finds the page a destination is on.</summary>
public static class PdfDestinations
{
    public static PDict? Page(PdfSource source, IToken destination)
    {
        var resolved = source.Resolve(destination);
        switch (resolved)
        {
            case ArrayToken: return source.WrapArray(destination)?.Dict(0);
            case DictionaryToken: return source.WrapDict(destination)?.Array("D")?.Dict(0);
            case NameToken n: return Named(source, Encoding.UTF8.GetBytes(n.Data));
            case StringToken s: return Named(source, s.GetBytes());
            case HexToken h: return Named(source, h.Bytes.ToArray());
            default: return null;
        }
    }

    static PDict? Named(PdfSource source, byte[] name)
    {
        var catalog = source.Catalog;
        if (catalog == null) return null;
        if (catalog.Dict("Dests") is { } dests && dests.RawObject(Encoding.UTF8.GetString(name)) is { } obj && Page(source, obj) is { } found) return found;
        if (catalog.Dict("Names")?.Dict("Dests") is not { } tree) return null;
        return Lookup(source, name, tree, 0);
    }

    static PDict? Lookup(PdfSource source, byte[] name, PDict node, int depth)
    {
        if (depth >= 32) return null;
        if (node.Array("Names") is { } names)
        {
            for (int k = 0; k + 1 < names.Count; k += 2)
            {
                var key = names.Object(k) switch { StringToken s => s.GetBytes(), HexToken h => h.Bytes.ToArray(), _ => null };
                if (key == null || !key.AsSpan().SequenceEqual(name) || names.Raw(k + 1) is not { } value) continue;
                return Page(source, value);
            }
        }
        if (node.Array("Kids") is { } kids)
            for (int k = 0; k < kids.Count; k++)
                if (kids.Dict(k) is { } kid && Lookup(source, name, kid, depth + 1) is { } found) return found;
        return null;
    }
}
