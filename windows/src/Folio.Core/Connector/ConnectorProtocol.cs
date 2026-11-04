using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Web;

namespace Folio.Core.Connector;

/// <summary>
/// The HTTP dialect the browser extension speaks to Folio on 127.0.0.1:23120 — the same as the macOS app's, so one
/// extension serves both. Only extension origins may call it, and POSTs must carry X-Folio-Connector.
/// </summary>
public static class ConnectorProtocol
{
    public const int Port = 23120;
    public const string Header = "x-folio-connector";
    public const int ApiVersion = 2;
    public const int MaxBodyBytes = 300 * 1024 * 1024;

    public sealed record Request(string Method, string Path, Dictionary<string, string> Query, Dictionary<string, string> Headers, byte[] Body)
    {
        public string? HeaderValue(string name) => Headers.GetValueOrDefault(name.ToLowerInvariant());
        public JsonNode? Json()
        {
            try { return JsonNode.Parse(Body); } catch (JsonException) { return null; }
        }
    }

    public sealed record Response(int Status, byte[] Body, string ContentType = "application/json; charset=utf-8")
    {
        public Dictionary<string, string> Headers { get; init; } = [];

        public static Response Json(JsonNode value, int status = 200) => new(status, Encoding.UTF8.GetBytes(value.ToJsonString()));
        public static Response Error(string message, int status) => Json(new JsonObject { ["error"] = message }, status);

        public byte[] Serialized()
        {
            var reason = Status switch
            {
                200 => "OK", 204 => "No Content", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
                413 => "Payload Too Large", 500 => "Internal Server Error", 502 => "Bad Gateway", 503 => "Service Unavailable", _ => "OK",
            };
            var head = new StringBuilder($"HTTP/1.1 {Status} {reason}\r\nContent-Type: {ContentType}\r\nContent-Length: {Body.Length}\r\nConnection: close\r\n");
            foreach (var (name, value) in Headers.OrderBy(h => h.Key, StringComparer.Ordinal)) head.Append($"{name}: {value}\r\n");
            head.Append("\r\n");
            return [.. Encoding.UTF8.GetBytes(head.ToString()), .. Body];
        }
    }

    public enum ParseState { Incomplete, Invalid, Complete }

