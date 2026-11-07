using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;

namespace Folio.Core.Retrieval;

/// <summary>Outcome of a metadata lookup.</summary>
public abstract record ResolveResult
{
    /// <summary>A trustworthy match was found.</summary>
    public sealed record Found(Metadata Metadata) : ResolveResult;
    /// <summary>The sources answered, but nothing matched well enough. Retrying will not help.</summary>
    public sealed record NotFound : ResolveResult;
    /// <summary>No source could be reached. Worth retrying later.</summary>
    public sealed record NetworkError : ResolveResult;

    public static readonly ResolveResult Missing = new NotFound();
    public static readonly ResolveResult Offline = new NetworkError();
}

public sealed class MetadataEngineConfiguration
{
    /// <summary>Contact address for the Crossref / OpenAlex polite pool; also sent in the User-Agent.</summary>
    public string? Mailto { get; set; }
    public string? OpenAlexApiKey { get; set; }
    public TimeSpan RequestTimeout { get; set; } = TimeSpan.FromSeconds(15);
    public TimeSpan OverallTimeout { get; set; } = TimeSpan.FromSeconds(35);
    /// <summary>Also sends the layout of a PDF's first five pages to Zotero's recognizer service.</summary>
    public bool UseZoteroRecognizer { get; set; } = true;
}

sealed record Candidate(Metadata Metadata, SourceKind Source);

/// <summary>Decides whether a record returned by a source really is the PDF at hand. Errs on the side of rejecting.</summary>
sealed class CandidateScorer
{
    public const double AcceptWithAuthors = 0.90, AcceptTitleOnly = 0.97, IdentifierMinimum = 0.85;
    const int MinimumWindowTokens = 4;

    public sealed record Evaluation(double GuessSimilarity, double PageSimilarity, bool AuthorsFound, bool IsEditorialNotice, int TitleTokenCount)
    {
        public double TitleSimilarity => Math.Max(GuessSimilarity, PageSimilarity);
        public bool IsAccepted
        {
            get
            {
                if (IsEditorialNotice) return false;
                if (TitleSimilarity >= AcceptWithAuthors && AuthorsFound) return true;
                if (GuessSimilarity >= AcceptTitleOnly && TitleTokenCount >= 4) return true;
                return PageSimilarity >= AcceptTitleOnly && TitleTokenCount >= 6;
            }
        }
    }

    readonly List<string> _guesses;
    readonly List<string> _pageTokens;

    public CandidateScorer(string pageText, List<string> guesses)
    {
        _guesses = guesses;
        _pageTokens = TextMatcher.Tokens(pageText);
    }

    public Evaluation Evaluate(Metadata m)
    {
        var titleTokens = TextMatcher.Tokens(m.Title);
        var guess = _guesses.Count == 0 ? 0 : _guesses.Max(g => TitleNormalizer.Similarity(g, m.Title));
        var page = titleTokens.Count >= MinimumWindowTokens ? TextMatcher.WindowSimilarity(m.Title, _pageTokens) : 0;
        return new Evaluation(guess, page, AuthorsAppear(m.Authors), IsUnexpectedEditorialNotice(m.Title), titleTokens.Count);
    }

    public bool VerifiesIdentifierResult(Metadata m, bool selfDescribing)
    {
        var e = Evaluate(m);
        if (e.IsEditorialNotice) return false;
        if (e.TitleSimilarity >= IdentifierMinimum) return true;
        return selfDescribing && e.AuthorsFound;
    }

    public bool AcceptsRecognizedFields(Metadata m)
    {
        if (_guesses.FirstOrDefault() is not { } best || TitleNormalizer.Similarity(best, m.Title) < AcceptWithAuthors) return false;
        return Evaluate(m).IsAccepted;
    }

    bool AuthorsAppear(List<Author> authors)
    {
        foreach (var author in authors.Take(3))
        {
            var family = author.Family.Trim();
            if (family.Length == 0) continue;
            if (TextMatcher.ContainsName(family, _pageTokens)) return true;
            if (author.Given.Length > 0 && TextMatcher.ContainsName(author.Given, _pageTokens)
                && TextMatcher.Tokens(family).All(t => _pageTokens.Any(p => p.StartsWith(t, StringComparison.Ordinal))))
                return true;
        }
        return false;
    }

    static readonly string[] NoticePrefixes =
    [
        "correction", "corrigendum", "erratum", "errata", "retraction", "retracted", "expression of concern",
        "reply to", "response to", "comment on", "comments on", "author correction", "publisher correction",
        "withdrawn", "withdrawal", "notice of", "editorial", "review of",
    ];

