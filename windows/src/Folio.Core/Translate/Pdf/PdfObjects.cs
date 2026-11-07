using System.IO.Compression;
using System.Runtime.CompilerServices;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Tokens;

namespace Folio.Core.Translate.Pdf;

/// <summary>
/// A parsed PDF for the engine: PdfPig reads the file structure (cross-reference, objects); these wrappers give the
/// typed access the macOS engine has through CGPDF (PDFDictionary.name/dict/array/stream/number …).
/// </summary>
public sealed class PdfSource : IDisposable
{
    public PdfDocument Document { get; }
    readonly ConditionalWeakTable<IToken, object> _keys = new();
    readonly Dictionary<IndirectReference, PDict> _dicts = [];
    readonly Dictionary<IndirectReference, PStream> _streams = [];
    long _nextKey = 1_000_000_000;

    PdfSource(PdfDocument document) { Document = document; }

    public static PdfSource Open(string path) => new(PdfDocument.Open(path, new ParsingOptions { UseLenientParsing = true, ClipPaths = false }));
    public static PdfSource Open(byte[] data) => new(PdfDocument.Open(data, new ParsingOptions { UseLenientParsing = true, ClipPaths = false }));

    public void Dispose() => Document.Dispose();

    public IToken? Resolve(IToken? token, int depth = 0)
    {
        while (token is IndirectReferenceToken r && depth++ < 32)
        {
            try { token = Document.Structure.GetObject(r.Data).Data; }
            catch { return null; }
        }
        return token;
    }

    /// <summary>A stable key for an object (pointer identity in the macOS engine).</summary>
    public long Key(IToken token, IndirectReference? reference)
    {
        if (reference is { } r) return ((long)r.ObjectNumber << 8) | (uint)(r.Generation & 0xFF);
        lock (_keys) return (long)_keys.GetValue(token, _ => Interlocked.Increment(ref _nextKey));
    }

    internal PDict? WrapDict(IToken? raw)
    {
        IndirectReference? reference = raw is IndirectReferenceToken r ? r.Data : null;
        var token = Resolve(raw);
        if (token is StreamToken s) token = s.StreamDictionary;
        if (token is not DictionaryToken d) return null;
        if (reference is { } key)
        {
            lock (_dicts)
            {
                if (_dicts.TryGetValue(key, out var cached)) return cached;
                return _dicts[key] = new PDict(this, d, reference);
            }
        }
        return new PDict(this, d, null);
    }

    internal PStream? WrapStream(IToken? raw)
    {
        IndirectReference? reference = raw is IndirectReferenceToken r ? r.Data : null;
        if (Resolve(raw) is not StreamToken s) return null;
        if (reference is { } key)
        {
            lock (_streams)
            {
                if (_streams.TryGetValue(key, out var cached)) return cached;
                return _streams[key] = new PStream(this, s, reference);
            }
        }
        return new PStream(this, s, null);
    }

    internal PArray? WrapArray(IToken? raw) => Resolve(raw) is ArrayToken a ? new PArray(this, a) : null;

    public PDict Trailer
    {
        get
        {
            var t = Document.Structure.CrossReferenceTable.Trailer;
            var entries = new Dictionary<NameToken, IToken> { [NameToken.Root] = new IndirectReferenceToken(t.Root) };
            if (t.Info is { } info) entries[NameToken.Info] = info;
            return new PDict(this, new DictionaryToken(entries), null);
        }
    }

    public PDict? Catalog => Trailer.Dict("Root");

    List<PDict>? _pages;

    /// <summary>The page dictionaries in order (with Parent links for inherited attributes).</summary>
    public List<PDict> Pages
    {
        get
        {
            if (_pages != null) return _pages;
            var result = new List<PDict>();
            void Walk(PDict node, int depth)
            {
                if (depth > 64) return;
                if (node.Name("Type") == "Page" || node.Array("Kids") == null) { result.Add(node); return; }
                var kids = node.Array("Kids")!;
                for (int i = 0; i < kids.Count; i++) if (kids.Dict(i) is { } kid) Walk(kid, depth + 1);
            }
            if (Catalog?.Dict("Pages") is { } root) Walk(root, 0);
            return _pages = result;
        }
    }
}

/// <summary>A dictionary (or a stream's dictionary) of a PdfSource.</summary>
public sealed class PDict(PdfSource source, DictionaryToken token, IndirectReference? reference)
{
    public PdfSource Source { get; } = source;
    public DictionaryToken Token { get; } = token;
    public IndirectReference? Reference { get; } = reference;
    public long Key => Source.Key(Token, Reference);

