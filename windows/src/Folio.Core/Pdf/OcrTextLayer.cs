using System.Globalization;
using System.Text;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Tokens;
using Folio.Core.Translate;
using Folio.Core.Translate.Pdf;

namespace Folio.Core;

/// <summary>A word recognised on a page image, in the image's pixels (origin top-left, y down).</summary>
public sealed record OcrWord(string Text, double X, double Y, double Width, double Height);

/// <summary>A line of words, left to right.</summary>
public sealed record OcrLine(IReadOnlyList<OcrWord> Words)
{
    /// <summary>How far the line is turned on the image (radians, clockwise): its words' boxes are then given as they would be
    /// with the image turned back by that about its origin (a tilting scan, the title up the side of a chart).</summary>
    public double Angle { get; init; }

    /// <summary>The boxes of the words together, on the image.</summary>
    public Rect Box
    {
        get
        {
            var rect = Words.Aggregate(Rect.Null, (r, w) => r.Union(new Rect(w.X, w.Y, w.Width, w.Height)));
            return Angle == 0 ? rect : rect.Applying(Affine.Rotation(Angle));
        }
    }

    public string Text => OcrTextLayer.Join(Words.Select(w => w.Text));
}

/// <summary>What was recognised on one page (1-based), in the coordinates of an image of the page as it is shown (crop
/// box, rotation applied) that is ImageWidth × ImageHeight large.</summary>
public sealed record OcrPageResult(int Page, double ImageWidth, double ImageHeight, IReadOnlyList<OcrLine> Lines)
{
    /// <summary>How far the image was turned (clockwise, degrees) past the page's own rotation to read it: a page scanned sideways.</summary>
    public int Turn { get; init; }
    /// <summary>The page had recognised text already: this takes its place.</summary>
    public bool Replaces { get; init; }
    public int Characters => Lines.Sum(l => l.Words.Sum(w => w.Text.Count(c => !char.IsWhiteSpace(c))));
}

/// <summary>
/// The invisible text layer OCR adds to a scanned page (OCR-01), as OCRmyPDF and Tesseract write it and as the macOS app
/// does (FolioTranslate OCRTextLayer.swift): text rendering mode 3 in a "glyphless" Type0 font (Identity-H, every glyph
/// empty and half an em wide, ToUnicode giving back the UTF-16 units), each word stretched (Tz) to its box on its line's
/// height, one text matrix per line. Written as an incremental update: the page images stay byte for byte.
/// </summary>
public static class OcrTextLayer
{
    public const string FontResource = "FolioOCR";
    const string BaseFont = "GlyphLessFont";
    const double GlyphWidth = 500, Descent = 0.2;

    readonly record struct Matrix(double A, double B, double C, double D, double Tx, double Ty)
    {
        /// <summary>This, then other.</summary>
        public Matrix Then(Matrix o) => new(A * o.A + B * o.C, A * o.B + B * o.D, C * o.A + D * o.C, C * o.B + D * o.D,
                                            Tx * o.A + Ty * o.C + o.Tx, Tx * o.B + Ty * o.D + o.Ty);
    }

    /// <summary>Maps the coordinates of a page image as shown (top-left origin, crop box with /Rotate applied) to user space.</summary>
    static Matrix DisplayToUser(PdfRect crop, int rotation, double imageWidth)
    {
        rotation = ((rotation % 360) + 360) % 360;
        double shownWidth = rotation % 180 == 0 ? crop.Width : crop.Height;
        double scale = shownWidth / Math.Max(imageWidth, 1);
        var toUser = rotation switch
        {
            90 => new Matrix(0, 1, 1, 0, crop.Left, crop.Bottom),
            180 => new Matrix(-1, 0, 0, 1, crop.Right, crop.Bottom),
            270 => new Matrix(0, -1, -1, 0, crop.Right, crop.Top),
            _ => new Matrix(1, 0, 0, -1, crop.Left, crop.Top),
        };
        return new Matrix(scale, 0, 0, scale, 0, 0).Then(toUser);
    }

