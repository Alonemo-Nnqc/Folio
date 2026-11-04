using Folio.Core.Retrieval;

namespace Folio.Core;

/// <summary>What the importer needs from the interface: messages and the two duplicate questions.</summary>
public interface IImportUi
{
    void Toast(string message, string icon = "info", string? actionTitle = null, Action? action = null);
    /// <summary>The file is in the trash: restore it?</summary>
    Task<bool> AskRestore(string title);
    /// <summary>A retrieved PDF is a paper already in the library: attach it there (true) or discard it (false).</summary>
    Task<bool> AskAttachDuplicate(string title);
}

/// <summary>
/// Imports files and retrieves their metadata in the background, as the macOS ImportCoordinator does: four lookups
/// at a time, network failures retried up to three times (and when the network comes back), full-text indexing,
/// and automatic purging of trash older than 30 days.
/// </summary>
public sealed class Importer
{
    public const int EngineRevision = 3;
    const int MaxConcurrent = 4;
    const int MaxNetworkRetries = 3;

    readonly Func<Library> _library;
    readonly AppSettings _settings;
    readonly IImportUi _ui;
    readonly object _lock = new();
    readonly Queue<string> _queue = new();
    readonly HashSet<string> _queued = [];
    int _running;
    readonly List<string> _failedNames = [];
    CancellationTokenSource? _failureToast;
    int _indexing;
    MetadataEngine? _engine;

    public Importer(Func<Library> library, AppSettings settings, IImportUi ui)
    {
        _library = library;
        _settings = settings;
        _ui = ui;
        settings.Changed += key => { if (key is "crossrefMailto" or "openAlexAPIKey" or "useZoteroRecognizer") _engine = null; };
        System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged += (_, e) => { if (e.IsAvailable) RetryNetworkFailures(); };
    }

    public MetadataEngine Engine => _engine ??= new MetadataEngine(new MetadataEngineConfiguration
    {
        Mailto = Text.NonEmpty(_settings.CrossrefMailto),
        OpenAlexApiKey = Text.NonEmpty(_settings.OpenAlexApiKey),
        UseZoteroRecognizer = _settings.UseZoteroRecognizer,
    });

    Library Library => _library();

    /// <summary>Picks up pending and retryable items of a freshly opened library.</summary>
    public void LibraryDidLoad(LibrarySnapshot snapshot)
    {
        bool retryFailed = _settings.MetadataEngineRevision < EngineRevision;
        _settings.MetadataEngineRevision = EngineRevision;
        foreach (var item in snapshot.Items.Values.Where(i => !i.IsTrashed && i.Kind == ItemKind.Standalone))
        {
            bool isPdf = snapshot.FilesOf(item.Id).FirstOrDefault()?.IsPdf ?? false;
            switch (item.MetadataState)
            {
                case MetadataState.Pending: Enqueue(item.Id); break;
                case MetadataState.NetworkFailed when item.RetryCount < MaxNetworkRetries: Enqueue(item.Id); break;
                case MetadataState.Failed when retryFailed && isPdf: Retrieve(item.Id, snapshot); break;
            }
        }
        IndexFulltext();
        PurgeTrashIfNeeded();
    }

    public void PurgeTrashIfNeeded()
    {
        if (!_settings.AutoPurgeTrash) return;
        _ = Task.Run(() => { try { Library.PurgeTrash(DateTime.UtcNow.AddDays(-30)); } catch { } });
    }

    public void RefreshChangedFiles() => Task.Run(() =>
    {
        try { if (Library.RefreshFingerprints().Count > 0) IndexFulltext(); } catch { }
    });

    // MARK: Importing