    IToken? Raw(string key) => Token.Data.TryGetValue(key, out var v) ? v : null;
    public IToken? Object(string key) => Source.Resolve(Raw(key));
    public IToken? RawObject(string key) => Raw(key);
    public bool Contains(string key) => Token.Data.ContainsKey(key);

    public string? Name(string key) => Object(key) is NameToken n ? n.Data : null;
    public PDict? Dict(string key) => Object(key) is DictionaryToken ? Source.WrapDict(Raw(key)) : null;
    public PArray? Array(string key) => Source.WrapArray(Raw(key));
    public PStream? Stream(string key) => Source.WrapStream(Raw(key));
    public double? Number(string key) => Object(key) is NumericToken n ? n.Double : null;
    public bool? Bool(string key) => Object(key) is BooleanToken b ? b.Data : null;
    public byte[]? String(string key) => Object(key) switch
    {
        StringToken s => s.GetBytes(),
        HexToken h => h.Bytes.ToArray(),
        _ => null,
    };

    public IEnumerable<(string Key, IToken Raw)> Entries => Token.Data.Select(kv => (kv.Key, kv.Value));

    public Affine? Matrix(string key)
    {
        var n = Array(key)?.Numbers();
        return n is { Count: 6 } ? new Affine(n[0], n[1], n[2], n[3], n[4], n[5]) : null;
    }

    public Rect? Rect(string key)
    {
        var n = Array(key)?.Numbers();
        if (n is not { Count: 4 }) return null;
        return new Rect(Math.Min(n[0], n[2]), Math.Min(n[1], n[3]), Math.Abs(n[2] - n[0]), Math.Abs(n[3] - n[1]));
    }

    /// <summary>An attribute a page inherits from its ancestors (Resources, MediaBox, Rotate …).</summary>
    public IToken? Inherited(string key)
    {
        PDict? node = this;
        for (int depth = 0; node != null && depth < 32; depth++)
        {
            if (node.Contains(key)) return node.RawObject(key);
            node = node.Dict("Parent");
        }
        return null;
    }

    public PDict? InheritedDict(string key) => Source.WrapDict(Inherited(key));
    public Rect? InheritedRect(string key)
    {
        var n = Source.WrapArray(Inherited(key))?.Numbers();
        if (n is not { Count: 4 }) return null;
        return new Rect(Math.Min(n[0], n[2]), Math.Min(n[1], n[3]), Math.Abs(n[2] - n[0]), Math.Abs(n[3] - n[1]));
    }

    public PDict? Resources => InheritedDict("Resources");

    /// <summary>Decoded page content: the stream, or the streams of the array joined with newlines.</summary>
    public byte[] Contents()
    {
        if (Stream("Contents") is { } stream) return stream.Data;
        if (Array("Contents") is not { } array) return [];
        var output = new MemoryStream();
        for (int i = 0; i < array.Count; i++)
        {
            if (array.Stream(i) is not { } s) continue;
            output.Write(s.Data);
            output.WriteByte(0x0A);
        }
        return output.ToArray();
    }
}

public sealed class PArray(PdfSource source, ArrayToken token)
{
    public ArrayToken Token { get; } = token;
    public int Count => Token.Data.Count;
    public IToken? Raw(int i) => i < Count ? Token.Data[i] : null;
    public IToken? Object(int i) => source.Resolve(Raw(i));
    public double? Number(int i) => Object(i) is NumericToken n ? n.Double : null;
    public string? Name(int i) => Object(i) is NameToken n ? n.Data : null;
    public PDict? Dict(int i) => Object(i) is DictionaryToken or StreamToken ? source.WrapDict(Raw(i)) : null;
    public PArray? Array(int i) => source.WrapArray(Raw(i));
    public PStream? Stream(int i) => source.WrapStream(Raw(i));
    public List<double> Numbers() => Enumerable.Range(0, Count).Select(i => Number(i) ?? 0).ToList();
}

/// <summary>Raw: decoded. Jpeg / Jpeg2000: the image file. Encoded: still in filters Folio does not decode
/// (CCITT fax, JBIG2): <see cref="PStream.Remaining"/> names them.</summary>
public enum StreamFormat { Raw, Jpeg, Jpeg2000, Encoded }

/// <summary>A stream of a PdfSource; Data is decoded (except JPEG / JPEG 2000 images, which stay as they are).</summary>
public sealed class PStream
{
    readonly StreamToken _token;
    byte[]? _data;
    StreamFormat _format;

    internal PStream(PdfSource source, StreamToken token, IndirectReference? reference)
    {
        _token = token;
        Reference = reference;
        Source = source;
        Dict = new PDict(source, token.StreamDictionary, reference);
    }