    /// <summary>A point of the page's user space on an image of the page as shown (imageWidth wide).</summary>
    internal static (double X, double Y) UserToDisplay(Rect crop, int rotation, double imageWidth, double x, double y)
    {
        var m = DisplayToUser(new PdfRect(crop.MinX, crop.MinY, crop.MaxX, crop.MaxY), rotation, imageWidth);
        double det = m.A * m.D - m.B * m.C;
        if (Math.Abs(det) < 1e-12) return (0, 0);
        double dx = x - m.Tx, dy = y - m.Ty;
        return ((dx * m.D - dy * m.C) / det, (dy * m.A - dx * m.B) / det);
    }

    /// <summary>The page's user space → the pixels of an image of the page as shown (imageWidth wide).</summary>
    internal static Affine UserToImage(Rect crop, int rotation, double imageWidth)
    {
        var m = DisplayToUser(new PdfRect(crop.MinX, crop.MinY, crop.MaxX, crop.MaxY), rotation, imageWidth);
        return new Affine(m.A, m.B, m.C, m.D, m.Tx, m.Ty).Inverted();
    }

    public readonly record struct PdfRect(double Left, double Bottom, double Right, double Top)
    {
        public double Width => Right - Left;
        public double Height => Top - Bottom;
    }

    static string F(double v) => Math.Round(v, 4).ToString("0.####", CultureInfo.InvariantCulture);

    /// <summary>The page's text layer: one BT … ET drawing every word (and the spaces between words) invisibly.</summary>
    public static string Content(OcrPageResult result, PdfRect crop, int rotation, string font = FontResource)
    {
        var toUser = DisplayToUser(crop, rotation + result.Turn, result.ImageWidth);
        var out_ = new StringBuilder($"BT\n3 Tr\n/{font} 1 Tf\n");
        foreach (var line in result.Lines)
        {
            var words = line.Words.Where(w => w.Text.Length > 0 && w.Width > 0).ToList();
            if (words.Count == 0) continue;
            double top = words.Min(w => w.Y), bottom = words.Max(w => w.Y + w.Height);
            double height = bottom - top;
            if (height <= 0) continue;
            double baseline = bottom - height * Descent;
            double start = words[0].X;
            var m = new Matrix(height, 0, 0, -height, start, baseline);
            if (line.Angle != 0) m = m.Then(new Matrix(Math.Cos(line.Angle), Math.Sin(line.Angle), -Math.Sin(line.Angle), Math.Cos(line.Angle), 0, 0));
            m = m.Then(toUser);
            out_.Append($"{F(m.A)} {F(m.B)} {F(m.C)} {F(m.D)} {F(m.Tx)} {F(m.Ty)} Tm");
            double at = start;
            for (int i = 0; i < words.Count; i++)
            {
                var word = words[i];
                if (Math.Abs(word.X - at) > 1e-6) out_.Append($" {F((word.X - at) / height)} 0 Td");
                at = word.X;
                out_.Append(' ').Append(Show(word.Text, word.Width, height)).Append('\n');
                if (i + 1 < words.Count && NeedsSpace(word.Text, words[i + 1].Text))
                {
                    double gap = Math.Max(words[i + 1].X - (word.X + word.Width), height * 0.05);
                    out_.Append(' ').Append(Show(" ", gap, height)).Append('\n');
                }
            }
        }
        out_.Append("ET\n");
        return out_.ToString();
    }

    static string Show(string text, double width, double height)
    {
        double natural = text.Length * GlyphWidth / 1000 * height;
        double stretch = Math.Clamp(width / Math.Max(natural, 1e-6) * 100, 0.1, 100_000);
        var hex = new StringBuilder(text.Length * 4);
        foreach (char unit in text) hex.Append(((int)unit).ToString("X4"));
        return $"{F(stretch)} Tz <{hex}> Tj";
    }

    /// <summary>Words of scripts written without spaces (Chinese, Japanese) follow each other directly.</summary>
    public static bool NeedsSpace(string left, string right) =>
        left.Length > 0 && right.Length > 0 && !(IsCjk(char.ConvertToUtf32(left, left.Length - (char.IsLowSurrogate(left[^1]) && left.Length > 1 ? 2 : 1))) || IsCjk(char.ConvertToUtf32(right, 0)));

    public static bool IsCjk(int c) => c is >= 0x2E80 and <= 0x2FFF or >= 0x3000 and <= 0x303F or >= 0x3040 and <= 0x30FF or >= 0x3100 and <= 0x31FF
        or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xAC00 and <= 0xD7AF or >= 0xF900 and <= 0xFAFF or >= 0xFE30 and <= 0xFE4F
        or >= 0xFF00 and <= 0xFFEF or >= 0x20000 and <= 0x3FFFF;

