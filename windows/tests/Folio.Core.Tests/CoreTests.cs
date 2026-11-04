using Folio.Core;
using Folio.Core.Citation;
using Folio.Core.Retrieval;

namespace Folio.Core.Tests;

public class LibraryTests
{
    static Metadata Paper(string title = "Spectral Dynamic Attention Network for Hyperspectral Image Super-Resolution") => new(title)
    {
        Type = ItemType.Preprint,
        Authors = [new("Zhang", "Tengya"), new("Gao", "Feng")],
        Year = 2026,
        Source = "arXiv",
        ArxivId = "2604.27326",
        Doi = "10.48550/arxiv.2604.27326",
    };

    [Fact]
    public void CreatesItemsWithCitationKeysAndDetectsDuplicates()
    {
        using var library = Library.Temporary();
        var first = library.CreateItem(Paper());
        var created = Assert.IsType<CreateOutcome.Created>(first);
        Assert.Equal("zhang2026", library.Item(created.ItemId)!.CitationKey);
        Assert.IsType<CreateOutcome.Duplicate>(library.CreateItem(Paper()));
        var other = Assert.IsType<CreateOutcome.Created>(library.CreateItem(Paper("Another Paper Entirely") with { Doi = "10.1/x", ArxivId = null }));
        Assert.Equal("zhang2026a", library.Item(other.ItemId)!.CitationKey);
    }

    [Fact]
    public void ChineseFamilyNamesBecomePinyinKeys()
    {
        var m = new Metadata("论文") { Authors = [new("张", "三")], Year = 2024 };
        Assert.Equal("zhang2024", CitationKeyGenerator.BaseKey(m));
    }

    [Fact]
    public void GroupsNestTwoLevelsAndTagsAreUnique()
    {
        using var library = Library.Temporary();
        var parent = library.CreateGroup("2026美赛B题");
        var child = library.CreateGroup("参考文献", parent.Id);
        Assert.Throws<LibraryException>(() => library.CreateGroup("太深", child.Id));
        Assert.Throws<LibraryException>(() => library.CreateGroup("参考文献", parent.Id));
        var id = ((CreateOutcome.Created)library.CreateItem(Paper())).ItemId;
        library.AddItems([id], child.Id, false);
        var snapshot = library.Snapshot();
        Assert.Contains(id, ViewResolver.Members(ViewScope.Group(parent.Id), snapshot, includeSubgroupItems: true));
        Assert.DoesNotContain(id, ViewResolver.Members(ViewScope.Unfiled, snapshot, true));
        var tag = library.CreateTag("必读", "#FF3B30");
        Assert.Throws<LibraryException>(() => library.CreateTag("必读", "#000000"));
        library.SetTag(tag.Id, [id], true);
        Assert.Single(library.Snapshot().TagsOf(id));
    }

    [Fact]
    public void ImportsFilesTrashesAndRestores()
    {
        using var library = Library.Temporary();
        var source = Path.Combine(Path.GetTempPath(), $"paper-{Guid.NewGuid()}.pdf");
        File.WriteAllText(source, "%PDF-1.4 fake");
        var outcome = Assert.IsType<ImportOutcome.Imported>(library.ImportFiles([source]).Single());
        Assert.IsType<ImportOutcome.DuplicateFile>(library.ImportFiles([source]).Single());
        library.TrashItems([outcome.ItemId]);
        Assert.IsType<ImportOutcome.DuplicateInTrash>(library.ImportFiles([source]).Single());
        library.RestoreItems([outcome.ItemId]);
        Assert.False(library.Item(outcome.ItemId)!.IsTrashed);
        Assert.IsType<ApplyOutcome.Created>(library.ApplyMetadata(Paper(), outcome.ItemId, autoRename: true));
        var file = library.Files(outcome.ItemId).Single();
        Assert.StartsWith("Files/Zhang_2026_Spectral Dynamic Attention", file.RelativePath);
        Assert.True(File.Exists(library.FilePath(file)));
    }

    [Fact]
    public void SearchesMetadataAndFulltext()
    {
        using var library = Library.Temporary();
        var id = ((CreateOutcome.Created)library.CreateItem(Paper())).ItemId;
        var rows = ViewResolver.Rows(new ViewQuery(ViewScope.All, "hyperspectral zhang"), library.Snapshot());
        Assert.Equal([id], rows);
        Assert.Empty(ViewResolver.Rows(new ViewQuery(ViewScope.All, "nothing-like-this"), library.Snapshot()));
    }

