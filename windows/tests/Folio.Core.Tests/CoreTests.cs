using Folio.Core;
using Folio.Core.Citation;
using Folio.Core.Retrieval;

namespace Folio.Core.Tests;

public class LibraryTests
{
    static FileRecord TabFile(string id, TranslationKind? kind = null, string? by = null, string? of = null) =>
        new("i", $"Files/{id}.pdf", $"{id}.pdf", 0, id, DateTime.UtcNow, id: id) { TranslationKind = kind, TranslatedBy = by, TranslationOf = of };

    [Theory]
    [InlineData("SnakeSAM: A topology-preserving foundation model", "SnakeSAM")]
    [InlineData("视网膜分割：一种新方法", "视网膜分割")]
    [InlineData(" Attention Is All You Need ", "Attention Is All You Need")]
    [InlineData("Sleeping at 10:30 in Teens", "Sleeping at 10:30 in Teens")]
    [InlineData("Trailing:", "Trailing:")]
    [InlineData("X: a study", "X: a study")]
    public void ShortTitlesStopAtTheSubtitle(string title, string expected) => Assert.Equal(expected, FileLabel.ShortTitle(title));

    [Fact]
    public void TabsTellPapersAndTranslationsApart()
    {
        Loc.Override = "zh-Hans";
        var item = new Item(ItemKind.Regular, "SnakeSAM: A topology-preserving model", id: "i") { DefaultFileId = "p" };
        var original = TabFile("p");
        var mono = TabFile("m", TranslationKind.Mono, "Google", "p");
        var dual = TabFile("d", TranslationKind.Dual, "Google", "p");
        List<FileRecord> files = [original, mono, dual];
        Assert.Equal("SnakeSAM", FileLabel.TabTitle(original, item, files));
        // The kind comes first, so a narrow tab still shows it, then who translated it.
        Assert.Equal("译文 · Google · SnakeSAM", FileLabel.TabTitle(mono, item, files));
        Assert.Equal("双语对照 · Google · SnakeSAM", FileLabel.TabTitle(dual, item, files));
        // Several of a kind: the service tells them apart; the same service: the time.
        var other = TabFile("o", TranslationKind.Mono, "DeepSeek", "p");
        Assert.Equal("译文 · Google · SnakeSAM", FileLabel.TabTitle(mono, item, [.. files, other]));
        Assert.Equal("译文 · DeepSeek · SnakeSAM", FileLabel.TabTitle(other, item, [.. files, other]));
        var again = TabFile("a", TranslationKind.Mono, "Google", "p");
        again.DateAdded = mono.DateAdded.AddHours(3);
        Assert.NotEqual(FileLabel.TabTitle(mono, item, [.. files, again]), FileLabel.TabTitle(again, item, [.. files, again]));
        Assert.StartsWith("译文 · ", FileLabel.TabTitle(again, item, [.. files, again]));
        Assert.Contains("Google", FileLabel.TabTitle(again, item, [.. files, again]));
        Assert.EndsWith(" · SnakeSAM", FileLabel.TabTitle(again, item, [.. files, again]));
        // Within one service, the model; the same service and model, the time, and nothing that is the same for all.
        var low = TabFile("l", TranslationKind.Dual, "Agent · low", "p");
        var high = TabFile("h", TranslationKind.Dual, "Agent · high", "p");
        Assert.Equal("双语对照 · Agent · low · SnakeSAM", FileLabel.TabTitle(low, item, [original, low, high]));
        var later = TabFile("t", TranslationKind.Dual, "Agent · low", "p");
        later.DateAdded = low.DateAdded.AddHours(3);
        var timed = FileLabel.TabTitle(later, item, [original, low, later]);
        Assert.StartsWith("双语对照 · ", timed);
        Assert.EndsWith(" · SnakeSAM", timed);
        Assert.Contains("Agent", timed);
        Assert.DoesNotContain("low", timed);
        Assert.NotEqual(timed, FileLabel.TabTitle(low, item, [original, low, later]));
        // Another file of the paper keeps its own name.
        var supplement = TabFile("Supplement");
        Assert.Equal("Supplement", FileLabel.TabTitle(supplement, item, [.. files, supplement]));
    }

    [Fact]
    public void CommandLinesForCmdKeepQuotesAndDropLineBreaks()
    {
        Assert.Equal("\"C:\\my tools\\t.cmd\" \"--flag\" \"say \"\"hi\"\"\" \"one two\"",
            Folio.Core.Translate.Services.CommandLine.ForCmd(["C:\\my tools\\t.cmd", "--flag", "say \"hi\"", "one\r\ntwo"]));
        var plain = new System.Diagnostics.ProcessStartInfo("x");
        Folio.Core.Translate.Services.CommandLine.Apply(plain, ["a b", "c"]);
        Assert.Equal(["a b", "c"], plain.ArgumentList);
        var shell = new System.Diagnostics.ProcessStartInfo("cmd.exe");
        Folio.Core.Translate.Services.CommandLine.Apply(shell, ["/d", "/s", "/c", "findstr /r \".*\""]);
        Assert.Equal("/d /s /c \"findstr /r \".*\"\"", shell.Arguments);
        Assert.Empty(shell.ArgumentList);
    }