    bool IsUnexpectedEditorialNotice(string title)
    {
        var normalized = TitleNormalizer.Normalize(title);
        var prefix = NoticePrefixes.FirstOrDefault(p => normalized.StartsWith(p, StringComparison.Ordinal));
        return prefix != null && !_guesses.Any(g => TitleNormalizer.Normalize(g).StartsWith(prefix, StringComparison.Ordinal));
    }
}

static class CandidateRanking
{
    static int Tier(Candidate c, bool pdfHasArxivId)
    {
        var m = c.Metadata;
        bool isPreprint = m.Type == ItemType.Preprint || m.ArxivId != null || (m.Doi != null && IdentifierExtractor.ArxivIdFromDoi(m.Doi) != null);
        if (pdfHasArxivId) return isPreprint && m.ArxivId != null ? 0 : (m.Doi != null ? 1 : 2);
        if (!isPreprint && m.Doi != null) return 0;
        if (!isPreprint && c.Source == SourceKind.Dblp) return 1;
        return isPreprint ? 3 : 2;
    }

    public static (Candidate Candidate, CandidateScorer.Evaluation Evaluation)? Best(
        List<(Candidate Candidate, CandidateScorer.Evaluation Evaluation)> accepted, bool pdfHasArxivId)
    {
        if (accepted.Count == 0) return null;
        return accepted.OrderBy(a => Tier(a.Candidate, pdfHasArxivId))
            .ThenByDescending(a => a.Evaluation.TitleSimilarity)
            .ThenByDescending(a => Completeness(a.Candidate.Metadata)).First();
    }

    static int Completeness(Metadata m) =>
        new object?[] { m.Year, m.Source, m.Volume, m.Issue, m.Pages, m.Publisher, m.Doi, m.Abstract }.Count(f => f != null) + Math.Min(m.Authors.Count, 3);
}

/// <summary>Which identifiers found in a PDF are worth a lookup: at most 3 DOIs, 1 arXiv ID and 1 ISBN.</summary>
sealed class LookupPlan
{
    public List<FoundIdentifier> Identifiers { get; }
    public bool PdfHasArxivId { get; }

    public LookupPlan(List<FoundIdentifier> found)
    {
        var arxiv = found.FirstOrDefault(f => f.IsArxiv && f.IsSelfDescribing) ?? found.FirstOrDefault(f => f.IsArxiv);
        var arxivId = (arxiv?.Identifier as Identifier.Arxiv)?.Value;
        var dois = found.Where(f => f.Identifier is Identifier.Doi d && (arxivId == null || IdentifierExtractor.ArxivIdFromDoi(d.Value) != arxivId)).ToList();
        var chosen = dois.Take(3).ToList();
        if (dois.FirstOrDefault(d => d.IsSelfDescribing) is { } own && !chosen.Contains(own) && chosen.Count > 0) chosen[^1] = own;
        if (arxiv != null) chosen.Add(arxiv);
        if (found.FirstOrDefault(f => f.IsIsbn) is { } isbn) chosen.Add(isbn);
        Identifiers = chosen;
        PdfHasArxivId = arxiv != null;
    }
}

/// <summary>
/// Retrieves bibliographic metadata for PDFs, identifiers and free-text queries from open sources (Crossref, DOI
/// content negotiation, arXiv, OpenAlex, DBLP, Open Library, CVF, Zotero's recognizer). The same pipeline and
/// thresholds as the macOS MetadataEngine. Keep one instance so connections and the per-host throttle are shared.
/// </summary>
public sealed class MetadataEngine
{
    readonly MetadataEngineConfiguration _config;
    readonly CrossrefClient _crossref;
    readonly DoiNegotiationClient _negotiation;
    readonly ArxivClient _arxiv;
    readonly OpenAlexClient _openAlex;
    readonly DblpClient _dblp;
    readonly OpenLibraryClient _openLibrary;
    readonly CvfClient _cvf;
    readonly ZoteroRecognizerClient _recognizer;
    static readonly TimeSpan SearchGrace = TimeSpan.FromMilliseconds(800);
    static readonly TimeSpan RecognizerTimeout = TimeSpan.FromSeconds(10);
    static readonly TimeSpan RecognizerLookupTimeout = TimeSpan.FromSeconds(12);
    const int MaxSearchRounds = 2;
    static readonly TimeSpan MinimumTimeForRound = TimeSpan.FromMilliseconds(2500);

