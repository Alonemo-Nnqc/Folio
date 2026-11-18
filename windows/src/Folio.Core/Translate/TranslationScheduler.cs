namespace Folio.Core.Translate;

/// <summary>Which waiting translation starts next: the first in line whose service has room, while there is room in all.
/// (The macOS TranslationScheduler.)</summary>
public static class TranslationScheduler
{
    public static int? Next(IReadOnlyList<string> waiting, IReadOnlyCollection<string> running, int perService, int total)
    {
        if (running.Count >= total) return null;
        for (int i = 0; i < waiting.Count; i++)
            if (running.Count(s => s == waiting[i]) < perService) return i;
        return null;
    }
}
