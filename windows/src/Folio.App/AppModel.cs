using Folio.Core;
using Folio.Core.Citation;
using Microsoft.UI.Dispatching;

namespace Folio.App;

/// <summary>What the sidebar has selected.</summary>
public sealed record SidebarSelection(ViewScope Scope);

/// <summary>
/// The app's state and actions, shared by every view (the macOS AppModel). The snapshot is rebuilt after every change —
/// ours, or another process's (folio-cli used by AI agents), noticed through SQLite's data_version.
/// </summary>
public sealed partial class AppModel : IImportUi
{
    readonly DispatcherQueue _ui;
    readonly DispatcherQueueTimer _externalChanges;
    long _dataVersion = -1;
    bool _refreshQueued;

    public AppSettings Settings { get; } = AppSettings.Shared;
    public Library Library { get; private set; } = null!;
    public LibrarySnapshot Snapshot { get; private set; } = LibrarySnapshot.Empty;
    public Importer Importer { get; }
    public ToastCenter Toasts { get; }
    public Updater Updater { get; }
    public ConnectorServer Connector { get; }
    readonly Lazy<CslRenderer> _csl = new(() => new CslRenderer());
    readonly object _cslLock = new();

    public ViewScope Scope { get; private set; } = ViewScope.All;
    public string SearchText { get; private set; } = "";
    public bool SearchWholeLibrary { get; set; }
    IReadOnlySet<string>? _fulltextMatches;
    public List<string> Rows { get; private set; } = [];
    public IReadOnlyList<string> SelectedItemIds { get; private set; } = [];
    public Dictionary<string, int> Counts { get; private set; } = [];

    /// <summary>Raised on the UI thread after the snapshot or the rows changed.</summary>
    public event Action? SnapshotChanged;
    public event Action? RowsChanged;
    public event Action? SelectionChanged;
    public event Action<string>? RevealRequested;

    /// <summary>Opening papers in the reader is the window's job.</summary>
    public event Action<FileRecord>? OpenInReaderRequested;

    public AppModel(DispatcherQueue ui)
    {
        _ui = ui;
        Toasts = new ToastCenter(ui);
        Importer = new Importer(() => Library, Settings, this);
        Updater = new Updater(this);
        Connector = new ConnectorServer(this);
        _externalChanges = ui.CreateTimer();
        _externalChanges.Interval = TimeSpan.FromSeconds(1.5);
        _externalChanges.Tick += (_, _) => CheckExternalChanges();
    }

    public void Start()
    {
        OpenLibrary(Settings.LibraryPath);
        _externalChanges.Start();
        if (Settings.BrowserConnectorEnabled) Connector.Start();
        Updater.StartAutomaticChecks();
        // Warm citeproc up so the first copy is instant.
        _ = Task.Run(() => { lock (_cslLock) _ = _csl.Value; });
    }

    void OpenLibrary(string path)
    {
        Library?.Dispose();
        Library = new Library(path);
        Library.Changed += QueueRefresh;
        RefreshNow();
        Importer.LibraryDidLoad(Snapshot);
    }

    /// <summary>Moves the library folder (Settings ▸ General).</summary>
    public void RelocateLibrary(string newParent)
    {
        var target = Path.Combine(newParent, Path.GetFileName(Library.Root.TrimEnd(Path.DirectorySeparatorChar)));
        if (Directory.Exists(target) && Directory.EnumerateFileSystemEntries(target).Any())
            throw new IOException(Loc.S("目标位置已有同名文件夹"));
        var old = Library.Root;
        Library.Dispose();
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        Directory.Move(old, target);
        Settings.LibraryPath = target;
        OpenLibrary(target);
    }

    public void SwitchLibrary(string path)
    {
        Settings.LibraryPath = path;
        OpenLibrary(path);
    }

    // MARK: Snapshot

    void QueueRefresh()
    {
        lock (this)
        {
            if (_refreshQueued) return;
            _refreshQueued = true;
        }
        _ui.TryEnqueue(DispatcherQueuePriority.Low, () =>
        {
            lock (this) _refreshQueued = false;
            RefreshNow();
        });
    }

    void RefreshNow()
    {
        Snapshot = Library.Snapshot();
        _dataVersion = Library.Database.Read(Library.Database.DataVersion);
        Counts = SidebarCounts.Compute(Snapshot, Settings.IncludeSubgroupItems);
        if (Scope is ViewScope.GroupScope g && !Snapshot.GroupsById.ContainsKey(g.Id)) Scope = ViewScope.All;
        if (Scope is ViewScope.TagScope t && !Snapshot.TagsById.ContainsKey(t.Id)) Scope = ViewScope.All;
        ResolveRows();
        SnapshotChanged?.Invoke();
    }

    void CheckExternalChanges()
    {
        try
        {
            var version = Library.Database.Read(Library.Database.DataVersion);
            if (version != _dataVersion) QueueRefresh();
        }
        catch { }
    }

    public void ResolveRows()
    {
        var query = new ViewQuery(Scope, SearchText, SearchWholeLibrary, _fulltextMatches, Settings.IncludeSubgroupItems, Snapshot.Sort(Scope));
        Rows = ViewResolver.Rows(query, Snapshot);
        RowsChanged?.Invoke();
    }

    public void SelectScope(ViewScope scope)
    {
        if (scope == Scope) return;
        Scope = scope;
        ResolveRows();
    }

    public void Search(string text)
    {
        SearchText = text;
        _fulltextMatches = null;
        ResolveRows();
        if (text.Trim().Length < 2) return;
        _ = Task.Run(() =>
        {
            var ids = Library.FulltextItemIds(text);
            _ui.TryEnqueue(() =>
            {
                if (SearchText != text) return;
                _fulltextMatches = ids;
                ResolveRows();
            });
        });
    }

