using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace Folio.Core.Retrieval;

public enum SourceErrorKind { Network, Unavailable, Rejected, Malformed, Cancelled }

/// <summary>Why a source could not answer. Transient errors (network, overload) are worth retrying later.</summary>
public sealed class SourceException(SourceErrorKind kind, int status = 0) : Exception($"{kind} {status}")
{
    public SourceErrorKind Kind { get; } = kind;
    public int Status { get; } = status;
    public bool IsTransient => Kind is SourceErrorKind.Network or SourceErrorKind.Unavailable;
}

enum SourceKind { Crossref, OpenAlex, Dblp, Arxiv, DoiNegotiation, OpenLibrary }

/// <summary>Spaces requests to hosts that ask for it (arXiv: one per second).</summary>
sealed class HostThrottle
{
    public static readonly HostThrottle Shared = new(new() { ["export.arxiv.org"] = TimeSpan.FromSeconds(1) });
    readonly Dictionary<string, TimeSpan> _intervals;
    readonly Dictionary<string, DateTime> _nextFree = [];
    readonly object _lock = new();

    public HostThrottle(Dictionary<string, TimeSpan> intervals) { _intervals = intervals; }

    public TimeSpan Reserve(string host)
    {
        host = host.ToLowerInvariant();
        if (!_intervals.TryGetValue(host, out var interval) || interval <= TimeSpan.Zero) return TimeSpan.Zero;
        lock (_lock)
        {
            var now = DateTime.UtcNow;
            var slot = _nextFree.TryGetValue(host, out var free) && free > now ? free : now;
            _nextFree[host] = slot + interval;
            return slot - now;
        }
    }
}

/// <summary>HTTP plumbing shared by the sources: User-Agent with the contact address, status mapping, throttling.</summary>
sealed class Transport
{
    readonly HttpClient _http;
    readonly HostThrottle _throttle;
    readonly string _userAgent;

    public Transport(HttpClient http, HostThrottle throttle, string? mailto)
    {
        _http = http;
        _throttle = throttle;
        _userAgent = Text.NonEmpty(mailto) is { } m ? $"Folio/1.0 (mailto:{m})" : "Folio/1.0";
    }

    public async Task<byte[]?> Get(string url, CancellationToken ct, string accept = "application/json")
    {
        ct.ThrowIfCancellationRequested();
        var wait = _throttle.Reserve(new Uri(url).Host);
        if (wait > TimeSpan.Zero)
        {
            try { await Task.Delay(wait, ct); } catch (OperationCanceledException) { throw new SourceException(SourceErrorKind.Cancelled); }
        }
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("User-Agent", _userAgent);
        request.Headers.TryAddWithoutValidation("Accept", accept);
        return await Perform(request, ct);
    }

    public async Task<byte[]?> PostJson(string url, byte[] body, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = new ByteArrayContent(body) };
        request.Content.Headers.ContentType = new("application/json");
        request.Headers.TryAddWithoutValidation("User-Agent", _userAgent);
        request.Headers.TryAddWithoutValidation("Accept", "application/json");
        return await Perform(request, ct);
    }

    async Task<byte[]?> Perform(HttpRequestMessage request, CancellationToken ct)
    {
        HttpResponseMessage response;
        try { response = await _http.SendAsync(request, ct); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw new SourceException(SourceErrorKind.Cancelled); }
        catch (Exception) { throw new SourceException(SourceErrorKind.Network); }
        using (response)
        {
            int status = (int)response.StatusCode;
            if (status is >= 200 and < 300)
            {
                try { return await response.Content.ReadAsByteArrayAsync(ct); }
                catch (OperationCanceledException) { throw new SourceException(SourceErrorKind.Cancelled); }
                catch { throw new SourceException(SourceErrorKind.Network); }
            }
            if (status is 404 or 410) return null;
            if (status == 429 || status >= 500) throw new SourceException(SourceErrorKind.Unavailable, status);
            throw new SourceException(SourceErrorKind.Rejected, status);
        }
    }

    public async Task<JsonElement?> GetJson(string url, CancellationToken ct, string accept = "application/json")
    {
        var data = await Get(url, ct, accept);
        if (data == null) return null;
        try { return JsonDocument.Parse(data).RootElement.Clone(); }
        catch (JsonException) { throw new SourceException(SourceErrorKind.Malformed); }
    }

    public static string Url(string @base, params (string Name, string? Value)[] query)
    {
        var parts = query.Where(q => q.Value != null).Select(q => $"{Uri.EscapeDataString(q.Name)}={Uri.EscapeDataString(q.Value!)}");
        var qs = string.Join('&', parts);
        return qs.Length == 0 ? @base : $"{@base}?{qs}";
    }
}