    /// <summary>The ends of real shims, from a Windows machine: npm's start with a check for node.exe, which is not what they run.</summary>
    [Theory]
    [InlineData("\"%_prog%\"  \"%dp0%\\node_modules\\cline\\bin\\cline\" %*", "node_modules/cline/bin/cline", true)]
    [InlineData("\"%_prog%\"  \"%dp0%\\node_modules\\@earendil-works\\pi-coding-agent\\dist\\bundle\\cli.js\" %*", "node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js", true)]
    [InlineData("\"%dp0%\\node_modules\\opencode-ai\\bin\\opencode.exe\"   %*", "node_modules/opencode-ai/bin/opencode.exe", false)]
    public void NpmShimsRunWhatTheyPointAt(string lastLine, string expected, bool throughNode)
    {
        if (!OperatingSystem.IsWindows()) expected = expected.Replace('\\', '/');
        var folder = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var shim = Path.Combine(folder, "tool.cmd");
            File.WriteAllText(shim, "@ECHO off\r\nSETLOCAL\r\nCALL :find_dp0\r\nIF EXIST \"%dp0%\\node.exe\" (\r\n  SET \"_prog=%dp0%\\node.exe\"\r\n) ELSE (\r\n  SET \"_prog=node\"\r\n)\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & " + lastLine + "\r\n");
            var (file, arguments, _) = Folio.Core.Translate.Services.LocalProcess.Resolve([shim, "--flag"]);
            var target = (throughNode ? arguments[0] : file).Replace('\\', '/');
            Assert.EndsWith(expected, target);
            Assert.Equal("--flag", arguments[^1]);
            Assert.Equal(throughNode ? 2 : 1, arguments.Count);
        }
        finally { Directory.Delete(folder, true); }
    }

    /// <summary>Shims of other shapes run what they start, without cmd.exe (whose line ends at 8191 characters, shorter than a prompt).</summary>
    [Fact]
    public void OtherShimsRunWithoutCmd()
    {
        if (!OperatingSystem.IsWindows()) return;
        var folder = Directory.CreateTempSubdirectory().FullName;
        try
        {
            // Pi's: the Node it installed, when it is there.
            var node = Path.Combine(folder, "pi-node", "node.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(node)!);
            File.WriteAllText(node, "");
            var pi = Path.Combine(folder, "bin", "pi.cmd");
            Directory.CreateDirectory(Path.GetDirectoryName(pi)!);
            File.WriteAllText(pi, "@ECHO off\nSETLOCAL\nSET \"node=node\"\nIF EXIST \"" + node + "\" SET \"node=" + node + "\"\n\"%node%\" \"%~dp0pi-launcher.js\" %*\nSET \"pi_exit_code=%ERRORLEVEL%\"\nIF \"%pi_exit_code%\"==\"9009\" (\n  GOTO node_missing\n)\nEXIT /B %pi_exit_code%\n");
            var (file, arguments, _) = Folio.Core.Translate.Services.LocalProcess.Resolve([pi, "-p", "a prompt"]);
            Assert.Equal(node, file);
            Assert.Equal([Path.Combine(folder, "bin", "pi-launcher.js"), "-p", "a prompt"], arguments);

            // DeepSeek Harness's: Electron run as Node, from four folders up.
            var app = Path.Combine(folder, "DeepSeek Harness.exe");
            File.WriteAllText(app, "");
            var dsh = Path.Combine(folder, "resources", "runtime", "cli", "bin", "dsh.cmd");
            Directory.CreateDirectory(Path.GetDirectoryName(dsh)!);
            File.WriteAllText(dsh, "@echo off\r\nsetlocal DisableDelayedExpansion\r\nset \"ELECTRON_RUN_AS_NODE=1\"\r\n\"%~dp0..\\..\\..\\..\\DeepSeek Harness.exe\" --expose-internals \"%~dp0..\\..\\..\\app.asar\\dsh\\lib\\cli.js\" %*\r\nexit /b %errorlevel%\r\n");
            var (exe, args, environment) = Folio.Core.Translate.Services.LocalProcess.Resolve([dsh, "--profile", "headless", "-"]);
            Assert.Equal(app, exe);
            Assert.Equal(["--expose-internals", Path.Combine(folder, "resources", "app.asar", "dsh", "lib", "cli.js"), "--profile", "headless", "-"], args);
            Assert.Equal("1", environment["ELECTRON_RUN_AS_NODE"]);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public void DeepseekHarnessKeyIsReadFromItsRefs()
    {
        var yaml = "version: 1\nrecords:\n  deepseek-account-platform/default:\n    kind: grant\n    payload:\n      token: abc\nrefs:\n  DEEPSEEK_API_KEY: sk-test123\n";
        Assert.Equal("sk-test123", Folio.Core.Translate.Services.DeepseekHarness.StoredKey(yaml));
        Assert.Equal("sk-q", Folio.Core.Translate.Services.DeepseekHarness.StoredKey("refs:\r\n  OTHER: x\r\n  DEEPSEEK_API_KEY: \"sk-q\"\r\n"));
        Assert.Null(Folio.Core.Translate.Services.DeepseekHarness.StoredKey("records:\n  DEEPSEEK_API_KEY: nope\n"));
    }

    [Fact]
    public void CodexProviderSectionsAreRead()
    {
        var toml = "model_provider = \"custom\"\nmodel = \"gpt-6-astra\"\n[tui]\nx = 1\n\n[model_providers.custom]\nname = \"custom\"\nbase_url = \"https://relay.example\"\nexperimental_bearer_token = 'sk-1'\n";
        Assert.Equal("https://relay.example", Folio.Core.Translate.Services.AgentModels.SectionValue(toml, "model_providers.custom", "base_url"));
        Assert.Equal("sk-1", Folio.Core.Translate.Services.AgentModels.SectionValue(toml, "model_providers.custom", "experimental_bearer_token"));
        Assert.Null(Folio.Core.Translate.Services.AgentModels.SectionValue(toml, "tui", "base_url"));
    }

    [Fact]
    public void CodexDroppedStreamIsExplainedNotRetried()
    {
        Loc.Override = "zh-Hans";
        var printed = "OpenAI Codex v0.167.0\nuser\nTranslate this JSON object: there is no reason not to translate\nERROR: Reconnecting... 5/5\nERROR: stream disconnected before completion: stream closed before response.completed\n";
        var error = Folio.Core.Translate.Services.AgentFailure.Classify("exit 1: " + printed, Folio.Core.Translate.Services.LocalAgent.Codex);
        Assert.Equal(Folio.Core.Translate.Services.ProviderError.Kinds.AgentSetup, error.Kind);
        Assert.False(error.IsRetryable);
        var shown = Folio.Core.Translate.Services.TranslationErrorClassifier.Classify("agent-setup codex: stream-disconnected https://relay.example").Message;
        Assert.Contains("https://relay.example/v1", shown);
        Assert.Equal("stream disconnected before completion: stream closed before response.completed",
            Folio.Core.Translate.Services.AgentFailure.FirstMeaningfulLine(printed).Replace("ERROR: ", ""));
    }

    [Fact]
    public void TabsOfLooseFilesUseTheirNames()
    {
        Loc.Override = "zh-Hans";
        var item = new Item(ItemKind.Standalone, "scan.pdf", id: "i") { DefaultFileId = "scan" };
        var scan = TabFile("scan");
        var translated = TabFile("scan（译文）", TranslationKind.Mono, null, "scan");
        Assert.Equal("scan", FileLabel.TabTitle(scan, item, [scan, translated]));
        Assert.Equal("译文 · scan", FileLabel.TabTitle(translated, item, [scan, translated]));
        Assert.Equal("scan", FileLabel.TabTitle(scan, null, []));
    }

    [Fact]
    public void TabToolTipsCarryWhatTheTabLeavesOut()
    {
        Loc.Override = "zh-Hans";
        var item = new Item(ItemKind.Regular, "SnakeSAM: A topology-preserving model", id: "i") { DefaultFileId = "p", Authors = [new("Li", "Jingwen")], Year = 2026 };
        var original = TabFile("p");
        var mono = TabFile("m", TranslationKind.Mono, "Google", "p");
        Assert.Equal("SnakeSAM: A topology-preserving model\nLi 2026 · 译文 · Google", FileLabel.TabToolTip(mono, item, [original, mono]));
    }

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

public class AnnotationTests
{
    /// <summary>FOLIO_SAMPLE_PDF: a real paper; annotations are written to a copy and read back.</summary>
    [Fact]
    public void WritesAnnotationsByIncrementalUpdate()
    {
        var sample = Environment.GetEnvironmentVariable("FOLIO_SAMPLE_PDF");
        if (string.IsNullOrEmpty(sample) || !File.Exists(sample)) return;
        var copy = Path.Combine(Path.GetTempPath(), $"annotated-{Guid.NewGuid():N}.pdf");
        File.Copy(sample, copy);
        var before = PdfAnnotations.Read(copy).Count;
        // The quad of page 1's first text line, from its letters.
        double[] quad;
        using (var doc = UglyToad.PdfPig.PdfDocument.Open(copy))
        {
            var letters = doc.GetPage(1).Letters.Where(l => l.Value.Trim().Length > 0).ToList();
            var y = letters[0].StartBaseLine.Y;
            var line = letters.Where(l => Math.Abs(l.StartBaseLine.Y - y) < 1).ToList();
            double left = line.Min(l => l.BoundingBox.Left), right = line.Max(l => l.BoundingBox.Right);
            double bottom = line.Min(l => l.BoundingBox.Bottom), top = line.Max(l => l.BoundingBox.Top);
            quad = [left, top, right, top, left, bottom, right, bottom];
        }
        // A highlight over the top of page 1, an underline, a note and a stroke.
        AnnotationWriter.Add(copy, [
            new NewAnnotation(1, "Highlight", "yellow", Quads: [quad], Author: "Folio Test"),
            new NewAnnotation(1, "Underline", "blue", Quads: [[50, 650, 300, 650, 50, 630, 300, 630]]),
            new NewAnnotation(1, "Text", "pink", Rect: [500, 500, 520, 520], Contents: "批注：中文内容"),
            new NewAnnotation(2, "Ink", "red", Strokes: [[100, 100, 150, 150, 200, 120]]),
        ]);
        var after = PdfAnnotations.Read(copy);
        Assert.Equal(before + 4, after.Count);
        Assert.Contains(after, a => a.Kind == "note" && a.Comment == "批注：中文内容");
        Assert.Contains(after, a => a.Kind == "highlight" && a.Author == "Folio Test" && !string.IsNullOrEmpty(a.Text));
        Assert.Equal(PdfText.PageCount(sample), PdfText.PageCount(copy));
        File.Copy(copy, Path.Combine(Path.GetTempPath(), "folio-annotated-latest.pdf"), true);
    }

    /// <summary>The reader's editing: recolour, comment, move and delete by object number; undo by cutting the end off.</summary>
    [Fact]
    public void ModifiesRemovesAndUndoesAnnotations()
    {
        var original = TestPdfs.OnePage();
        var copy = Path.Combine(Path.GetTempPath(), $"folio-annotation-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(copy, original);
        try
        {
            AnnotationWriter.Add(copy, [new NewAnnotation(1, "Highlight", "yellow", Quads: [[10, 100, 200, 100, 10, 80, 200, 80]], Author: "作者")]);
            long afterAdd = new FileInfo(copy).Length;
            long number = ObjectNumberOfFirstAnnotation(copy);
            Assert.True(AnnotationWriter.Modify(copy, 1, number, color: "green"));
            var green = Assert.Single(PdfAnnotations.Read(copy));
            Assert.Equal(AnnotationColors.Hex("green").ToUpperInvariant(), MaskToHex(green.ColorHex));
            Assert.Equal("作者", green.Author);
            Assert.True(AnnotationWriter.Modify(copy, 1, number, contents: "评论 comment"));
            Assert.Equal("评论 comment", Assert.Single(PdfAnnotations.Read(copy)).Comment);
            Assert.True(AnnotationWriter.Modify(copy, 1, number, dx: 5, dy: -5));
            Assert.Single(PdfAnnotations.Read(copy));
            // Undo is exact: back to the earlier bytes.
            var tail = AnnotationWriter.TruncateTo(copy, afterAdd);
            Assert.Equal(AnnotationColors.Hex("yellow").ToUpperInvariant(), MaskToHex(Assert.Single(PdfAnnotations.Read(copy)).ColorHex));
            AnnotationWriter.Append(copy, tail);
            Assert.Equal("评论 comment", Assert.Single(PdfAnnotations.Read(copy)).Comment);
            Assert.True(AnnotationWriter.Remove(copy, 1, number));
            Assert.Empty(PdfAnnotations.Read(copy));
            Assert.False(AnnotationWriter.Remove(copy, 1, number));
        }
        finally { File.Delete(copy); }
    }

    static string MaskToHex(string hex) => hex.ToUpperInvariant();

    static long ObjectNumberOfFirstAnnotation(string path)
    {
        using var document = UglyToad.PdfPig.PdfDocument.Open(path);
        var page = document.GetPage(1);
        var annots = page.Dictionary.Data["Annots"] as UglyToad.PdfPig.Tokens.ArrayToken;
        return ((UglyToad.PdfPig.Tokens.IndirectReferenceToken)annots!.Data[0]).Data.ObjectNumber;
    }
}

public class LayoutTests
{
    /// <summary>HarfBuzz keeps reading the font for as long as it shapes: a collection must not take it away (this used to crash the process).</summary>
    [Fact]
    public void ShapingSurvivesGarbageCollection()
    {
        for (int round = 0; round < 40; round++)
        {
            var text = $"Round {round} of shaping 第 {round} 轮排版 {Guid.NewGuid():N}";
            var paragraph = new Folio.Core.Translate.Typeset.Paragraph(text, new bool[text.Length], new Folio.Core.Translate.Typeset.InlineObject?[text.Length], "zh-CN", round % 2 == 0, 12, default);
            Assert.True(paragraph.Advance(0) > 0);
            System.Runtime.GCSettings.LargeObjectHeapCompactionMode = System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
            GC.Collect(GC.MaxGeneration, GCCollectionMode.Aggressive, blocking: true, compacting: true);
            // Whatever was freed gets reused, so a stale pointer reads rubbish instead of the old font.
            var rubbish = Enumerable.Range(0, 8).Select(_ => new byte[1 << 24]).ToList();
            rubbish.ForEach(b => Array.Fill(b, (byte)0xFF));
            GC.KeepAlive(rubbish);
        }
    }

    /// <summary>FOLIO_SAMPLE_PDF + FOLIO_LAYOUT_DUMP: writes the analysis in the macOS folio-translate layout DUMP format, for diffing.</summary>
    [Fact]
    public void DumpsLayoutLikeTheMacEngine()
    {
        var sample = Environment.GetEnvironmentVariable("FOLIO_SAMPLE_PDF");
        var output = Environment.GetEnvironmentVariable("FOLIO_LAYOUT_DUMP");
        if (string.IsNullOrEmpty(sample) || string.IsNullOrEmpty(output)) return;
        using var source = Folio.Core.Translate.Pdf.PdfSource.Open(sample);
        var analyzer = new Folio.Core.Translate.Layout.LayoutAnalyzer();
        var layouts = analyzer.Analyze(source, Enumerable.Range(1, source.Pages.Count).ToList());
        var sb = new System.Text.StringBuilder();
        sb.Append(System.FormattableString.Invariant($"body size {analyzer.BodySize:F1}\n"));
        foreach (var layout in layouts)
        {
            var counts = new Dictionary<Folio.Core.Translate.Layout.BlockKind, int>();
            foreach (var block in layout.Blocks)
            {
                counts[block.Kind] = counts.GetValueOrDefault(block.Kind) + 1;
                var r = block.Rect;
                sb.Append(System.FormattableString.Invariant($"[{Folio.Core.Translate.Layout.BlockKinds.Raw(block.Kind)}{(block.Translate ? "*" : "")}] ({r.MinX:F0},{r.MinY:F0} {r.W:F0}x{r.H:F0}) "))
                  .Append(string.Join(" | ", block.Lines.Select(l => l.Text))).Append('\n');
            }
            sb.Append($"page {layout.Number}: ").Append(string.Join(", ", Enum.GetValues<Folio.Core.Translate.Layout.BlockKind>()
                .Where(counts.ContainsKey).Select(k => $"{Folio.Core.Translate.Layout.BlockKinds.Raw(k)} {counts[k]}")))
              .Append($", figures {layout.Figures.Count}, tables {layout.Tables.Count}\n");
        }
        File.WriteAllText(output, sb.ToString());
    }

    /// <summary>FOLIO_SAMPLE_PDF + FOLIO_FAKE_OUT: the macOS engine's `folio-translate fake` (placeholder Chinese), for comparing renders.</summary>
    [Fact]
    public void RendersAFakeTranslationLikeTheMacEngine()
    {
        var sample = Environment.GetEnvironmentVariable("FOLIO_SAMPLE_PDF");
        var output = Environment.GetEnvironmentVariable("FOLIO_FAKE_OUT");
        if (string.IsNullOrEmpty(sample) || string.IsNullOrEmpty(output)) return;
        using var source = Folio.Core.Translate.Pdf.PdfSource.Open(sample);
        var analyzer = new Folio.Core.Translate.Layout.LayoutAnalyzer();
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var layouts = analyzer.Analyze(source, Enumerable.Range(1, source.Pages.Count).ToList());
        var report = new System.Text.StringBuilder($"layout {watch.Elapsed.TotalSeconds:F2} s\n");
        var segments = Folio.Core.Translate.Engine.SegmentBuilder.Segments(layouts, "zh");
        const string text0 = "本文提出了一种简单而有效的方法，用于在未知目标域上提升语义分割模型的泛化能力。我们在多个基准数据集上进行了大量实验，结果表明该方法优于现有技术。";
        var translations = new Dictionary<string, string>();
        foreach (var segment in segments)
        {
            int letters = segment.Source.Count(char.IsLetter);
            int length = Math.Max(2, (int)(letters * 0.42));
            var text = new System.Text.StringBuilder();
            int pieces = segment.Formulas.Count + 1;
            for (int k = 0; k < pieces; k++)
            {
                int n = length / pieces;
                for (int i = 0; i < n; i++) text.Append(text0[(k * 7 + i) % text0.Length]);
                if (k < segment.Formulas.Count) text.Append($"{{v{k + 1}}}");
            }
            translations[segment.Id] = text.ToString();
        }
        watch.Restart();
        var renderer = new Folio.Core.Translate.Engine.TranslationRenderer(source, "zh");
        var result = renderer.Render(layouts, segments, translations, true, true, Folio.Core.Translate.TranslationOptions.DualLayouts.sideBySide, null);
        report.Append($"render {watch.Elapsed.TotalSeconds:F2} s, {segments.Count} segments, {segments.Sum(s => s.Formulas.Count)} formulas\n");
        Directory.CreateDirectory(output);
        var name = Path.GetFileNameWithoutExtension(sample);
        File.WriteAllBytes(Path.Combine(output, name + ".mono.pdf"), result.Mono!);
        File.WriteAllBytes(Path.Combine(output, name + ".dual.pdf"), result.Dual!);
        report.Append($"mono {result.Mono!.Length} bytes, dual {result.Dual!.Length} bytes\n");
        File.WriteAllText(Path.Combine(output, "report.txt"), report.ToString());
    }

    /// <summary>FOLIO_SAMPLE_PDF + FOLIO_TRANSLATE_OUT (+ FOLIO_TRANSLATE_SERVICE, default google): a real translation of pages 1–2.</summary>
    [Fact]
    public async Task TranslatesWithARealService()
    {
        var sample = Environment.GetEnvironmentVariable("FOLIO_SAMPLE_PDF");
        var output = Environment.GetEnvironmentVariable("FOLIO_TRANSLATE_OUT");
        if (string.IsNullOrEmpty(sample) || string.IsNullOrEmpty(output)) return;
        Folio.Core.Translate.TranslationJob.SupportDirectory = Path.Combine(output, "support");
        var request = new Folio.Core.Translate.TranslationRequest
        {
            Input = sample, OutputDirectory = output, ServiceId = Environment.GetEnvironmentVariable("FOLIO_TRANSLATE_SERVICE") ?? "google",
            Options = new Folio.Core.Translate.TranslationOptions { Pages = "1-2", OnlyIncludeTranslatedPages = true },
        };
        var events = new System.Collections.Concurrent.ConcurrentQueue<string>();
        var job = new Folio.Core.Translate.TranslationJob(request);
        var last = await job.Run(e => { if (e is not Folio.Core.Translate.TranslationEvent.Progress) events.Enqueue(e.ToString()); });
        File.WriteAllLines(Path.Combine(output, "events.txt"), events);
        Assert.IsType<Folio.Core.Translate.TranslationEvent.Finished>(last);
    }
}

public class LocalizationTests
{
    /// <summary>Every interface string of the Windows app has an English translation (in the macOS tables or Windows.xcstrings).</summary>
    [Fact]
    public void EveryStringHasAnEnglishTranslation()
    {
        var here = Here();
        var src = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "src"));
        var english = Loc.EnglishTable;
        var missing = new SortedSet<string>();
        foreach (var file in Directory.EnumerateFiles(src, "*.cs", SearchOption.AllDirectories))
        {
            if (file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") || file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")) continue;
            foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(File.ReadAllText(file), @"Loc\.S\(\s*""((?:[^""\\]|\\.)*)"""))
            {
                var key = System.Text.RegularExpressions.Regex.Unescape(m.Groups[1].Value);
                if (System.Text.RegularExpressions.Regex.IsMatch(key, @"\p{IsCJKUnifiedIdeographs}") && !english.ContainsKey(key)) missing.Add(key);
            }
        }
        Assert.True(missing.Count == 0, "No English for: " + string.Join(" | ", missing));
    }

    static string Here([System.Runtime.CompilerServices.CallerFilePath] string path = "") => path;
}