    public static List<string> Expand(IEnumerable<string> paths)
    {
        var result = new List<string>();
        foreach (var path in paths)
        {
            if (Directory.Exists(path))
                result.AddRange(Directory.EnumerateFiles(path, "*.pdf", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, MatchCasing = MatchCasing.CaseInsensitive })
                    .Where(f => !Path.GetFileName(f).StartsWith('.')));
            else if (File.Exists(path)) result.Add(path);
        }
        return result;
    }

    public async Task ImportFiles(IEnumerable<string> paths, string? groupId)
    {
        var files = Expand(paths);
        if (files.Count == 0)
        {
            _ui.Toast(Loc.S("没有找到可导入的文件"), "question");
            return;
        }
        var outcomes = await Task.Run(() => Library.ImportFiles(files, groupId));
        foreach (var outcome in outcomes)
        {
            switch (outcome)
            {
                case ImportOutcome.Imported imported when imported.IsPdf:
                    if (_settings.AutoRetrieveOnImport) Enqueue(imported.ItemId);
                    else Library.SetMetadataState(MetadataState.None, imported.ItemId);
                    IndexFulltext();
                    break;
                case ImportOutcome.DuplicateFile d:
                    var title = Library.Item(d.ExistingItemId)?.Title ?? "";
                    if (d.AddedToGroup && groupId != null && Library.Snapshot().GroupsById.GetValueOrDefault(groupId) is { } g)
                        _ui.Toast(Loc.S("已有该文献，已加入「%@」", g.Name), "copy");
                    else _ui.Toast(Loc.S("已有该文献「%@」", title), "copy");
                    break;
                case ImportOutcome.DuplicateInTrash t:
                    if (await _ui.AskRestore(Library.Item(t.ExistingItemId)?.Title ?? "")) Library.RestoreItems([t.ExistingItemId]);
                    break;
                case ImportOutcome.Failed f:
                    _ui.Toast(Loc.S("无法添加「%@」：%@", Path.GetFileName(f.Path), f.Reason), "warning");
                    break;
            }
        }
    }

    public async Task AttachFiles(IEnumerable<string> paths, string itemId)
    {
        var outcomes = await Task.Run(() => Library.AddFiles(paths, itemId, _settings.AutoRenameFiles));
        int added = outcomes.Count(o => o is AddFileOutcome.Added);
        if (outcomes.Any(o => o is AddFileOutcome.Duplicate)) _ui.Toast(Loc.S("已有该文献"), "copy");
        else if (added > 0) _ui.Toast(added == 1 ? Loc.S("已添加文件") : Loc.S("已添加 %lld 个文件", added), "attach");
        if (added > 0) IndexFulltext();
        foreach (var f in outcomes.OfType<AddFileOutcome.Failed>())
            _ui.Toast(Loc.S("无法添加「%@」：%@", Path.GetFileName(f.Path), f.Reason), "warning");
    }

    // MARK: Retrieval

    public void Retrieve(string itemId, LibrarySnapshot snapshot)
    {
        if (!snapshot.Items.TryGetValue(itemId, out var item)) return;
        if (item.Kind == ItemKind.Standalone)
        {
            Library.SetMetadataState(MetadataState.Pending, itemId);
            Enqueue(itemId);
        }
        else _ = RefreshRegularItem(item);
    }

    void Enqueue(string id)
    {
        lock (_lock)
        {
            if (!_queued.Add(id)) return;
            _queue.Enqueue(id);
        }
        Pump();
    }

    void Pump()
    {
        while (true)
        {
            string id;
            lock (_lock)
            {
                if (_running >= MaxConcurrent || _queue.Count == 0) return;
                id = _queue.Dequeue();
                _running++;
            }
            _ = Task.Run(async () =>
            {
                try { await ResolveStandalone(id); }
                catch { }
                finally
                {
                    lock (_lock) { _running--; _queued.Remove(id); }
                    Pump();
                }
            });
        }
    }

    public bool IsRetrieving(string id) { lock (_lock) return _queued.Contains(id); }

    async Task ResolveStandalone(string id)
    {
        var library = Library;
        var item = library.Item(id);
        if (item == null || item.Kind != ItemKind.Standalone || library.Files(id).FirstOrDefault() is not { } file) return;
        if (item.MetadataState != MetadataState.Pending) library.SetMetadataState(MetadataState.Pending, id);
        switch (await Engine.ResolvePdf(library.FilePath(file)))
        {
            case ResolveResult.Found found:
                await Apply(found.Metadata, id);
                break;
            case ResolveResult.NotFound:
                library.SetMetadataState(MetadataState.Failed, id);
                ReportFailure(item.Title);
                break;
            default:
                library.SetMetadataState(MetadataState.NetworkFailed, id, incrementRetry: true);
                ReportFailure(item.Title);
                break;
        }
    }

    public async Task Apply(Metadata metadata, string standaloneId)
    {
        try
        {
            if (Library.ApplyMetadata(metadata, standaloneId, _settings.AutoRenameFiles) is ApplyOutcome.DuplicateItem duplicate)
            {
                var title = Library.Item(duplicate.ExistingItemId)?.Title ?? metadata.Title;
                Library.SetMetadataState(MetadataState.None, standaloneId);
                if (await _ui.AskAttachDuplicate(title)) Library.MergeStandalone(standaloneId, duplicate.ExistingItemId, _settings.AutoRenameFiles);
                else Library.DiscardStandalone(standaloneId);
            }
        }
        catch (Exception e)
        {
            _ui.Toast(Loc.S("无法创建条目：%@", e.Message), "warning");
        }
    }

    async Task RefreshRegularItem(Item item)
    {
        var identifier = item.Doi ?? item.ArxivId ?? item.Isbn;
        _ui.Toast(Loc.S("正在重新检索元数据…"), "refresh");
        ResolveResult result;
        if (!string.IsNullOrEmpty(identifier)) result = await Engine.Resolve(identifier);
        else
        {
            var best = (await Engine.Search(item.Title)).FirstOrDefault();
            result = best != null && TitleNormalizer.Similarity(best.Title, item.Title) >= 0.9 ? new ResolveResult.Found(best) : ResolveResult.Missing;
        }
        switch (result)
        {
            case ResolveResult.Found found:
                Library.UpdateMetadata(item.Id, found.Metadata, _settings.AutoRenameFiles);
                _ui.Toast(Loc.S("元数据已更新"), "check");
                break;
            case ResolveResult.NotFound:
                _ui.Toast(Loc.S("未检索到该条目的元数据"), "question");
                break;
            default:
                _ui.Toast(Loc.S("网络不可用，请稍后重试"), "offline");
                break;
        }
    }

    /// <summary>Failures arriving close together are reported in one message.</summary>
    void ReportFailure(string name)
    {
        CancellationTokenSource cts;
        lock (_lock)
        {
            _failedNames.Add(name);
            _failureToast?.Cancel();
            cts = _failureToast = new CancellationTokenSource();
        }
        _ = Task.Run(async () =>
        {
            try { await Task.Delay(1500, cts.Token); } catch { return; }
            List<string> names;
            lock (_lock) { names = [.. _failedNames]; _failedNames.Clear(); }
            _ui.Toast(names.Count == 1 ? Loc.S("未检索到「%@」的元数据，已保留为独立文件", names[0]) : Loc.S("%lld 个文件未检索到元数据，已保留为独立文件", names.Count), "question");
        });
    }

    void RetryNetworkFailures()
    {
        try
        {
            foreach (var item in Library.Snapshot().Items.Values)
                if (!item.IsTrashed && item.Kind == ItemKind.Standalone && item.MetadataState == MetadataState.NetworkFailed && item.RetryCount < MaxNetworkRetries)
                    Enqueue(item.Id);
        }
        catch { }
    }

    // MARK: Full-text index

    public void IndexFulltext()
    {
        if (Interlocked.Exchange(ref _indexing, 1) == 1) return;
        _ = Task.Run(() =>
        {
            try
            {
                var library = Library;
                while (true)
                {
                    var pending = library.FilesNeedingFulltext();
                    if (pending.Count == 0) break;
                    foreach (var batch in pending.Chunk(20))
                        library.SetFulltext(batch.Select(f => (f.Id, PdfText.FullText(library.FilePath(f)))).ToList());
                }
            }
            catch { }
            finally { Interlocked.Exchange(ref _indexing, 0); }
        });
    }
}
