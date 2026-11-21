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

    /// <summary>The 出版物 column: where the paper appeared as a capsule ("CVPR", "TPAMI"), then its ranks (CCF class from
    /// easyScholar or the built-in list, 中科院 zone, JCR quartile, impact factor), as on the Mac (VenueBadgesView).</summary>
    static object? VenueDto(Item i, LibrarySnapshot s)
    {
        var venue = VenueCatalog.Of(i);
        var metrics = s.JournalMetricsOf(i);
        var badges = new List<object>();
        var tips = new List<string>();
        if (venue != null)
        {
            badges.Add(new { kind = "venue", text = venue.Abbreviation });
            tips.Add(venue.FullName ?? venue.Abbreviation);
        }
        if ((metrics?.Ccf ?? venue?.Ccf) is { } ccf)
        {
            badges.Add(new { kind = "ccf", text = $"CCF-{ccf}" });
            tips.Add(Loc.S("中国计算机学会推荐：%@ 类", ccf));
        }
        if (metrics != null)
        {
            if ((metrics.CasZone ?? metrics.CasBaseZone) is { } zone)
                badges.Add(new { kind = $"cas{zone}", text = Loc.S("中科院%lld区", zone) + (metrics.CasTop ? " Top" : ""), emphasized = metrics.CasTop });
            if (metrics.JcrQuartile is { } q) badges.Add(new { kind = $"q{q}", text = $"Q{q}" });
            if (metrics.ImpactFactor is { } f) badges.Add(new { kind = "if", text = $"IF {JournalMetrics.Format(f)}" });
            if (metrics.Summary.Length > 0) tips.Add(metrics.Summary);
        }
        return badges.Count == 0 ? null : new { badges, tip = string.Join("\n", tips) };
    }

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