public class TranslationEngineTests
{
    /// <summary>A paper made on the spot (two columns of English), translated with placeholder Chinese: the output opens,
    /// its Chinese text can be read back (fonts embedded with their text), and the fonts are subsets, not whole fonts.</summary>
    [Fact]
    public void TranslatesAGeneratedPaper()
    {
        var paper = new MemoryStream();
        using (var document = SkiaSharp.SKDocument.CreatePdf(paper))
        {
            var canvas = document.BeginPage(612, 792);
            using var typeface = SkiaSharp.SKFontManager.Default.MatchFamily("Times New Roman") ?? SkiaSharp.SKFontManager.Default.MatchFamily("Liberation Serif") ?? SkiaSharp.SKTypeface.Default;
            using var title = new SkiaSharp.SKFont(typeface, 17);
            using var body = new SkiaSharp.SKFont(typeface, 10);
            using var paint = new SkiaSharp.SKPaint { Color = SkiaSharp.SKColors.Black, IsAntialias = true };
            canvas.DrawText("Learning to Segment Images with Few Examples", 120, 90, title, paint);
            var words = ("Deep networks need many annotated training samples to work well. In this paper we present a network and training strategy " +
                         "that relies on the strong use of data augmentation to use the available annotated samples more efficiently. The architecture " +
                         "consists of a contracting path to capture context and a symmetric expanding path that enables precise localization.").Split(' ');
            for (int column = 0; column < 2; column++)
            {
                float y = 140;
                for (int paragraph = 0; paragraph < 3; paragraph++)
                {
                    var line = "";
                    foreach (var word in words)
                    {
                        if (body.MeasureText(line + " " + word) > 240) { canvas.DrawText(line.Trim(), 60 + column * 270, y, body, paint); y += 12; line = ""; }
                        line += " " + word;
                    }
                    canvas.DrawText(line.Trim(), 60 + column * 270, y, body, paint);
                    y += 22;
                }
            }
            document.EndPage();
            document.Close();
        }
        using var source = Folio.Core.Translate.Pdf.PdfSource.Open(paper.ToArray());
        var layouts = new Folio.Core.Translate.Layout.LayoutAnalyzer().Analyze(source, [1]);
        var segments = Folio.Core.Translate.Engine.SegmentBuilder.Segments(layouts, "zh");
        Assert.True(segments.Count >= 4, $"{segments.Count} segments");
        var translations = segments.ToDictionary(s => s.Id, s => string.Concat(Enumerable.Repeat("深度网络需要大量带注释的训练样本。", Math.Max(1, s.Source.Length / 40))));
        var output = new Folio.Core.Translate.Engine.TranslationRenderer(source, "zh")
            .Render(layouts, segments, translations, true, true, Folio.Core.Translate.TranslationOptions.DualLayouts.sideBySide, null);
        Assert.NotNull(output.Mono);
        Assert.NotNull(output.Dual);
        // Whole Chinese fonts are 10–20 MB; subsets of a few dozen characters, a few hundred kB at most.
        Assert.True(output.Mono!.Length < 3_000_000, $"{output.Mono.Length} bytes");
        using var read = UglyToad.PdfPig.PdfDocument.Open(output.Mono);
        var text = string.Concat(read.GetPage(1).Letters.Select(l => l.Value));
        Assert.True(text.Contains("深度网络"), "text: " + text[..Math.Min(300, text.Length)]);
        using var dual = UglyToad.PdfPig.PdfDocument.Open(output.Dual!);
        Assert.Equal(1224, (int)dual.GetPage(1).Width);
    }
}

