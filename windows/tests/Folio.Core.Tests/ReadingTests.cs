using UglyToad.PdfPig.Writer;
using UglyToad.PdfPig.Content;

namespace Folio.Core.Tests;

/// <summary>READ-01: how far papers have been read, and the sidebar's 阅读 (as the macOS tests).</summary>
public class ReadingTests : IDisposable
{
    readonly string _root = Path.Combine(Path.GetTempPath(), $"folio-reading-{Guid.NewGuid():N}");

    public void Dispose() { try { Directory.Delete(_root, true); } catch { } }

    string Pdf(string name)
    {
        Directory.CreateDirectory(_root);
        var builder = new PdfDocumentBuilder();
        var font = builder.AddStandard14Font(UglyToad.PdfPig.Fonts.Standard14Fonts.Standard14Font.Helvetica);
        builder.AddPage(PageSize.A4).AddText(name + Guid.NewGuid(), 12, new UglyToad.PdfPig.Core.PdfPoint(50, 700), font);
        var path = Path.Combine(_root, name + ".pdf");
        File.WriteAllBytes(path, builder.Build());
        return path;
    }

    static ReadingState State(string file, int page, int? count, string? seen, int seconds) =>
        new(file, page, 0, 0, 1, true, 1, DateTime.UnixEpoch.AddSeconds(seconds), count, seen);

    [Fact]
    public void ProgressIsThePageReached()
    {
        Assert.Equal(10, new SeenPages(11, "11001110011").Reached);
        Assert.Equal(2, new SeenPages(16, "1110000000000001").Reached);
        Assert.Null(new SeenPages(4, "").Reached);
        Assert.Equal("01", new SeenPages(2, "0111").Stored);
        using var library = new Library(Path.Combine(_root, "lib"));
        library.ImportFiles([Pdf("a")]);
        var file = library.Snapshot().Files.Values.Single();
        Assert.Empty(library.ReadingProgress());
        library.SaveReadingState(State(file.Id, 3, 10, "1111000000", 100));
        // The place moves back, the page reached stays.
        library.SaveReadingState(library.KeepingSeenPages(State(file.Id, 0, 10, null, 200)));
        var progress = library.ReadingProgress()[file.ItemId];
        Assert.Equal((0.4, 3, file.Id), (progress.Fraction, progress.PageIndex, progress.FileId));
        // Left by a version before 1.6: filled in from the document.
        library.SaveReadingState(State(file.Id, 8, null, null, 300));
        Assert.Equal([file.Id], library.FilesWithoutPageCount());
        library.SetPageCount(10, file.Id);
        Assert.Equal(0.9, library.ReadingProgress()[file.ItemId].Fraction, 3);
        Assert.Empty(library.FilesWithoutPageCount());
    }

    [Fact]
    public void UnnamedDocumentsAreToldApartAndNamedByTheirHeading()
    {
        using var library = new Library(Path.Combine(_root, "lib"));
        library.CreateMarkdownDocument("未命名文档");
        var b = library.CreateMarkdownDocument("未命名文档");
        string Title() => library.Snapshot().Items[b.ItemId].Title;
        Assert.Equal("未命名文档 2", Title());
        library.WriteText("# 第一周\n", b.FileId);
        Assert.Equal(("第一周", "第一周.md"), (Title(), library.Snapshot().Files[b.FileId].FileName));
        Assert.Equal("# 第一周\n", library.Text(b.FileId));
        library.RenameMarkdownFile(b.FileId, "周报");
        library.WriteText("# 第三周\n", b.FileId);
        Assert.Equal(("周报", "周报.md"), (Title(), library.Snapshot().Files[b.FileId].FileName));
    }

    [Fact]
    public void APaperOpenedForTheFirstTimeHasNoneSeen()
    {
        using var library = new Library(Path.Combine(_root, "lib"));
        library.ImportFiles([Pdf("a")]);
        var file = library.Snapshot().Files.Values.Single();
        Assert.Equal("", library.KeepingSeenPages(State(file.Id, 29, 30, null, 1)).SeenPages);
    }

    [Fact]
    public void StatusScopesAndTheirOrder()
    {
        using var library = new Library(Path.Combine(_root, "lib"));
        library.ImportFiles([Pdf("a"), Pdf("b"), Pdf("c")]);
        var ids = library.Snapshot().Items.Keys.ToList();
        library.UpdateItems([ids[0], ids[1]], i => i.ReadStatus = ReadStatus.Reading);
        library.UpdateItem(ids[2], i => i.ReadStatus = ReadStatus.Read);
        var s = library.Snapshot();
        var counts = SidebarCounts.Compute(s, true);
        Assert.Equal((0, 2, 1), (counts["status:0"], counts["status:1"], counts["status:2"]));
        ViewQuery Query(DateTime a, DateTime b) => new(ViewScope.StatusOf(ReadStatus.Reading)) { LastRead = new Dictionary<string, DateTime> { [ids[0]] = a, [ids[1]] = b } };
        var (early, late) = (DateTime.UtcNow.AddYears(1), DateTime.UtcNow.AddYears(2));
        Assert.Equal([ids[0], ids[1]], ViewResolver.Rows(Query(late, early), s));
        Assert.Equal([ids[1], ids[0]], ViewResolver.Rows(Query(early, late), s));
        Assert.True(s.TracksReading(s.Items[ids[0]]));
    }
}
