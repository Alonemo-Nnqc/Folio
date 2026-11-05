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
}

public class LayoutTests
{
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
