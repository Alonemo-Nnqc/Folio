using System.Text;
using System.Text.Json;
using Folio.Core.Translate;
using Folio.Core.Translate.Services;

namespace Folio.Core.Tests;

/// <summary>Packages of a library and its settings (the macOS LibraryPackageTests and SettingsPackageTests).</summary>
public sealed class LibraryPackageTests : IDisposable
{
    readonly string _folder = Directory.CreateTempSubdirectory("folio-package-tests-").FullName;

    public void Dispose() { try { Directory.Delete(_folder, true); } catch (IOException) { } }

    string Pdf(string name, string text)
    {
        var path = Path.Combine(_folder, name);
        File.WriteAllText(path, text);
        return path;
    }

    static string Import(string path, Library library) => Assert.IsType<ImportOutcome.Imported>(library.ImportFiles([path])[0]).ItemId;

    LibraryPackage Export(Library library, byte[]? settings = null)
    {
        var path = Path.Combine(_folder, $"{Guid.NewGuid():N}.foliolib");
        library.ExportPackage(path, "1.6.0", settings: settings);
        return new LibraryPackage(path);
    }

    static LibraryImportSummary Bring(LibraryPackage package, Library library) => library.ImportPackage(package, File.Delete);

    [Fact]
    public void AWholeLibraryMovesToAnEmptyOne()
    {
        using var a = Library.Temporary();
        using var b = Library.Temporary();
        var parent = a.CreateGroup("深度学习");
        var child = a.CreateGroup("分割", parent.Id);
        var tag = a.CreateTag("必读", "#FF3B30");
        var id = Import(Pdf("论文 é.pdf", "pdf one"), a);
        a.ApplyMetadata(new Metadata("U-Net") { Authors = [new Author("Ronneberger", "Olaf")], Year = 2015 }, id, true);
        a.AddItems([id], child.Id, false);
        a.SetTag(tag.Id, [id], true);
        a.SetNote("# 笔记\n\n很好", id);
        var file = a.Files(id)[0];
        a.SetFulltext([(file.Id, "skip connections")]);
        a.SaveReadingState(new ReadingState(file.Id, 3, 0, 0, 1, true, 1, DateTime.UtcNow, null, null));
        var translated = a.AddTranslatedFile(Pdf("t.pdf", "译文"), file.Id, TranslationKind.Mono, "译文", "Google");
        var doc = a.CreateMarkdownDocument("计划", null, $"[U-Net](folio://open?item={id})");
        var gone = Import(Pdf("gone.pdf", "gone"), a);
        a.TrashItems([gone]);

        var package = Export(a);
        Assert.Equal((2, 3, 2, 1), (package.Info.Items, package.Info.Files, package.Info.Groups, package.Info.Tags));
        Assert.True(package.HasLibrary && package.Settings == null && package.Info.Date > DateTime.UtcNow.AddMinutes(-5));
        var summary = Bring(package, b);
        Assert.Equal((2, 3, 2, 1, 0), (summary.ItemsAdded, summary.FilesAdded, summary.GroupsCreated, summary.TagsCreated, summary.MissingFiles));
        var from = a.Snapshot();
        var to = b.Snapshot();
        Assert.False(to.Items.ContainsKey(gone)); // the trash stays behind
        Assert.Equal(from.Items[id].CitationKey, to.Items[id].CitationKey);
        Assert.Equal(file.Id, to.Items[id].DefaultFileId);
        Assert.Contains(child.Id, to.ItemGroups[id]);
        Assert.Contains(tag.Id, to.ItemTags[id]);
        Assert.Equal("# 笔记\n\n很好", b.Note(id));
        Assert.Equal(3, b.ReadingState(file.Id)!.PageIndex);
        Assert.Contains(id, b.FulltextItemIds("connections"));
        Assert.Equal(from.Files[file.Id].RelativePath, to.Files[file.Id].RelativePath);
        Assert.Equal(file.Id, to.Files[translated.Id].TranslationOf);
        Assert.Equal("pdf one", File.ReadAllText(b.FilePath(to.Files[file.Id])));
        Assert.Contains(id, b.Text(doc.FileId));
        Assert.Empty(b.RefreshFingerprints());
        var again = Bring(package, b);
        Assert.Equal((0, 0, 2, 0), (again.ItemsAdded, again.ItemsUpdated, again.ItemsUnchanged, again.FilesAdded));
        Assert.Empty(Directory.GetFiles(_folder, "*.partial"));
    }

