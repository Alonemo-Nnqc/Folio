namespace Folio.Core.Translate.Services;

/// <summary>A token a free service hands out for a while (Bing's translator session). Everyone asking at the same moment
/// shares one fetch (a warm-up and the translation that follows never fetch twice), and while the token is in use it is
/// fetched again in the background RenewBefore seconds before it runs out, so no translation waits for a token after the
/// first (SEL-20; as TokenStore.swift).</summary>
public sealed class TokenStore<T>(Func<CancellationToken, Task<(T Value, double Lifetime)>> fetch, double renewBefore = 60, double idleAfter = 15 * 60) where T : class
{
    readonly object _gate = new();
    T? _value;
    DateTime _expiry = DateTime.MinValue;
    DateTime _lastUse = DateTime.MinValue;
    Task<T>? _inFlight;
    Timer? _renewal;

    /// <summary>Fetches made (for tests).</summary>
    public int Fetches { get; private set; }

    /// <summary>The token if one is at hand, without fetching.</summary>
    public T? Cached { get { lock (_gate) return DateTime.UtcNow < _expiry ? _value : null; } }

    /// <summary>The current token, fetched first if there is none or it has run out.</summary>
    public Task<T> Get(CancellationToken cancel)
    {
        lock (_gate)
        {
            _lastUse = DateTime.UtcNow;
            if (_value != null && DateTime.UtcNow < _expiry) return Task.FromResult(_value);
        }
        return Load().WaitAsync(cancel);
    }

    /// <summary>The service refused the token: the next request fetches another.</summary>
    public void Invalidate()
    {
        lock (_gate)
        {
            _value = null;
            _expiry = DateTime.MinValue;
            _renewal?.Dispose();
            _renewal = null;
        }
    }

    Task<T> Load()
    {
        lock (_gate)
        {
            if (_inFlight != null) return _inFlight;
            Fetches++;
            _inFlight = Run();
            return _inFlight;
        }

        async Task<T> Run()
        {
            try
            {
                // Not tied to one caller: a translation given up on must not cancel the fetch others wait for.
                var (value, lifetime) = await fetch(CancellationToken.None).ConfigureAwait(false);
                lifetime = Math.Max(lifetime, 10);
                lock (_gate)
                {
                    _value = value;
                    _expiry = DateTime.UtcNow.AddSeconds(lifetime);
                    _renewal?.Dispose();
                    var due = lifetime - renewBefore;
                    _renewal = due > 5 ? new Timer(_ => Renew(), null, TimeSpan.FromSeconds(due), Timeout.InfiniteTimeSpan) : null;
                }
                return value;
            }
            finally
            {
                lock (_gate) _inFlight = null;
            }
        }
    }

    void Renew()
    {
        lock (_gate)
        {
            // Nobody has used it lately: let it run out.
            if ((DateTime.UtcNow - _lastUse).TotalSeconds > idleAfter) return;
        }
        _ = Load().ContinueWith(_ => { }, TaskScheduler.Default);
    }
}