    public PdfSource Source { get; }
    public PDict Dict { get; }
    public IndirectReference? Reference { get; }
    public long Key => Source.Key(_token, Reference);

    public byte[] Data { get { Decode(); return _data!; } }
    public StreamFormat Format { get { Decode(); return _format; } }
    /// <summary>For <see cref="StreamFormat.Encoded"/>: the filters (and their parameters) still applied to Data.</summary>
    public List<(string Filter, PDict? Parms)> Remaining { get { Decode(); return _remaining; } }
    List<(string, PDict?)> _remaining = [];

    void Decode()
    {
        if (_data != null) return;
        lock (this)
        {
            if (_data != null) return;
            (_data, _format, _remaining) = Filters.Decode(_token.Data.ToArray(), Dict);
        }
    }
}

/// <summary>Stream filters used by content streams, fonts and images (PDF 32000-1 §7.4).</summary>
static class Filters
{
    public static (byte[] Data, StreamFormat Format, List<(string, PDict?)> Remaining) Decode(byte[] data, PDict dict)
    {
        var filters = new List<string>();
        var parms = new List<PDict?>();
        if (dict.Name("Filter") is { } single) { filters.Add(single); parms.Add(dict.Dict("DecodeParms")); }
        else if (dict.Array("Filter") is { } array)
        {
            var parmArray = dict.Array("DecodeParms");
            for (int i = 0; i < array.Count; i++) { filters.Add(array.Name(i) ?? ""); parms.Add(parmArray?.Dict(i)); }
        }
        for (int i = 0; i < filters.Count; i++)
        {
            switch (filters[i])
            {
                case "FlateDecode" or "Fl": data = Predict(Inflate(data), parms[i]); break;
                case "LZWDecode" or "LZW": data = Predict(Lzw(data, parms[i]?.Number("EarlyChange") ?? 1), parms[i]); break;
                case "ASCIIHexDecode" or "AHx": data = AsciiHex(data); break;
                case "ASCII85Decode" or "A85": data = Ascii85(data); break;
                case "RunLengthDecode" or "RL": data = RunLength(data); break;
                case "DCTDecode" or "DCT": return (data, StreamFormat.Jpeg, []);
                case "JPXDecode": return (data, StreamFormat.Jpeg2000, []);
                default:
                    return (data, StreamFormat.Encoded, Enumerable.Range(i, filters.Count - i).Select(k => (filters[k], parms[k])).ToList());
            }
        }
        return (data, StreamFormat.Raw, []);
    }

    public static byte[] Inflate(byte[] data)
    {
        var output = new MemoryStream();
        try
        {
            // zlib header present in well-formed streams; fall back to raw deflate.
            bool zlib = data.Length > 2 && (data[0] & 0x0F) == 8 && ((data[0] << 8) | data[1]) % 31 == 0;
            using var input = new MemoryStream(data, zlib ? 2 : 0, data.Length - (zlib ? 2 : 0));
            using var inflater = new DeflateStream(input, CompressionMode.Decompress);
            var buffer = new byte[81920];
            int n;
            while (true)
            {
                try { n = inflater.Read(buffer, 0, buffer.Length); }
                catch (InvalidDataException) { break; }
                if (n <= 0) break;
                output.Write(buffer, 0, n);
            }
        }
        catch (InvalidDataException) { }
        return output.ToArray();
    }

    public static byte[] Deflate(byte[] data)
    {
        var output = new MemoryStream();
        using (var z = new ZLibStream(output, CompressionLevel.Optimal, leaveOpen: true)) z.Write(data);
        return output.ToArray();
    }

    static byte[] Predict(byte[] data, PDict? parms)
    {
        int predictor = (int)(parms?.Number("Predictor") ?? 1);
        if (predictor < 2) return data;
        int colors = (int)(parms?.Number("Colors") ?? 1), bpc = (int)(parms?.Number("BitsPerComponent") ?? 8), columns = (int)(parms?.Number("Columns") ?? 1);
        int bpp = Math.Max(1, colors * bpc / 8);
        int rowLength = (colors * bpc * columns + 7) / 8;
        if (predictor == 2)
        {
            if (bpc != 8) return data;
            var result = (byte[])data.Clone();
            for (int row = 0; row + rowLength <= result.Length; row += rowLength)
                for (int i = bpp; i < rowLength; i++) result[row + i] = (byte)(result[row + i] + result[row + i - bpp]);
            return result;
        }
        var output = new MemoryStream();
        var previous = new byte[rowLength];
        var current = new byte[rowLength];
        for (int pos = 0; pos < data.Length;)
        {
            int type = data[pos++];
            int n = Math.Min(rowLength, data.Length - pos);
            Array.Clear(current);
            Array.Copy(data, pos, current, 0, n);
            pos += n;
            for (int i = 0; i < rowLength; i++)
            {
                int left = i >= bpp ? current[i - bpp] : 0, up = previous[i], upLeft = i >= bpp ? previous[i - bpp] : 0;
                current[i] = type switch
                {
                    1 => (byte)(current[i] + left),
                    2 => (byte)(current[i] + up),
                    3 => (byte)(current[i] + (left + up) / 2),
                    4 => (byte)(current[i] + Paeth(left, up, upLeft)),
                    _ => current[i],
                };
            }
            output.Write(current, 0, rowLength);
            (previous, current) = (current, previous);
        }
        return output.ToArray();
    }

