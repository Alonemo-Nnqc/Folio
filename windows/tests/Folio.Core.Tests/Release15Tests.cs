using System.Text;
using Folio.Core.Translate;
using Folio.Core.Translate.Engine;
using Folio.Core.Translate.Layout;

namespace Folio.Core.Tests;

/// <summary>What 1.5 added on the Mac and Windows follows: Markdown documents, the 出版物 column, translation scheduling
/// and the table headers the engine translates by rule (the macOS MarkdownAndVenueTests and TranslationSchedulerTests).</summary>
public class MarkdownDocumentTests
{
    [Fact]
    public void StandaloneDocumentIsCreatedEditedAndSearched()
    {
        using var library = Library.Temporary();
        var (itemId, fileId) = library.CreateMarkdownDocument("阅读计划");
        var first = library.CreateMarkdownDocument("阅读计划");
        Assert.NotEqual(itemId, first.ItemId); // two documents with the same text are two documents
        var snapshot = library.Snapshot();
        var file = snapshot.Files[fileId];
        Assert.True(file.IsMarkdown);
        Assert.Equal(ItemKind.Standalone, snapshot.Items[itemId].Kind);
        Assert.Equal(fileId, snapshot.Items[itemId].DefaultFileId);
        Assert.Equal("", library.Text(fileId)); // a new document is a blank file
        Assert.Equal(0, snapshot.Files[fileId].Size);
        Assert.Equal("阅读计划", snapshot.Items[itemId].Title);

        const string text = "# 第一周\n\n- [ ] 读 **SAM** 论文\n";
        library.WriteText(text, fileId);
        Assert.Contains("SAM", library.Text(fileId));
        snapshot = library.Snapshot();
        Assert.Equal("第一周", snapshot.Items[itemId].Title); // the title follows the first heading
        Assert.Equal(Encoding.UTF8.GetByteCount(text), snapshot.Files[fileId].Size);
        Assert.Contains(itemId, library.FulltextItemIds("SAM"));
        // The file is plain UTF-8 without a byte order mark, as the Mac writes it.
        var bytes = File.ReadAllBytes(library.FilePath(snapshot.Files[fileId]));
        Assert.Equal(Encoding.UTF8.GetBytes(text), bytes);
    }

    [Fact]
    public void DocumentGoesIntoTheGroupShown()
    {
        using var library = Library.Temporary();
        var group = library.CreateGroup("笔记");
        var (itemId, _) = library.CreateMarkdownDocument("计划", group.Id);
        Assert.Contains(group.Id, library.Snapshot().ItemGroups[itemId]);
    }

    [Fact]
    public void AttachmentKeepsThePapersTitle()
    {
        using var library = Library.Temporary();
        var paper = ((CreateOutcome.Created)library.CreateItem(new Metadata("Segment Anything") { Type = ItemType.JournalArticle })).ItemId;
        var fileId = library.CreateMarkdownAttachment("精读笔记", paper);
        library.WriteText("# 精读\n内容", fileId);
        var snapshot = library.Snapshot();
        Assert.Equal(paper, snapshot.Files[fileId].ItemId);
        Assert.Equal("Segment Anything", snapshot.Items[paper].Title);
        Assert.Equal(fileId, snapshot.Items[paper].DefaultFileId);
        Assert.Equal("Two", Library.FirstHeading("text\n## Two\n"));
        Assert.Null(Library.FirstHeading("no heading\n"));
    }
}

public class VenueCatalogTests
{
    static string? Short(string? source, string? doi = null) => VenueCatalog.Of(source, doi)?.Abbreviation;

    [Fact]
    public void WellKnownVenuesGetTheirShortNames()
    {
        Assert.Equal("ICCV", Short("2023 IEEE/CVF International Conference on Computer Vision (ICCV)"));
        Assert.Equal("CVPR", Short("Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition"));
        Assert.Equal("CVPRW", Short("2024 IEEE/CVF Conference on Computer Vision and Pattern Recognition Workshops (CVPRW)"));
        Assert.Equal("NeurIPS", Short("Advances in Neural Information Processing Systems"));
        Assert.Equal("TPAMI", Short("IEEE Transactions on Pattern Analysis and Machine Intelligence"));
        Assert.Equal("ECCV", Short("European Conference on Computer Vision"));
        Assert.Equal("MedIA", Short("Medical Image Analysis"));
        Assert.Equal("arXiv", Short("arXiv"));
        Assert.Equal("Nature", Short("Nature"));
        Assert.Equal("CVPR", Short(null, "10.1109/CVPR52729.2023.00987"));
        Assert.Equal("BI", Short("Proceedings of the 31st Conference on Brain Informatics (BI 2026)"));
        Assert.Equal("JARSEOS", Short("Journal of Applied Remote Sensing and Earth Observation Science"));
        Assert.Equal("Array", Short("Array"));
        Assert.Equal("A", VenueCatalog.Of("CVPR", null)?.Ccf);
        Assert.Equal("PRL", Short("Pattern Recognition Letters"));
        Assert.Null(Short(null));
    }