    public MetadataEngine(MetadataEngineConfiguration? configuration = null)
    {
        _config = configuration ?? new();
        var http = new HttpClient(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All, PooledConnectionLifetime = TimeSpan.FromMinutes(5) })
        { Timeout = _config.RequestTimeout };
        var cvfHttp = new HttpClient(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All })
        { Timeout = _config.RequestTimeout > TimeSpan.FromSeconds(12) ? _config.RequestTimeout : TimeSpan.FromSeconds(12) };
        var transport = new Transport(http, HostThrottle.Shared, _config.Mailto);
        _crossref = new CrossrefClient(transport, Text.NonEmpty(_config.Mailto));
        _negotiation = new DoiNegotiationClient(transport);
        _arxiv = new ArxivClient(transport);
        _openAlex = new OpenAlexClient(transport, Text.NonEmpty(_config.Mailto), Text.NonEmpty(_config.OpenAlexApiKey));
        _dblp = new DblpClient(transport);
        _openLibrary = new OpenLibraryClient(transport);
        _cvf = new CvfClient(new Transport(cvfHttp, HostThrottle.Shared, _config.Mailto));
        _recognizer = new ZoteroRecognizerClient(new Transport(http, HostThrottle.Shared, null));
    }

    // MARK: Identifiers

    /// <summary>Resolves a DOI, arXiv ID or ISBN (bare, prefixed or as URL).</summary>
    public async Task<ResolveResult> Resolve(string identifier, CancellationToken ct = default)
    {
        if (Identifier.Parse(identifier) is not { } parsed) return ResolveResult.Missing;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(_config.OverallTimeout);
        try
        {
            var m = await Lookup(parsed, cts.Token);
            return m != null ? new ResolveResult.Found(m) : ResolveResult.Missing;
        }
        catch (SourceException e) { return e.IsTransient || e.Kind == SourceErrorKind.Cancelled ? ResolveResult.Offline : ResolveResult.Missing; }
        catch (OperationCanceledException) { return ResolveResult.Offline; }
    }

    internal async Task<Metadata?> Lookup(Identifier identifier, CancellationToken ct)
    {
        switch (identifier)
        {
            case Identifier.Doi d:
                if (IdentifierExtractor.ArxivIdFromDoi(d.Value) is { } arxivId) return await _arxiv.Lookup(arxivId, ct);
                try
                {
                    if (await _crossref.Work(d.Value, ct) is { } record) return record;
                }
                catch (SourceException e) when (e.Kind == SourceErrorKind.Unavailable) { }
                return await _negotiation.Lookup(d.Value, ct);
            case Identifier.Arxiv a:
                return await _arxiv.Lookup(a.Value, ct);
            case Identifier.Isbn i:
                return await _openLibrary.Lookup(i.Value, ct);
            default:
                return null;
        }
    }

    Task<List<Metadata>> TitleSearch(SourceKind source, string title, CancellationToken ct, int limit = 5) => source switch
    {
        SourceKind.Crossref => _crossref.Search(title, ct, limit),
        SourceKind.OpenAlex => _openAlex.Search(title, ct, limit),
        SourceKind.Dblp => _dblp.Search(title, ct, limit),
        SourceKind.Arxiv => _arxiv.Search(title, ct, limit),
        _ => Task.FromResult(new List<Metadata>()),
    };

    // MARK: PDFs

    /// <summary>Identifies the paper in a PDF. See the macOS MetadataEngine+PDF for the ranking rules.</summary>
    public async Task<ResolveResult> ResolvePdf(string path, CancellationToken ct = default)
    {
        if (await Task.Run(() => PdfFacts.Extract(path), ct) is not { } facts) return ResolveResult.Missing;
        var plan = new LookupPlan(IdentifierExtractor.Extract(facts));
        var guesses = TitleGuesser.Guesses(facts);
        if (plan.Identifiers.Count == 0 && guesses.Count == 0) return ResolveResult.Missing;
        var scorer = new CandidateScorer(facts.FirstPageText + "\n" + facts.SecondPageText, guesses);
        var cvf = CvfLookup.Detect(facts, guesses);
        var recognizerPdf = _config.UseZoteroRecognizer && !facts.UsedOcr ? path : null;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(_config.OverallTimeout);
        var started = DateTime.UtcNow;
        try
        {
            return await Identify(plan, guesses, cvf, recognizerPdf, scorer, started, cts.Token);
        }
        catch (OperationCanceledException)
        {
            return ResolveResult.Offline;
        }
    }

    sealed class Tally
    {
        public int Answered, SearchesAnswered;
        public bool IdentifierFailedTransiently;

        public void Record(SourceException e, bool identifier)
        {
            if (e.IsTransient) { if (identifier) IdentifierFailedTransiently = true; }
            else if (e.Kind != SourceErrorKind.Cancelled)
            {
                Answered++;
                if (!identifier) SearchesAnswered++;
            }
        }

        public ResolveResult OutcomeWithoutMatch => IdentifierFailedTransiently || SearchesAnswered < 2 ? ResolveResult.Offline : ResolveResult.Missing;
    }

    sealed class RecognizerState
    {
        public RecognizerResponse? Response;
        public Metadata? Fields;
        public List<(int Rank, Metadata Metadata)> Verified = [];
        public int PendingLookups;
        public Metadata? BestVerified => Verified.Count == 0 ? null : Verified.MinBy(v => v.Rank).Metadata;
        public bool HasResult => Fields != null || Verified.Count > 0;

        public static int Rank(Identifier id, bool pdfHasArxivId) => id switch
        {
            Identifier.Doi => pdfHasArxivId ? 1 : 0,
            Identifier.Arxiv => pdfHasArxivId ? 0 : 1,
            _ => 2,
        };

        public static Identifier Canonical(Identifier id) =>
            id is Identifier.Doi d && IdentifierExtractor.ArxivIdFromDoi(d.Value) is { } a ? new Identifier.Arxiv(a) : id;

        public static List<Identifier> Lookups(RecognizerResponse response, List<Identifier> planned)
        {
            var plannedCanonical = planned.Select(Canonical).ToList();
            var result = new List<Identifier>();
            foreach (var id in response.Identifiers.Select(Canonical))
                if (!result.Contains(id) && !plannedCanonical.Contains(id)) result.Add(id);
            return result;
        }

        public Metadata Enriched(Metadata m)
        {
            if (m.Abstract != null || Response == null || FieldNormalizer.CleanAbstract(Response.Abstract) is not { } abs
                || Response.Title is not { } title || TitleNormalizer.Similarity(title, m.Title) < 0.9) return m;
            var copy = m.Copy();
            copy.Abstract = abs;
            return copy;
        }

        public static bool IsSameWork(Metadata record, Metadata fields)
        {
            if (TitleNormalizer.Similarity(record.Title, fields.Title) < 0.95) return false;
            if (record.Year is { } a && fields.Year is { } b && Math.Abs(a - b) > 1) return false;
            return !(record.Doi is { } x && fields.Doi is { } y && x != y);
        }
    }

    async Task<ResolveResult> Identify(LookupPlan plan, List<string> guesses, CvfLookup? cvf, string? recognizerPdf, CandidateScorer scorer,
                                       DateTime started, CancellationToken ct)
    {
        var tally = new Tally();
        var accepted = new List<(Candidate Candidate, CandidateScorer.Evaluation Evaluation)>();
        var recognizer = new RecognizerState();
        int rounds = Math.Min(guesses.Count, MaxSearchRounds);
        for (int round = 0; round < Math.Max(rounds, 1); round++)
        {
            if (round > 0 && (accepted.Count > 0 || _config.OverallTimeout - (DateTime.UtcNow - started) < MinimumTimeForRound)) break;
            bool first = round == 0;
            var result = await RunRound(first ? plan : null, round < guesses.Count ? guesses[round] : null, first ? cvf : null,
                                        first ? recognizerPdf : null, plan.PdfHasArxivId, scorer, tally, accepted, recognizer, ct);
            if (result is ResolveResult.Found f) return new ResolveResult.Found(recognizer.Enriched(f.Metadata));
            if (result != null) return result;
            if (accepted.Count > 0 || recognizer.HasResult) break;
        }
        if (recognizer.BestVerified is { } verified) return new ResolveResult.Found(recognizer.Enriched(verified));
        var best = CandidateRanking.Best(accepted, plan.PdfHasArxivId);
        if (recognizer.Fields is { } fields)
        {
            if (best is { } b && RecognizerState.IsSameWork(b.Candidate.Metadata, fields))
                return new ResolveResult.Found(recognizer.Enriched(await Enriched(b.Candidate, ct)));
            return new ResolveResult.Found(fields);
        }
        if (best is not { } chosen) return cvf?.Fallback is { } fallback ? new ResolveResult.Found(fallback) : tally.OutcomeWithoutMatch;
        return new ResolveResult.Found(recognizer.Enriched(await Enriched(chosen.Candidate, ct)));
    }

    abstract record Event
    {
        public sealed record IdentifierDone(FoundIdentifier Found, Metadata? Metadata, SourceException? Error) : Event;
        public sealed record Search(SourceKind Source, List<Metadata>? Records, SourceException? Error) : Event;
        public sealed record Cvf(Metadata? Metadata, SourceException? Error) : Event;
        public sealed record Recognizer(RecognizerResponse? Response) : Event;
        public sealed record RecognizerLookup(Identifier Identifier, Metadata? Metadata) : Event;
        public sealed record GraceElapsed : Event;
    }

    async Task<ResolveResult?> RunRound(LookupPlan? plan, string? guess, CvfLookup? cvf, string? recognizerPdf, bool pdfHasArxivId,
                                        CandidateScorer scorer, Tally tally, List<(Candidate, CandidateScorer.Evaluation)> accepted,
                                        RecognizerState recognizer, CancellationToken outer)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(outer);
        var ct = cts.Token;
        var tasks = new List<Task<Event>>();
        int pendingAuthoritative = 0;

        foreach (var found in plan?.Identifiers ?? [])
        {
            if (found.IsSelfDescribing) pendingAuthoritative++;
            tasks.Add(Run(async () =>
            {
                try { return new Event.IdentifierDone(found, await Lookup(found.Identifier, ct), null); }
                catch (SourceException e) { return new Event.IdentifierDone(found, null, e); }
            }));
        }
        if (cvf != null)
        {
            pendingAuthoritative++;
            tasks.Add(Run(async () =>
            {
                try { return new Event.Cvf(await _cvf.Paper(cvf, ct), null); }
                catch (SourceException e) { return new Event.Cvf(null, e); }
            }));
        }
        if (recognizerPdf != null)
        {
            tasks.Add(Run(async () =>
            {
                using var budget = CancellationTokenSource.CreateLinkedTokenSource(ct);
                budget.CancelAfter(RecognizerTimeout);
                try
                {
                    var payload = await Task.Run(() => RecognizerPayload.Extract(recognizerPdf), budget.Token);
                    return new Event.Recognizer(payload == null ? null : await _recognizer.Recognize(payload, budget.Token));
                }
                catch (Exception) { return new Event.Recognizer(null); }
            }));
        }
        if (guess != null)
        {
            var sources = pdfHasArxivId ? new[] { SourceKind.Crossref, SourceKind.OpenAlex, SourceKind.Dblp }
                                        : new[] { SourceKind.Crossref, SourceKind.OpenAlex, SourceKind.Dblp, SourceKind.Arxiv };
            foreach (var source in sources)
                tasks.Add(Run(async () =>
                {
                    try { return new Event.Search(source, await TitleSearch(source, guess, ct), null); }
                    catch (SourceException e) { return new Event.Search(source, null, e); }
                }));
        }

        bool graceStarted = false;
        try
        {
            while (tasks.Count > 0)
            {
                var done = await Task.WhenAny(tasks);
                tasks.Remove(done);
                outer.ThrowIfCancellationRequested();
                var ev = await done;
                switch (ev)
                {
                    case Event.GraceElapsed:
                        if (recognizer.PendingLookups > 0) { graceStarted = false; break; }
                        return null;
                    case Event.IdentifierDone e:
                        if (e.Found.IsSelfDescribing) pendingAuthoritative--;
                        if (e.Error != null) tally.Record(e.Error, true);
                        else
                        {
                            tally.Answered++;
                            if (e.Metadata != null && scorer.VerifiesIdentifierResult(e.Metadata, e.Found.IsSelfDescribing)) return new ResolveResult.Found(e.Metadata);
                        }
                        break;
                    case Event.Cvf e:
                        pendingAuthoritative--;
                        if (e.Error != null) tally.Record(e.Error, true);
                        else
                        {
                            tally.Answered++;
                            if (e.Metadata != null && scorer.VerifiesIdentifierResult(e.Metadata, true)) return new ResolveResult.Found(e.Metadata);
                        }
                        break;
                    case Event.Recognizer { Response: { } response }:
                        recognizer.Response = response;
                        if (response.Metadata is { } fields && scorer.AcceptsRecognizedFields(fields)) recognizer.Fields = fields;
                        foreach (var id in RecognizerState.Lookups(response, plan?.Identifiers.Select(i => i.Identifier).ToList() ?? []))
                        {
                            recognizer.PendingLookups++;
                            tasks.Add(Run(async () =>
                            {
                                using var budget = CancellationTokenSource.CreateLinkedTokenSource(ct);
                                budget.CancelAfter(RecognizerLookupTimeout);
                                try { return new Event.RecognizerLookup(id, await Lookup(id, budget.Token)); }
                                catch (Exception) { return new Event.RecognizerLookup(id, null); }
                            }));
                        }
                        break;
                    case Event.RecognizerLookup e:
                        recognizer.PendingLookups--;
                        if (e.Metadata != null && scorer.VerifiesIdentifierResult(e.Metadata, false))
                            recognizer.Verified.Add((RecognizerState.Rank(e.Identifier, pdfHasArxivId), e.Metadata));
                        break;
                    case Event.Search e:
                        if (e.Error != null) tally.Record(e.Error, false);
                        else
                        {
                            tally.Answered++;
                            tally.SearchesAnswered++;
                            foreach (var m in e.Records!)
                            {
                                var evaluation = scorer.Evaluate(m);
                                if (evaluation.IsAccepted) accepted.Add((new Candidate(m, e.Source), evaluation));
                            }
                        }
                        break;
                }
                int higherPending = pendingAuthoritative + recognizer.PendingLookups;
                if (higherPending == 0 && recognizer.BestVerified is { } best) return new ResolveResult.Found(best);
                bool pending = tasks.Any(t => !t.IsCompleted);
                if ((accepted.Count > 0 || recognizer.Fields != null) && !graceStarted && pending && higherPending == 0)
                {
                    graceStarted = true;
                    tasks.Add(Run(async () =>
                    {
                        try { await Task.Delay(SearchGrace, ct); } catch (OperationCanceledException) { }
                        return (Event)new Event.GraceElapsed();
                    }));
                }
            }
            return null;
        }
        finally
        {
            cts.Cancel();
        }
    }

    static Task<Event> Run(Func<Task<Event>> work) => Task.Run(work);

    /// <summary>DBLP and OpenAlex records carrying a DOI are completed from Crossref, keeping fields Crossref lacks.</summary>
    async Task<Metadata> Enriched(Candidate candidate, CancellationToken ct)
    {
        var m = candidate.Metadata;
        if (candidate.Source is not (SourceKind.Dblp or SourceKind.OpenAlex) || m.Doi is not { } doi || IdentifierExtractor.ArxivIdFromDoi(doi) != null) return m;
        try
        {
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(ct);
            budget.CancelAfter(TimeSpan.FromSeconds(3));
            var full = await _crossref.Work(doi, budget.Token);
            if (full == null || TitleNormalizer.Similarity(full.Title, m.Title) < 0.9) return m;
            full.Abstract ??= m.Abstract;
            if (full.Authors.Count == 0) full.Authors = m.Authors;
            return full;
        }
        catch (Exception) { return m; }
    }

    // MARK: Manual matching

    /// <summary>Identifier or free-text search across sources, deduplicated and ranked by title similarity. At most 10.</summary>
    public async Task<List<Metadata>> Search(string query, CancellationToken ct = default)
    {
        var text = query.Trim();
        if (text.Length == 0) return [];
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(_config.OverallTimeout);
        if (Identifier.Parse(text) is { } identifier)
        {
            try { return await Lookup(identifier, cts.Token) is { } m ? [m] : []; }
            catch (Exception) { return []; }
        }
        var batches = await Task.WhenAll(new[] { SourceKind.Crossref, SourceKind.OpenAlex, SourceKind.Dblp, SourceKind.Arxiv }.Select(async s =>
        {
            try { return await TitleSearch(s, text, cts.Token, 6); }
            catch (Exception) { return new List<Metadata>(); }
        }));
        var unique = new List<Metadata>();
        foreach (var record in batches.SelectMany(b => b))
            if (!unique.Any(u => DuplicateMatcher.IsSameWork(u, record))) unique.Add(record);
        return unique.OrderByDescending(m => TitleNormalizer.Similarity(m.Title, text)).Take(10).ToList();
    }
}