    [Fact]
    public void TheNewerStays()
    {
        using var a = Library.Temporary();
        using var b = Library.Temporary();
        var id = Import(Pdf("p.pdf", "old"), a);
        var other = Import(Pdf("q.pdf", "q"), a);
        Bring(Export(a), b);
        var path = a.FilePath(a.Files(id)[0]);
        File.WriteAllText(path, "annotated");
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(1));
        Thread.Sleep(5);
        a.UpdateItem(id, i => i.Title = "new title");
        a.SetNote("from a", id);
        b.UpdateItem(other, i => i.Rating = 5);
        var summary = Bring(Export(a), b);
        Assert.Equal((0, 1, 1, 1), (summary.ItemsAdded, summary.ItemsUpdated, summary.ItemsUnchanged, summary.FilesUpdated));
        Assert.Equal("new title", b.Item(id)!.Title);
        Assert.Equal(5, b.Item(other)!.Rating);
        Assert.Equal("from a", b.Note(id));
        Assert.Equal("annotated", File.ReadAllText(b.FilePath(b.Files(id)[0])));
        Thread.Sleep(5);
        b.UpdateItem(id, i => i.Title = "newer title");
        Bring(Export(a), b);
        Assert.Equal("newer title", b.Item(id)!.Title);
        Bring(Export(b), a);
        Assert.Equal("newer title", a.Item(id)!.Title);
        Assert.Equal(5, a.Item(other)!.Rating);
    }

    [Fact]
    public void TheSamePaperAddedOnBothIsOne()
    {
        using var a = Library.Temporary();
        using var b = Library.Temporary();
        var inA = Import(Pdf("x.pdf", "same bytes"), a);
        a.SetNote("a's note", inA);
        var inB = Import(Pdf("y.pdf", "same bytes"), b);
        b.SetNote("b's note", inB);
        var group = a.CreateGroup("Reading");
        var groupB = b.CreateGroup("reading");
        a.AddItems([inA], group.Id, false);
        var workA = ((CreateOutcome.Created)a.CreateItem(new Metadata("Attention Is All You Need") { Doi = "10.1/x" })).ItemId;
        var workB = ((CreateOutcome.Created)b.CreateItem(new Metadata("Attention") { Doi = "10.1/x" })).ItemId;
        var doc = a.CreateMarkdownDocument("d", null, $"folio://open?item={workA}&page=2");
        a.CreateMarkdownDocument("empty a");
        b.CreateMarkdownDocument("empty b");
        var summary = Bring(Export(a), b);
        Assert.Equal((0, 2), (summary.GroupsCreated, summary.ItemsAdded));
        var snapshot = b.Snapshot();
        Assert.False(snapshot.Items.ContainsKey(inA) || snapshot.Items.ContainsKey(workA));
        Assert.Single(b.Files(inB));
        Assert.Contains(groupB.Id, snapshot.ItemGroups[inB]);
        Assert.Equal("b's note\n\na's note", b.Note(inB));
        Assert.Equal($"folio://open?item={workB}&page=2", b.Text(doc.FileId));
        Assert.Equal(0, Bring(Export(a), b).ItemsAdded);
    }

    [Fact]
    public void DeletedNamesTakenMissingAndDamaged()
    {
        using var a = Library.Temporary();
        using var b = Library.Temporary();
        var id = Import(Pdf("same.pdf", "a's"), a);
        var lost = Import(Pdf("lost.pdf", "lost"), a);
        Import(Pdf("same.pdf", "b's"), b);
        File.Delete(a.FilePath(a.Files(lost)[0]));
        var summary = Bring(Export(a), b);
        Assert.Equal((1, 1), (summary.ItemsAdded, summary.MissingFiles));
        Assert.Equal("Files/same 2.pdf", b.Files(id)[0].RelativePath);
        Assert.Null(b.Item(lost));
        b.TrashItems([id]);
        Bring(Export(a), b);
        Assert.False(b.Item(id)!.IsTrashed);

        // A damaged file is left out, the rest comes.
        using var c = Library.Temporary();
        var big = Import(Pdf("big.pdf", new string('x', 100_000)), a);
        var package = Export(a);
        var bytes = File.ReadAllBytes(package.Path);
        bytes[bytes.AsSpan().LastIndexOf(Encoding.ASCII.GetBytes(new string('x', 1000))) - 10] ^= 0xFF;
        File.WriteAllBytes(package.Path, bytes);
        summary = Bring(new LibraryPackage(package.Path), c);
        Assert.Null(c.Item(big));
        Assert.Equal(1, summary.ItemsAdded);
        File.WriteAllText(package.Path, "no zip at all");
        Assert.Throws<LibraryException>(() => new LibraryPackage(package.Path));
    }

    sealed class Memory : ISecretStore
    {
        public readonly Dictionary<string, string> Values = [];
        public string? Get(string serviceId, string option) => Values.GetValueOrDefault($"{serviceId}.{option}");
        public void Set(string value, string serviceId, string option) => Values[$"{serviceId}.{option}"] = value;
        public void Delete(string serviceId, string option) => Values.Remove($"{serviceId}.{option}");
    }

    const string Service = "openaicompatible", Key = "--openai-compatible-api-key", Url = "--openai-compatible-base-url";

    (AppSettings, Memory, GlossaryStore) Stores()
    {
        var name = Path.Combine(_folder, Guid.NewGuid().ToString("N"));
        return (new AppSettings(name + ".json"), new Memory(), new GlossaryStore(name + "-glossary.json"));
    }

    [Fact]
    public void SettingsKeysAndGlossaryMove()
    {
        var (a, aKeys, aTerms) = Stores();
        var (b, bKeys, bTerms) = Stores();
        var profile = new TranslationProfile { Id = "P", Name = "DeepSeek", ServiceId = Service, Fields = new() { [Url] = "https://api.deepseek.com" } };
        a.ShowReadingRings = false;
        a.TranslationParallelTotal = 5;
        a.LibraryPath = "D:\\Folio";
        a.SetFields(Service, new() { [Url] = "https://api.deepseek.com" });
        a.TranslationProfiles = [profile];
        a.TranslationOptions = new TranslationOptions { LangOut = "ja", GlossaryFile = "D:\\x.csv" };
        a.Language = "en";
        a.VisibleColumns = ["title", "year"];
        a.OpenAlexApiKey = "oa-key";
        aKeys.Set("sk-1", Service, Key);
        aKeys.Set("sk-p", profile.SecretOwner, Key);
        aKeys.Set("es", "easyscholar", "secretKey");
        aTerms.Save(new GlossaryTerm { Source = "attention", Target = "注意力" });
        bTerms.Save(new GlossaryTerm { Source = "Attention", Target = "关注", Language = "zh-CN" });
        bTerms.Save(new GlossaryTerm { Source = "mask", Target = "掩码" });
        b.SetFields("bing", new() { ["x"] = "y" });
        b.AutoPurgeTrash = false; // as it comes on a

        var data = SettingsPackage.Data(a, aKeys, aTerms, "pw");
        var text = Encoding.UTF8.GetString(data);
        Assert.DoesNotContain("sk-1", text);
        Assert.DoesNotContain("oa-key", text);
        Assert.DoesNotContain("libraryPath", text);
        Assert.DoesNotContain("x.csv", text);
        var package = new SettingsPackage(data);
        Assert.True(package.HasSecrets);
        Assert.Null(package.Secrets("no"));
        package.Apply(b, bKeys, bTerms, package.Secrets("pw"));
        Assert.False(b.ShowReadingRings);
        Assert.True(b.AutoPurgeTrash);
        Assert.Equal(5, b.TranslationParallelTotal);
        Assert.Null(b.Raw("libraryPath"));
        Assert.Equal("https://api.deepseek.com", b.FieldsOf(Service)[Url]);
        Assert.Equal("y", b.FieldsOf("bing")["x"]);
        Assert.Equal("DeepSeek", Assert.Single(b.TranslationProfiles).Name);
        Assert.Equal(("ja", null), (b.TranslationOptions.LangOut, b.TranslationOptions.GlossaryFile));
        Assert.Equal("en", b.Language);
        Assert.Equal(["title", "year"], b.VisibleColumns);
        Assert.Equal(("sk-1", "sk-p", "es", "oa-key"), (bKeys.Get(Service, Key), bKeys.Get("profile.P", Key), bKeys.Get("easyscholar", "secretKey"), b.OpenAlexApiKey));
        Assert.Equal(["注意力", "掩码"], bTerms.Terms().Select(t => t.Target));

        // Without keys, the keys here stay where they were for.
        var (c, cKeys, cTerms) = Stores();
        c.SetFields(Service, new() { [Url] = "https://api.mine.com" });
        cKeys.Set("sk-mine", Service, Key);
        new SettingsPackage(SettingsPackage.Data(a, aKeys, aTerms, null)).Apply(c, cKeys, cTerms, null);
        Assert.Equal("https://api.mine.com", c.FieldsOf(Service)[Url]);
        Assert.Equal("sk-mine", cKeys.Get(Service, Key));
    }

    [Fact]
    public void SettingsOfTheMac()
    {
        var (b, keys, terms) = Stores();
        var text = """{"platform":"macos","plist":"AAAA","values":{"showReadingRings":0,"appearance":7,"inkLineWidth":3.5,"autoPurgeTrash":false,"translationOptions":{"langIn":"en","langOut":"zh","outputs":"mono"},"translationProfiles":[],"language":""},"glossary":[]}""";
        new SettingsPackage(Encoding.UTF8.GetBytes(text)).Apply(b, keys, terms, null);
        Assert.False(b.ShowReadingRings);
        Assert.False(b.AutoPurgeTrash);
        Assert.Equal(3.5, b.InkLineWidth);
        Assert.Null(b.Raw("appearance"));
        Assert.Equal(TranslationOptions.OutputKinds.mono, b.TranslationOptions.Outputs);
        Assert.Throws<LibraryException>(() => new SettingsPackage("[]"u8.ToArray()));
    }

    /// <summary>The second one was written by the macOS app (its passwordBox test reads one of this).</summary>
    [Fact]
    public void PasswordBoxes()
    {
        var box = PasswordBox.Seal(Encoding.UTF8.GetBytes("sk-钥匙"), "密码 1", 1000);
        Assert.Equal("sk-钥匙", Encoding.UTF8.GetString(box.Open("密码 1")!));
        Assert.Null(box.Open("密码 2"));
        Assert.Equal("folio", Encoding.UTF8.GetString(JsonSerializer.Deserialize<PasswordBox>("""{"sealed":"5h/9OLEKZ78LERwuAR/s79uKxEO/KZDyGoMyCed9pS2B","rounds":1000,"salt":"HycWibbOPhPOyR1V26B5XA=="}""")!.Open("pässword")!));
    }

    /// <summary>FOLIO_UNPACK: a package of the macOS app, read into an empty library; FOLIO_PACK_TO: packed again there.</summary>
    [Fact]
    public void BetweenPlatforms()
    {
        if (Environment.GetEnvironmentVariable("FOLIO_UNPACK") is not { Length: > 0 } path) return;
        using var library = Library.Temporary();
        var package = new LibraryPackage(path);
        var summary = Bring(package, library);
        Assert.Equal((package.Info.Items, package.Info.Files, 0), (summary.ItemsAdded, summary.FilesAdded, summary.MissingFiles));
        Assert.Empty(library.RefreshFingerprints());
        if (Environment.GetEnvironmentVariable("FOLIO_PACK_TO") is { Length: > 0 } to) library.ExportPackage(to, "1.6.0", settings: "{}"u8.ToArray());
    }
}