/// <summary>Lenient JSON access: strings, numbers and one-element arrays all read as strings.</summary>
static class J
{
    public static JsonElement? Get(this JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null ? v : null;

    public static string? Str(this JsonElement? e) => e switch
    {
        null => null,
        { ValueKind: JsonValueKind.String } s => s.GetString(),
        { ValueKind: JsonValueKind.Number } n => n.GetRawText(),
        { ValueKind: JsonValueKind.Array } a => a.EnumerateArray().Select(x => ((JsonElement?)x).Str()).FirstOrDefault(x => x != null),
        { ValueKind: JsonValueKind.True } => "true",
        _ => null,
    };

    public static string? Str(this JsonElement e, string name) => e.Get(name).Str();

    public static IEnumerable<JsonElement> Array(this JsonElement? e) => e switch
    {
        { ValueKind: JsonValueKind.Array } a => a.EnumerateArray(),
        { ValueKind: JsonValueKind.Object } o => [o],
        _ => [],
    };

    /// <summary>Crossref/CSL date-parts: {"date-parts": [[2024, 5, 1]]}.</summary>
    public static List<int> DateParts(this JsonElement? e)
    {
        var first = e?.Get("date-parts").Array().FirstOrDefault();
        if (first is not { ValueKind: JsonValueKind.Array } row) return [];
        var parts = new List<int>();
        foreach (var p in row.EnumerateArray())
            if (int.TryParse(((JsonElement?)p).Str(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n)) parts.Add(n);
        return parts;
    }
}

sealed class CrossrefClient(Transport transport, string? mailto)
{
    const string SelectFields = "DOI,title,subtitle,author,published-print,published-online,issued,created,container-title,volume,issue,page,publisher,type,ISBN,URL,abstract";
    static readonly HashSet<string> IgnoredSearchTypes =
        ["peer-review", "component", "grant", "journal", "journal-issue", "journal-volume", "proceedings", "proceedings-series", "book-series", "book-set", "report-series"];

    public async Task<Metadata?> Work(string doi, CancellationToken ct)
    {
        var path = string.Join('/', doi.Split('/').Select(Uri.EscapeDataString));
        var json = await transport.GetJson(Transport.Url($"https://api.crossref.org/works/{path}", ("mailto", mailto)), ct);
        return json?.Get("message") is { } message ? MetadataFrom(message) : null;
    }

    public async Task<List<Metadata>> Search(string title, CancellationToken ct, int rows = 5)
    {
        var json = await transport.GetJson(Transport.Url("https://api.crossref.org/works",
            ("query.bibliographic", title), ("rows", rows.ToString(CultureInfo.InvariantCulture)), ("select", SelectFields), ("mailto", mailto)), ct);
        if (json?.Get("message")?.Get("items") is not { } items) return [];
        return items.EnumerateArray().Where(i => !IgnoredSearchTypes.Contains(i.Str("type") ?? "")).Select(MetadataFrom).OfType<Metadata>().ToList();
    }

    public static Metadata? MetadataFrom(JsonElement item)
    {
        var title = FieldNormalizer.CleanTitle(item.Get("title").Str());
        if (title == null) return null;
        if (FieldNormalizer.CleanTitle(item.Get("subtitle").Str()) is { } subtitle && !TitleNormalizer.Normalize(title).Contains(TitleNormalizer.Normalize(subtitle)))
            title += ": " + subtitle;
        var m = new Metadata(title) { Type = ItemTypeFor(item.Str("type")) };
        m.Authors = item.Get("author").Array().Select(p => NameParser.From(p.Str("family"), p.Str("given"), p.Str("name"))).OfType<Author>().ToList();
        foreach (var key in new[] { "published-print", "published-online", "issued", "created" })
        {
            if (FieldNormalizer.DateFromParts(item.Get(key).DateParts()) is { } d) { m.Year = d.Year; m.Date = d.Date; break; }
        }
        m.Publisher = FieldNormalizer.CleanText(item.Str("publisher"));
        m.Source = FieldNormalizer.CleanText(item.Get("container-title").Str());
        if (m.Source == null && m.Type is ItemType.Book or ItemType.Thesis or ItemType.Report) m.Source = m.Publisher;
        m.Volume = FieldNormalizer.CleanText(item.Str("volume"));
        m.Issue = FieldNormalizer.CleanText(item.Str("issue"));
        m.Pages = FieldNormalizer.NormalizePages(item.Str("page"));
        m.Doi = FieldNormalizer.NormalizeDoi(item.Str("DOI"));
        m.Isbn = Text.NonEmpty(new string((item.Get("ISBN").Str() ?? "").ToUpperInvariant().Where(c => char.IsDigit(c) || c == 'X').ToArray()));
        m.Url = Text.NonEmpty(item.Str("URL")) ?? (m.Doi != null ? $"https://doi.org/{m.Doi}" : null);
        m.Abstract = FieldNormalizer.CleanAbstract(item.Str("abstract"));
        return m;
    }

    public static ItemType ItemTypeFor(string? type) => type switch
    {
        "journal-article" => ItemType.JournalArticle,
        "proceedings-article" => ItemType.ConferencePaper,
        "posted-content" => ItemType.Preprint,
        "book" or "monograph" or "edited-book" or "reference-book" => ItemType.Book,
        "book-chapter" or "book-section" or "book-part" or "reference-entry" => ItemType.BookChapter,
        "dissertation" => ItemType.Thesis,
        "report" or "report-component" => ItemType.Report,
        "dataset" or "database" => ItemType.Dataset,
        _ => ItemType.Other,
    };
}

sealed class DoiNegotiationClient(Transport transport)
{
    public async Task<Metadata?> Lookup(string doi, CancellationToken ct)
    {
        var path = string.Join('/', doi.Split('/').Select(Uri.EscapeDataString));
        var json = await transport.GetJson($"https://doi.org/{path}", ct, "application/vnd.citationstyles.csl+json");
        return json is { } item ? MetadataFrom(item) : null;
    }

    public static Metadata? MetadataFrom(JsonElement item)
    {
        var title = FieldNormalizer.CleanTitle(item.Get("title").Str());
        if (title == null) return null;
        var m = new Metadata(title) { Type = ItemTypeFor(item.Str("type")) };
        m.Authors = item.Get("author").Array().Select(p => NameParser.From(p.Str("family"), p.Str("given"), p.Str("literal"))).OfType<Author>().ToList();
        foreach (var key in new[] { "published-print", "published-online", "issued", "created" })
            if (FieldNormalizer.DateFromParts(item.Get(key).DateParts()) is { } d) { m.Year = d.Year; m.Date = d.Date; break; }
        m.Publisher = FieldNormalizer.CleanText(item.Str("publisher"));
        m.Source = FieldNormalizer.CleanText(item.Get("container-title").Str());
        m.Doi = FieldNormalizer.NormalizeDoi(item.Str("DOI"));
        if (m.Doi != null && IdentifierExtractor.ArxivIdFromDoi(m.Doi) is { } arxiv)
        {
            m.Type = ItemType.Preprint; m.ArxivId = arxiv; m.Source = "arXiv";
        }
        if (m.Source == null && m.Type is ItemType.Book or ItemType.Thesis or ItemType.Report or ItemType.Dataset) m.Source = m.Publisher;
        m.Volume = FieldNormalizer.CleanText(item.Str("volume"));
        m.Issue = FieldNormalizer.CleanText(item.Str("issue"));
        m.Pages = FieldNormalizer.NormalizePages(item.Str("page"));
        m.Isbn = Text.NonEmpty(new string((item.Get("ISBN").Str() ?? "").ToUpperInvariant().Where(c => char.IsDigit(c) || c == 'X').ToArray()));
        m.Url = Text.NonEmpty(item.Str("URL")) ?? (m.Doi != null ? $"https://doi.org/{m.Doi}" : null);
        m.Abstract = FieldNormalizer.CleanAbstract(item.Str("abstract"));
        return m;
    }

    static ItemType ItemTypeFor(string? type) => type switch
    {
        "article-journal" or "journal-article" => ItemType.JournalArticle,
        "paper-conference" or "proceedings-article" => ItemType.ConferencePaper,
        "article" or "posted-content" => ItemType.Preprint,
        "book" or "monograph" => ItemType.Book,
        "chapter" or "book-chapter" => ItemType.BookChapter,
        "thesis" or "dissertation" => ItemType.Thesis,
        "report" => ItemType.Report,
        "dataset" => ItemType.Dataset,
        "webpage" or "post-weblog" => ItemType.Webpage,
        _ => ItemType.Other,
    };
}

sealed class ArxivClient(Transport transport)
{
    const string Accept = "application/atom+xml";

    public async Task<Metadata?> Lookup(string id, CancellationToken ct)
    {
        var data = await transport.Get(Transport.Url("https://export.arxiv.org/api/query", ("id_list", id), ("max_results", "1")), ct, Accept);
        return data == null ? null : Decode(data).FirstOrDefault();
    }

    public async Task<List<Metadata>> Search(string title, CancellationToken ct, int maxResults = 5)
    {
        if (SearchQuery(title) is not { } query) return [];
        var data = await transport.Get(Transport.Url("https://export.arxiv.org/api/query", ("search_query", query),
                                                     ("max_results", maxResults.ToString(CultureInfo.InvariantCulture))), ct, Accept);
        return data == null ? [] : Decode(data);
    }

    static List<Metadata> Decode(byte[] data)
    {
        try { return Parse(data); }
        catch (Exception) { throw new SourceException(SourceErrorKind.Malformed); }
    }

    public static List<Metadata> Parse(byte[] data)
    {
        var doc = XDocument.Parse(Encoding.UTF8.GetString(data));
        XNamespace atom = "http://www.w3.org/2005/Atom";
        var result = new List<Metadata>();
        foreach (var entry in doc.Root!.Elements(atom + "entry"))
        {
            var entryId = entry.Element(atom + "id")?.Value.Trim() ?? "";
            if (entryId.Contains("/api/errors") || ArxivIdFromEntry(entryId) is not { } id) continue;
            var title = FieldNormalizer.CleanTitle(entry.Element(atom + "title")?.Value);
            if (title == null || title == "Error") continue;
            var m = new Metadata(title)
            {
                Type = ItemType.Preprint,
                Authors = entry.Elements(atom + "author").Select(a => a.Element(atom + "name")?.Value.Trim() ?? "")
                    .Select(NameParser.FromDisplayName).OfType<Author>().ToList(),
                Source = "arXiv", Publisher = "arXiv", Doi = $"10.48550/arxiv.{id.ToLowerInvariant()}", ArxivId = id,
                Url = $"https://arxiv.org/abs/{id}",
                Abstract = FieldNormalizer.CleanAbstract(entry.Element(atom + "summary")?.Value.Trim()),
            };
            if (FieldNormalizer.DateFromString(entry.Element(atom + "published")?.Value.Trim()) is { } d) { m.Year = d.Year; m.Date = d.Date; }
            result.Add(m);
        }
        return result;
    }

    static string? ArxivIdFromEntry(string raw)
    {
        int i = raw.IndexOf("/abs/", StringComparison.Ordinal);
        if (i < 0) return null;
        var id = Regex.Replace(raw[(i + 5)..], @"v\d+$", "");
        return id.Length == 0 ? null : id;
    }

    static readonly HashSet<string> Stopwords =
    [
        "a", "an", "the", "of", "for", "and", "or", "in", "on", "with", "to", "via", "by", "from", "at", "is",
        "are", "as", "its", "into", "towards", "toward", "we", "our", "not", "but", "be", "this", "that",
    ];

    static string? SearchQuery(string title)
    {
        var seen = new HashSet<string>();
        var words = TextMatcher.Tokens(title).Where(w => w.Length >= 3 && w.All(char.IsLetter) && !Stopwords.Contains(w) && seen.Add(w)).ToList();
        return words.Count < 2 ? null : string.Join(" AND ", words.Take(8).Select(w => $"ti:{w}"));
    }
}

sealed class OpenAlexClient(Transport transport, string? mailto, string? apiKey)
{
    const string SelectFields = "id,doi,title,display_name,publication_year,publication_date,type,type_crossref,authorships,primary_location,biblio,abstract_inverted_index";

    public async Task<List<Metadata>> Search(string title, CancellationToken ct, int perPage = 5)
    {
        var query = TitleNormalizer.Normalize(title);
        if (query.Length == 0) return [];
        var json = await transport.GetJson(Transport.Url("https://api.openalex.org/works", ("filter", $"title.search:{query}"),
            ("per-page", perPage.ToString(CultureInfo.InvariantCulture)), ("select", SelectFields), ("mailto", mailto), ("api_key", apiKey)), ct);
        return json?.Get("results").Array().Select(MetadataFrom).OfType<Metadata>().ToList() ?? [];
    }

    public static Metadata? MetadataFrom(JsonElement work)
    {
        var title = FieldNormalizer.CleanTitle(work.Str("title") ?? work.Str("display_name"));
        if (title == null) return null;
        var source = work.Get("primary_location")?.Get("source");
        var m = new Metadata(title) { Type = ItemTypeFor(work.Str("type"), work.Str("type_crossref"), source?.Str("type")) };
        m.Authors = work.Get("authorships").Array().Select(a => a.Get("author")?.Str("display_name")).Where(n => n != null)
            .Select(n => NameParser.FromDisplayName(n!)).OfType<Author>().ToList();
        if (FieldNormalizer.DateFromString(work.Str("publication_date")) is { } d) { m.Year = d.Year; m.Date = d.Date; }
        else if (int.TryParse(work.Str("publication_year"), out var year)) { m.Year = year; m.Date = year.ToString(CultureInfo.InvariantCulture); }
        m.Source = FieldNormalizer.CleanText(source?.Str("display_name"));
        m.Publisher = FieldNormalizer.CleanText(source?.Str("host_organization_name"));
        var biblio = work.Get("biblio");
        m.Volume = FieldNormalizer.CleanText(biblio?.Str("volume"));
        m.Issue = FieldNormalizer.CleanText(biblio?.Str("issue"));
        if (FieldNormalizer.CleanText(biblio?.Str("first_page")) is { } first)
        {
            var last = FieldNormalizer.CleanText(biblio?.Str("last_page"));
            m.Pages = last == null ? first : last == first ? first : $"{first}-{last}";
        }
        m.Doi = FieldNormalizer.NormalizeDoi(work.Str("doi"));
        if (m.Doi != null && IdentifierExtractor.ArxivIdFromDoi(m.Doi) is { } arxiv)
        {
            m.ArxivId = arxiv; m.Type = ItemType.Preprint; m.Source = "arXiv"; m.Publisher = "arXiv";
        }
        m.Url = m.Doi != null ? $"https://doi.org/{m.Doi}" : Text.NonEmpty(work.Get("primary_location")?.Str("landing_page_url"));
        if (work.Get("abstract_inverted_index") is { ValueKind: JsonValueKind.Object } index) m.Abstract = RebuildAbstract(index);
        return m;
    }

    static ItemType ItemTypeFor(string? type, string? crossrefType, string? sourceType)
    {
        var mapped = CrossrefClient.ItemTypeFor(crossrefType);
        if (mapped != ItemType.Other) return mapped;
        return type switch
        {
            "article" or "review" or "letter" or "editorial" or "erratum" => sourceType == "conference" ? ItemType.ConferencePaper : ItemType.JournalArticle,
            "preprint" => ItemType.Preprint,
            "book" => ItemType.Book,
            "book-chapter" => ItemType.BookChapter,
            "dissertation" => ItemType.Thesis,
            "report" => ItemType.Report,
            "dataset" => ItemType.Dataset,
            _ => ItemType.Other,
        };
    }

    static string? RebuildAbstract(JsonElement index)
    {
        var positioned = new List<(int, string)>();
        foreach (var word in index.EnumerateObject())
            foreach (var p in word.Value.EnumerateArray())
                if (p.TryGetInt32(out var pos)) positioned.Add((pos, word.Name));
        if (positioned.Count == 0 || positioned.Count >= 20_000) return null;
        return FieldNormalizer.CleanAbstract(string.Join(' ', positioned.OrderBy(p => p.Item1).Select(p => p.Item2)));
    }
}

sealed class DblpClient(Transport transport)
{
    public async Task<List<Metadata>> Search(string title, CancellationToken ct, int hits = 5)
    {
        var query = TitleNormalizer.Normalize(title);
        if (query.Length == 0) return [];
        var json = await transport.GetJson(Transport.Url("https://dblp.org/search/publ/api", ("q", query), ("format", "json"), ("h", hits.ToString(CultureInfo.InvariantCulture))), ct);
        return json?.Get("result")?.Get("hits")?.Get("hit").Array().Select(h => h.Get("info")).OfType<JsonElement>().Select(MetadataFrom).OfType<Metadata>().ToList() ?? [];
    }

    public static Metadata? MetadataFrom(JsonElement info)
    {
        var title = FieldNormalizer.CleanTitle(info.Str("title"), dropTrailingPeriod: true);
        if (title == null) return null;
        var m = new Metadata(title);
        var venue = FieldNormalizer.CleanText(info.Get("venue").Str());
        m.Authors = info.Get("authors")?.Get("author").Array().Select(a => a.ValueKind == JsonValueKind.String ? a.GetString() : a.Str("text"))
            .Where(n => n != null).Select(n => NameParser.FromDisplayName(n!)).OfType<Author>().ToList() ?? [];
        if (int.TryParse(info.Get("year").Str(), out var year)) { m.Year = year; m.Date = year.ToString(CultureInfo.InvariantCulture); }
        m.Volume = FieldNormalizer.CleanText(info.Get("volume").Str());
        m.Issue = FieldNormalizer.CleanText(info.Get("number").Str());
        m.Pages = FieldNormalizer.NormalizePages(info.Get("pages").Str());
        m.Doi = FieldNormalizer.NormalizeDoi(info.Str("doi"));
        m.Url = Text.NonEmpty(info.Get("ee").Str()) ?? Text.NonEmpty(info.Str("url"));
        m.Source = venue;
        m.Type = info.Str("type") switch
        {
            "Journal Articles" => ItemType.JournalArticle,
            "Conference and Workshop Papers" => ItemType.ConferencePaper,
            "Books and Theses" => ItemType.Book,
            "Parts in Books or Collections" => ItemType.BookChapter,
            "Data and Artifacts" => ItemType.Dataset,
            "Informal and Other Publications" or "Informal Publications" => ItemType.Preprint,
            _ => ItemType.Other,
        };
        if (venue == "CoRR")
        {
            m.Type = ItemType.Preprint;
            m.Source = "arXiv";
            var fromVolume = m.Volume?.Replace("abs/", "");
            m.ArxivId = new[] { fromVolume, m.Doi == null ? null : IdentifierExtractor.ArxivIdFromDoi(m.Doi) }
                .FirstOrDefault(x => x != null && (IdentifierExtractor.ArxivIds(x, false).Count > 0 || x.Contains('/')));
            m.Volume = null;
            if (m.ArxivId != null && m.Doi == null) m.Doi = $"10.48550/arxiv.{m.ArxivId.ToLowerInvariant()}";
        }
        return m;
    }
}

sealed class OpenLibraryClient(Transport transport)
{
    const int MaxAuthors = 6;

    public async Task<Metadata?> Lookup(string isbn, CancellationToken ct)
    {
        var edition = await transport.GetJson($"https://openlibrary.org/isbn/{isbn}.json", ct);
        if (edition is not { } e) return null;
        var title = FieldNormalizer.CleanTitle(e.Str("title"));
        if (title == null) return null;
        if (FieldNormalizer.CleanTitle(e.Str("subtitle")) is { } subtitle) title += ": " + subtitle;
        var m = new Metadata(title) { Type = ItemType.Book };
        if (FieldNormalizer.DateFromString(e.Str("publish_date")) is { } d) { m.Year = d.Year; m.Date = d.Date; }
        m.Publisher = FieldNormalizer.CleanText(e.Get("publishers").Str());
        m.Source = m.Publisher;
        m.Isbn = e.Get("isbn_13").Str() ?? e.Get("isbn_10").Str() ?? isbn;
        m.Url = e.Str("key") is { } key ? $"https://openlibrary.org{key}" : null;
        var authorKeys = e.Get("authors").Array().Select(a => a.Str("key")).OfType<string>().ToList();
        if (authorKeys.Count == 0 && e.Get("works").Array().FirstOrDefault().Str("key") is { } workKey)
        {
            try
            {
                var work = await transport.GetJson($"https://openlibrary.org{workKey}.json", ct);
                authorKeys = work?.Get("authors").Array().Select(a => a.Get("author")?.Str("key")).OfType<string>().ToList() ?? [];
            }
            catch (SourceException) { }
        }
        var lookups = authorKeys.Take(MaxAuthors).Select(async key =>
        {
            try
            {
                var record = await transport.GetJson($"https://openlibrary.org{key}.json", ct);
                var name = record?.Str("name") ?? record?.Str("personal_name");
                return name == null ? null : NameParser.FromDisplayName(name);
            }
            catch (SourceException) { return null; }
        });
        m.Authors = (await Task.WhenAll(lookups)).OfType<Author>().ToList();
        return m;
    }
}

/// <summary>CVF open-access pages for CVPR / ICCV / WACV papers that carry the CVF watermark.</summary>
sealed partial class CvfLookup
{
    public string Conference = "";
    public bool IsWorkshop;
    public List<int> Years = [];
    public string FamilyName = "";
    public string Title = "";
    public Metadata? Fallback;

    static readonly Dictionary<string, string> Booktitles = new()
    {
        ["CVPR"] = "Proceedings of the IEEE/CVF Conference on Computer Vision and Pattern Recognition (CVPR)",
        ["ICCV"] = "Proceedings of the IEEE/CVF International Conference on Computer Vision (ICCV)",
        ["WACV"] = "Proceedings of the IEEE/CVF Winter Conference on Applications of Computer Vision (WACV)",
    };

    [GeneratedRegex(@"This\s+(CVPR|ICCV|WACV)\s*(\d{4})?\s*(workshop\s+)?paper\s+is\s+the\s+Open\s+Access\s+version", RegexOptions.IgnoreCase)]
    private static partial Regex Watermark();

    [GeneratedRegex(@"(CVPR|ICCV|WACV)[\s_'-]*(20\d{2})", RegexOptions.IgnoreCase)]
    private static partial Regex VenueYear();

    public static CvfLookup? Detect(PdfFacts facts, List<string> guesses)
    {
        int currentYear = DateTime.UtcNow.Year;
        var match = Watermark().Match(facts.FirstPageText);
        if (!match.Success) return null;
        var conference = match.Groups[1].Value.ToUpperInvariant();
        var years = new List<int>();
        if (match.Groups[2].Success) years.Add(int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture));
        foreach (var text in new[] { facts.FileName, facts.MetadataText, facts.FirstPageText })
            foreach (Match hit in VenueYear().Matches(text))
            {
                if (hit.Groups[1].Value.ToUpperInvariant() != conference) continue;
                var year = int.Parse(hit.Groups[2].Value, CultureInfo.InvariantCulture);
                if (year >= 2013 && year <= currentYear + 1 && !years.Contains(year)) years.Add(year);
            }
        int? explicitYear = years.Count > 0 ? years[0] : null;
        if (years.Count == 0) years = Enumerable.Range(0, 3).Select(i => currentYear - i).Where(y => conference != "ICCV" || y % 2 == 1).ToList();
        if (guesses.FirstOrDefault() is not { } title || FirstAuthorFamily(facts, title) is not { } family) return null;
        return new CvfLookup
        {
            Conference = conference, IsWorkshop = match.Groups[3].Success, Years = years, FamilyName = family, Title = title,
            Fallback = EmbeddedFallback(facts, conference, explicitYear),
        };
    }

    static string? FirstAuthorFamily(PdfFacts facts, string title)
    {
        var first = facts.EmbeddedAuthor?.Split([';', ','])[0];
        if (first != null && NameParser.FromDisplayName(first) is { Family.Length: > 0 } a) return a.Family;
        var lines = facts.FirstPageLines.Select(l => l.Text).ToList();
        var normalizedTitle = TitleNormalizer.Normalize(title);
        int titleIndex = lines.FindLastIndex(line => TitleNormalizer.Normalize(line) is { Length: > 0 } n && normalizedTitle.EndsWith(n, StringComparison.Ordinal));
        if (titleIndex < 0 || titleIndex + 1 >= lines.Count) return null;
        var words = lines[titleIndex + 1].Split([' ', ',', '\t'], StringSplitOptions.RemoveEmptyEntries)
            .Select(w => new string(w.Where(c => char.IsLetter(c) || c == '-').ToArray())).Where(w => w.Length > 0).ToList();
        return words.Count >= 2 ? words[1] : null;
    }

    static Metadata? EmbeddedFallback(PdfFacts facts, string conference, int? year)
    {
        if (facts.EmbeddedTitle is not { } raw) return null;
        var title = TitleGuesser.Clean(raw);
        if (!TitleGuesser.IsTrustworthyEmbeddedTitle(title)) return null;
        if (TextMatcher.WindowSimilarity(title, TextMatcher.Tokens(facts.FirstPageText)) < 0.9 || facts.EmbeddedAuthor is not { } rawAuthors) return null;
        var authors = rawAuthors.Split(';').Select(NameParser.FromDisplayName).OfType<Author>().ToList();
        if (authors.FirstOrDefault() is not { } first || !TextMatcher.ContainsName(first.Family, TextMatcher.Tokens(facts.FirstPageText))) return null;
        return new Metadata(title) { Type = ItemType.ConferencePaper, Authors = authors, Source = Booktitles.GetValueOrDefault(conference), Year = year };
    }
}

sealed partial class CvfClient(Transport transport)
{
    public async Task<Metadata?> Paper(CvfLookup lookup, CancellationToken ct)
    {
        if (lookup.IsWorkshop) return null;
        var urls = lookup.Years.Select(y => UrlFor(lookup.Conference, y, lookup.FamilyName, lookup.Title)).OfType<string>().ToList();
        SourceException? transient = null;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var tasks = urls.Select(async url =>
        {
            try
            {
                var data = await transport.Get(url, cts.Token, "text/html");
                return data == null ? null : Parse(Encoding.UTF8.GetString(data), url);
            }
            catch (SourceException e)
            {
                if (e.IsTransient) transient = e;
                return null;
            }
        }).ToList();
        while (tasks.Count > 0)
        {
            var done = await Task.WhenAny(tasks);
            tasks.Remove(done);
            if (done.Result is { } m) { cts.Cancel(); return m; }
        }
        if (transient != null) throw transient;
        return null;
    }