/// <summary>Zotero's recognizer answer.</summary>
sealed class RecognizerResponse
{
    public string? Type, Title, Abstract, Year, Container, Volume, Issue, Pages, Publisher, Url, Issn, Isbn, Doi, Arxiv, Language;
    public List<(string? First, string? Last)> Authors = [];

    public static RecognizerResponse? Parse(byte[] data)
    {
        if (data.All(b => b is 0x20 or 0x0A or 0x0D or 0x09)) return null;
        JsonElement root;
        try { root = JsonDocument.Parse(data).RootElement; }
        catch (JsonException) { throw new SourceException(SourceErrorKind.Malformed); }
        if (root.ValueKind != JsonValueKind.Object) return null;
        string? S(string key) => Text.NonEmpty(root.Get(key).Str());
        var r = new RecognizerResponse
        {
            Type = S("type"), Title = S("title"), Abstract = S("abstract"), Year = S("year"), Container = S("container"), Volume = S("volume"),
            Issue = S("issue"), Pages = S("pages"), Publisher = S("publisher"), Url = S("url"), Issn = S("ISSN"), Isbn = S("ISBN"),
            Doi = S("doi"), Arxiv = S("arxiv"), Language = S("language"),
            Authors = root.Get("authors").Array().Select(a => (a.Get("firstName").Str(), a.Get("lastName").Str())).ToList(),
        };
        return r.Title == null && r.Identifiers.Count == 0 ? null : r;
    }

