using Folio.Core;
using Folio.Core.Translate.Services;

namespace Folio.App;

/// <summary>Journal ranks for the open library (META-30), as the macOS JournalMetricsCoordinator: the easyScholar key (kept
/// with the translation keys, encrypted for this Windows user), the fetch queue fed after every snapshot while 自动获取 is
/// on, and what 设置 ▸ 检索 shows about it.</summary>
public sealed class JournalMetricsCoordinator(AppModel model)
{
    const string SecretService = "easyscholar", SecretOption = "secretKey";

    JournalMetricsService? _service;
    string? _key;
    bool _keyLoaded;
    HashSet<string> _lastEnqueued = [];

    /// <summary>Raised (on any thread) when the queue or its problem changed.</summary>
    public event Action? StatusChanged;

    public string SecretKey
    {
        get
        {
            if (!_keyLoaded) { _key = SecretStore.Shared.Get(SecretService, SecretOption); _keyLoaded = true; }
            return _key ?? "";
        }
    }

    public bool HasKey => SecretKey.Trim().Length > 0;

    public JournalMetricsService.Status Status => _service?.Current ?? new JournalMetricsService.Status(0, null);

    /// <summary>The line under the key in 设置, and whether it needs attention.</summary>
    public (string Text, bool Attention)? StatusText
    {
        get
        {
            var status = Status;
            switch (status.Problem)
            {
                case { Kind: JournalMetricsService.ProblemKind.InvalidKey }: return (Loc.S("密钥无效，已停止获取"), true);
                case { Kind: JournalMetricsService.ProblemKind.Network } when status.Pending == 0: return (Loc.S("网络不可用，稍后自动重试"), true);
                case { Kind: JournalMetricsService.ProblemKind.Service } p when status.Pending == 0: return (Loc.S("easyScholar 暂时无法使用（%@）", p.Message), true);
            }
            if (status.Pending > 0) return (Loc.S("正在获取 %lld 个期刊的指标…", status.Pending), false);
            return null;
        }
    }

    /// <summary>A new key replaces the old one: earlier "not listed" answers are forgotten (the new key may see more).</summary>
    public void SaveKey(string key)
    {
        key = key.Trim();
        if (key == SecretKey) return;
        SecretStore.Shared.Set(key, SecretService, SecretOption);
        _key = key;
        _lastEnqueued = [];
        var service = Current();
        service?.SetKey(key);
        if (key.Length > 0) SnapshotDidChange();
        StatusChanged?.Invoke();
    }

    public async Task<(bool Ok, string Text)> Test(string key)
    {
        key = key.Trim();
        if (key.Length == 0) return (false, Loc.S("请先填写密钥"));
        var service = Current() ?? new JournalMetricsService(model.Library);
        try
        {
            var result = await service.Test(key);
            return result switch
            {
                EasyScholarResult.Found found => (true, Loc.S("连接成功：Nature %@", new JournalMetrics(found.Ranks, DateTime.UtcNow).Summary)),
                EasyScholarResult.NotIndexed => (true, Loc.S("连接成功")),
                EasyScholarResult.InvalidKey => (false, Loc.S("密钥无效，请检查是否完整复制")),
                EasyScholarResult.RateLimited => (false, Loc.S("请求过于频繁，请稍后再试")),
                EasyScholarResult.Failed failed => (false, Loc.S("easyScholar 暂时无法使用（%@）", failed.Message)),
                _ => (false, ""),
            };
        }
        catch (Exception e) { return (false, Loc.S("无法连接 easyScholar：%@", e.Message)); }
    }

    /// <summary>"刷新期刊指标": these items' journals are asked again, first in the queue.</summary>
    public void Refresh(IEnumerable<string> itemIds)
    {
        var s = model.Snapshot;
        var names = itemIds.Select(id => s.Items.GetValueOrDefault(id)).OfType<Item>().Select(JournalMetrics.JournalName).OfType<string>().Distinct().ToList();
        if (names.Count == 0 || !HasKey) return;
        Current()?.Enqueue(names, force: true);
    }

    public void AutoFetchDidChange()
    {
        if (model.Settings.JournalMetricsAutoFetch) { _lastEnqueued = []; SnapshotDidChange(); }
        else _service?.CancelAll();
    }

    /// <summary>After every snapshot: journals never looked up (new items, changed names) or older than 30 days join the queue.</summary>
    public void SnapshotDidChange()
    {
        if (!model.Settings.JournalMetricsAutoFetch || !HasKey) return;
        var stale = JournalMetricsService.StaleJournals(model.Snapshot);
        var fresh = stale.Where(n => !_lastEnqueued.Contains(JournalMetrics.Key(n))).ToList();
        if (fresh.Count == 0) return;
        foreach (var n in fresh) _lastEnqueued.Add(JournalMetrics.Key(n));
        Current()?.Enqueue(fresh);
    }

    /// <summary>The service for the library now open (another library gets its own).</summary>
    JournalMetricsService? Current()
    {
        if (_service != null && ReferenceEquals(_service.Library, model.Library)) return _service;
        _service?.CancelAll();
        var service = new JournalMetricsService(model.Library) { RetryDelay = TimeSpan.FromMinutes(5) };
        service.StatusChanged += _ => StatusChanged?.Invoke();
        service.SetKey(SecretKey);
        _service = service;
        _lastEnqueued = [];
        return service;
    }
}