    /// <summary>Words of a line joined as they are read.</summary>
    public static string Join(IEnumerable<string> words)
    {
        var text = new StringBuilder();
        foreach (var w in words.Where(w => w.Length > 0))
        {
            if (text.Length > 0 && NeedsSpace(text.ToString(), w)) text.Append(' ');
            text.Append(w);
        }
        return text.ToString();
    }

    /// <summary>The TrueType font the macOS app embeds too: 65535 empty glyphs, 500 units wide, the glyph of each UTF-16 unit being the
    /// one of its number. With one glyph for all characters macOS before 27 loses the text when PDFKit saves the file.</summary>
    public static readonly byte[] TrueType = MakeTrueType();

    static byte[] MakeTrueType()
    {
        const int glyphs = 65535;
        var @base = Convert.FromBase64String(TwoGlyphTrueType);
        static byte[] Word(long v) => [(byte)(v >> 8), (byte)v];
        static byte[] Long(long v) => [(byte)(v >> 24), (byte)(v >> 16), (byte)(v >> 8), (byte)v];
        static byte[] Words(params int[] v) => v.SelectMany(x => Word(x)).ToArray();
        long Read(long at, int count) { long v = 0; for (int k = 0; k < count; k++) v = v << 8 | @base[at + k]; return v; }
        var tables = new List<(string Name, byte[] Data)>();
        for (int k = 0; k < Read(4, 2); k++)
        {
            int record = 12 + k * 16;
            var name = Encoding.ASCII.GetString(@base, record, 4);
            var data = @base.AsSpan((int)Read(record + 8, 4), (int)Read(record + 12, 4)).ToArray();
            switch (name)
            {
                case "maxp": Word(glyphs).CopyTo(data, 4); break;
                case "hhea": Word(1).CopyTo(data, 34); break;
                case "hmtx": data = [.. Word(500), .. new byte[2 * glyphs]]; break;
                case "loca": data = new byte[2 * (glyphs + 1)]; break;
                case "head": Long(0).CopyTo(data, 8); break;
                // Format 4: the characters from the space on, each its own number.
                case "cmap": data = Words(0, 2, 0, 3, 0, 20, 3, 1, 0, 20, 4, 32, 0, 4, 4, 1, 0, 0xFFFE, 0xFFFF, 0, 0x20, 0xFFFF, 0, 1, 0, 0); break;
            }
            tables.Add((name, data));
        }
        static uint Sum(byte[] data)
        {
            uint total = 0;
            for (int at = 0; at < data.Length; at += 4)
            {
                uint value = 0;
                for (int k = 0; k < 4; k++) value = value << 8 | (at + k < data.Length ? data[at + k] : 0u);
                total += value;
            }
            return total;
        }
        List<byte> directory = [.. @base[..12]], body = [];
        int headAt = 0;
        foreach (var (name, data) in tables)
        {
            int at = 12 + tables.Count * 16 + body.Count;
            if (name == "head") headAt = at;
            directory.AddRange([.. Encoding.ASCII.GetBytes(name), .. Long(Sum(data)), .. Long(at), .. Long(data.Length)]);
            body.AddRange([.. data, .. new byte[(4 - data.Length % 4) % 4]]);
        }
        byte[] font = [.. directory, .. body];
        Long(unchecked(0xB1B0AFBA - Sum(font))).CopyTo(font, headAt + 8);
        return font;
    }