    public List<Identifier> Identifiers
    {
        get
        {
            var result = new List<Identifier>();
            if (Arxiv != null && Identifier.Parse("arXiv:" + Regex.Replace(Arxiv, @"(?i)^arxiv:\s*", "")) is Identifier.Arxiv a) result.Add(a);
            if ((FieldNormalizer.NormalizeDoi(Doi) ?? (Doi == null ? null : IdentifierExtractor.Dois(Doi).FirstOrDefault())) is { } d) result.Add(new Identifier.Doi(d));
            if (Isbn != null)
            {
                var digits = new string(Isbn.ToUpperInvariant().Where(c => char.IsDigit(c) || c == 'X').ToArray());
                if (digits.Length is 10 or 13) result.Add(new Identifier.Isbn(digits));
            }
            return result;
        }
    }

    public Metadata? Metadata
    {
        get
        {
            if (FieldNormalizer.CleanTitle(Title) is not { } title) return null;
            var m = new Metadata(title)
            {
                Type = Type == "book-chapter" ? ItemType.BookChapter : ItemType.JournalArticle,
                Authors = Authors.Select(a => NameParser.From(a.Last, a.First, null)).OfType<Author>().ToList(),
                Source = FieldNormalizer.CleanText(Container), Volume = FieldNormalizer.CleanText(Volume), Issue = FieldNormalizer.CleanText(Issue),
                Pages = FieldNormalizer.NormalizePages(Pages), Publisher = FieldNormalizer.CleanText(Publisher), Url = Text.NonEmpty(Url),
                Abstract = FieldNormalizer.CleanAbstract(Abstract),
            };
            if (FieldNormalizer.DateFromString(Year) is { } d) { m.Year = d.Year; m.Date = d.Date; }
            foreach (var id in Identifiers)
            {
                switch (id)
                {
                    case Identifier.Doi doi: m.Doi = doi.Value; break;
                    case Identifier.Arxiv ax: m.ArxivId = ax.Value; break;
                    case Identifier.Isbn isbn: m.Isbn = isbn.Value; break;
                }
            }
            if (m.Url == null && m.Doi != null) m.Url = $"https://doi.org/{m.Doi}";
            return m;
        }
    }
}