    public void SetSelection(IReadOnlyList<string> ids)
    {
        SelectedItemIds = ids;
        SelectionChanged?.Invoke();
    }

    public Item? SelectedItem => SelectedItemIds.Count == 1 ? Snapshot.Items.GetValueOrDefault(SelectedItemIds[0]) : null;

    public void Sort(SortColumn? column, bool ascending)
    {
        Perform(() => Library.SetSort(new SortState(column, ascending), Scope));
    }

    // MARK: Actions

    /// <summary>Runs a library change, reporting failures as a toast.</summary>
    public void Perform(Action change)
    {
        try { change(); }
        catch (Exception e) { Toasts.Show(e.Message, "warning"); }
    }

    public void OpenItem(string itemId)
    {
        if (!Snapshot.Items.TryGetValue(itemId, out var item)) return;
        var files = Snapshot.FilesOf(itemId);
        var file = files.FirstOrDefault(f => f.Id == item.DefaultFileId) ?? files.FirstOrDefault(f => f.IsPdf) ?? files.FirstOrDefault();
        if (file == null)
        {
            if (item.Url is { Length: > 0 } url) Shell.Open(url);
            else Toasts.Show(Loc.S("该条目没有附件"), "info");
            return;
        }
        OpenFile(file);
    }

    public void OpenFile(FileRecord file)
    {
        var path = Library.FilePath(file);
        if (!File.Exists(path))
        {
            Toasts.Show(Loc.S("找不到文件「%@」", file.FileName), "warning");
            return;
        }
        if (Settings.MarkReadingOnOpen && Snapshot.Items.TryGetValue(file.ItemId, out var item) && item.Kind == ItemKind.Regular && item.ReadStatus == ReadStatus.Unread)
            Perform(() => Library.UpdateItem(item.Id, i => i.ReadStatus = ReadStatus.Reading));
        if (file.IsPdf && Settings.OpenWith == OpenWith.Folio) OpenInReaderRequested?.Invoke(file);
        else if (Settings.OpenWith == OpenWith.Custom && Settings.OpenWithAppPath is { Length: > 0 } app) Shell.OpenWith(app, path);
        else Shell.Open(path);
    }

    public void Retrieve(IEnumerable<string> itemIds)
    {
        foreach (var id in itemIds) Importer.Retrieve(id, Snapshot);
    }

    public void TrashItems(IReadOnlyCollection<string> ids)
    {
        if (ids.Count == 0) return;
        Perform(() => Library.TrashItems(ids));
        Toasts.Show(ids.Count == 1 ? Loc.S("已移到回收站") : Loc.S("已将 %lld 项移到回收站", ids.Count), "delete",
                    Loc.S("撤销"), () => Perform(() => Library.RestoreItems(ids)));
    }

    public void RestoreItems(IReadOnlyCollection<string> ids) => Perform(() => Library.RestoreItems(ids));

    public void Reveal(string itemId)
    {
        if (Snapshot.Items.TryGetValue(itemId, out var item) && item.IsTrashed) SelectScope(ViewScope.Trash);
        else if (!Rows.Contains(itemId)) { SearchText = ""; SelectScope(ViewScope.All); ResolveRows(); }
        RevealRequested?.Invoke(itemId);
    }

    /// <summary>folio://select?item=… (browser extension, AI agents).</summary>
    public void OpenLink(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var uri)) return;
        var query = System.Web.HttpUtility.ParseQueryString(uri.Query);
        if (uri.Host is "select" or "item" && query["item"] is { } id) Reveal(id);
        else if (uri.Host == "open" && query["item"] is { } open) OpenItem(open);
    }

    // MARK: Citations

    public List<CitationEntry> Entries(IEnumerable<string> itemIds) => itemIds
        .Select(id => Snapshot.Items.GetValueOrDefault(id)).OfType<Item>().Where(i => i.Kind == ItemKind.Regular)
        .Select(i => new CitationEntry(i.Id, i.CitationKey ?? CitationKeyGenerator.BaseKey(i.Metadata), i.Metadata)).ToList();

    public CitationOutput Cite(IEnumerable<string> itemIds, CitationStyle style)
    {
        var entries = Entries(itemIds);
        lock (_cslLock) return _csl.Value.Render(entries, style);
    }

    public (List<string> Each, string Combined) InText(IEnumerable<string> itemIds, CitationStyle style)
    {
        var entries = Entries(itemIds);
        lock (_cslLock) return _csl.Value.InTextCitations(entries, style);
    }

    public CitationStyle DefaultStyle => CitationStyles.Named(Settings.CitationStyle) ?? CitationStyle.Gbt7714;

    // MARK: IImportUi

    void IImportUi.Toast(string message, string icon, string? actionTitle, Action? action) => Toasts.Show(message, icon, actionTitle, action);

    Task<bool> IImportUi.AskRestore(string title) => Dialogs.Confirm(Loc.S("「%@」在回收站中", title), Loc.S("要将它恢复到文献库吗？"), Loc.S("恢复"), Loc.S("取消"));

    Task<bool> IImportUi.AskAttachDuplicate(string title) =>
        Dialogs.Confirm(Loc.S("文献库中已有「%@」", title), Loc.S("可以把这个文件作为附件添加到该条目，或者放弃它。"), Loc.S("作为附件添加到该条目"), Loc.S("放弃"));

    public void RunOnUi(Action action) => _ui.TryEnqueue(() => action());
}
