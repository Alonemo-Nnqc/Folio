using Folio.Core.Translate;
using Folio.Core.Translate.Services;

namespace Folio.Core.Tests;

/// <summary>Folio's glossary: terms kept from paper to paper, the user's word over a model's. The same cases as the
/// macOS GlossaryStoreTests.</summary>
public class GlossaryStoreTests
{
    static string Scratch()
    {
        var folder = Path.Combine(Path.GetTempPath(), "folio-glossary-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        return folder;
    }

    [Fact]
    public void WhatTheUserWroteStaysWhateverAModelFindsLater()
    {
        var folder = Scratch();
        try
        {
            var store = new GlossaryStore(Path.Combine(folder, "glossary.json"));
            Assert.NotNull(store.Save(new GlossaryTerm { Source = "domain generalization", Target = "域泛化", Language = "zh" }));
            // A model finds the same term (written a little differently), a new one, and a name kept as it is.
            var added = store.Learn([new("Domain Generalization", "领域泛化"), new("style transfer", "风格迁移"), new("CLIP", "CLIP")], "zh-CN", "A Paper");
            Assert.Equal(1, added);
            var terms = store.Terms("zh");
            Assert.Equal(["域泛化", "风格迁移"], terms.Select(t => t.Target));
            Assert.Equal(GlossaryTerm.Extracted, terms[1].Origin);
            Assert.Equal("A Paper", terms[1].Paper);
            // Read again from disk by another store; the file is what the macOS app writes.
            Assert.Equal(2, new GlossaryStore(Path.Combine(folder, "glossary.json")).Terms().Count);
            var text = File.ReadAllText(Path.Combine(folder, "glossary.json"));
            Assert.Contains("\"isEnabled\": true", text);
            Assert.Contains("\"origin\": \"extracted\"", text);
            Assert.Matches("\"added\": \"\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ\"", text);
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public void TermsAreChangedSwitchedOffAndRemoved()
    {
        var folder = Scratch();
        try
        {
            var store = new GlossaryStore(Path.Combine(folder, "glossary.json"));
            store.Learn([new("backbone", "主干"), new("ablation", "消融")], "zh", null);
            var term = store.Terms().First(t => t.Source == "backbone");
            term.Target = "骨干网络";
            store.Save(term);
            Assert.Equal("骨干网络", store.Entries("zh").First(e => e.Source == "backbone").Target);
            Assert.Equal(2, store.Terms().Count);
            var other = store.Terms().First(t => t.Source == "ablation");
            other.IsEnabled = false;
            store.Save(other);
            Assert.Equal(["backbone"], store.Entries("zh").Select(e => e.Source));
            store.Remove([term.Id]);
            Assert.Equal(["ablation"], store.Terms().Select(t => t.Source));
            // Another language has its own terms.
            store.Save(new GlossaryTerm { Source = "backbone", Target = "バックボーン", Language = "ja" });
            Assert.Single(store.Entries("ja"));
            Assert.Empty(store.Entries("zh"));
            Assert.Null(store.Save(new GlossaryTerm { Source = "  ", Target = "x", Language = "zh" }));
            // A list handed out is a copy: changing it changes nothing until it is saved.
            store.Terms()[0].Target = "changed";
            Assert.DoesNotContain(store.Terms(), t => t.Target == "changed");
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public void AListGoesOutAndComesBackAsCsv()
    {
        var folder = Scratch();
        try
        {
            var store = new GlossaryStore(Path.Combine(folder, "a.json"));
            store.Save(new GlossaryTerm { Source = "few-shot learning", Target = "小样本学习", Language = "zh" });
            store.Save(new GlossaryTerm { Source = "loss", Target = "损失", Language = "zh" });
            // A comma and a quote in a term come back as they went out.
            store.Save(new GlossaryTerm { Source = "precision, recall", Target = "精确率、召回率", Language = "zh" });
            store.Save(new GlossaryTerm { Source = "the \"bitter lesson\"", Target = "“苦涩的教训”", Language = "zh" });
            var file = Path.Combine(folder, "terms.csv");
            File.WriteAllText(file, store.ExportCsv("zh"));
            var other = new GlossaryStore(Path.Combine(folder, "b.json"));
            Assert.Equal(4, other.ImportCsv(file, "zh"));
            Assert.Equal(store.Entries("zh"), other.Entries("zh"));
            Assert.All(other.Terms(), t => Assert.Equal(GlossaryTerm.User, t.Origin));
        }
        finally { Directory.Delete(folder, true); }
    }

    [Fact]
    public void TheAppsGlossaryIsBesideTheCache()
    {
        // Read, not set: other tests run jobs against the same folder at the same time.
        Assert.Equal(Path.Combine(TranslationJob.SupportDirectory, "glossary.json"), GlossaryStore.Shared.Path);
        Assert.True(new TranslationOptions().RememberTerms);
        Assert.True(System.Text.Json.JsonSerializer.Deserialize<TranslationOptions>("{\"langOut\":\"ja\"}")!.RememberTerms, "options saved before the switch existed keep terms");
        Assert.Equal(["a, b", "c \"d\"", "e"], TranslationJob.CsvFields("\"a, b\", \"c \"\"d\"\"\" ,e"));
    }
}