sealed class ZoteroRecognizerClient(Transport transport)
{
    public async Task<RecognizerResponse?> Recognize(RecognizerPayload payload, CancellationToken ct)
    {
        var data = await transport.PostJson("https://services.zotero.org/recognizer/recognize", payload.Json(), ct);
        return data == null ? null : RecognizerResponse.Parse(data);
    }
}

/// <summary>The words of a PDF's first pages with positions and fonts, as Zotero's pdf-worker sends them.</summary>
sealed class RecognizerPayload
{
    const int MaxPages = 5;

    public sealed record Word(double XMin, double YMin, double XMax, double YMax, double FontSize, bool SpaceAfter, double Baseline,
                              bool Bold, bool Italic, int FontIndex, string Text);
    public sealed record Page(double Width, double Height, List<List<Word>> Lines, List<string> Fonts);

    public Dictionary<string, string> Metadata = [];
    public int TotalPages;
    public string FileName = "";
    public List<Page> Pages = [];

    public static RecognizerPayload? Extract(string path)
    {
        try
        {
            using var document = PdfDocument.Open(path);
            var payload = new RecognizerPayload { TotalPages = document.NumberOfPages, FileName = Path.GetFileName(path) };
            var info = document.Information;
            foreach (var (key, value) in new[] { ("Title", info.Title), ("Author", info.Author), ("Subject", info.Subject), ("Keywords", info.Keywords),
                                                 ("Creator", info.Creator), ("Producer", info.Producer) })
                if (value != null) payload.Metadata[key] = value;
            for (int i = 1; i <= Math.Min(MaxPages, document.NumberOfPages); i++) payload.Pages.Add(PageOf(document.GetPage(i)));
            return payload.Pages.Sum(p => p.Lines.Sum(l => l.Count)) > 0 ? payload : null;
        }
        catch { return null; }
    }