    /// <summary>What it is made from: two empty glyphs.</summary>
    const string TwoGlyphTrueType =
        "AAEAAAAKAIAAAwAgT1MvMkUAQ7AAAAEoAAAAYGNtYXAADABzAAABkAAAADRnbHlmAAAAAAAAAcwAAAABaGVhZC9AyCYAAACsAAAANmhoZWEDIgEuAAAA5AAAACRobXR4AfQAAAAAAYgAAAAGbG9jYQAAAAAAAAHEAAAABm1heHAAAwACAAABCAAAACBuYW1lPah3zwAAAdAAAABjcG9zdAAHAAAAAAI0AAAAJgABAAAAAQAAN22Si18PPPUAAwPoAAAAAOcawncAAAAA5xrCdwAA/zgB9AMgAAAAAwACAAAAAAAAAAEAAAMg/zgAAAH0AAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAEAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAwH0AZAABQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAPz8/PwAAACAAIAMg/zgAAAMgAMgAAAAAAAAAAAAAAAAAAAAgAAAB9AAAAAAAAAAAAAIAAAADAAAAFAADAAEAAAAUAAQAIAAAAAQABAABAAAAIP//AAAAIP///+EAAQAAAAAAAAAAAAAAAAAAAAAAAAAEADYAAQAAAAAAAQAIAAAAAQAAAAAAAgAHAAgAAwABBAkAAQAQAA8AAwABBAkAAgAOAB9Gb2xpb09DUlJlZ3VsYXIARgBvAGwAaQBvAE8AQwBSAFIAZQBnAHUAbABhAHIAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAMAAA==";