    public static (ParseState State, Request? Request, string? Error) Parse(byte[] data, int length)
    {
        var span = data.AsSpan(0, length);
        int end = span.IndexOf("\r\n\r\n"u8);
        if (end < 0) return length > 64 * 1024 ? (ParseState.Invalid, null, "headers too large") : (ParseState.Incomplete, null, null);
        string head;
        try { head = Encoding.UTF8.GetString(span[..end]); } catch { return (ParseState.Invalid, null, "bad headers"); }
        var lines = head.Split("\r\n");
        var requestLine = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (requestLine.Length < 2) return (ParseState.Invalid, null, "bad request line");
        var headers = new Dictionary<string, string>();
        foreach (var line in lines.Skip(1))
        {
            int colon = line.IndexOf(':');
            if (colon < 0) continue;
            headers[line[..colon].Trim().ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        int contentLength = int.TryParse(headers.GetValueOrDefault("content-length"), out var l) ? l : 0;
        if (contentLength > MaxBodyBytes) return (ParseState.Invalid, null, "body too large");
        int bodyStart = end + 4;
        if (length - bodyStart < contentLength) return (ParseState.Incomplete, null, null);
        var target = requestLine[1];
        int q = target.IndexOf('?');
        var path = q >= 0 ? target[..q] : target;
        var query = new Dictionary<string, string>();
        if (q >= 0)
        {
            var parsed = HttpUtility.ParseQueryString(target[(q + 1)..]);
            foreach (string? key in parsed.Keys) if (key != null) query[key] = parsed[key] ?? "";
        }
        return (ParseState.Complete, new Request(requestLine[0].ToUpperInvariant(), Uri.UnescapeDataString(path), query, headers, span.Slice(bodyStart, contentLength).ToArray()), null);
    }

    public static bool IsAllowedOrigin(string? origin)
    {
        if (string.IsNullOrEmpty(origin) || origin == "null") return true;
        return new[] { "chrome-extension://", "safari-web-extension://", "moz-extension://", "ms-browser-extension://" }.Any(origin.StartsWith);
    }

    public static Dictionary<string, string> CorsHeaders(string? origin)
    {
        if (string.IsNullOrEmpty(origin) || !IsAllowedOrigin(origin)) return [];
        return new()
        {
            ["Access-Control-Allow-Origin"] = origin,
            ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
            ["Access-Control-Allow-Headers"] = "Content-Type, X-Folio-Connector",
            ["Access-Control-Max-Age"] = "600",
            ["Vary"] = "Origin",
        };
    }

    public static bool IsLocalHost(string? host)
    {
        if (string.IsNullOrEmpty(host)) return false;
        string name = host.StartsWith('[') ? new string(host.Skip(1).TakeWhile(c => c != ']').ToArray()) : host.Split(':', 2)[0];
        return name.ToLowerInvariant() is "127.0.0.1" or "localhost" or "::1";
    }

    public static Response? Reject(Request request)
    {
        if (!IsLocalHost(request.HeaderValue("host"))) return Response.Error("Folio only answers requests to 127.0.0.1.", 403);
        if (!IsAllowedOrigin(request.HeaderValue("origin"))) return Response.Error("Only Folio's browser extension may use this service.", 403);
        if (request.Method == "POST" && request.HeaderValue(Header) == null) return Response.Error("Missing X-Folio-Connector header.", 403);
        return null;
    }

    /// <summary>Metadata the extension read off a page.</summary>
    public static Metadata? MetadataFrom(JsonNode? item)
    {
        if (item?["title"]?.ToString().Trim() is not { Length: > 0 } title) return null;
        string? Text(string key) => item[key] is JsonValue v && v.ToString().Trim() is { Length: > 0 } s ? s : null;
        var m = new Metadata(title)
        {
            Authors = (item["authors"] as JsonArray ?? []).Select(a => a switch
            {
                JsonValue v when v.ToString() is { } name => ParseName(name),
                JsonObject o when o["family"]?.ToString() is { Length: > 0 } family => new Author(family, o["given"]?.ToString() ?? ""),
                _ => null,
            }).OfType<Author>().ToList(),
        };
        m.Date = Text("date");
        m.Year = item["year"] is JsonValue y && int.TryParse(y.ToString(), out var year) ? year : m.Date is { Length: >= 4 } d && int.TryParse(d[..4], out var dy) ? dy : null;
        m.Source = Text("venue");
        m.Volume = Text("volume");
        m.Issue = Text("issue");
        m.Pages = Text("pages");
        m.Publisher = Text("publisher");
        m.Doi = Text("doi")?.ToLowerInvariant().Replace("https://doi.org/", "").Replace("doi:", "");
        m.ArxivId = Text("arxiv");
        m.Isbn = Text("isbn");
        m.Url = Text("url");
        m.Abstract = Text("abstract");
        m.Type = Text("type") is { } t && ItemTypes.All.Any(x => x.Raw() == t) ? ItemTypes.Parse(t)
            : m.ArxivId != null && m.Source == null ? ItemType.Preprint : ItemType.JournalArticle;
        if (m.Type == ItemType.Preprint && m.Source == null && m.ArxivId != null) m.Source = "arXiv";
        return m;
    }

    static Author? ParseName(string raw)
    {
        var name = raw.Trim();
        if (name.Length == 0) return null;
        int comma = name.IndexOf(',');
        if (comma >= 0) return new Author(name[..comma].Trim(), name[(comma + 1)..].Trim());
        var parts = name.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 1 ? new Author(parts[^1], string.Join(' ', parts[..^1])) : new Author(name);
    }

    /// <summary>A looked-up record completed with what only the page had.</summary>
    public static Metadata Merge(Metadata resolved, Metadata page)
    {
        var merged = resolved.Copy();
        if (string.IsNullOrEmpty(merged.Abstract)) merged.Abstract = page.Abstract;
        if (string.IsNullOrEmpty(merged.Url)) merged.Url = page.Url;
        if (string.IsNullOrEmpty(merged.Pages)) merged.Pages = page.Pages;
        if (string.IsNullOrEmpty(merged.Volume)) merged.Volume = page.Volume;
        if (string.IsNullOrEmpty(merged.Issue)) merged.Issue = page.Issue;
        if (merged.Authors.Count == 0) merged.Authors = page.Authors;
        return merged;
    }
}
