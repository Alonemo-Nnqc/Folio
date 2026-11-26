namespace Folio.Core.Tests;

/// <summary>Folders imported as groups, and what Markdown documents are called (as the macOS FolderImportTests and MarkdownAndVenueTests).</summary>
public class FolderAndNameTests : IDisposable
{
    readonly string _root = Path.Combine(Path.GetTempPath(), $"folio-folder-{Guid.NewGuid():N}");

    public void Dispose() { try { Directory.Delete(_root, true); } catch { } }

    ImportFolder Folder(params string[] files)
    {
        var root = Path.Combine(_root, Guid.NewGuid().ToString("N"), "论文");
        foreach (var name in files)
        {
            var path = Path.Combine(root, Path.Combine(name.Split('/')));
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, name);
        }
        return ImportFolder.Scan(root)!;
    }

    static string Paper(Library library, string title) =>
        ((CreateOutcome.Created)library.CreateItem(new Metadata(title) { Type = ItemType.JournalArticle })).ItemId;

    [Fact]
    public void FoldersBecomeGroups()
    {
        using var library = Library.Temporary();
        var found = Folder("a.pdf", "笔记.md", "x.txt", "SAM/b.pdf", "SAM/v2/c.pdf", "空/说明.txt", ".隐藏/d.pdf");
        Assert.Equal(4, found.FileCount);
        Assert.Equal(["SAM"], found.Children.Select(c => c.Name));
        var first = library.CreateGroup("第一");
        var last = library.CreateGroup("最后");
        var (top, outcomes) = library.ImportFolder(found, null, 1);
        var snapshot = library.Snapshot();
        Assert.Equal([first.Id, top!, last.Id], snapshot.TopLevelGroups);
        Assert.Equal("论文", snapshot.GroupsById[top!].Name);
        var sam = snapshot.ChildGroups[top!].Single();
        var v2 = snapshot.ChildGroups[sam].Single();
        Assert.Equal(("SAM", "v2"), (snapshot.GroupsById[sam].Name, snapshot.GroupsById[v2].Name));
        Assert.Equal(4, outcomes.Count);
        Assert.Contains(snapshot.Items.Values, i => i.Title == "笔记"); // a Markdown file has no extension in its title
        // Once more: the same groups, nothing twice.
        var again = library.ImportFolder(found);
        Assert.Equal(top, again.GroupId);
        Assert.All(again.Outcomes, o => Assert.IsType<ImportOutcome.DuplicateFile>(o));
        Assert.Equal(5, library.Snapshot().GroupsById.Count);
    }

    [Fact]
    public void GroupsGoNoDeeperThanTheyMay()
    {
        using var library = Library.Temporary();
        var parent = library.CreateGroup("上级");
        library.ImportFolder(Folder("1/2/3/4/5/x.pdf", "1/2/y.pdf"), parent.Id);
        var snapshot = library.Snapshot();
        Assert.Equal(new[] { "1", "2", "上级", "论文" }.Order(StringComparer.Ordinal), snapshot.GroupsById.Values.Select(g => g.Name).Order(StringComparer.Ordinal));
        var deepest = snapshot.GroupsById.Values.Single(g => g.Name == "2");
        // On a group of the last level: its files, no group.
        var (group, outcomes) = library.ImportFolder(Folder("z.pdf"), deepest.Id);
        Assert.Null(group);
        Assert.Single(outcomes);
        Assert.Null(ImportFolder.Scan(Path.Combine(_root, "没有")));
    }

    [Fact]
    public void ADocumentIsCalledTheSameWhereverItsNameShows()
    {
        using var library = Library.Temporary();
        var paper = Paper(library, "Segment Anything");
        // A paper's attachment has the plain file name already; the new document is the first of its kind all the same.
        var attached = library.CreateMarkdownAttachment("未命名文档", paper);
        var document = library.CreateMarkdownDocument("未命名文档");
        var snapshot = library.Snapshot();
        Assert.Equal("未命名文档 2.md", snapshot.Files[document.FileId].FileName);
        Assert.Equal("未命名文档", snapshot.Items[document.ItemId].Title);
        Assert.Equal("未命名文档", snapshot.Files[attached].DocumentName);
        var second = library.CreateMarkdownAttachment("未命名文档", paper);
        var other = library.CreateMarkdownAttachment("未命名文档", Paper(library, "SAM 2"));
        snapshot = library.Snapshot();
        Assert.Equal("未命名文档 2", snapshot.Files[second].DocumentName);
        Assert.Equal("未命名文档", snapshot.Files[other].DocumentName);
        library.RenameMarkdownFile(second, "想法");
        Assert.Equal("想法", library.Snapshot().Files[second].DocumentName);
        // A number free again is used again.
        library.TrashItems([library.CreateMarkdownDocument("未命名文档").ItemId]);
        var fourth = library.CreateMarkdownDocument("未命名文档");
        Assert.Equal("未命名文档 2", library.Snapshot().Items[fourth.ItemId].Title);
    }

    [Fact]
    public void UnnamedDocumentsAreNamedByTheirFirstLine()
    {
        using var library = Library.Temporary();
        var a = library.CreateMarkdownDocument("未命名文档");
        (string, string) Names() => (library.Snapshot().Items[a.ItemId].Title, library.Snapshot().Files[a.FileId].FileName);
        // While the line is being written the file keeps its name.
        library.WriteText("今天读", a.FileId);
        Assert.Equal(("今天读", "未命名文档.md"), Names());
        library.WriteText("今天读了三篇\n", a.FileId);
        Assert.Equal(("今天读了三篇", "今天读了三篇.md"), Names());
        // A heading says better what it is.
        library.WriteText("今天读了三篇\n\n# 周报\n", a.FileId);
        Assert.Equal(("周报", "周报.md"), Names());
        library.RenameMarkdownFile(a.FileId, "存档");
        library.WriteText("别的\n", a.FileId);
        Assert.Equal("存档", Names().Item1);
        Assert.Equal("读 SAM 的论文", Library.NameFrom("---\ntitle: x\n---\n\n- [ ] 读 **SAM** 的[论文](https://a.b)\n")?.Name);
        Assert.Equal("引用", Library.NameFrom("```swift\nlet a = 1\n```\n> 引用\n")?.Name);
        Assert.Null(Library.NameFrom("\n***\n  \n"));
        Assert.Equal(40, Library.NameFrom(new string('长', 80) + "\n")?.Name.Length);
    }
}