    static int Paeth(int a, int b, int c)
    {
        int p = a + b - c, pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    static byte[] AsciiHex(byte[] data)
    {
        var output = new List<byte>();
        int? high = null;
        foreach (var c in data)
        {
            if (c == (byte)'>') break;
            int v = c is >= (byte)'0' and <= (byte)'9' ? c - '0' : c is >= (byte)'A' and <= (byte)'F' ? c - 'A' + 10 : c is >= (byte)'a' and <= (byte)'f' ? c - 'a' + 10 : -1;
            if (v < 0) continue;
            if (high is { } h) { output.Add((byte)(h << 4 | v)); high = null; } else high = v;
        }
        if (high is { } last) output.Add((byte)(last << 4));
        return output.ToArray();
    }

    static byte[] Ascii85(byte[] data)
    {
        var output = new List<byte>();
        var group = new List<int>();
        int start = 0;
        if (data.Length >= 2 && data[0] == '<' && data[1] == '~') start = 2;
        for (int i = start; i < data.Length; i++)
        {
            byte c = data[i];
            if (c == '~') break;
            if (c is (byte)' ' or (byte)'\n' or (byte)'\r' or (byte)'\t' or 0 or 12) continue;
            if (c == 'z' && group.Count == 0) { output.AddRange([0, 0, 0, 0]); continue; }
            if (c < '!' || c > 'u') continue;
            group.Add(c - '!');
            if (group.Count == 5)
            {
                uint v = 0;
                foreach (var g in group) v = v * 85 + (uint)g;
                output.AddRange([(byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v]);
                group.Clear();
            }
        }
        if (group.Count > 1)
        {
            int n = group.Count;
            while (group.Count < 5) group.Add(84);
            uint v = 0;
            foreach (var g in group) v = v * 85 + (uint)g;
            var bytes = new[] { (byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v };
            output.AddRange(bytes.Take(n - 1));
        }
        return output.ToArray();
    }

    static byte[] RunLength(byte[] data)
    {
        var output = new List<byte>();
        for (int i = 0; i < data.Length;)
        {
            int length = data[i++];
            if (length == 128) break;
            if (length < 128)
            {
                for (int k = 0; k <= length && i < data.Length; k++) output.Add(data[i++]);
            }
            else if (i < data.Length)
            {
                var b = data[i++];
                for (int k = 0; k < 257 - length; k++) output.Add(b);
            }
        }
        return output.ToArray();
    }

    static byte[] Lzw(byte[] data, double earlyChange)
    {
        var output = new List<byte>();
        var table = new List<byte[]>();
        void Reset()
        {
            table.Clear();
            for (int i = 0; i < 256; i++) table.Add([(byte)i]);
            table.Add([]); table.Add([]);
        }
        Reset();
        int bitPos = 0, codeLength = 9;
        byte[]? previous = null;
        int early = (int)earlyChange;
        while (true)
        {
            int code = 0;
            for (int k = 0; k < codeLength; k++)
            {
                int byteIndex = (bitPos + k) >> 3;
                if (byteIndex >= data.Length) return output.ToArray();
                int bit = (data[byteIndex] >> (7 - ((bitPos + k) & 7))) & 1;
                code = (code << 1) | bit;
            }
            bitPos += codeLength;
            if (code == 256) { Reset(); codeLength = 9; previous = null; continue; }
            if (code == 257) break;
            byte[] entry;
            if (code < table.Count) entry = table[code];
            else if (previous != null) entry = [.. previous, previous[0]];
            else break;
            output.AddRange(entry);
            if (previous != null) table.Add([.. previous, entry[0]]);
            previous = entry;
            int size = table.Count + early;
            codeLength = size >= 2048 ? 12 : size >= 1024 ? 11 : size >= 512 ? 10 : 9;
        }
        return output.ToArray();
    }
}
