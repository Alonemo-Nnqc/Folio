using Folio.Core;

namespace Folio.App;

/// <summary>期刊指标 (META-30): 设置 ▸ 检索's section, 刷新期刊指标, and what the inspector and the list show.</summary>
public static partial class Api
{
    /// <summary>An item's journal ranks for the page: null when never looked up, no badges when easyScholar does not list it.</summary>
    static object? JournalMetricsDto(Item i, LibrarySnapshot s) =>
        s.JournalMetricsOf(i) is { } m
            ? new
            {
                badges = m.Badges.Select(b => new { kind = b.Kind, text = b.Text, detail = b.Detail, emphasized = b.Emphasized }),
                rank = m.RankText, impactFactor = m.ImpactFactor is { } f ? JournalMetrics.Format(f) : null, summary = m.Summary,
            }
            : null;

    static object JournalMetricsState()
    {
        var c = M.JournalMetrics;
        var line = c.StatusText;
        return new
        {
            key = c.SecretKey, hasKey = c.HasKey, autoFetch = M.Settings.JournalMetricsAutoFetch, pending = c.Status.Pending,
            status = line?.Text, attention = line?.Attention ?? false, keyPage = EasyScholarClient.KeyPage,
        };
    }

    static void InstallJournalMetrics()
    {
        Bridge.On("journalMetrics.state", _ =>
        {
            // Opening 设置 fills in whatever the library still lacks.
            M.JournalMetrics.SnapshotDidChange();
            return JournalMetricsState();
        });
        Bridge.On("journalMetrics.setKey", a => { M.JournalMetrics.SaveKey(a.Str("key")); return JournalMetricsState(); });
        Bridge.On("journalMetrics.setAutoFetch", a =>
        {
            M.Settings.JournalMetricsAutoFetch = a.Bool("on");
            M.JournalMetrics.AutoFetchDidChange();
            return JournalMetricsState();
        });
        Bridge.OnAsync("journalMetrics.test", async a =>
        {
            var (ok, text) = await M.JournalMetrics.Test(a.Str("key"));
            return (object?)new { ok, text };
        });
        Bridge.On("journalMetrics.refresh", a =>
        {
            if (!M.JournalMetrics.HasKey) return new { needsKey = true };
            M.JournalMetrics.Refresh(a.Strs("items"));
            return new { needsKey = false };
        });
        M.JournalMetrics.StatusChanged += () => App.Ui.TryEnqueue(() => App.Broadcast("journalMetrics", JournalMetricsState()));
        M.SnapshotChanged += () => M.JournalMetrics.SnapshotDidChange();
    }
}