    /// <summary>A library written by the macOS app (folio-seed demo) opens and reads the same.</summary>
    [Fact]
    public void ReadsALibraryWrittenByTheMacApp()
    {
        var path = Environment.GetEnvironmentVariable("FOLIO_MAC_LIBRARY");
        if (string.IsNullOrEmpty(path) || !Directory.Exists(path)) return;
        var copy = Path.Combine(Path.GetTempPath(), $"folio-mac-copy-{Guid.NewGuid()}");
        Directory.CreateDirectory(copy);
        foreach (var file in Directory.GetFiles(path)) File.Copy(file, Path.Combine(copy, Path.GetFileName(file)));
        using var library = new Library(copy);
        var s = library.Snapshot();
        Assert.NotEmpty(s.Items);
        Assert.NotEmpty(s.Tags);
        Assert.NotEmpty(s.TopLevelGroups);
        Assert.Contains(s.Items.Values, i => i.Kind == ItemKind.Regular && i.Authors.Count > 0 && i.CitationKey != null);
        // And the macOS app's migrations are recognized: nothing is migrated twice.
        library.CreateGroup("Windows " + Guid.NewGuid().ToString("N")[..6]);
        Assert.Equal(s.Items.Count, library.Snapshot().Items.Count);
    }
}

public class TextTests
{
    [Theory]
    [InlineData("doi:10.1016/J.BSPC.2024.106296.", "10.1016/j.bspc.2024.106296")]
    [InlineData("https://doi.org/10.1109/TPAMI.2020.1234", "10.1109/tpami.2020.1234")]
    public void ParsesDois(string input, string expected) => Assert.Equal(new Identifier.Doi(expected), Identifier.Parse(input));

    [Theory]
    [InlineData("arXiv:2604.27326v2", "2604.27326")]
    [InlineData("https://arxiv.org/abs/2405.02717", "2405.02717")]
    [InlineData("2405.02717", "2405.02717")]
    public void ParsesArxivIds(string input, string expected) => Assert.Equal(new Identifier.Arxiv(expected), Identifier.Parse(input));

    [Fact]
    public void ParsesIsbns() => Assert.Equal(new Identifier.Isbn("9780262035613"), Identifier.Parse("ISBN 978-0-262-03561-3"));

    [Fact]
    public void NormalizesTitles()
    {
        Assert.Equal("cafe deja vu", TitleNormalizer.Normalize("Café — Déjà-Vu!"));
        Assert.True(TitleNormalizer.Similarity("Deep Residual Learning for Image Recognition", "Deep residual learning for image recognition.") >= 0.99);
    }

    [Fact]
    public void NamesFilesLikeTheMacApp()
    {
        var m = new Metadata("UNet++: A Nested U-Net Architecture") { Authors = [new("Zhou", "Zongwei")], Year = 2018 };
        Assert.Equal("Zhou_2018_UNet++ - A Nested U-Net Architecture", FileNamer.BaseName(m));
        Assert.Equal("DeepSeek · deepseek-chat", FileNamer.TranslatedBy("论文（简体中文译文 · DeepSeek · deepseek-chat）"));
    }

    [Fact]
    public void UsesTheMacStringsInEnglish()
    {
        Loc.Override = "en";
        try
        {
            Assert.Equal("A group named “X” already exists", Loc.S("已存在名为「%@」的分组", "X"));
            Assert.True(Loc.EnglishTable.Count > 900);
        }
        finally { Loc.Override = "zh-Hans"; }
    }
}

public class CitationTests
{
    static readonly CitationEntry Entry = new("1", "zhang2026", new Metadata("Spectral Dynamic Attention Network for Hyperspectral Image Super-Resolution")
    {
        Type = ItemType.JournalArticle, Authors = [new("Zhang", "Tengya"), new("Gao", "Feng")], Year = 2026,
        Source = "IEEE Transactions on Geoscience and Remote Sensing", Volume = "64", Pages = "1-14", Doi = "10.1109/tgrs.2026.1",
    });

    [Fact]
    public void FormatsWithCiteproc()
    {
        var renderer = new CslRenderer();
        var apa = renderer.Render([Entry], CitationStyle.Apa).PlainText;
        Assert.Contains("Zhang, T., & Gao, F. (2026)", apa);
        var gb = renderer.Render([Entry], CitationStyle.Gbt7714).PlainText;
        Assert.StartsWith("ZHANG T, GAO F.", gb);
        var (each, _) = renderer.InTextCitations([Entry], CitationStyle.Apa);
        Assert.Equal("(Zhang & Gao, 2026)", each[0]);
    }

    [Fact]
    public void RoundTripsBibTeX()
    {
        var bib = BibTeXWriter.Document([Entry]);
        Assert.Contains("@article{zhang2026,", bib);
        var parsed = ReferenceFormats.Parse(bib).Single();
        Assert.Equal(Entry.Metadata.Title, parsed.Metadata.Title);
        Assert.Equal("zhang2026", parsed.CitationKey);
        Assert.Equal(2, parsed.Metadata.Authors.Count);
    }
}
