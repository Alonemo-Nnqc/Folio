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
    bool _refreshQueued, _building, _buildAgain;
    long _changes;
    readonly object _refreshLock = new();
    Microsoft.Data.Sqlite.SqliteConnection? _watcher;

    public AppSettings Settings { get; } = AppSettings.Shared;
    public Library Library { get; private set; } = null!;
    public LibrarySnapshot Snapshot { get; private set; } = LibrarySnapshot.Empty;
    public Importer Importer { get; }
    public ToastCenter Toasts { get; }
    public Updater Updater { get; }
    public ConnectorServer Connector { get; }
    public TranslationCoordinator Translations { get; }
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
    public event Action<FileRecord, int?>? OpenInReaderRequested;

    public AppModel(DispatcherQueue ui)
    {
        _ui = ui;
        Toasts = new ToastCenter(ui);
        Importer = new Importer(() => Library, Settings, this);
        Updater = new Updater(this);
        Connector = new ConnectorServer(this);
        Translations = new TranslationCoordinator(this);
        _externalChanges = ui.CreateTimer();
        _externalChanges.Interval = TimeSpan.FromSeconds(1.5);
        _externalChanges.Tick += (_, _) => CheckExternalChanges();
    }

    /// <summary>Why the chosen library could not be opened at launch, to tell the user once the window is up.</summary>
    public string? StartupProblem { get; private set; }

    public void Start()
    {
        try { OpenLibrary(Settings.LibraryPath); }
        catch (Exception e)
        {
            // A library on a drive that is gone, or a damaged one: Folio still starts, and says so. The setting stays, for when
            // the drive comes back.
            CrashLog.Write(e);
            StartupProblem = Loc.S("无法打开文献库：%@", $"{Settings.LibraryPath}\n{e.Message}");
            OpenLibrary(AppSettings.FallbackLibrary);
        }
        Importer.RetrievalChanged += () => _ui.TryEnqueue(() => SnapshotChanged?.Invoke());
        _externalChanges.Start();
        if (Settings.BrowserConnectorEnabled) Connector.Start();
        Updater.StartAutomaticChecks();
        // Warm citeproc up so the first copy is instant.
        Task.Run(() => { lock (_cslLock) _ = _csl.Value; }).Fire();
    }

    void OpenLibrary(string path)
    {
        // A library that cannot be opened leaves the current one in place.
        var library = new Library(path);
        _watcher?.Dispose();
        _watcher = null;
        Library?.Dispose();
        Library = library;
        try { _watcher = library.Database.OpenWatcher(); } catch (Exception e) { CrashLog.Write(e); }
        Library.Changed += QueueRefresh;
        RefreshNow();
        Importer.LibraryDidLoad(Snapshot);
    }

    /// <summary>Raised before the library's folder or database goes away: readers close their files.</summary>
    public event Action? LibraryWillChange;

    /// <summary>Moves the whole library folder into another folder and reopens it there (Settings ▸ 文献库).</summary>
    public async Task RelocateLibrary(string newParent)
    {
        var old = Library.Root.TrimEnd(Path.DirectorySeparatorChar);
        var target = Path.Combine(newParent, Path.GetFileName(old));
        if (string.Equals(Path.GetFullPath(target), Path.GetFullPath(old), StringComparison.OrdinalIgnoreCase)) return;
        if (Directory.Exists(target) && Directory.EnumerateFileSystemEntries(target).Any())
            throw new IOException(Loc.S("目标位置已有同名文件夹"));
        if (Path.GetFullPath(target).StartsWith(Path.GetFullPath(old) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException(Loc.S("不能把文献库移到它自己里面"));
        LibraryWillChange?.Invoke();
        _watcher?.Dispose();
        _watcher = null;
        Library.Dispose();
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        try
        {
            await Task.Run(() =>
            {
                if (Directory.Exists(target)) Directory.Delete(target);
                if (string.Equals(Path.GetPathRoot(old), Path.GetPathRoot(target), StringComparison.OrdinalIgnoreCase)) Directory.Move(old, target);
                else
                {
                    // Directory.Move cannot cross drives: copy everything first, so a failure leaves the original whole.
                    try { CopyDirectory(old, target); }
                    catch { try { Directory.Delete(target, true); } catch { } throw; }
                    Directory.Delete(old, true);
                }
            });
            Settings.LibraryPath = target;
            OpenLibrary(target);
        }
        catch
        {
            OpenLibrary(old);
            throw;
        }
    }

    static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
        foreach (var dir in Directory.GetDirectories(from)) CopyDirectory(dir, Path.Combine(to, Path.GetFileName(dir)));
    }

    public void SwitchLibrary(string path)
    {
        LibraryWillChange?.Invoke();
        OpenLibrary(path);
        Settings.LibraryPath = path;
    }

    // MARK: Snapshot

    /// <summary>Rebuilds the snapshot off the UI thread; changes arriving meanwhile start one more round afterwards.</summary>
    void QueueRefresh()
    {
        Interlocked.Increment(ref _changes);
        lock (_refreshLock)
        {
            if (_refreshQueued) return;
            _refreshQueued = true;
        }
        _ui.TryEnqueue(DispatcherQueuePriority.Low, () => BuildSnapshot().Fire());
    }

    async Task BuildSnapshot()
    {
        var library = Library;
        lock (_refreshLock) _refreshQueued = false;
        if (_building) { _buildAgain = true; return; }
        _building = true;
        try
        {
            while (true)
            {
                _buildAgain = false;
                long changes = Interlocked.Read(ref _changes);
                long version = WatchedVersion();
                var includeSubgroups = Settings.IncludeSubgroupItems;
                var (snapshot, counts) = await Task.Run(() =>
                {
                    var built = library.Snapshot();
                    return (built, SidebarCounts.Compute(built, includeSubgroups));
                });
                if (library != Library) return;
                Apply(snapshot, counts, version, latest: changes == Interlocked.Read(ref _changes));
                if (!_buildAgain && changes == Interlocked.Read(ref _changes)) return;
            }
        }
        catch (Exception e) when (e is not OutOfMemoryException) { CrashLog.Write(e); }
        finally { _building = false; }
    }

    void Apply(LibrarySnapshot snapshot, Dictionary<string, int> counts, long version, bool latest)
    {
        Snapshot = snapshot;
        Counts = counts;
        _dataVersion = version;
        // A group or tag made a moment ago may not be in an older snapshot.
        if (latest && Scope is ViewScope.GroupScope g && !Snapshot.GroupsById.ContainsKey(g.Id)) Scope = ViewScope.All;
        if (latest && Scope is ViewScope.TagScope t && !Snapshot.TagsById.ContainsKey(t.Id)) Scope = ViewScope.All;
        ResolveRows();
        SnapshotChanged?.Invoke();
    }

    /// <summary>First load, on the spot: the window needs it.</summary>
    void RefreshNow()
    {
        var snapshot = Library.Snapshot();
        Apply(snapshot, SidebarCounts.Compute(snapshot, Settings.IncludeSubgroupItems), WatchedVersion(), latest: true);
    }

    long WatchedVersion()
    {
        try { return _watcher != null ? Library.Database.DataVersion(_watcher) : -1; }
        catch (Exception e) when (e is Microsoft.Data.Sqlite.SqliteException or InvalidOperationException) { return -1; }
    }

    /// <summary>folio-cli and other processes writing to the library.</summary>
    void CheckExternalChanges()
    {
        long version = WatchedVersion();
        if (version != -1 && version != _dataVersion) QueueRefresh();
    }

    /// <summary>Reading positions change all the time while scrolling and show nowhere in the library: they refresh nothing.</summary>
    public void SaveReadingState(ReadingState state)
    {
        CheckExternalChanges();
        bool current = WatchedVersion() == _dataVersion;
        Perform(() => Library.SaveReadingState(state));
        if (current) _dataVersion = WatchedVersion();
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

    /// <summary>"包含 PDF 全文" in the search bar.</summary>
    public bool IncludeFulltext { get; private set; }

    public void SetFulltextSearch(bool on)
    {
        IncludeFulltext = on;
        Search(SearchText);
    }

    public void Search(string text)
    {
        SearchText = text;
        _fulltextMatches = null;
        ResolveRows();
        if (!IncludeFulltext || text.Trim().Length < 2) return;
        var library = Library;
        Task.Run(() =>
        {
            IReadOnlySet<string> ids;
            try { ids = library.FulltextItemIds(text); }
            catch (Exception e) { CrashLog.Write(e); return; }
            _ui.TryEnqueue(() =>
            {
                if (SearchText != text) return;
                _fulltextMatches = ids;
                ResolveRows();
            });
        }).Fire();
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

    public void OpenItem(string itemId, int? page = null)
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
        OpenFile(file, page);
    }

    public void OpenFile(FileRecord file, int? page = null)
    {
        var path = Library.FilePath(file);
        if (!File.Exists(path))
        {
            Toasts.Show(Loc.S("找不到文件「%@」", file.FileName), "warning");
            return;
        }
        // After the reader is up: the paper should appear first.
        if (Settings.MarkReadingOnOpen && Snapshot.Items.TryGetValue(file.ItemId, out var item) && item.Kind == ItemKind.Regular && item.ReadStatus == ReadStatus.Unread)
            _ui.TryEnqueue(DispatcherQueuePriority.Low, () => Perform(() => Library.UpdateItem(item.Id, i => i.ReadStatus = ReadStatus.Reading)));
        if (file.IsPdf && Settings.OpenWith == OpenWith.Folio) OpenInReaderRequested?.Invoke(file, page);
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
        else if (!Rows.Contains(itemId)) { SearchText = ""; _fulltextMatches = null; SelectScope(ViewScope.All); ResolveRows(); }
        RevealRequested?.Invoke(itemId);
    }

    /// <summary>folio://select?item=… (browser extension, AI agents).</summary>
    public void OpenLink(string link)
    {
        if (!Uri.TryCreate(link, UriKind.Absolute, out var uri)) return;
        var query = System.Web.HttpUtility.ParseQueryString(uri.Query);
        if (uri.Host is "select" or "item" && query["item"] is { } id) Reveal(id);
        else if (uri.Host == "open" && query["item"] is { } open) OpenItem(open, int.TryParse(query["page"], out var page) ? page : null);
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

    Task<bool> IImportUi.AskRestore(string title) =>
        AskOnUi(() => Dialogs.Confirm(Loc.S("「%@」在回收站中", title), Loc.S("要将它恢复到文献库吗？"), Loc.S("恢复"), Loc.S("取消")));

    Task<bool> IImportUi.AskAttachDuplicate(string title) =>
        AskOnUi(() => Dialogs.Confirm(Loc.S("文献库中已有「%@」", title), Loc.S("可以把这个文件作为附件添加到该条目，或者放弃它。"), Loc.S("作为附件添加到该条目"), Loc.S("放弃")));

    /// <summary>The importer asks from its background lookups, and a dialog can only live on the UI thread.</summary>
    Task<bool> AskOnUi(Func<Task<bool>> ask)
    {
        if (_ui.HasThreadAccess) return ask();
        var answer = new TaskCompletionSource<bool>();
        bool queued = _ui.TryEnqueue(async () =>
        {
            try { answer.SetResult(await ask()); }
            catch (Exception e) { answer.SetException(e); }
        });
        if (!queued) answer.SetResult(false);
        return answer.Task;
    }

    public void RunOnUi(Action action) => _ui.TryEnqueue(() => action());
}