    static string? UrlFor(string conference, int year, string family, string title)
    {
        var familySlug = string.Join('_', SlugWords(family));
        var titleSlug = string.Join('_', SlugWords(title).Take(10));
        if (familySlug.Length == 0 || titleSlug.Length == 0) return null;
        var file = $"{familySlug}_{titleSlug}_{conference}_{year}_paper.html";
        var folder = year >= 2021 ? $"content/{conference}{year}" : $"content_{conference}_{year}";
        return $"https://openaccess.thecvf.com/{folder}/html/{file}";
    }

    static List<string> SlugWords(string text)
    {
        var folded = Text.Fold(text);
        return text.Normalize(NormalizationForm.FormKD).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)
            .Select(w => new string(w.Where(c => c < 128 && (char.IsLetterOrDigit(c) || c == '-')).ToArray()))
            .Where(w => w.Length > 0 && w != "-").ToList();
    }

    static Metadata? Parse(string html, string url)
    {
        var bib = FirstMatch("<div class=\"bibref[^\"]*\">(.*?)</div>", html);
        if (bib == null) return null;
        string? Field(string name) => FirstMatch(name + @"\s*=\s*\{(.*?)\},?\s*\n", bib + "\n") is { } v ? FieldNormalizer.CleanText(v) ?? v : null;
        var title = FieldNormalizer.CleanTitle(Field("title"));
        if (title == null) return null;
        var m = new Metadata(title)
        {
            Type = ItemType.ConferencePaper,
            Authors = (Field("author") ?? "").Split(" and ").Select(NameParser.FromDisplayName).OfType<Author>().ToList(),
            Source = Field("booktitle"),
            Pages = FieldNormalizer.NormalizePages(Field("pages")),
            Url = url,
            Abstract = FirstMatch("<div id=\"abstract\">(.*?)</div>", html) is { } a ? FieldNormalizer.CleanAbstract(a) : null,
        };
        if (int.TryParse(Field("year"), out var year)) { m.Year = year; m.Date = year.ToString(CultureInfo.InvariantCulture); }
        return m;
    }

