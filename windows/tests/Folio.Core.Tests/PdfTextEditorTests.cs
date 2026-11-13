using Folio.Core.Translate.Edit;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Fonts.Standard14Fonts;
using UglyToad.PdfPig.Writer;

namespace Folio.Core.Tests;

/// <summary>EDIT-01: replacing the text of a block, the rest of the page untouched.</summary>
public class PdfTextEditorTests
{
    static string Sample()
    {
        var builder = new PdfDocumentBuilder();
        var font = builder.AddStandard14Font(Standard14Font.TimesRoman);
        var bold = builder.AddStandard14Font(Standard14Font.TimesBold);
        var page = builder.AddPage(PageSize.Letter);
        page.AddText("A Study of Editable Documents", 20, new PdfPoint(150, 700), bold);
        string[] first = ["Portable documents are hard to change once they are written,", "because their text is a list of glyphs placed one by one", "on the page rather than flowing paragraphs of words."];
        for (int i = 0; i < first.Length; i++) page.AddText(first[i], 11, new PdfPoint(72, 640 - i * 14), font);
        string[] second = ["The second paragraph stays exactly as it was written here,", "with every word in its place after the first one changes."];
        for (int i = 0; i < second.Length; i++) page.AddText(second[i], 11, new PdfPoint(72, 560 - i * 14), font);
        builder.AddPage(PageSize.Letter).AddText("Page two keeps its own text as well.", 11, new PdfPoint(72, 700), font);
        var path = Path.Combine(Path.GetTempPath(), $"edit-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, builder.Build());
        return path;
    }

    [Fact]
    public void ABlockIsReplacedAndTheRestStays()
    {
        var path = Sample();
        try
        {
            var blocks = PdfTextEditor.Blocks(path, 1);
            var paragraph = blocks.First(b => b.Text.StartsWith("Portable"));
            Assert.True(paragraph.IsEditable);
            Assert.InRange(paragraph.FontSize, 10.5, 11.5);
            var data = PdfTextEditor.Replace(path, 1, paragraph.Index, paragraph.Text, "Folio can now change the words of a paragraph in place.");
            using var edited = PdfDocument.Open(data);
            Assert.Equal(2, edited.NumberOfPages);
            var text = string.Join(" ", edited.GetPage(1).GetWords().Select(w => w.Text));
            Assert.Contains("Folio can now change", text);
            Assert.DoesNotContain("Portable", text);
            Assert.Contains("second paragraph stays exactly", text);
            Assert.Contains("Editable Documents", text);
            Assert.Contains("Page two keeps", edited.GetPage(2).Text);
            // A stale view of the block is refused.
            Assert.Throws<InvalidOperationException>(() => PdfTextEditor.Replace(path, 1, paragraph.Index, "something else", "x"));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void ARunInHeadingIsPartOfItsParagraph()
    {
        var builder = new PdfDocumentBuilder();
        var font = builder.AddStandard14Font(Standard14Font.TimesRoman);
        var bold = builder.AddStandard14Font(Standard14Font.TimesBold);
        var page = builder.AddPage(PageSize.Letter);
        var heading = page.AddText("Results.", 11, new PdfPoint(72, 640), bold);
        double x = 72 + heading.Max(l => l.EndBaseLine.X) - 72 + 4;
        page.AddText("The method was compared with four others on every dataset,", 11, new PdfPoint(x, 640), font);
        page.AddText("and it found the thin vessels the others missed in most images.", 11, new PdfPoint(72, 626), font);
        page.AddText("Further work will look at three dimensional data and at speed.", 11, new PdfPoint(72, 612), font);
        var path = Path.Combine(Path.GetTempPath(), $"lead-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, builder.Build());
        try
        {
            var block = PdfTextEditor.Blocks(path, 1).First(b => b.Text.Contains("method"));
            Assert.StartsWith("Results. The method", block.Text);
            var data = PdfTextEditor.Replace(path, 1, block.Index, block.Text, "Results. Folio rewrote this paragraph, its heading kept.");
            using var edited = PdfDocument.Open(data);
            var text = string.Join(" ", edited.GetPage(1).GetWords().Select(w => w.Text));
            Assert.Contains("Results.", text);
            Assert.Contains("Folio rewrote this paragraph", text);
            Assert.DoesNotContain("compared", text);
            Assert.Equal(1, text.Split("Results.").Length - 1);
        }
        finally { File.Delete(path); }
    }
}
