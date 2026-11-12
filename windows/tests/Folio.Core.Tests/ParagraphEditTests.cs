using Folio.Core.Translate.Edit;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;
using UglyToad.PdfPig.Core;
using UglyToad.PdfPig.Fonts.Standard14Fonts;
using UglyToad.PdfPig.Writer;

namespace Folio.Core.Tests;

/// <summary>EDIT-01: a paragraph edited in place keeps the page's fonts and lines; only the lines a change reaches are set
/// again, and the file gets an update of that page alone.</summary>
public class ParagraphEditTests
{
    static readonly string[] Lines =
    [
        "Portable documents are hard to change once they are written,",
        "because their text is a list of glyphs placed one by one on",
        "the page rather than flowing paragraphs of words, and so a",
        "change of a single word has to be set again by hand there.",
    ];

    static string Sample()
    {
        var builder = new PdfDocumentBuilder();
        var font = builder.AddStandard14Font(Standard14Font.TimesRoman);
        var page = builder.AddPage(PageSize.Letter);
        for (int i = 0; i < Lines.Length; i++) page.AddText(Lines[i], 11, new PdfPoint(72, 640 - i * 14), font);
        page.AddText("The second paragraph stays exactly as it was written.", 11, new PdfPoint(72, 560), font);
        builder.AddPage(PageSize.Letter).AddText("Page two keeps its own text as well.", 11, new PdfPoint(72, 700), font);
        var path = Path.Combine(Path.GetTempPath(), $"para-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, builder.Build());
        return path;
    }

    static int BlockOf(string path, string start) => PdfTextEditor.Blocks(path, 1).First(b => b.Text.StartsWith(start, StringComparison.Ordinal)).Index;

    static string Words(string path, int page)
    {
        using var document = PdfDocument.Open(path);
        return string.Join(" ", document.GetPage(page).GetWords().Select(w => w.Text));
    }

    [Fact]
    public void AnUntouchedParagraphWritesNothing()
    {
        var path = Sample();
        try
        {
            using var editing = ParagraphEditing.Open(path, 1, BlockOf(path, "Portable"));
            Assert.NotNull(editing);
            Assert.StartsWith("Portable documents", editing!.Paragraph.String());
            Assert.False(editing.Paragraph.IsModified);
            var before = File.ReadAllBytes(path);
            Assert.False(editing.Apply());
            Assert.Equal(before, File.ReadAllBytes(path));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void AWordDeletedChangesItsLineAndTheFileGetsAnUpdate()
    {
        var path = Sample();
        try
        {
            var before = File.ReadAllBytes(path);
            using (var editing = ParagraphEditing.Open(path, 1, BlockOf(path, "Portable"))!)
            {
                var p = editing.Paragraph;
                var range = p.Find("hard ")!.Value;
                p.Replace(range.Start, range.End, "");
                Assert.InRange(p.RewrittenLines.Count, 1, 2);
                Assert.Equal(0, p.RewrittenLines[0]);
                Assert.NotNull(editing.Preview());
                Assert.True(editing.Apply());
            }
            var after = File.ReadAllBytes(path);
            // An incremental update: the file as it was, then the page's new content.
            Assert.True(after.Length > before.Length);
            Assert.Equal(before, after[..before.Length]);
            var text = Words(path, 1);
            Assert.Contains("are to change", text);
            Assert.DoesNotContain("hard", text);
            Assert.Contains("set again by hand", text);
            Assert.Contains("second paragraph stays exactly", text);
            Assert.Contains("Page two keeps", Words(path, 2));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void TypingUsesTheFontOfThePage()
    {
        var path = Sample();
        try
        {
            using (var editing = ParagraphEditing.Open(path, 1, BlockOf(path, "Portable"))!)
            {
                var p = editing.Paragraph;
                var range = p.Find("single")!.Value;
                p.Replace(range.Start, range.End, "lazy");
                Assert.True(p.IsModified);
                var drawing = p.Draw();
                Assert.Empty(drawing.Fallback);
                Assert.True(editing.Apply());
            }
            Assert.Contains("change of a lazy word", Words(path, 1));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void UndoingToTheOpeningSnapshotIsUnmodified()
    {
        var path = Sample();
        try
        {
            using var editing = ParagraphEditing.Open(path, 1, BlockOf(path, "Portable"))!;
            var p = editing.Paragraph;
            var start = p.Snapshot;
            var range = p.Find("glyphs")!.Value;
            p.Replace(range.Start, range.End, "letters");
            Assert.True(p.IsModified);
            p.Snapshot = start;
            Assert.False(p.IsModified);
            Assert.Empty(p.RewrittenLines);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void HyphenationFollowsThePatterns()
    {
        var points = Hyphenation.Points("segmentation");
        Assert.NotEmpty(points);
        Assert.All(points, p => Assert.InRange(p, 2, "segmentation".Length - 3));
        Assert.Contains(3, Hyphenation.Points("segmentation")); // seg-men-ta-tion
        Assert.Empty(Hyphenation.Points("word"));
    }
}

/// <summary>TRANS-40: which words read from a picture are translated.</summary>
public class ImageTextTests
{
    [Theory]
    [InlineData("Performance Drop", true)]
    [InlineData("Encoder", true)]
    [InlineData("GT", false)]
    [InlineData("CNN", false)]
    [InlineData("0.85", false)]
    [InlineData("x", false)]
    [InlineData("Fig 3a", true)]
    public void WordsWorthTranslating(string text, bool expected) =>
        Assert.Equal(expected, Folio.Core.Translate.Engine.ImageText.IsWords(text));
}
