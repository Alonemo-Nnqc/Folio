using System.Net;
using System.Text.Json;

namespace Folio.Core;

/// <summary>What easyScholar answered for one journal.</summary>
public abstract record EasyScholarResult
{
    public sealed record Found(Dictionary<string, string> Ranks) : EasyScholarResult;
    public sealed record NotIndexed : EasyScholarResult;
    public sealed record InvalidKey(string Message) : EasyScholarResult;
    public sealed record RateLimited(string Message) : EasyScholarResult;
    public sealed record Failed(string Message) : EasyScholarResult;
}

/// <summary>easyScholar's open API: GET https://www.easyscholar.cc/open/getPublicationRank?secretKey=…&amp;publicationName=…,
/// answering {"code":200,"data":{"officialRank":{"all":{…},"select":{…}}}} or {"code":40002,"msg":"Key错误"}. At most two
/// requests a second. Same reading as EasyScholarClient.swift.</summary>
public sealed class EasyScholarClient(HttpClient? http = null)
{
    public const string Endpoint = "https://www.easyscholar.cc/open/getPublicationRank";
    /// <summary>Where users find their SecretKey.</summary>
    public const string KeyPage = "https://www.easyscholar.cc/console/user/open";

    static readonly HttpClient Shared = new(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All }) { Timeout = TimeSpan.FromSeconds(15) };
    readonly HttpClient _http = http ?? Shared;

    public static string Url(string journal, string secretKey) =>
        $"{Endpoint}?secretKey={Uri.EscapeDataString(secretKey)}&publicationName={Uri.EscapeDataString(journal)}";

    /// <summary>Looks up one journal. Network failures throw HttpRequestException / TaskCanceledException.</summary>
    public async Task<EasyScholarResult> Lookup(string journal, string secretKey, CancellationToken cancel = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, Url(journal, secretKey));
        request.Headers.TryAddWithoutValidation("Accept", "application/json");
        using var response = await _http.SendAsync(request, cancel);
        var data = await response.Content.ReadAsByteArrayAsync(cancel);
        return Parse(data, (int)response.StatusCode);
    }

    public static EasyScholarResult Parse(byte[] data, int status)
    {
        if (status == 429) return new EasyScholarResult.RateLimited("HTTP 429");
        JsonElement root;
        try
        {
            using var doc = JsonDocument.Parse(data, new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
            root = doc.RootElement.Clone();
        }
        catch (JsonException) { return new EasyScholarResult.Failed(status == 200 ? "unreadable response" : $"HTTP {status}"); }
        if (root.ValueKind != JsonValueKind.Object) return new EasyScholarResult.Failed(status == 200 ? "unreadable response" : $"HTTP {status}");
        int code = status;
        if (root.TryGetProperty("code", out var c))
        {
            if (c.ValueKind == JsonValueKind.Number && c.TryGetInt32(out var n)) code = n;
            else if (c.ValueKind == JsonValueKind.String && int.TryParse(c.GetString(), out var s)) code = s;
        }
        string message = (root.TryGetProperty("msg", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString()
            : root.TryGetProperty("message", out var m2) && m2.ValueKind == JsonValueKind.String ? m2.GetString() : "")?.Trim() ?? "";
        if (code != 200)
        {
            var lower = message.ToLowerInvariant();
            if (code == 40002 || (lower.Contains("key") && (message.Contains("错误") || message.Contains("无效") || lower.Contains("invalid"))))
                return new EasyScholarResult.InvalidKey(message.Length == 0 ? "Key错误" : message);
            if (code == 429 || message.Contains("频繁") || message.Contains("过快") || lower.Contains("too many") || lower.Contains("rate"))
                return new EasyScholarResult.RateLimited(message);
            return new EasyScholarResult.Failed(message.Length == 0 ? $"code {code}" : $"{message}（{code}）");
        }
        if (!root.TryGetProperty("data", out var payload) || payload.ValueKind != JsonValueKind.Object) return new EasyScholarResult.NotIndexed();
        var ranks = new Dictionary<string, string>();
        if (payload.TryGetProperty("officialRank", out var official) && official.ValueKind == JsonValueKind.Object)
        {
            foreach (var part in new[] { "all", "select" })
            {
                if (!official.TryGetProperty(part, out var dict) || dict.ValueKind != JsonValueKind.Object) continue;
                foreach (var p in dict.EnumerateObject())
                {
                    string? text = p.Value.ValueKind switch { JsonValueKind.String => p.Value.GetString(), JsonValueKind.Number => p.Value.GetRawText(), _ => null };
                    text = text?.Trim();
                    if (!string.IsNullOrEmpty(text)) ranks.TryAdd(p.Name, text);
                }
            }
        }
        return ranks.Count == 0 ? new EasyScholarResult.NotIndexed() : new EasyScholarResult.Found(ranks);
    }
}

/// <summary>Fetches journal ranks from easyScholar into the library's cache (META-30), as JournalMetricsService.swift:
/// one journal at a time, at least Interval apart; answers ("not listed" included) cached for 30 days; a refused key stops
/// everything until the key changes; network trouble pauses the queue for RetryDelay; a journal that keeps failing is left
/// alone for the session after MaximumAttempts.</summary>
public sealed class JournalMetricsService(Library library, EasyScholarClient? client = null)
{
    public enum ProblemKind { InvalidKey, Network, Service }
    public sealed record Problem(ProblemKind Kind, string Message);
    public sealed record Status(int Pending, Problem? Problem);

    sealed record Job(string Key, string Name, bool Force);

    public Library Library => library;
    readonly EasyScholarClient _client = client ?? new EasyScholarClient();
    public TimeSpan Interval { get; init; } = TimeSpan.FromMilliseconds(600);
    public TimeSpan RetryDelay { get; init; } = TimeSpan.FromMinutes(5);
    public int MaximumAttempts { get; init; } = 3;
    public event Action<Status>? StatusChanged;

    readonly object _gate = new();
    string? _key;
    readonly List<Job> _queue = [];
    readonly Dictionary<string, (int Count, DateTime NotBefore)> _failures = [];
    DateTime? _pausedUntil;
    Problem? _problem;
    Task? _worker;
    int _generation;
    string? _current;
    DateTime _nextSlot = DateTime.MinValue;
    readonly List<(string, JournalMetrics)> _unsaved = [];
    DateTime _lastSave = DateTime.UtcNow;

    public Status Current { get { lock (_gate) return new Status(_queue.Count + (_current == null ? 0 : 1), _problem); } }

    /// <summary>A new (or removed) key starts over: earlier refusals and failures no longer apply.</summary>
    public void SetKey(string? key)
    {
        var normalized = string.IsNullOrWhiteSpace(key) ? null : key.Trim();
        lock (_gate)
        {
            if (normalized == _key) return;
            _key = normalized;
            _problem = null;
            _failures.Clear();
            _pausedUntil = null;
            if (_key == null) _queue.Clear();
        }
        Report();
        StartIfNeeded();
    }

    /// <summary>Adds journals to look up. force (刷新期刊指标) asks again even when cached, goes first, ignores failures.</summary>
    public void Enqueue(IEnumerable<string> names, bool force = false)
    {
        bool added = false;
        lock (_gate)
        {
            if (_key == null || _problem?.Kind == ProblemKind.InvalidKey) return;
            var now = DateTime.UtcNow;
            if (!force && _pausedUntil is { } paused && now < paused) return;
            var known = _queue.Select(j => j.Key).ToHashSet();
            if (_current != null) known.Add(_current);
            var jobs = new List<Job>();
            foreach (var name in names)
            {
                var key = JournalMetrics.Key(name);
                if (key.Length == 0) continue;
                if (force)
                {
                    _failures.Remove(key);
                    _queue.RemoveAll(j => j.Key == key);
                    if (key != _current) jobs.Add(new Job(key, JournalMetrics.QueryName(name), true));
                    continue;
                }
                if (known.Contains(key)) continue;
                if (_failures.TryGetValue(key, out var f) && (f.Count >= MaximumAttempts || now < f.NotBefore)) continue;
                known.Add(key);
                jobs.Add(new Job(key, JournalMetrics.QueryName(name), false));
            }
            if (jobs.Count == 0) return;
            if (force) _queue.InsertRange(0, jobs); else _queue.AddRange(jobs);
            added = true;
        }
        if (added) { Report(); StartIfNeeded(); }
    }

    /// <summary>Stops and forgets what is queued.</summary>
    public void CancelAll()
    {
        lock (_gate)
        {
            _queue.Clear();
            _generation++;
            _current = null;
            _worker = null;
        }
        Flush();
        Report();
    }

    /// <summary>"测试": one lookup with key (not necessarily the saved one).</summary>
    public async Task<EasyScholarResult> Test(string key, string journal = "Nature")
    {
        await WaitForSlot();
        return await _client.Lookup(journal, key.Trim());
    }

    /// <summary>Waits until the queue is empty (tests).</summary>
    public async Task Idle()
    {
        while (true)
        {
            Task? worker;
            lock (_gate) worker = _worker;
            if (worker == null) return;
            await worker;
        }
    }

    void StartIfNeeded()
    {
        lock (_gate)
        {
            if (_worker != null || _queue.Count == 0 || _key == null) return;
            int run = ++_generation;
            _worker = Task.Run(() => Run(run));
        }
    }

    async Task Run(int generation)
    {
        int rateLimitedInARow = 0;
        while (true)
        {
            Job job;
            string key;
            lock (_gate)
            {
                if (generation != _generation || _queue.Count == 0 || _key == null) break;
                job = _queue[0];
                _queue.RemoveAt(0);
                _current = job.Key;
                key = _key;
            }
            Report();
            await WaitForSlot();
            lock (_gate) if (generation != _generation || _key != key) break;
            try
            {
                var result = await _client.Lookup(job.Name, key);
                lock (_gate)
                {
                    if (generation != _generation || _key != key) break;
                    switch (result)
                    {
                        case EasyScholarResult.Found found:
                            rateLimitedInARow = 0;
                            Store(job, new JournalMetrics(found.Ranks, DateTime.UtcNow));
                            if (_problem?.Kind == ProblemKind.Service) _problem = null;
                            break;
                        case EasyScholarResult.NotIndexed:
                            rateLimitedInARow = 0;
                            Store(job, new JournalMetrics(new Dictionary<string, string>(), DateTime.UtcNow));
                            break;
                        case EasyScholarResult.InvalidKey invalid:
                            _problem = new Problem(ProblemKind.InvalidKey, invalid.Message);
                            _queue.Clear();
                            break;
                        case EasyScholarResult.RateLimited:
                            rateLimitedInARow++;
                            if (rateLimitedInARow <= 5)
                            {
                                _queue.Insert(0, job);
                                var start = _nextSlot > DateTime.UtcNow ? _nextSlot : DateTime.UtcNow;
                                _nextSlot = start.AddSeconds(rateLimitedInARow * 2);
                            }
                            else { Fail(job, new Problem(ProblemKind.Service, "too many requests")); rateLimitedInARow = 0; }
                            break;
                        case EasyScholarResult.Failed failed:
                            Fail(job, new Problem(ProblemKind.Service, failed.Message));
                            break;
                    }
                }
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or IOException)
            {
                // Offline, DNS, timeout: everything else would fail the same way; try again later.
                lock (_gate)
                {
                    Fail(job, new Problem(ProblemKind.Network, e.Message));
                    _pausedUntil = DateTime.UtcNow + RetryDelay;
                    _queue.RemoveAll(j => !j.Force);
                }
            }
            bool flush;
            lock (_gate)
            {
                if (generation == _generation) _current = null;
                flush = _queue.Count == 0 || job.Force || _unsaved.Count >= 10 || DateTime.UtcNow - _lastSave > TimeSpan.FromSeconds(2);
            }
            if (flush) Flush();
            Report();
        }
        Flush();
        lock (_gate)
        {
            if (generation != _generation) return;
            _current = null;
            _worker = null;
        }
        Report();
        StartIfNeeded();
    }

    void Store(Job job, JournalMetrics metrics)
    {
        _failures.Remove(job.Key);
        _unsaved.Add((job.Key, metrics));
    }

    void Fail(Job job, Problem problem)
    {
        int count = (_failures.TryGetValue(job.Key, out var f) ? f.Count : 0) + 1;
        _failures[job.Key] = (count, DateTime.UtcNow + RetryDelay);
        _problem = problem;
    }

    void Flush()
    {
        List<(string, JournalMetrics)> entries;
        lock (_gate)
        {
            _lastSave = DateTime.UtcNow;
            if (_unsaved.Count == 0) return;
            entries = [.. _unsaved];
            _unsaved.Clear();
        }
        try { library.SaveJournalMetrics(entries); } catch (Exception) { /* a locked or closed library: asked again next time */ }
    }

    async Task WaitForSlot()
    {
        DateTime slot;
        lock (_gate)
        {
            var now = DateTime.UtcNow;
            slot = _nextSlot > now ? _nextSlot : now;
            _nextSlot = slot + Interval;
        }
        var wait = slot - DateTime.UtcNow;
        if (wait > TimeSpan.Zero) await Task.Delay(wait);
    }

    void Report() => StatusChanged?.Invoke(Current);

    /// <summary>Journals of the library whose ranks were never fetched or are older than 30 days, most recently changed
    /// items first, each once.</summary>
    public static List<string> StaleJournals(LibrarySnapshot snapshot, DateTime? now = null)
    {
        var n = now ?? DateTime.UtcNow;
        var stale = new Dictionary<string, (string Name, DateTime Modified)>();
        foreach (var item in snapshot.Items.Values)
        {
            if (item.IsTrashed || JournalMetrics.JournalName(item) is not { } name) continue;
            var key = JournalMetrics.Key(name);
            if (snapshot.JournalMetrics.TryGetValue(key, out var cached) && cached.IsFresh(n)) continue;
            if (stale.TryGetValue(key, out var known) && known.Modified >= item.DateModified) continue;
            stale[key] = (name, item.DateModified);
        }
        return stale.Values.OrderByDescending(v => v.Modified).ThenBy(v => v.Name, StringComparer.Ordinal).Select(v => v.Name).ToList();
    }
}