public class AgentTests
{
    [Fact]
    public void EditsJsonWithCommentsKeepingEverythingElse()
    {
        const string original = "{\n  // my servers\n  \"mcpServers\": {\n    \"other\": { \"command\": \"x\" }, // keep\n  },\n  \"theme\": \"dark\"\n}\n";
        var home = Path.Combine(Path.GetTempPath(), $"folio-home-{Guid.NewGuid()}");
        Directory.CreateDirectory(Path.Combine(home, ".gemini"));
        File.WriteAllText(Path.Combine(home, ".gemini", "settings.json"), original);
        var integrator = new Folio.Core.Agent.AgentIntegrator(home, @"C:\Program Files\Folio\folio-cli.exe", useAgentCommands: false) { VerifiesCommands = false, CommandFoldersOverride = [] };
        var gemini = Folio.Core.Agent.AgentIntegrator.Catalog.First(d => d.Id == "gemini-cli");
        integrator.SetMcp(true, gemini);
        var added = File.ReadAllText(Path.Combine(home, ".gemini", "settings.json"));
        Assert.Contains("// my servers", added);
        Assert.Contains("// keep", added);
        Assert.Contains("\"folio\"", added);
        Assert.Equal(@"C:\Program Files\Folio\folio-cli.exe", integrator.InstalledCommand(gemini));
        integrator.SetMcp(false, gemini);
        Assert.Equal(original, File.ReadAllText(Path.Combine(home, ".gemini", "settings.json")));

        var codex = Folio.Core.Agent.AgentIntegrator.Catalog.First(d => d.Id == "codex");
        integrator.SetMcp(true, codex);
        Assert.Equal(@"C:\Program Files\Folio\folio-cli.exe", integrator.InstalledCommand(codex));
        integrator.SetMcp(false, codex);
        Assert.Null(integrator.InstalledCommand(codex));

        var claude = Folio.Core.Agent.AgentIntegrator.Catalog.First(d => d.Id == "claude-code");
        integrator.SetSkill(true, claude);
        Assert.True(integrator.Status(claude).SkillInstalled);
        integrator.SetSkill(false, claude);
        Assert.False(integrator.Status(claude).SkillInstalled);
        Directory.Delete(home, true);
    }