    internal static string ToUnicodeCMap()
    {
        var ranges = Enumerable.Range(0, 256).Select(i => $"<{i:X2}00> <{i:X2}FF> <{i:X2}00>").ToList();
        var text = new StringBuilder("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n");
        for (int i = 0; i < ranges.Count; i += 100)
        {
            var chunk = ranges.Skip(i).Take(100).ToList();
            text.Append($"{chunk.Count} beginbfrange\n").Append(string.Join('\n', chunk)).Append("\nendbfrange\n");
        }
        text.Append("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
        return text.ToString();
    }

    /// <summary>Adds the text layers to their pages (by page number) of the PDF at path, in one incremental update.</summary>
    public static void Write(string path, IReadOnlyDictionary<int, OcrPageResult> layers) => AnnotationWriter.AddTextLayers(path, layers);
}

public static partial class AnnotationWriter
{
    /// <summary>OCR-01: the font objects once, then for every page with a layer a new page dictionary whose contents are the
    /// original drawing (in its own graphics state) followed by the invisible text, and whose fonts include FolioOCR.</summary>
    internal static void AddTextLayers(string path, IReadOnlyDictionary<int, OcrPageResult> layers)
    {
        if (layers.Count == 0 || layers.Values.All(l => l.Lines.Count == 0)) return;
        // Locked against changes (an owner password): written out whole without it first, as the Mac writes every recognised file.
        if (ScannedPdf.IsEncrypted(path)) File.WriteAllBytes(path, ScannedPdf.Decrypted(path));
        // What an earlier recognition left that nobody can read goes.
        var cleaned = new Dictionary<int, byte[]>();
        using (var source = PdfSource.Open(path))
            foreach (var number in layers.Keys)
                if (number >= 1 && number <= source.Pages.Count && ScannedPdf.WithoutUnreadableLayer(source.Pages[number - 1], layers[number].Replaces) is { } content) cleaned[number] = content;
        Update(path, (document, pages, next, write) =>
        {
            IToken Resolve(IToken t) => t is IndirectReferenceToken r ? document.Structure.GetObject(r.Data).Data : t;
            string Stream(string dict, byte[] data) => $"<<{dict} /Length {data.Length}>>\nstream\n{Encoding.Latin1.GetString(data)}\nendstream";
            // The font.
            long file = next(), descriptor = next(), cid = next(), toUnicode = next(), font = next();
            using (var packed = new MemoryStream())
            {
                using (var deflate = new System.IO.Compression.ZLibStream(packed, System.IO.Compression.CompressionLevel.SmallestSize, true)) deflate.Write(OcrTextLayer.TrueType);
                write(file, Stream($"/Length1 {OcrTextLayer.TrueType.Length} /Filter /FlateDecode", packed.ToArray()));
            }
            write(descriptor, "<</Type /FontDescriptor /FontName /GlyphLessFont /Flags 5 /FontBBox [0 -200 500 800] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 800 /StemV 80 /FontFile2 " + file + " 0 R>>");
            write(cid, $"<</Type /Font /Subtype /CIDFontType2 /BaseFont /GlyphLessFont /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /FontDescriptor {descriptor} 0 R /DW 500 /CIDToGIDMap /Identity>>");
            write(toUnicode, Stream("", Encoding.ASCII.GetBytes(OcrTextLayer.ToUnicodeCMap())));
            write(font, $"<</Type /Font /Subtype /Type0 /BaseFont /GlyphLessFont /Encoding /Identity-H /DescendantFonts [{cid} 0 R] /ToUnicode {toUnicode} 0 R>>");

            foreach (var (number, layer) in layers)
            {
                if (layer.Lines.Count == 0 || number < 1 || number > document.NumberOfPages) continue;
                var info = pages(number);
                var page = document.GetPage(number);
                var cropBox = page.CropBox.Bounds;
                var crop = new OcrTextLayer.PdfRect(cropBox.Left, cropBox.Bottom, cropBox.Right, cropBox.Top);
                int rotation = page.Rotation.Value;
                // Resources, the page's own or inherited, with the font added under a name not taken yet.
                DictionaryToken? resources = null;
                if (info.Dictionary.TryGet(NameToken.Resources, out var res) && Resolve(res) is DictionaryToken own) resources = own;
                else
                {
                    IToken? parent = info.Dictionary.Data.GetValueOrDefault("Parent");
                    for (int depth = 0; resources == null && parent != null && depth < 32; depth++)
                    {
                        if (Resolve(parent) is not DictionaryToken node) break;
                        if (node.TryGet(NameToken.Resources, out var inherited) && Resolve(inherited) is DictionaryToken r) resources = r;
                        parent = node.Data.GetValueOrDefault("Parent");
                    }
                }
                var resourceEntries = resources?.Data.ToDictionary(kv => kv.Key, kv => kv.Value) ?? [];
                var fonts = resourceEntries.TryGetValue("Font", out var f) && Resolve(f) is DictionaryToken fd ? fd.Data.ToDictionary(kv => kv.Key, kv => kv.Value) : [];
                var name = OcrTextLayer.FontResource;
                for (int i = 1; fonts.ContainsKey(name); i++) name = OcrTextLayer.FontResource + i;
                fonts[name] = new IndirectReferenceToken(new IndirectReference(font, 0));
                resourceEntries["Font"] = new DictionaryToken(fonts.ToDictionary(kv => NameToken.Create(kv.Key), kv => kv.Value));
                // Contents: q, the original, Q and the text.
                long open = next(), text = next();
                write(open, Stream("", "q\n"u8.ToArray()));
                write(text, Stream("", Encoding.ASCII.GetBytes("\nQ\n" + OcrTextLayer.Content(layer, crop, rotation, name))));
                var contents = new List<IToken> { new IndirectReferenceToken(new IndirectReference(open, 0)) };
                if (cleaned.TryGetValue(number, out var clean))
                {
                    long kept = next();
                    write(kept, Stream("", clean));
                    contents.Add(new IndirectReferenceToken(new IndirectReference(kept, 0)));
                }
                else if (info.Dictionary.Data.TryGetValue("Contents", out var c))
                {
                    if (c is IndirectReferenceToken && Resolve(c) is ArrayToken list) contents.AddRange(list.Data);
                    else if (c is ArrayToken array) contents.AddRange(array.Data);
                    else contents.Add(c);
                }
                contents.Add(new IndirectReferenceToken(new IndirectReference(text, 0)));
                var entries = info.Dictionary.Data.Where(kv => kv.Key is not "Contents" and not "Resources")
                    .Select(kv => (kv.Key, Value: kv.Value)).ToList();
                entries.Add(("Resources", new DictionaryToken(resourceEntries.ToDictionary(kv => NameToken.Create(kv.Key), kv => kv.Value))));
                entries.Add(("Contents", new ArrayToken(contents)));
                var dict = new StringBuilder("<<");
                foreach (var (key, value) in entries) dict.Append('/').Append(EscapeName(key)).Append(' ').Append(Serialize(value)).Append(' ');
                dict.Append(">>");
                write(info.Number, dict.ToString());
            }
            return [];
        });
    }
}

/// <summary>Tells scanned PDFs (pages that are pictures of text, with no text layer) from PDFs with text, as the macOS app
/// (ScannedPDF.swift).</summary>
public static class ScannedPdf
{
    /// <summary>Fewer characters than this on a page: no text layer to speak of (a page number, a stamp).</summary>
    public const int MinimumCharacters = 20;
    /// <summary>The page is mostly a picture. A page without any text needs less of one (a scan set small on the page).</summary>
    const double MinimumImageCoverage = 0.3;
    public const double MinimumCoverageWithoutText = 0.12;
    /// <summary>Drawn shapes on a page of text turned into outlines: each letter one or two filled curves.</summary>
    public const int MinimumOutlines = 120;
    /// <summary>Pages looked at to decide about a whole document.</summary>
    const int SamplePages = 8;