    static string? FirstMatch(string pattern, string text)
    {
        var m = Regex.Match(text, pattern, RegexOptions.Singleline);
        return m.Success ? m.Groups[1].Value : null;
    }
}

/// <summary>Locates and downloads open-access PDFs (arXiv, OpenAlex's best location).</summary>
public static partial class OpenAccessPdf
{
    static readonly HttpClient Http = new(new SocketsHttpHandler { AllowAutoRedirect = true, AutomaticDecompression = DecompressionMethods.All })
    { Timeout = TimeSpan.FromSeconds(60) };

    public static async Task<string?> Locate(string? doi, string? arxivId, string? mailto = null, CancellationToken ct = default)
    {
        if (Text.NonEmpty(arxivId) is { } a) return $"https://arxiv.org/pdf/{a}";
        if (FieldNormalizer.NormalizeDoi(doi) is not { } d) return null;
        if (IdentifierExtractor.ArxivIdFromDoi(d) is { } x) return $"https://arxiv.org/pdf/{x}";
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Transport.Url($"https://api.openalex.org/works/doi:{d}", ("select", "best_oa_location,locations"), ("mailto", mailto)));
            request.Headers.TryAddWithoutValidation("User-Agent", UserAgent(mailto));
            using var response = await Http.SendAsync(request, ct);
            if (!response.IsSuccessStatusCode) return null;
            using var doc = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(ct));
            var root = doc.RootElement;
            var candidates = new List<string?> { root.Get("best_oa_location")?.Str("pdf_url") };
            candidates.AddRange(root.Get("locations").Array().Select(l => l.Str("pdf_url")));
            return candidates.FirstOrDefault(c => c != null && Uri.TryCreate(c, UriKind.Absolute, out _));
        }
        catch { return null; }
    }

    /// <summary>Downloads the PDF into a temporary folder; follows a landing page's citation_pdf_url once.</summary>
    public static async Task<string> Download(string url, string? mailto = null, CancellationToken ct = default)
    {
        var target = new Uri(url);
        for (int attempt = 0; attempt < 2; attempt++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, target);
            request.Headers.TryAddWithoutValidation("User-Agent", UserAgent(mailto));
            request.Headers.TryAddWithoutValidation("Accept", "application/pdf,text/html;q=0.8,*/*;q=0.5");
            using var response = await Http.SendAsync(request, ct);
            if (!response.IsSuccessStatusCode) throw new IOException($"HTTP {(int)response.StatusCode}");
            var data = await response.Content.ReadAsByteArrayAsync(ct);
            var final = response.RequestMessage?.RequestUri ?? target;
            if (IsPdf(data))
            {
                var folder = Path.Combine(Path.GetTempPath(), $"folio-download-{Guid.NewGuid()}");
                Directory.CreateDirectory(folder);
                var file = Path.Combine(folder, FileNameFor(final));
                await File.WriteAllBytesAsync(file, data, ct);
                return file;
            }
            var html = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 2_000_000));
            if (attempt > 0 || PdfLink(html, final) is not { } next)
                throw new IOException(Loc.S("下载的文件不是 PDF（可能需要登录或订阅）"));
            target = next;
        }
        throw new IOException(Loc.S("下载的文件不是 PDF（可能需要登录或订阅）"));
    }

    public static bool IsPdf(ReadOnlySpan<byte> data) => data[..Math.Min(1024, data.Length)].IndexOf("%PDF"u8) >= 0;

    static Uri? PdfLink(string html, Uri baseUri)
    {
        string[] patterns =
        [
            """<meta[^>]+name=["']citation_pdf_url["'][^>]+content=["']([^"']+)["']""",
            """<meta[^>]+content=["']([^"']+)["'][^>]+name=["']citation_pdf_url["']""",
            """<meta[^>]+http-equiv=["']refresh["'][^>]+content=["'][^"']*url=([^"'>]+)["']""",
            """<(?:iframe|embed)[^>]+src=["']([^"']+)["']""",
            """window\.location(?:\.href)?\s*=\s*["']([^"']+)["']""",
        ];
        foreach (var pattern in patterns)
        {
            var m = Regex.Match(html, pattern, RegexOptions.IgnoreCase);
            if (!m.Success) continue;
            var raw = m.Groups[1].Value.Replace("&amp;", "&").Trim();
            if (Uri.TryCreate(baseUri, raw, out var url) && url.Scheme is "http" or "https") return url;
        }
        return null;
    }

    static string FileNameFor(Uri url)
    {
        var name = Uri.UnescapeDataString(url.Segments.LastOrDefault() ?? "").Replace("/", "_");
        if (name.Length == 0) name = "download";
        name = FileNamer.Sanitize(name);
        if (!name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) name += ".pdf";
        return name;
    }

    static string UserAgent(string? mailto) => Text.NonEmpty(mailto) is { } m ? $"Folio/1.0 (Windows; mailto:{m})" : "Folio/1.0 (Windows)";
}