    [Fact]
    public async Task ServesMcpAgainstALibrary()
    {
        using var library = Library.Temporary();
        library.CreateItem(new Metadata("Attention Is All You Need") { Authors = [new Author("Vaswani", "Ashish")], Year = 2017, Doi = "10.48550/arxiv.1706.03762" });
        var toolbox = new Folio.Core.Agent.LibraryToolbox(library, new Folio.Core.Agent.AgentConfiguration(library.Root));
        var server = new Folio.Core.Agent.McpServer(toolbox);
        var init = await server.Receive("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}""");
        Assert.Equal("2025-06-18", init!["result"]!["protocolVersion"]!.GetValue<string>());
        var tools = await server.Receive("""{"jsonrpc":"2.0","id":2,"method":"tools/list"}""");
        Assert.Equal(26, tools!["result"]!["tools"]!.AsArray().Count);
        var call = await server.Receive("""{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_library","arguments":{"query":"attention vaswani","limit":5}}}""");
        var text = call!["result"]!["content"]![0]!["text"]!.GetValue<string>();
        Assert.Contains("Attention Is All You Need", text);
        var cite = await server.Receive("""{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"format_citations","arguments":{"items":["10.48550/arxiv.1706.03762"],"style":"apa"}}}""");
        Assert.Contains("Vaswani", cite!["result"]!["content"]![0]!["text"]!.GetValue<string>());
        var bad = await server.Receive("""{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_item","arguments":{"itme":"x"}}}""");
        Assert.True(bad!["result"]!["isError"]!.GetValue<bool>());
        var modern = await server.Receive("""{"jsonrpc":"2.0","id":6,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}""");
        Assert.Equal("complete", modern!["result"]!["resultType"]!.GetValue<string>());
        Assert.Null(await server.Receive("""{"jsonrpc":"2.0","method":"notifications/initialized"}"""));
    }
}