    [Fact]
    public void TheListSortsByVenueAsTheMacStoresIt()
    {
        Assert.Equal(SortColumn.Venue, SortColumns.Parse("venue"));
        Assert.Equal("venue", SortColumn.Venue.Raw());
        using var library = Library.Temporary();
        var tpami = ((CreateOutcome.Created)library.CreateItem(new Metadata("B paper") { Source = "IEEE Transactions on Pattern Analysis and Machine Intelligence" })).ItemId;
        var cvpr = ((CreateOutcome.Created)library.CreateItem(new Metadata("A paper") { Source = "CVPR" })).ItemId;
        var none = ((CreateOutcome.Created)library.CreateItem(new Metadata("C paper"))).ItemId;
        var s = library.Snapshot();
        var sorted = new[] { tpami, none, cvpr }.Select(id => s.Items[id]).ToList();
        sorted.Sort((a, b) => SortComparators.Compare(a, b, SortColumn.Venue, true, s));
        Assert.Equal([cvpr, tpami, none], sorted.Select(i => i.Id));
    }
}

public class TranslationSchedulerTests
{
    /// <summary>Starts everything it can, as the coordinator's Pump does.</summary>
    static List<string> Run(List<string> waiting, int perService, int total)
    {
        var running = new List<string>();
        while (TranslationScheduler.Next(waiting, running, perService, total) is { } index)
        {
            running.Add(waiting[index]);
            waiting.RemoveAt(index);
        }
        return running;
    }

    [Fact]
    public void OneServiceIsLimitedByItsOwnShare() =>
        Assert.Equal(["deepseek", "deepseek"], Run(Enumerable.Repeat("deepseek", 6).ToList(), 2, 6));

    [Fact]
    public void OtherServicesDoNotWaitBehindABusyOne() =>
        Assert.Equal(["deepseek", "deepseek", "google", "claude", "google"], Run(["deepseek", "deepseek", "deepseek", "google", "claude", "google"], 2, 6));

    [Fact]
    public void TheTotalCapsAllServices()
    {
        var started = Run(["a", "b", "c", "d", "e", "f", "g", "h", "i"], 2, 8);
        Assert.Equal(8, started.Count);
        Assert.Null(TranslationScheduler.Next(["x"], started, 2, 8));
    }

    [Fact]
    public void OrderIsKeptWithinAService() =>
        // The first waiting paper of a service with room goes first.
        Assert.Equal(1, TranslationScheduler.Next(["a", "b", "a"], ["a", "a"], 2, 6));
}

public class TableHeaderTests
{
    [Fact]
    public void BenchmarkGroupsTranslateByRule()
    {
        Assert.Equal("中", StandardCells.Translate("med.", "zh-Hans"));
        Assert.Equal("高频", StandardCells.Translate("Freq.", "zh-Hans"));
        Assert.Equal("均值 ± 标准差", StandardCells.Translate("mean ± std", "zh-Hans"));
        Assert.Null(StandardCells.Translate("small", "ja"));
        Assert.True(StandardCells.IsKnown(" Rare "));
    }

    [Fact]
    public void AbbreviationsAloneAreKept()
    {
        // Known headers go through StandardCells; other abbreviations read as something else to a translator.
        Assert.True(LayoutAnalyzer.IsCellText("freq."));
        Assert.True(LayoutAnalyzer.IsCellText("small"));
        Assert.False(LayoutAnalyzer.IsCellText("Acc."));
        Assert.False(LayoutAnalyzer.IsCellText("w/o"));
        Assert.True(LayoutAnalyzer.IsCellText("zero-shot transfer methods:"));
    }
}

public class VenueColumnTests
{
    [Fact]
    public void ListsChosenBeforeGetTheVenueColumnOnce()
    {
        var path = Path.Combine(Path.GetTempPath(), $"folio-settings-{Guid.NewGuid():N}.json");
        try
        {
            var settings = new AppSettings(path);
            settings.VisibleColumns = ["title", "source", "year"];
            settings.AddVenueColumnOnce();
            Assert.Equal(["title", "venue", "source", "year"], settings.VisibleColumns);
            // Hidden afterwards, it stays hidden.
            settings.VisibleColumns = ["title", "source", "year"];
            settings.AddVenueColumnOnce();
            Assert.Equal(["title", "source", "year"], settings.VisibleColumns);
            // New users see it by default.
            var fresh = new AppSettings(path + ".new");
            fresh.AddVenueColumnOnce();
            Assert.Contains("venue", fresh.VisibleColumns);
        }
        finally
        {
            File.Delete(path);
            File.Delete(path + ".new");
        }
    }
}