    /// <summary>What is on a page: characters somebody can read in the body of the page (not the line a download service prints
    /// along the edge, not a watermark across it), all of them, glyphs no one can copy, how much of the page images cover,
    /// small filled curves (letters drawn as shapes).</summary>
    public readonly record struct PageFacts(int Characters, int AllCharacters, int Unreadable, double ImageCoverage, int Outlines, int Type3 = 0)
    {
        public bool NeedsOcr => Characters < MinimumCharacters
            && (Unreadable >= MinimumCharacters || Outlines >= MinimumOutlines
                || ImageCoverage >= (AllCharacters < MinimumCharacters ? MinimumCoverageWithoutText : MinimumImageCoverage));
        /// <summary>Nothing on the page that says what kind of document it is.</summary>
        public bool IsBlank => AllCharacters < MinimumCharacters && !NeedsOcr;
    }

    public static PageFacts Facts(PDict page)
    {
        var interpreter = new ContentInterpreter();
        interpreter.Run(page);
        return Facts(interpreter, PdfComposer.Geometry(page).CropBox);
    }

    internal static PageFacts Facts(ContentInterpreter interpreter, Rect crop)
    {
        var body = crop.InsetBy(crop.W * 0.045, crop.H * 0.06);
        int inBody = 0, all = 0, unreadable = 0, type3 = 0;
        foreach (var glyph in interpreter.Glyphs)
        {
            if (glyph.IsClipped) continue;
            if (ReadableCharacters(glyph) is not { } count)
            {
                unreadable++;
                if (glyph.Font >= 0 && glyph.Font < interpreter.Fonts.Count && interpreter.Fonts[glyph.Font].Dict.Name("Subtype") == "Type3") type3++;
                continue;
            }
            if (count == 0) continue;
            all += count;
            // A watermark runs across the page at a slant: neither along a line nor up the side.
            double quarter = Math.Abs(Math.IEEERemainder(glyph.Angle, Math.PI / 2));
            var box = glyph.Box;
            if (quarter <= 0.1 && body.Contains(new Pt(box.MidX, box.MidY))) inBody += count;
        }
        double covered = 0;
        foreach (var mark in interpreter.Marks)
        {
            if (mark.Kind != GraphicMark.MarkKind.Image) continue;
            var visible = mark.Rect.Intersection(crop);
            if (!visible.IsNull) covered += visible.W * visible.H;
        }
        double limit = Math.Max(crop.W, crop.H) * 0.06;
        int outlines = interpreter.Marks.Count(m => m.Kind == GraphicMark.MarkKind.Fill && !m.IsWhite && m.HasCurves && m.Rect.W < limit && m.Rect.H < limit);
        return new PageFacts(inBody, all, unreadable, Math.Min(1, covered / Math.Max(crop.W * crop.H, 1)), outlines, type3);
    }

    /// <summary>How many characters copying the glyph gives (0 for a space); null when what it gives is nothing or nonsense.</summary>
    internal static int? ReadableCharacters(Glyph glyph)
    {
        if (glyph.Text == null) return null;
        int count = 0;
        foreach (var rune in glyph.Text.EnumerateRunes())
        {
            if (Rune.IsWhiteSpace(rune)) continue;
            if (rune.Value is < 0x20 or >= 0x7F and < 0xA0 or >= 0xE000 and <= 0xF8FF or >= 0xFFF0 and <= 0xFFFF or >= 0xF0000) return null;
            count++;
        }
        return count;
    }

    /// <summary>Whether the document is a scan to recognise: of the pages looked at (some across the whole document, blank ones
    /// aside), at least half have text only as a picture.</summary>
    public static bool IsScanned(string path)
    {
        try
        {
            using var source = PdfSource.Open(path);
            if (!CanRead(source)) return false;
            int looked = 0, scanned = 0;
            foreach (var number in Sample(source.Pages.Count))
            {
                var facts = Facts(source.Pages[number - 1]);
                if (facts.IsBlank) continue;
                looked++;
                if (facts.NeedsOcr && !Reads(source, number, facts)) scanned++;
            }
            return scanned > 0 && scanned * 2 >= looked;
        }
        catch { return false; }
    }