public class ZoteroTests
{
    static void Exec(Microsoft.Data.Sqlite.SqliteConnection c, string sql)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    [Fact]
    public void ImportsAZoteroLibrary()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"zotero-{Guid.NewGuid()}");
        Directory.CreateDirectory(Path.Combine(dir, "storage", "ATT1"));
        Directory.CreateDirectory(Path.Combine(dir, "storage", "ATT2"));
        File.WriteAllBytes(Path.Combine(dir, "storage", "ATT1", "paper.pdf"), "%PDF-1.4 original"u8.ToArray());
        File.WriteAllBytes(Path.Combine(dir, "storage", "ATT2", "paper.zh.dual.pdf"), "%PDF-1.4 translated"u8.ToArray());
        using (var c = new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={Path.Combine(dir, "zotero.sqlite")};Pooling=False"))
        {
            c.Open();
            Exec(c, """
            CREATE TABLE libraries (libraryID INTEGER PRIMARY KEY, type TEXT NOT NULL);
            CREATE TABLE itemTypes (itemTypeID INTEGER PRIMARY KEY, typeName TEXT);
            CREATE TABLE items (itemID INTEGER PRIMARY KEY, itemTypeID INT NOT NULL, dateAdded TIMESTAMP NOT NULL, dateModified TIMESTAMP NOT NULL, libraryID INT NOT NULL, key TEXT NOT NULL);
            CREATE TABLE deletedItems (itemID INTEGER PRIMARY KEY, dateDeleted TEXT);
            CREATE TABLE fields (fieldID INTEGER PRIMARY KEY, fieldName TEXT);
            CREATE TABLE itemDataValues (valueID INTEGER PRIMARY KEY, value);
            CREATE TABLE itemData (itemID INT, fieldID INT, valueID INT, PRIMARY KEY (itemID, fieldID));
            CREATE TABLE creatorTypes (creatorTypeID INTEGER PRIMARY KEY, creatorType TEXT);
            CREATE TABLE creators (creatorID INTEGER PRIMARY KEY, firstName TEXT, lastName TEXT, fieldMode INT);
            CREATE TABLE itemCreators (itemID INT, creatorID INT, creatorTypeID INT, orderIndex INT);
            CREATE TABLE itemAttachments (itemID INTEGER PRIMARY KEY, parentItemID INT, linkMode INT, path TEXT, contentType TEXT);
            CREATE TABLE collections (collectionID INTEGER PRIMARY KEY, key TEXT, collectionName TEXT, parentCollectionID INT, libraryID INT);
            CREATE TABLE collectionItems (collectionID INT, itemID INT);
            CREATE TABLE tags (tagID INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE itemTags (itemID INT, tagID INT, type INT);
            CREATE TABLE syncedSettings (setting TEXT, libraryID INT, value);
            INSERT INTO libraries VALUES (1, 'user');
            INSERT INTO itemTypes VALUES (3, 'attachment'), (28, 'note'), (22, 'journalArticle');
            INSERT INTO creatorTypes VALUES (10, 'author');
            INSERT INTO fields VALUES (1, 'title'), (6, 'date'), (8, 'DOI'), (100, 'publicationTitle'), (19, 'extra');
            INSERT INTO items VALUES (1, 22, '2024-03-01 10:00:00', '2024-03-02 10:00:00', 1, 'ITEM1');
            INSERT INTO itemDataValues VALUES (1, 'U-Net: Convolutional Networks'), (2, '2015-05-00 May 2015'), (3, 'https://doi.org/10.1007/978-3-319-24574-4_28'), (4, 'MICCAI'), (5, 'arXiv:1505.04597 [cs]');
            INSERT INTO itemData VALUES (1, 1, 1), (1, 6, 2), (1, 8, 3), (1, 100, 4), (1, 19, 5);
            INSERT INTO creators VALUES (1, 'Olaf', 'Ronneberger', 0), (2, NULL, 'BIOSS Centre', 1);
            INSERT INTO itemCreators VALUES (1, 1, 10, 0), (1, 2, 10, 1);
            INSERT INTO items VALUES (2, 3, '2024-03-01 10:00:00', '2024-03-01 10:00:00', 1, 'ATT1');
            INSERT INTO itemAttachments VALUES (2, 1, 0, 'storage:paper.pdf', 'application/pdf');
            INSERT INTO items VALUES (3, 3, '2024-03-05 10:00:00', '2024-03-05 10:00:00', 1, 'ATT2');
            INSERT INTO itemAttachments VALUES (3, 1, 0, 'storage:paper.zh.dual.pdf', 'application/pdf');
            INSERT INTO itemDataValues VALUES (6, 'paper-google-compare');
            INSERT INTO itemData VALUES (3, 1, 6);
            INSERT INTO items VALUES (4, 3, '2024-03-01 10:00:00', '2024-03-01 10:00:00', 1, 'SNAP');
            INSERT INTO itemAttachments VALUES (4, 1, 1, 'storage:page.html', 'text/html');
            INSERT INTO items VALUES (5, 3, '2024-03-01 10:00:00', '2024-03-01 10:00:00', 1, 'LINK');
            INSERT INTO itemAttachments VALUES (5, 1, 3, 'https://example.com', NULL);
            INSERT INTO items VALUES (6, 28, '2024-03-01 10:00:00', '2024-03-01 10:00:00', 1, 'NOTE');
            INSERT INTO items VALUES (7, 22, '2024-03-01 10:00:00', '2024-03-01 10:00:00', 1, 'GONE');
            INSERT INTO deletedItems VALUES (7, '2024-04-01');
            INSERT INTO collections VALUES (1, 'C1', 'Vision', NULL, 1), (2, 'C2', 'Segmentation', 1, 1), (3, 'C3', 'Medical', 2, 1);
            INSERT INTO collectionItems VALUES (3, 1);
            INSERT INTO tags VALUES (1, 'Important'), (2, 'Computer Science - CV');
            INSERT INTO itemTags VALUES (1, 1, 0), (1, 2, 1);
            INSERT INTO syncedSettings VALUES ('tagColors', 1, '[{"name":"Important","color":"#FF3B30"}]');
            """);
        }
        try
        {
            using var reader = new Folio.Core.Zotero.ZoteroReader(dir);
            var (prepared, report) = reader.Read(new Folio.Core.Zotero.ZoteroReadOptions());
            Assert.Equal(1, report.RegularItems);
            Assert.Equal(2, report.Collections);
            Assert.Equal(1, report.SkippedSnapshots);
            Assert.Equal(1, report.SkippedLinks);
            Assert.Equal(1, report.SkippedNotes);
            Assert.Equal(1, report.SkippedTrashed);
            Assert.Equal(1, report.AutomaticTagsAvailable);
            var entry = prepared.Entries.Single();
            Assert.Equal("10.1007/978-3-319-24574-4_28", entry.Metadata!.Doi);
            Assert.Equal("1505.04597", entry.Metadata.ArxivId);
            Assert.Equal("2015-05", entry.Metadata.Date);
            Assert.Equal("BIOSS Centre", entry.Metadata.Authors[1].Family);
            Assert.Equal(["C2"], entry.GroupKeys);
            Assert.Equal(["Important"], entry.TagNames);
            Assert.Null(entry.Files[0].TranslationKind);
            Assert.Equal(TranslationKind.Dual, entry.Files[1].TranslationKind);
            Assert.Equal("Google", entry.Files[1].TranslatedBy);

            using var library = Library.Temporary();
            var summary = library.ImportPrepared(prepared);
            Assert.Equal(1, summary.ItemsImported);
            Assert.Equal(2, summary.FilesImported);
            Assert.Equal(2, summary.GroupsCreated);
            Assert.Equal(1, summary.TagsCreated);
            var s = library.Snapshot();
            var item = s.Items.Values.Single();
            Assert.Equal("#FF3B30", s.Tags.Single().ColorHex);
            Assert.Single(s.ItemGroups[item.Id]);
            var files = s.FilesOf(item.Id);
            Assert.Equal(files.Single(f => f.TranslationKind == null).Id, item.DefaultFileId);
            Assert.Equal(item.DefaultFileId, files.Single(f => f.TranslationKind == TranslationKind.Dual).TranslationOf);
            // Importing again finds everything already there.
            Assert.Equal(1, library.ImportPrepared(prepared).DuplicatesSkipped);
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            Directory.Delete(dir, true);
        }
    }
}

static class TestPdfs
{
    /// <summary>A one-page PDF with a classic cross-reference table.</summary>
    public static byte[] OnePage()
    {
        var objects = new[]
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] >>",
        };
        var sb = new System.Text.StringBuilder("%PDF-1.4\n");
        var offsets = new List<int>();
        for (int i = 0; i < objects.Length; i++)
        {
            offsets.Add(sb.Length);
            sb.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n");
        }
        int xref = sb.Length;
        sb.Append($"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
        foreach (var o in offsets) sb.Append($"{o:D10} 00000 n \n");
        sb.Append($"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
        return System.Text.Encoding.ASCII.GetBytes(sb.ToString());
    }
}