    static Page PageOf(UglyToad.PdfPig.Content.Page page)
    {
        var crop = page.CropBox.Bounds;
        var result = new Page(Round4(crop.Width), Round4(crop.Height), [], []);
        foreach (var line in PdfLines.GroupLines(page.Letters))
        {
            var words = new List<Word>();
            var current = new List<UglyToad.PdfPig.Content.Letter>();
            void Flush(bool spaceAfter)
            {
                if (current.Count == 0) return;
                var letters = current;
                current = [];
                var name = PdfLines.BaseFontName(letters[0].FontName ?? "");
                int fontIndex = result.Fonts.IndexOf(name);
                if (fontIndex < 0) { fontIndex = result.Fonts.Count; result.Fonts.Add(name); }
                double xMin = letters.Min(l => l.BoundingBox.Left), xMax = letters.Max(l => l.BoundingBox.Right);
                double yMin = letters.Min(l => l.BoundingBox.Bottom), yMax = letters.Max(l => l.BoundingBox.Top);
                var lowered = name.ToLowerInvariant();
                words.Add(new Word(Round4(xMin - crop.Left), Round4(crop.Height - (yMax - crop.Bottom)), Round4(xMax - crop.Left),
                                   Round4(crop.Height - (yMin - crop.Bottom)), Round4(letters[0].PointSize), spaceAfter,
                                   Round4(crop.Height - (letters[0].StartBaseLine.Y - crop.Bottom)),
                                   new[] { "bold", "black", "heavy" }.Any(lowered.Contains), new[] { "italic", "oblique" }.Any(lowered.Contains),
                                   fontIndex, string.Concat(letters.Select(l => l.Value))));
            }
            UglyToad.PdfPig.Content.Letter? previous = null;
            foreach (var letter in line)
            {
                if (string.IsNullOrWhiteSpace(letter.Value)) { Flush(true); previous = null; continue; }
                if (previous != null)
                {
                    double gap = letter.StartBaseLine.X - previous.EndBaseLine.X;
                    if (gap > Math.Max(previous.PointSize, 1) * 0.2) Flush(true);
                    else if (letter.FontName != previous.FontName || Math.Abs(letter.PointSize - previous.PointSize) > 0.01) Flush(false);
                }
                current.Add(letter);
                previous = letter;
            }
            Flush(false);
            if (words.Count > 0) result.Lines.Add(words);
        }
        return result;
    }

    static double Round4(double v) => Math.Round(v * 10_000) / 10_000;

    public byte[] Json()
    {
        var pages = new JsonArray();
        foreach (var page in Pages)
        {
            var lines = new JsonArray();
            foreach (var words in page.Lines)
            {
                var encoded = new JsonArray();
                foreach (var w in words)
                    encoded.Add(new JsonArray(w.XMin, w.YMin, w.XMax, w.YMax, w.FontSize, w.SpaceAfter ? 1 : 0, w.Baseline, 0, 0,
                                              w.Bold ? 1 : 0, w.Italic ? 1 : 0, 0, w.FontIndex, w.Text));
                lines.Add(new JsonArray(encoded));
            }
            pages.Add(new JsonArray(page.Width, page.Height, new JsonArray(new JsonArray(new JsonArray(new JsonArray(0, 0, 0, 0, lines))))));
        }
        var obj = new JsonObject
        {
            ["metadata"] = new JsonObject(Metadata.Select(kv => new KeyValuePair<string, JsonNode?>(kv.Key, kv.Value))),
            ["totalPages"] = TotalPages,
            ["fileName"] = FileName,
            ["pages"] = pages,
        };
        return JsonSerializer.SerializeToUtf8Bytes(obj);
    }
}