    /// <summary>Open to us: not encrypted, or encrypted with no password to open it and copying allowed (a file locked against changes:
    /// many downloaded papers and books are), as the Mac's.</summary>
    public static bool CanRead(PdfSource source)
    {
        if (source.Document.Structure.CrossReferenceTable.Trailer.EncryptionToken is not { } token) return true;
        return source.Resolve(token) is DictionaryToken encryption && encryption.TryGet(NameToken.Create("P"), out NumericToken? permissions)
            && ((long)permissions.Double & 16) != 0;
    }

    public static bool IsEncrypted(string path)
    {
        using var source = PdfSource.Open(path);
        return source.Document.Structure.CrossReferenceTable.Trailer.EncryptionToken != null;
    }

    /// <summary>The document written out whole, without its encryption: pages (with what they inherit), annotations, outline,
    /// destinations, forms and info.</summary>
    public static byte[] Decrypted(string path)
    {
        using var source = PdfSource.Open(path);
        var writer = new PdfWriter();
        var copier = new PdfCopier(writer, source);
        int pagesNode = writer.Reserve();
        var objects = source.Pages.Select(page => copier.PageMap[page.Key] = writer.Reserve()).ToList();
        HashSet<string> inherited = ["Parent", "Resources", "MediaBox", "CropBox", "Rotate"];
        for (int i = 0; i < objects.Count; i++)
        {
            var page = source.Pages[i];
            var entries = copier.Entries(page, inherited);
            entries["Parent"] = PdfValue.Ref(pagesNode);
            foreach (var key in new[] { "Resources", "MediaBox", "CropBox", "Rotate" })
                if (page.Inherited(key) is { } value) entries[key] = copier.Copy(value);
            writer.Set(objects[i], PdfValue.Dict(entries));
        }
        writer.Set(pagesNode, PdfValue.Dict(new() { ["Type"] = PdfValue.Name("Pages"), ["Kids"] = PdfValue.Array(objects.Select(PdfValue.Ref)), ["Count"] = PdfValue.Int(objects.Count) }));
        var catalog = source.Catalog is { } root ? copier.Entries(root, new HashSet<string> { "Type", "Pages" }) : [];
        catalog["Type"] = PdfValue.Name("Catalog");
        catalog["Pages"] = PdfValue.Ref(pagesNode);
        int? info = source.Trailer.Dict("Info") is { } dict ? writer.Add(PdfValue.Dict(copier.Entries(dict))) : null;
        return writer.Finish(writer.Add(PdfValue.Dict(catalog)), info);
    }

    /// <summary>Pages spread over the document: the first three, then evenly to the last.</summary>
    internal static List<int> Sample(int count)
    {
        if (count <= SamplePages) return Enumerable.Range(1, Math.Max(count, 0)).ToList();
        var pages = new List<int> { 1, 2, 3 };
        int rest = SamplePages - pages.Count;
        for (int k = 1; k <= rest; k++) pages.Add(3 + (int)Math.Round((count - 3) * (double)k / rest));
        return pages;
    }

    /// <summary>Whether another reader (PdfPig) gets text from a page whose fonts Folio cannot read.</summary>
    static bool Reads(PdfSource source, int number, PageFacts facts)
    {
        // Glyphs drawn by procedures (Type 3) without names: what PdfPig gives for them are their codes, not their text.
        if (facts.Unreadable < MinimumCharacters || facts.Type3 * 2 >= facts.Unreadable) return false;
        try { return source.Document.GetPage(number).Text.Count(char.IsLetterOrDigit) * 3 >= facts.Unreadable; }
        catch { return false; }
    }

    /// <summary>Whether any page of the document has no text of its own.</summary>
    public static bool HasPagesWithoutText(string path)
    {
        try { return PagesNeedingOcr(path).Count > 0; }
        catch { return false; }
    }

