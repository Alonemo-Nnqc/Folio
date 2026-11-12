using static Folio.Core.AppDatabase;

namespace Folio.Core;

public sealed partial class Library
{
    // Journal ranks cache (META-30)

    /// <summary>Stores fetched ranks (or "not listed", empty Ranks) per journal name, in one transaction.</summary>
    public void SaveJournalMetrics(IReadOnlyList<(string Name, JournalMetrics Metrics)> entries)
    {
        if (entries.Count == 0) return;
        Database.Write((c, tx) =>
        {
            foreach (var (name, metrics) in entries)
            {
                var key = JournalMetrics.Key(name);
                if (key.Length == 0) continue;
                Exec(c, tx, "INSERT OR REPLACE INTO journalMetrics (name, json, fetchedAt) VALUES (?, ?, ?)", key, metrics.Json, FormatDate(metrics.FetchedAt));
            }
        });
    }

    /// <summary>Forgets every cached answer (a new key may see journals the old one could not).</summary>
    public void ClearJournalMetrics() => Database.Write((c, tx) => { Exec(c, tx, "DELETE FROM journalMetrics"); });
}
