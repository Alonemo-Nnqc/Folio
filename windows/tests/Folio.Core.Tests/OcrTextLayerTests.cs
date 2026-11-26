using Folio.Core.Translate;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Writer;
using UglyToad.PdfPig.Content;

namespace Folio.Core.Tests;

/// <summary>OCR-01: the invisible text layer, as the macOS OCRTextLayer tests.</summary>
public class OcrTextLayerTests
{
    static string BlankPdf(int pages = 1)
    {
        var builder = new PdfDocumentBuilder();
        for (int i = 0; i < pages; i++)
        {
            var page = builder.AddPage(PageSize.Letter);
            page.DrawRectangle(new UglyToad.PdfPig.Core.PdfPoint(50, 50), 100, 100);
        }
        var path = Path.Combine(Path.GetTempPath(), $"ocr-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, builder.Build());
        return path;
    }

    /// <summary>"Hello world" and "扫描件识别" on a 1224×1584 image of a letter page (2x).</summary>
    static OcrPageResult Result(int page = 1) => new(page, 1224, 1584,
    [
        new OcrLine([new OcrWord("Hello", 144, 200, 150, 40), new OcrWord("world", 310, 200, 160, 40)]),
        new OcrLine("扫描件识别".Select((c, i) => new OcrWord(c.ToString(), 144 + i * 44, 300, 44, 44)).ToList()),
    ]);

    [Fact]
    public void TextIsExtractedAndSearchable()
    {
        var path = BlankPdf(2);
        try
        {
            long before = new FileInfo(path).Length;
            OcrTextLayer.Write(path, new Dictionary<int, OcrPageResult> { [2] = Result(2) });
            Assert.True(new FileInfo(path).Length > before);
            using var document = PdfDocument.Open(path);
            Assert.Equal(2, document.NumberOfPages);
            var text = string.Join(" ", document.GetPage(2).GetWords().Select(w => w.Text));
            Assert.Contains("Hello", text);
            Assert.Contains("world", text);
            Assert.Contains("扫描件识别", document.GetPage(2).Text);
            Assert.DoesNotContain("Hello", document.GetPage(1).Text);
            // Where the words are: "Hello" starts at 72 pt from the left, on the line 100–120 pt below the top.
            var hello = document.GetPage(2).GetWords().First(w => w.Text.StartsWith("Hello"));
            Assert.InRange(hello.BoundingBox.Left, 70, 74);
            Assert.InRange(hello.BoundingBox.Bottom, 792 - 122, 792 - 98);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void ContentIsInvisibleAndStretchedToEachWord()
    {
        var content = OcrTextLayer.Content(Result(), new OcrTextLayer.PdfRect(0, 0, 612, 792), 0);
        Assert.StartsWith("BT\n3 Tr\n/FolioOCR 1 Tf\n", content);
        Assert.EndsWith("ET\n", content);
        Assert.Contains("<00480065006C006C006F> Tj", content);
        Assert.Contains("<0020> Tj", content);
        Assert.Contains("<626B> Tj", content);
        Assert.Contains("20 0 0 20 72 ", content);
        Assert.Contains(" 150 Tz <00480065006C006C006F>", content);
    }

    [Fact]
    public void PagesWithTextAreNotScans()
    {
        var builder = new PdfDocumentBuilder();
        var font = builder.AddStandard14Font(UglyToad.PdfPig.Fonts.Standard14Fonts.Standard14Font.Helvetica);
        var page = builder.AddPage(PageSize.A4);
        page.AddText("This page has a real text layer with plenty of characters.", 12, new UglyToad.PdfPig.Core.PdfPoint(50, 700), font);
        var path = Path.Combine(Path.GetTempPath(), $"text-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, builder.Build());
        try { Assert.False(ScannedPdf.IsScanned(path)); }
        finally { File.Delete(path); }
    }

    /// <summary>A page that is one picture (a 1×1 white JPEG stretched over it, as far as the analysis goes), with content after it.</summary>
    static string ScanPdf(params string[] contents) => Pdf(612, 792, contents);

    static string Pdf(int width, int height, params string[] contents)
    {
        var objects = new List<byte[]>();
        int Add(string body) { objects.Add(System.Text.Encoding.Latin1.GetBytes(body)); return objects.Count; }
        int image = Add("<</Type/XObject/Subtype/Image/Width 1/Height 1/ColorSpace/DeviceGray/BitsPerComponent 8/Length 1>>\nstream\n\u00ff\nendstream");
        int font = Add("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>");
        // A font that draws but does not say what: no names, no ToUnicode.
        int glyph = Add("<</Length 23>>\nstream\n1000 0 0 0 750 750 d1  \nendstream");
        int mute = Add($"<</Type/Font/Subtype/Type3/FontBBox[0 0 750 750]/FontMatrix[.001 0 0 .001 0 0]/CharProcs<</q1 {glyph} 0 R>>/Encoding<</Type/Encoding/Differences[65/q1/q1/q1]>>/FirstChar 65/LastChar 67/Widths[500 500 500]/Resources<<>>>>");
        int pagesNode = objects.Count + contents.Length * 2 + 1;
        var kids = new List<int>();
        foreach (var content in contents)
        {
            int c = Add($"<</Length {content.Length}>>\nstream\n{content}\nendstream");
            kids.Add(Add($"<</Type/Page/Parent {pagesNode} 0 R/MediaBox[0 0 {width} {height}]/Resources<</XObject<</I {image} 0 R>>/Font<</F {font} 0 R/M {mute} 0 R>>>>/Contents {c} 0 R>>"));
        }
        Add($"<</Type/Pages/Count {kids.Count}/Kids[{string.Join(' ', kids.Select(k => $"{k} 0 R"))}]>>");
        int root = Add($"<</Type/Catalog/Pages {pagesNode} 0 R>>");
        var output = new MemoryStream();
        void Write(string t) => output.Write(System.Text.Encoding.Latin1.GetBytes(t));
        Write("%PDF-1.5\n");
        var offsets = new List<long>();
        for (int k = 0; k < objects.Count; k++) { offsets.Add(output.Position); Write($"{k + 1} 0 obj\n"); output.Write(objects[k]); Write("\nendobj\n"); }
        long xref = output.Position;
        Write($"xref\n0 {objects.Count + 1}\n0000000000 65535 f \n" + string.Concat(offsets.Select(o => $"{o:D10} 00000 n \n")) + $"trailer<</Size {objects.Count + 1}/Root {root} 0 R>>\nstartxref\n{xref}\n%%EOF");
        var path = Path.Combine(Path.GetTempPath(), $"scan-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, output.ToArray());
        return path;
    }

    const string Picture = "q 612 0 0 792 0 0 cm /I Do Q ";
    const string Text = "BT /F 12 Tf 60 700 Td (This cover page was added by the document delivery service) Tj ET";

    static void Check(string path, bool scanned, params int[] pages)
    {
        try
        {
            Assert.Equal(scanned, ScannedPdf.IsScanned(path));
            Assert.Equal(pages, ScannedPdf.PagesNeedingOcr(path));
        }
        finally { File.Delete(path); }
    }

    [Fact] public void APictureOfAPageIsAScan() => Check(ScanPdf(Picture), true, 1);
    [Fact] public void FooterOfADatabaseDoesNotHideTheScan() =>
        Check(ScanPdf(Picture + "BT /F 7 Tf 60 20 Td (China Academic Journal Electronic Publishing House. All rights reserved.) Tj ET"), true, 1);
    [Fact] public void SlantedWatermarkDoesNotHideTheScan() =>
        Check(ScanPdf(Picture + "BT /F 40 Tf 0.7 0.7 -0.7 0.7 100 200 Tm (FOR LIBRARY USE ONLY SAMPLE COPY) Tj ET"), true, 1);
    [Fact] public void CoverPageWithTextDoesNotHideTheScan() => Check(ScanPdf(Text, Picture, Picture, Picture), true, 2, 3, 4);
    [Fact] public void SmallScanOnAPageWithoutText() => Check(ScanPdf("q 300 0 0 388 150 200 cm /I Do Q"), true, 1);
    [Fact] public void PictureBesideTextIsNoScan() => Check(ScanPdf(Picture + Text), false);
    [Fact] public void BlankPagesAreNotCounted() => Check(ScanPdf("", "", "", Picture), true, 4);

    /// <summary>The same font as the macOS app's, byte for byte.</summary>
    [Fact]
    public void TheFontIsTheMacs()
    {
        Assert.Equal(262732, OcrTextLayer.TrueType.Length);
        Assert.StartsWith("EA3F30BF2BAE38C4", Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(OcrTextLayer.TrueType)));
    }

    [Fact]
    public void UnreadableLayerIsReplaced()
    {
        var path = ScanPdf(Picture + string.Concat(Enumerable.Range(0, 10).Select(k => $"BT 3 Tr /M 10 Tf 60 {700 - k * 20} Td (ABCABCABC) Tj ET ")));
        try
        {
            Assert.True(ScannedPdf.IsScanned(path));
            OcrTextLayer.Write(path, new Dictionary<int, OcrPageResult> { [1] = Result(1) });
            using var source = Folio.Core.Translate.Pdf.PdfSource.Open(path);
            var interpreter = new Folio.Core.Translate.Pdf.ContentInterpreter();
            interpreter.Run(source.Pages[0]);
            Assert.DoesNotContain(interpreter.Glyphs, g => g.Text == null);
            Assert.True(interpreter.IsRecognizedScan || interpreter.Glyphs.Count < 20);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void RecognisedScanIsTranslatable()
    {
        var path = ScanPdf(Picture);
        try
        {
            var words = "Scanned documents become searchable after optical character recognition".Split(' ');
            // Boxes edge to edge, as text recognition gives them.
            var lines = new List<OcrLine>();
            for (int l = 0; l < 3; l++)
            {
                double x = 144;
                lines.Add(new OcrLine(words.Select(w => { var word = new OcrWord(w, x, 300 + l * 48, w.Length * 14, 36); x += w.Length * 14; return word; }).ToList()));
            }
            OcrTextLayer.Write(path, new Dictionary<int, OcrPageResult> { [1] = new(1, 1224, 1584, lines) });
            Assert.False(ScannedPdf.IsScanned(path));
            using var source = Folio.Core.Translate.Pdf.PdfSource.Open(path);
            var layouts = new Folio.Core.Translate.Layout.LayoutAnalyzer().Analyze(source, [1]);
            Assert.True(layouts[0].IsScan);
            var segments = Folio.Core.Translate.Engine.SegmentBuilder.Segments(layouts[0]);
            Assert.Contains(segments, s => s.Source.Contains("Scanned documents become searchable"));
            var output = new Folio.Core.Translate.Engine.TranslationRenderer(source, "zh").Render(layouts, segments, segments.ToDictionary(s => s.Id, _ => "译文甲乙丙丁"),
                true, false, TranslationOptions.DualLayouts.sideBySide, null);
            Assert.NotNull(output.Mono);
            using var written = PdfDocument.Open(output.Mono!);
            Assert.DoesNotContain("Scanned", written.GetPage(1).Text);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void TurnedPageTextLandsWhereItShows()
    {
        // A page read a quarter turn clockwise: its first line's start is at the bottom left corner of the page as stored.
        var content = OcrTextLayer.Content(new OcrPageResult(1, 1584, 1224, [new OcrLine([new OcrWord("Hello", 0, 0, 150, 40)])]) { Turn = 90 }, new OcrTextLayer.PdfRect(0, 0, 612, 792), 0);
        Assert.Contains("0 20 -20 0 16 0 Tm", content);
    }
}