    /// <summary>Several lines that are parts of sentences: a page of text, not a picture with labels.</summary>
    public static bool IsPageOfText(OcrPageResult result)
    {
        int lines = 0, characters = 0;
        foreach (var line in result.Lines)
        {
            var text = line.Text;
            int words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(w => w.Length >= 2 && w.All(c => char.IsLetter(c) || char.IsPunctuation(c)));
            int han = text.EnumerateRunes().Count(r => OcrTextLayer.IsCjk(r.Value) && Rune.IsLetter(r));
            if (words < 6 && han < 14) continue;
            lines++;
            characters += text.Length;
        }
        return lines >= 5 && characters >= 120;
    }

    /// <summary>The pages (1-based) that need text recognised. force: when none looks like a scan, every page with a picture on it.</summary>
    public static List<int> PagesNeedingOcr(string path, bool force = false)
    {
        using var source = PdfSource.Open(path);
        if (!CanRead(source)) throw new InvalidOperationException(Loc.S("PDF 已加密或受密码保护，无法识别文字。"));
        var facts = source.Pages.Select(Facts).ToList();
        var pages = Enumerable.Range(1, facts.Count).Where(n => facts[n - 1].NeedsOcr && !Reads(source, n, facts[n - 1])).ToList();
        if (pages.Count == 0 && force) pages = Enumerable.Range(1, facts.Count).Where(n => facts[n - 1].ImageCoverage >= 0.1).ToList();
        return pages;
    }

    /// <summary>Whether a page's text is the hidden layer of a recognition that can be taken out: it can be read anew.</summary>
    public static bool CanBeReadAnew(string path, int number)
    {
        using var source = PdfSource.Open(path);
        var interpreter = new ContentInterpreter();
        interpreter.Run(source.Pages[number - 1]);
        return interpreter.IsRecognizedScan && interpreter.Runs.Where(r => r.RenderMode == 3 && r.GlyphEnd > r.GlyphStart).All(r => r.Location.Stream.Equals(StreamPath.Root));
    }

    /// <summary>The boxes of what is text on a page already, in the pixels of an image of the page as shown, turned by turn degrees.</summary>
    public static List<OcrWord> TextOn(string path, int number, double imageWidth, double imageHeight, int turn = 0, bool hidden = true)
    {
        using var source = PdfSource.Open(path);
        var page = source.Pages[number - 1];
        var interpreter = new ContentInterpreter();
        interpreter.Run(page);
        var geometry = PdfComposer.Geometry(page);
        var boxes = new List<OcrWord>();
        foreach (var glyph in interpreter.Glyphs)
        {
            if (glyph.IsClipped || (!hidden && glyph.RenderMode == 3) || ReadableCharacters(glyph) is not > 0) continue;
            var box = glyph.Box;
            var (x, y) = OcrTextLayer.UserToDisplay(geometry.CropBox, geometry.Rotation + turn, imageWidth, box.MidX, box.MidY);
            boxes.Add(new OcrWord(glyph.Text ?? "", x, y, 0, 0));
        }
        return boxes;
    }

    /// <summary>The page's content without the hidden text of an earlier recognition nobody can read (its font does not say which
    /// characters it draws): left in, it would be selected and copied along with the new text. Null: none.</summary>
    internal static byte[]? WithoutUnreadableLayer(PDict page, bool all = false)
    {
        var interpreter = new ContentInterpreter();
        interpreter.Run(page);
        if (!interpreter.Streams.TryGetValue(StreamPath.Root, out var stream)) return null;
        var drop = new List<(int Start, int End)>();
        foreach (var run in interpreter.Runs)
        {
            if (!run.Location.Stream.Equals(StreamPath.Root) || run.RenderMode != 3 || run.GlyphEnd <= run.GlyphStart) continue;
            if (!all && !Enumerable.Range(run.GlyphStart, run.GlyphEnd - run.GlyphStart).Any(g => ReadableCharacters(interpreter.Glyphs[g]) == null)) continue;
            if (run.Location.Index < 0 || run.Location.Index >= stream.Ops.Count) continue;
            var op = stream.Ops[run.Location.Index];
            if (op.Name is "Tj" or "TJ") drop.Add((op.Start, op.End));
        }
        if (drop.Count == 0) return null;
        var result = (byte[])stream.Source.Clone();
        foreach (var (start, end) in drop) Array.Fill(result, (byte)' ', start, end - start);
        return result;
    }
}
