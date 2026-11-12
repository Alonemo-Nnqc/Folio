using System.Globalization;
using System.Text;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Tokens;

namespace Folio.Core;

/// <summary>A word recognised on a page image, in the image's pixels (origin top-left, y down).</summary>
public sealed record OcrWord(string Text, double X, double Y, double Width, double Height);

/// <summary>A line of words, left to right.</summary>
public sealed record OcrLine(IReadOnlyList<OcrWord> Words);

/// <summary>What was recognised on one page (1-based), in the coordinates of an image of the page as it is shown (crop
/// box, rotation applied) that is ImageWidth × ImageHeight large.</summary>
public sealed record OcrPageResult(int Page, double ImageWidth, double ImageHeight, IReadOnlyList<OcrLine> Lines)
{
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

    public readonly record struct PdfRect(double Left, double Bottom, double Right, double Top)
    {
        public double Width => Right - Left;
        public double Height => Top - Bottom;
    }

    static string F(double v) => Math.Round(v, 4).ToString("0.####", CultureInfo.InvariantCulture);

    /// <summary>The page's text layer: one BT … ET drawing every word (and the spaces between words) invisibly.</summary>
    public static string Content(OcrPageResult result, PdfRect crop, int rotation, string font = FontResource)
    {
        var toUser = DisplayToUser(crop, rotation, result.ImageWidth);
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
            var m = new Matrix(height, 0, 0, -height, start, baseline).Then(toUser);
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

    /// <summary>The glyphless TrueType font (two empty glyphs, 500 units wide), the one the macOS app embeds.</summary>
    internal static readonly byte[] GlyphlessTrueType = Convert.FromBase64String(
        "AAEAAAAKAIAAAwAgT1MvMkUAQ7AAAAEoAAAAYGNtYXAADABzAAABkAAAADRnbHlmAAAAAAAAAcwAAAABaGVhZC9AyCYAAACsAAAANmhoZWEDIgEuAAAA5AAAACRobXR4AfQAAAAAAYgAAAAGbG9jYQAAAAAAAAHEAAAABm1heHAAAwACAAABCAAAACBuYW1lPah3zwAAAdAAAABjcG9zdAAHAAAAAAI0AAAAJgABAAAAAQAAN22Si18PPPUAAwPoAAAAAOcawncAAAAA5xrCdwAA/zgB9AMgAAAAAwACAAAAAAAAAAEAAAMg/zgAAAH0AAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAEAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAwH0AZAABQAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAPz8/PwAAACAAIAMg/zgAAAMgAMgAAAAAAAAAAAAAAAAAAAAgAAAB9AAAAAAAAAAAAAIAAAADAAAAFAADAAEAAAAUAAQAIAAAAAQABAABAAAAIP//AAAAIP///+EAAQAAAAAAAAAAAAAAAAAAAAAAAAAEADYAAQAAAAAAAQAIAAAAAQAAAAAAAgAHAAgAAwABBAkAAQAQAA8AAwABBAkAAgAOAB9Gb2xpb09DUlJlZ3VsYXIARgBvAGwAaQBvAE8AQwBSAFIAZQBnAHUAbABhAHIAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAMAAA==");

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
        Update(path, (document, pages, next, write) =>
        {
            IToken Resolve(IToken t) => t is IndirectReferenceToken r ? document.Structure.GetObject(r.Data).Data : t;
            string Stream(string dict, byte[] data) => $"<<{dict} /Length {data.Length}>>\nstream\n{Encoding.Latin1.GetString(data)}\nendstream";
            // The font.
            long file = next(), descriptor = next(), gidMap = next(), cid = next(), toUnicode = next(), font = next();
            write(file, Stream($"/Length1 {OcrTextLayer.GlyphlessTrueType.Length}", OcrTextLayer.GlyphlessTrueType));
            write(descriptor, "<</Type /FontDescriptor /FontName /GlyphLessFont /Flags 5 /FontBBox [0 -200 500 800] /ItalicAngle 0 /Ascent 800 /Descent -200 /CapHeight 800 /StemV 80 /FontFile2 " + file + " 0 R>>");
            var map = new byte[65536 * 2];
            for (int i = 1; i < map.Length; i += 2) map[i] = 1;
            write(gidMap, Stream("", map));
            write(cid, $"<</Type /Font /Subtype /CIDFontType2 /BaseFont /GlyphLessFont /CIDSystemInfo <</Registry (Adobe) /Ordering (Identity) /Supplement 0>> /FontDescriptor {descriptor} 0 R /DW 500 /CIDToGIDMap {gidMap} 0 R>>");
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
                if (info.Dictionary.Data.TryGetValue("Contents", out var c))
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
/// (ScannedPDF.swift): a page needs OCR when it has fewer than 20 characters and images cover at least 30% of it; a
/// document is a scan when at least half of its first three pages do.</summary>
public static class ScannedPdf
{
    const int MinimumCharacters = 20, SamplePages = 3;
    const double MinimumImageCoverage = 0.3;

    static bool NeedsOcr(Page page)
    {
        int characters = page.Letters.Sum(l => l.Value.Count(c => !char.IsWhiteSpace(c)));
        if (characters >= MinimumCharacters) return false;
        var crop = page.CropBox.Bounds;
        double area = Math.Max(crop.Width * crop.Height, 1), covered = 0;
        foreach (var image in page.GetImages())
        {
            var b = image.Bounds;
            double w = Math.Min(b.Right, crop.Right) - Math.Max(b.Left, crop.Left), h = Math.Min(b.Top, crop.Top) - Math.Max(b.Bottom, crop.Bottom);
            if (w > 0 && h > 0) covered += w * h;
        }
        return covered / area >= MinimumImageCoverage;
    }

    public static bool IsScanned(string path)
    {
        try
        {
            using var document = PdfDocument.Open(path);
            if (document.IsEncrypted) return false;
            int sample = Math.Min(SamplePages, document.NumberOfPages), scanned = 0;
            for (int n = 1; n <= sample; n++) if (NeedsOcr(document.GetPage(n))) scanned++;
            return scanned > 0 && scanned * 2 >= sample;
        }
        catch { return false; }
    }

    /// <summary>The pages (1-based) that need text recognised.</summary>
    public static List<int> PagesNeedingOcr(string path)
    {
        using var document = PdfDocument.Open(path);
        return Enumerable.Range(1, document.NumberOfPages).Where(n => NeedsOcr(document.GetPage(n))).ToList();
    }
}
