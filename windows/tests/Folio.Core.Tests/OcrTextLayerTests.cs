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
}
