using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Layout;

namespace Folio.Core.Translate.Services;

// Port of macos/.../FolioTranslate/Services/TranslationProvider.swift and LLMProviders.swift.

/// <summary>A term and its fixed translation.</summary>
public sealed record GlossaryEntry(string Source, string Target);

/// <summary>What every request knows about the paper being translated.</summary>
public sealed record TranslationContext(string SourceLanguage, string TargetLanguage, string? Title, string? Summary, List<GlossaryEntry> Glossary)
{
    /// <summary>For the words in the paper's figures: the captions of those figures.</summary>
    public List<string> FigureCaptions { get; init; } = [];
}

/// <summary>One text to translate and what kind of text it is.</summary>
public sealed record TranslationItem(string Text, BlockKind Kind)
{
    public bool IsShort => Kind is BlockKind.Heading or BlockKind.TableCell or BlockKind.Title or BlockKind.Figure;
}

/// <summary>How a provider likes its work: how much text per request and how many requests at once.</summary>
public sealed record ProviderLimits(int BatchCharacters, int BatchItems, int Concurrency, bool UsesContext, double StartupSeconds = 1.5, double SecondsPerCharacter = 0.01);

/// <summary>A translation backend.</summary>
public interface ITranslationProvider
{
    ProviderLimits Limits { get; }
    /// <summary>Translations of <paramref name="items"/>, in order.</summary>
    Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel);
    /// <summary>Terms of the field with their translations (large language models only).</summary>
    Task<List<GlossaryEntry>> ExtractTerms(string excerpt, TranslationContext context, CancellationToken cancel) => Task.FromResult(new List<GlossaryEntry>());
    /// <summary>Gets the first request ready without sending any text: the connection opened (DNS, TCP, TLS) and any token
    /// fetched. Failures are ignored; the request itself will say what went wrong (SEL-20).</summary>
    Task Prewarm() => Task.CompletedTask;
    /// <summary>The model that answers, for the log (null where the service has none to name).</summary>
    string? ModelName => null;
}

/// <summary>Why a request failed. Detail is what the error classifier reads.</summary>
public sealed class ProviderError : Exception
{
    /// <summary>Truncated: the reply was cut off at the model's output limit; the same request would be cut off again,
    /// half of it may fit.</summary>
    public enum Kinds { Http, Network, InvalidResponse, Cancelled, Process, AgentSetup, Refused, Truncated }

    public Kinds Kind { get; }
    public int Status { get; }
    public string Detail { get; }
    public string? Host { get; init; }
    /// <summary>Seconds the server asked to wait (Retry-After).</summary>
    public double? RetryAfter { get; init; }

    public ProviderError(Kinds kind, string detail, string? host = null, int status = 0) : base(detail)
    {
        Kind = kind;
        Detail = detail;
        Host = host;
        Status = status;
    }

    public static ProviderError HttpStatus(int status, string detail, string? host = null) => new(Kinds.Http, detail, host, status);

    /// <summary>Worth trying again: rate limits, server errors, dropped connections, unreadable replies.</summary>
    public bool IsRetryable => Kind switch
    {
        Kinds.Http => Status == 429 || Status == 408 || Status >= 500,
        Kinds.Network or Kinds.InvalidResponse or Kinds.Process => true,
        _ => false,
    };

    static readonly Regex Refusal = new(
        @"content[_ \-]?(filter|policy|management|moderation|risk|safety)|data_inspection_failed|inappropriate[_ ]content|sensitive[_ ]words?|content exists risk|responsible ?ai|policy violation|violat(es|ion)[^\n]{0,40}(policy|guidelines|usage)|prohibited content|blocked (by|due to)[^\n]{0,30}(safety|policy|moderation)|finish_reason""?\s*[:=]\s*""?(content_filter|safety)|内容(审核|安全|风险)|敏感(词|内容|信息)|不合规|违规",
        RegexOptions.IgnoreCase);

    static readonly Regex Decline = new(
        @"^(I('m| am) sorry|I can(no|')t (help|assist|translate|comply|provide)|I won'?t|Sorry, (but )?I can|抱歉|对不起，?我无法|我无法(协助|翻译|提供))",
        RegexOptions.IgnoreCase);

    /// <summary>What services say when their content review stops a text.</summary>
    public static bool IsContentRefusal(string text) => Refusal.IsMatch(text);

    /// <summary>A model declining in words instead of translating.</summary>
    public static bool IsDecline(string reply) => Decline.IsMatch(reply.Trim());
}

public static class LanguageNames
{
    /// <summary>English name of a language code, for prompts.</summary>
    public static string English(string code) => code.ToLowerInvariant() switch
    {
        "zh" or "zh-cn" or "zh-hans" => "Simplified Chinese",
        "zh-tw" or "zh-hant" or "zh-hk" => "Traditional Chinese",
        "en" => "English",
        "ja" => "Japanese",
        "ko" => "Korean",
        "fr" => "French",
        "de" => "German",
        "es" => "Spanish",
        "it" => "Italian",
        "pt" => "Portuguese",
        "ru" => "Russian",
        "ar" => "Arabic",
        _ => TryCulture(code),
    };

    static string TryCulture(string code)
    {
        try { return CultureInfo.GetCultureInfo(code).EnglishName; } catch { return code; }
    }
}

/// <summary>The batch protocol shared by every large language model and agent: a JSON object of numbered texts in,
/// the same keys with translations out.</summary>
public static class LLMBatch
{
    public static string SystemPrompt(TranslationContext context)
    {
        string source = LanguageNames.English(context.SourceLanguage), target = LanguageNames.English(context.TargetLanguage);
        var prompt = new StringBuilder($"""
        You are an expert translator of academic papers. Translate each value of the JSON object the user sends from {source} into {target}.

        Rules:
        - Reply with only a JSON object that has exactly the same keys, each mapped to its translation. No explanations, no code fences.
        - Placeholders like {"{v1}"}, {"{v2}"} stand for formulas. Keep every one of them exactly as written and put it where it belongs in the translated sentence.
        - {"{v0}"} is not a formula: it marks where the text breaks across a column or a page. Keep it once, at the corresponding point of your translation.
        - The values are consecutive passages of the paper, in reading order.
        - Keep citations ([12], [3, 7], Smith et al. (2020)), URLs, code, numbers and units unchanged.
        - Keep names of models, methods, datasets, metrics, software and abbreviations (e.g. ResNet-50, CLIP, mIoU, ImageNet, GAN) in their original form.
        - Use the established terminology of the field and translate terms consistently; follow the glossary.
        - Headings, table cells and other short items: translate concisely, without adding final punctuation.
        - Write fluent, natural {target} academic prose. Do not add, omit or explain anything.
        - Translate every value in full, each under its own key: never merge two values, leave one out or give one back in {source} (a value that is only a name, a number or a formula stays as it is).
        - Each value is one piece of text; keep it one piece (no line breaks).
        """);
        prompt.Replace("\r\n", "\n");
        if (!string.IsNullOrEmpty(context.Title)) prompt.Append($"\n\nPaper title: {context.Title}");
        if (!string.IsNullOrEmpty(context.Summary)) prompt.Append($"\nAbstract: {context.Summary[..Math.Min(1500, context.Summary.Length)]}");
        if (context.Glossary.Count > 0)
            prompt.Append($"\n\nGlossary ({source} → {target}):\n").Append(string.Join("\n", context.Glossary.Select(g => $"- {g.Source} → {g.Target}")));
        if (context.FigureCaptions.Count > 0)
            prompt.Append("\n\nThe figure labels to translate come from figures with these captions (for their meaning and terms; do not translate the captions):\n")
                .Append(string.Join("\n", context.FigureCaptions.Select(c => "- " + c)));
        return prompt.ToString();
    }

    static readonly JsonSerializerOptions Unescaped = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>The user message: {"1": "…", "2": "…"} in reading order, with a note on which items are short.</summary>
    public static string UserMessage(List<TranslationItem> items)
    {
        string Json(string s) => JsonSerializer.Serialize(s, Unescaped);
        var message = "{" + string.Join(", ", items.Select((item, i) => $"{Json((i + 1).ToString())}: {Json(item.Text)}")) + "}";
        var shortItems = items.Select((item, i) => (item, i)).Where(p => p.item.IsShort && p.item.Kind != BlockKind.Figure).Select(p => (p.i + 1).ToString()).ToList();
        if (shortItems.Count > 0) message += "\n\nShort items (headings or table cells): " + string.Join(", ", shortItems);
        // Words read from the paper's pictures: labels to translate, each one, not names to keep.
        var labels = items.Select((item, i) => (item, i)).Where(p => p.item.Kind == BlockKind.Figure).Select(p => (p.i + 1).ToString()).ToList();
        if (labels.Count > 0)
            message += "\n\nItems " + string.Join(", ", labels) + " are labels inside the paper's figures (diagram boxes, legends, axis titles), "
                + "read from the images in reading order. Translate every one of them completely, concisely and without final punctuation, "
                + "even single words such as Encoder, Prompt or Output, using the terms the paper itself uses; keep only proper names and "
                + "abbreviations (ResNet, SAM, GT) as they are. The labels were read by OCR and may have a misread letter: translate what "
                + "the label evidently says. A label that is unreadable noise: give it back unchanged.";
        return message;
    }

    /// <summary>Reads the reply. Missing keys come back as null.</summary>
    public static List<string?> Parse(string reply, int count)
    {
        if (count <= 0) return [];
        reply = WithoutThinking(reply);
        if ((JsonObjectIn(reply) ?? LenientObject(reply)) is { } obj)
        {
            var values = Numbered(obj, count);
            if (values.Any(v => v != null)) return values;
        }
        // A plain list of the translations, in order.
        if (JsonArrayIn(reply) is { } list && list.Count == count) return list;
        return Enumerable.Repeat<string?>(null, count).ToList();
    }

    static readonly Regex Thinking = new(@"<(think|thinking)>.*?</\1>", RegexOptions.Singleline);

    /// <summary>The reply without what a reasoning model thought aloud before it (&lt;think&gt;…&lt;/think&gt;): braces,
    /// quotes and drafts in there are not the answer.</summary>
    public static string WithoutThinking(string reply)
    {
        var text = Thinking.Replace(reply, "");
        // Only the closing tag (the opening one went with the prompt).
        foreach (var tag in new[] { "</think>", "</thinking>" })
        {
            int end = text.LastIndexOf(tag, StringComparison.Ordinal);
            if (end >= 0) text = text[(end + tag.Length)..];
        }
        return text;
    }

    static string? TextOf(JsonNode? value)
    {
        static string? Plain(JsonNode? node) => node is JsonValue v && v.TryGetValue<string>(out var text) ? text : null;
        switch (value)
        {
            case null: return null;
            case JsonValue v: return Plain(v) ?? v.ToJsonString();
            case JsonObject wrapped:
                var strings = wrapped.Select(p => Plain(p.Value)).Where(t => t != null).ToList();
                if (strings.Count == 1) return strings[0];
                return Plain(wrapped["translation"]) ?? Plain(wrapped["text"]) ?? Plain(wrapped["target"]);
            default: return null;
        }
    }

    /// <summary>The texts under "1", "2", …: at the top of the object, or one level down ({"translations": {…}}, a list
    /// under one key). A text may itself be wrapped ({"translation": "…"}).</summary>
    public static List<string?> Numbered(JsonObject obj, int count)
    {
        var byNumber = new Dictionary<int, string>();
        foreach (var (key, value) in obj)
            if (int.TryParse(key.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out int n) && TextOf(value) is { } text) byNumber[n] = text;
        if (byNumber.Count == 0 && obj.Count == 1)
        {
            var inner = obj.First().Value;
            if (inner is JsonObject nested) return Numbered(nested, count);
            if (inner is JsonArray list && list.Count == count) return list.Select(TextOf).ToList();
        }
        return Enumerable.Range(1, count).Select(k => byNumber.TryGetValue(k, out var text) ? text : null).ToList();
    }

    /// <summary>A JSON list of texts in text, if that is what it holds.</summary>
    public static List<string?>? JsonArrayIn(string text)
    {
        int start = text.IndexOf('['), end = text.LastIndexOf(']');
        if (start < 0 || end <= start) return null;
        try
        {
            if (JsonNode.Parse(text[start..(end + 1)]) is not JsonArray list) return null;
            var values = list.Select(v => v is JsonValue value && value.TryGetValue<string>(out var s) ? s : null).ToList();
            return values.Any(v => v != null) ? values : null;
        }
        catch { return null; }
    }

    /// <summary>The first JSON object in text (models sometimes wrap it in code fences or add a sentence).</summary>
    public static JsonObject? JsonObjectIn(string text)
    {
        var candidate = text.Trim();
        if (TryObject(candidate) is { } whole) return whole;
        int fence = candidate.IndexOf("```", StringComparison.Ordinal);
        if (fence >= 0)
        {
            candidate = candidate[(fence + 3)..];
            int newline = candidate.IndexOf('\n');
            if (newline >= 0) candidate = candidate[(newline + 1)..];
            int end = candidate.IndexOf("```", StringComparison.Ordinal);
            if (end >= 0) candidate = candidate[..end];
        }
        int think = candidate.IndexOf("</think>", StringComparison.Ordinal);
        if (think >= 0) candidate = candidate[(think + 8)..];
        int start = candidate.IndexOf('{'), last = candidate.LastIndexOf('}');
        if (start < 0 || last <= start) return null;
        return TryObject(candidate[start..(last + 1)]);
    }

    static JsonObject? TryObject(string json)
    {
        try { return JsonNode.Parse(json) as JsonObject; } catch { return null; }
    }

    /// <summary>{"1": "…"} whose values break JSON: each value runs from its key to the last quote before the next key.</summary>
    public static JsonObject? LenientObject(string text)
    {
        var keys = Regex.Matches(text, @"""(\d+)""\s*:\s*""").ToList();
        if (keys.Count == 0) return null;
        var obj = new JsonObject();
        for (int i = 0; i < keys.Count; i++)
        {
            int start = keys[i].Index + keys[i].Length;
            int limit = i + 1 < keys.Count ? keys[i + 1].Index : text.Length;
            var chunk = text[start..limit];
            int close = chunk.LastIndexOf('"');
            if (close < 0) continue;
            var value = chunk[..close].Replace("\\n", " ").Replace("\\\"", "\"").Replace("\\\\", "\\");
            obj[keys[i].Groups[1].Value] = value;
        }
        return obj.Count == 0 ? null : obj;
    }

    public static string TermsPrompt(TranslationContext context)
    {
        var target = LanguageNames.English(context.TargetLanguage);
        return $$"""
        You build glossaries for translating academic papers into {{target}}. From the excerpt the user sends, pick the technical terms whose translation must stay consistent (concepts, task names, phrases of the field), at most 30, and give the established {{target}} translation of each.
        Leave out names of models, methods, datasets, metrics and software, and abbreviations, which stay untranslated.
        Reply with only JSON: {"terms": [{"source": "...", "target": "..."}]}
        """.Replace("\r\n", "\n");
    }

    public static List<GlossaryEntry> ParseTerms(string reply)
    {
        if (JsonObjectIn(WithoutThinking(reply))?["terms"] is not JsonArray terms) return [];
        var result = new List<GlossaryEntry>();
        foreach (var term in terms.OfType<JsonObject>())
        {
            var source = term["source"]?.GetValueKind() == JsonValueKind.String ? term["source"]!.GetValue<string>() : null;
            var target = term["target"]?.GetValueKind() == JsonValueKind.String ? term["target"]!.GetValue<string>() : null;
            if (string.IsNullOrEmpty(source) || string.IsNullOrEmpty(target) || source.Length >= 80) continue;
            result.Add(new GlossaryEntry(source, target));
        }
        return result;
    }
}

/// <summary>HTTP for the providers: non-2xx answers and transport failures become ProviderErrors.</summary>
public static class Http
{
    /// <summary>One client for every service: its connections stay open between requests, so a token request, a warm-up
    /// and the translations after them all go over the same connection.</summary>
    public static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        MaxConnectionsPerServer = 16,
        AutomaticDecompression = DecompressionMethods.All,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(90),
        ConnectTimeout = TimeSpan.FromSeconds(15),
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    static readonly Dictionary<string, DateTime> WarmedAt = [];
    public const double WarmInterval = 30;

    /// <summary>True the first time in WarmInterval seconds for host (and notes the time).</summary>
    public static bool ShouldWarm(string host)
    {
        lock (WarmedAt)
        {
            if (WarmedAt.TryGetValue(host, out var last) && (DateTime.UtcNow - last).TotalSeconds < WarmInterval) return false;
            WarmedAt[host] = DateTime.UtcNow;
            return true;
        }
    }

    /// <summary>Opens a connection to url's host with a body-less request (HEAD) and leaves it in the pool for the
    /// translation that follows. The answer does not matter; no text is sent.</summary>
    public static async Task Warm(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) return;
        var host = uri.IsDefaultPort ? uri.Host : $"{uri.Host}:{uri.Port}";
        if (!ShouldWarm(host)) return;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            using var response = await Client.SendAsync(new HttpRequestMessage(HttpMethod.Head, uri), HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        }
        catch
        {
            // Unreachable for now: the next warm-up may try again at once.
            lock (WarmedAt) WarmedAt.Remove(host);
        }
    }

    public static HttpRequestMessage Request(string url, HttpMethod? method = null, Dictionary<string, string>? headers = null, JsonNode? json = null)
    {
        var request = new HttpRequestMessage(method ?? HttpMethod.Post, url);
        foreach (var (key, value) in headers ?? []) request.Headers.TryAddWithoutValidation(key, value);
        if (json != null) request.Content = new StringContent(json.ToJsonString(), Encoding.UTF8, "application/json");
        return request;
    }

    static string HostOf(Uri uri) => uri.IsDefaultPort ? uri.Host : $"{uri.Host}:{uri.Port}";

    /// <summary>What a non-2xx answer becomes.</summary>
    static ProviderError Failure(HttpResponseMessage response, byte[] data, string host)
    {
        int status = (int)response.StatusCode;
        var body = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 2000));
        bool refused = status is 400 or 403 or 422 or 451 && ProviderError.IsContentRefusal(body);
        double? retry = response.Headers.RetryAfter?.Delta?.TotalSeconds;
        return refused ? new ProviderError(ProviderError.Kinds.Refused, $"Error code: {status} - {body}", host) { RetryAfter = retry }
            : new ProviderError(ProviderError.Kinds.Http, $"Error code: {status} - {body}", host, status) { RetryAfter = retry };
    }

    public static async Task<byte[]> Send(HttpRequestMessage request, CancellationToken cancel, double timeoutSeconds = 180)
    {
        var uri = request.RequestUri!;
        string host = HostOf(uri);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        try
        {
            using var response = await Client.SendAsync(request, timeout.Token);
            var data = await response.Content.ReadAsByteArrayAsync(timeout.Token);
            if ((int)response.StatusCode is < 200 or >= 300) throw Failure(response, data, host);
            return data;
        }
        catch (ProviderError) { throw; }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            throw new ProviderError(ProviderError.Kinds.Cancelled, "cancelled", host);
        }
        catch (OperationCanceledException)
        {
            throw new ProviderError(ProviderError.Kinds.Network, $"Connection timed out: {uri.Host}", host);
        }
        catch (HttpRequestException e)
        {
            throw new ProviderError(ProviderError.Kinds.Network, NetworkDetail(e, uri.Host), host);
        }
    }

    /// <summary>Sends the request and hands over its answer as it arrives: each event of a stream (server-sent events:
    /// the text after "data:") goes to onEvent, and null comes back at its end. A server that answers in one piece
    /// instead (JSON: it does not stream, whatever was asked) gets its whole body returned.
    ///
    /// A reply that takes minutes to write no longer runs into the time limit of a request, which now only counts the
    /// silence between two pieces (idleSeconds); and how far the reply has come is known, not guessed.</summary>
    public static async Task<byte[]?> Stream(HttpRequestMessage request, Action<string> onEvent, CancellationToken cancel, double idleSeconds = 180)
    {
        var uri = request.RequestUri!;
        string host = HostOf(uri);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(idleSeconds));
        try
        {
            using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if ((int)response.StatusCode is < 200 or >= 300)
                throw Failure(response, await response.Content.ReadAsByteArrayAsync(timeout.Token), host);
            bool? isStream = response.Content.Headers.ContentType?.MediaType?.Contains("event-stream", StringComparison.OrdinalIgnoreCase) == true ? true : null;
            await using var body = await response.Content.ReadAsStreamAsync(timeout.Token);
            var whole = new MemoryStream();
            var line = new MemoryStream();
            var buffer = new byte[16384];
            // False once the stream said it is done.
            bool Take()
            {
                var text = Encoding.UTF8.GetString(line.GetBuffer(), 0, (int)line.Length).TrimEnd('\r');
                line.SetLength(0);
                if (isStream == null && text.Trim().Length > 0) isStream = text.StartsWith("data:") || text.StartsWith("event:") || text.StartsWith(':');
                if (isStream != true || !text.StartsWith("data:")) return true;
                var payload = text[5..].Trim();
                if (payload == "[DONE]") return false;
                if (payload.Length > 0) onEvent(payload);
                return true;
            }
            while (true)
            {
                int read = await body.ReadAsync(buffer, timeout.Token);
                if (read <= 0) break;
                timeout.CancelAfter(TimeSpan.FromSeconds(idleSeconds));
                // Lines end at a line feed only: a text may hold other characters Unicode calls line ends (U+2028).
                for (int i = 0; i < read; i++)
                {
                    if (isStream != true) whole.WriteByte(buffer[i]);
                    if (buffer[i] != 0x0A) { line.WriteByte(buffer[i]); continue; }
                    if (!Take()) return null;
                }
            }
            if (line.Length > 0) Take();
            return isStream == true ? null : whole.ToArray();
        }
        catch (ProviderError) { throw; }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            throw new ProviderError(ProviderError.Kinds.Cancelled, "cancelled", host);
        }
        catch (OperationCanceledException)
        {
            throw new ProviderError(ProviderError.Kinds.Network, $"Connection timed out: {uri.Host}", host);
        }
        catch (HttpRequestException e)
        {
            throw new ProviderError(ProviderError.Kinds.Network, NetworkDetail(e, uri.Host), host);
        }
        catch (IOException e)
        {
            throw new ProviderError(ProviderError.Kinds.Network, $"Connection reset: server disconnected: {uri.Host} ({e.Message})", host);
        }
    }

    /// <summary>Transport failures in the words the classifier knows.</summary>
    static string NetworkDetail(HttpRequestException e, string host)
    {
        var inner = e.InnerException;
        if (inner is System.Net.Sockets.SocketException socket)
        {
            switch (socket.SocketErrorCode)
            {
                case System.Net.Sockets.SocketError.HostNotFound or System.Net.Sockets.SocketError.NoData or System.Net.Sockets.SocketError.TryAgain:
                    return $"nodename nor servname provided, or not known: {host}";
                case System.Net.Sockets.SocketError.ConnectionRefused: return $"Connection refused: {host}";
                case System.Net.Sockets.SocketError.TimedOut: return $"Connection timed out: {host}";
                case System.Net.Sockets.SocketError.ConnectionReset: return $"Connection reset: server disconnected: {host}";
                case System.Net.Sockets.SocketError.NetworkUnreachable: return "Network is unreachable";
            }
        }
        if (inner is System.Security.Authentication.AuthenticationException) return $"SSLError: {host}";
        if (e.HttpRequestError == HttpRequestError.NameResolutionError) return $"nodename nor servname provided, or not known: {host}";
        if (e.HttpRequestError == HttpRequestError.SecureConnectionError) return $"SSLError: {host}";
        if (e.HttpRequestError == HttpRequestError.ProxyTunnelError) return $"ProxyError: {host}";
        return $"Connection error: {e.Message} {host}";
    }

    public static JsonNode Json(byte[] data)
    {
        try { return JsonNode.Parse(data) ?? throw new JsonException(); }
        catch (JsonException)
        {
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unreadable reply: " + Encoding.UTF8.GetString(data, 0, Math.Min(300, data.Length)));
        }
    }

    public static string Prefix(byte[] data, int n = 300) => Encoding.UTF8.GetString(data, 0, Math.Min(n, data.Length));
}

/// <summary>How far the reply to the request under way has come: the characters of the answer received so far (0: the
/// model is still thinking, but alive). Whoever asked sets Sink around the call; providers that read their reply as it
/// arrives report to it.</summary>
public static class StreamProgress
{
    static readonly AsyncLocal<Action<int>?> Current = new();
    public static Action<int>? Sink { get => Current.Value; set => Current.Value = value; }
    public static void Report(int characters) => Current.Value?.Invoke(characters);
}

/// <summary>Parameters Folio adds to a request on its own (a low temperature, a thinking level kept low) are not known to
/// every model and server behind an API: a 400 that turns one down must not stop the translation. The request goes
/// again without it, and what was turned down is remembered while the app runs, so later requests leave it out at once.
/// Parameters the user chose are never dropped this way; their refusal is shown.</summary>
public static class ParameterMemory
{
    static readonly Dictionary<string, HashSet<string>> RefusedBy = [];

    public static HashSet<string> Refused(string key)
    {
        lock (RefusedBy) return RefusedBy.TryGetValue(key, out var names) ? [.. names] : [];
    }

    static void Add(IEnumerable<string> names, string key)
    {
        lock (RefusedBy)
        {
            if (!RefusedBy.TryGetValue(key, out var known)) RefusedBy[key] = known = [];
            known.UnionWith(names);
        }
    }

    static readonly Regex TurnedDown = new(
        "unsupported|not support|unknown|unrecognized|unexpected|invalid|not allowed|not permitted|extra|does not exist|only the default|deprecated|incompatible|cannot be",
        RegexOptions.IgnoreCase);

    /// <summary>The parameter among those sent that a server's answer (the detail of an HTTP 400 or 422) names as the
    /// one it does not take; null when it names none of them.</summary>
    public static string? Rejected(string detail, IEnumerable<string> sent)
    {
        if (!TurnedDown.IsMatch(detail)) return null;
        return sent.OrderByDescending(n => n.Length).FirstOrDefault(n => detail.Contains(n, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Sends a request with the optional parameters extras (by name), as send builds it from those left. On a
    /// 400 or 422 the one the server names goes (or, when it names none, all of them) and the request is sent again;
    /// what worked without them is remembered under key. A request that fails without them as well fails with its
    /// first answer: the parameters were not the reason.</summary>
    public static async Task<byte[]> Send(string key, Dictionary<string, JsonNode?> extras, Func<Dictionary<string, JsonNode?>, Task<byte[]>> send)
    {
        var left = new Dictionary<string, JsonNode?>(extras);
        foreach (var name in Refused(key)) left.Remove(name);
        ProviderError? first = null;
        var dropped = new List<string>();
        while (true)
        {
            try
            {
                var data = await send(left);
                if (dropped.Count > 0) Add(dropped, key);
                return data;
            }
            catch (ProviderError error)
            {
                if (error.Kind != ProviderError.Kinds.Http || error.Status is not (400 or 422) || left.Count == 0)
                {
                    if (first != null) throw first;
                    throw;
                }
                first ??= error;
                var names = Rejected(error.Detail, left.Keys) is { } named ? [named] : left.Keys.ToList();
                foreach (var name in names) left.Remove(name);
                dropped.AddRange(names);
            }
        }
    }
}

/// <summary>A chat model that takes a system prompt and a user message and returns text.</summary>
public abstract class ChatModel : ITranslationProvider
{
    public abstract ProviderLimits Limits { get; }
    public abstract Task<string> Complete(string system, string user, CancellationToken cancel);

    public virtual async Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel)
    {
        var system = LLMBatch.SystemPrompt(context);
        var reply = await Complete(system, LLMBatch.UserMessage(items), cancel);
        var parsed = LLMBatch.Parse(reply, items.Count);
        var missingAll = new ProviderError(ProviderError.Kinds.InvalidResponse, "the reply is missing translations: " + reply[..Math.Min(300, reply.Length)]);
        if (parsed.All(p => p == null))
        {
            if (ProviderError.IsDecline(reply) || ProviderError.IsContentRefusal(reply))
                throw new ProviderError(ProviderError.Kinds.Refused, "declined: " + reply[..Math.Min(300, reply.Length)]);
            throw missingAll;
        }
        // What came back is kept. Only the texts a model left out are asked for again: one skipped of thirty does not
        // make it translate the other twenty-nine a second time.
        for (int round = 0; round < 2 && parsed.Any(p => p == null); round++)
        {
            var missing = Enumerable.Range(0, parsed.Count).Where(i => parsed[i] == null).ToList();
            var more = LLMBatch.Parse(await Complete(system, LLMBatch.UserMessage(missing.Select(i => items[i]).ToList()), cancel), missing.Count);
            for (int k = 0; k < missing.Count; k++) parsed[missing[k]] = more[k];
            if (more.All(m => m == null)) break;
        }
        if (parsed.Any(p => p == null)) throw missingAll;
        return parsed.Select(p => p!).ToList();
    }

    public async Task<List<GlossaryEntry>> ExtractTerms(string excerpt, TranslationContext context, CancellationToken cancel) =>
        LLMBatch.ParseTerms(await Complete(LLMBatch.TermsPrompt(context), excerpt, cancel));
}

/// <summary>OpenAI Chat Completions and the many services compatible with it. `optional` names the body fields
/// (temperature, names in extraBody) that are Folio's own idea, not the user's choice: left out when a model or server
/// turns them down (ParameterMemory).</summary>
public sealed class OpenAIChatProvider(string endpoint, string? apiKey, string model, double? temperature, Dictionary<string, JsonNode?>? extraBody,
                                       Dictionary<string, string>? extraHeaders, ProviderLimits limits, HashSet<string>? optional = null) : ChatModel
{
    public string? ModelName => model;
    public override ProviderLimits Limits => limits;
    public Dictionary<string, JsonNode?> ExtraBody => extraBody ?? [];
    public HashSet<string> Optional => optional ?? [];

    public override async Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        // The reply is read as it is written. A server that cannot do that answers in one piece (or, turning the
        // parameter down, is asked again without it).
        var extras = new Dictionary<string, JsonNode?> { ["stream"] = true };
        var chosen = new Dictionary<string, JsonNode?>();
        if (temperature is { } t) (Optional.Contains("temperature") ? extras : chosen)["temperature"] = t;
        foreach (var (key, value) in extraBody ?? []) (Optional.Contains(key) ? extras : chosen)[key] = value;
        var headers = new Dictionary<string, string>(extraHeaders ?? []);
        if (!string.IsNullOrEmpty(apiKey)) headers["Authorization"] = $"Bearer {apiKey}";
        StringBuilder? written = null;
        string? finish = null;
        var data = await ParameterMemory.Send(endpoint + "|" + model, extras, async left =>
        {
            written = null;
            finish = null;
            var body = new JsonObject
            {
                ["model"] = model,
                ["messages"] = new JsonArray(new JsonObject { ["role"] = "system", ["content"] = system }, new JsonObject { ["role"] = "user", ["content"] = user }),
            };
            foreach (var (key, value) in chosen) body[key] = value?.DeepClone();
            foreach (var (key, value) in left) body[key] = value?.DeepClone();
            if (!body.ContainsKey("stream")) body["stream"] = false;
            return await Http.Stream(Http.Request(endpoint, headers: headers, json: body), payload =>
            {
                if (TryParse(payload) is not { } piece) return;
                if (piece["error"] is { } error) throw StreamFailure(error);
                if (piece["choices"] is not JsonArray { Count: > 0 } pieces || pieces[0] is not JsonObject choice) return;
                if (choice["delta"]?["content"] is JsonValue delta && delta.TryGetValue<string>(out var text)) (written ??= new()).Append(text);
                if (choice["finish_reason"] is JsonValue reason && reason.TryGetValue<string>(out var why)) finish = why;
                // Thinking counts as a sign of life, not as part of the answer.
                StreamProgress.Report(written?.Length ?? 0);
            }, cancel) ?? [];
        });
        string? content = written?.ToString();
        if (data.Length > 0)
        {
            // Answered in one piece.
            if (Http.Json(data) is not JsonObject obj || obj["choices"] is not JsonArray { Count: > 0 } choices || choices[0]?["message"] is not JsonObject message)
                throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply: " + Http.Prefix(data));
            finish = choices[0]?["finish_reason"]?.GetValueKind() == JsonValueKind.String ? choices[0]!["finish_reason"]!.GetValue<string>() : null;
            content = message["content"] switch
            {
                JsonValue v when v.TryGetValue<string>(out var s) => s,
                JsonArray parts => string.Concat(parts.OfType<JsonObject>().Select(p => p["text"]?.GetValue<string>() ?? "")),
                _ => null,
            };
        }
        if (finish is "content_filter" or "safety" && string.IsNullOrWhiteSpace(content))
            throw new ProviderError(ProviderError.Kinds.Refused, $"finish_reason: {finish}");
        // Cut off at the output limit: what is there ends in the middle of a text.
        if (finish == "length")
            throw new ProviderError(ProviderError.Kinds.Truncated, "the reply was cut off at the model's output limit (finish_reason: length)");
        return content ?? throw new ProviderError(ProviderError.Kinds.InvalidResponse, "empty reply");
    }

    internal static JsonObject? TryParse(string json)
    {
        try { return JsonNode.Parse(json) as JsonObject; } catch (JsonException) { return null; }
    }

    static readonly Regex Busy = new("overloaded|rate.?limit|too many requests|capacity|busy", RegexOptions.IgnoreCase);

    /// <summary>An error a server sends in the middle of a stream (the status was already 200).</summary>
    internal static ProviderError StreamFailure(JsonNode error)
    {
        var text = error is JsonObject o && o["message"] is JsonValue m && m.TryGetValue<string>(out var message) ? message : error.ToJsonString();
        if (ProviderError.IsContentRefusal(text)) return new ProviderError(ProviderError.Kinds.Refused, "stream error: " + text);
        return Busy.IsMatch(text) ? ProviderError.HttpStatus(429, "Error code: 429 - " + text)
            : new ProviderError(ProviderError.Kinds.InvalidResponse, "stream error: " + text);
    }

    /// <summary>{base}/chat/completions; a bare host means its /v1.</summary>
    public static string? ChatUrl(string @base)
    {
        var normalized = OpenAIBaseUrl.Normalized(@base);
        var url = normalized.EndsWith("/chat/completions") ? normalized : normalized + "/chat/completions";
        return Uri.TryCreate(url, UriKind.Absolute, out _) ? url : null;
    }
}

/// <summary>Anthropic's Messages API.</summary>
public sealed class AnthropicProvider(string @base, string apiKey, string model, ProviderLimits limits) : ChatModel
{
    public string? ModelName => model;
    public override ProviderLimits Limits => limits;

    public override async Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        var url = @base.TrimEnd('/') + "/v1/messages";
        // Translating needs little deliberation: a low effort answers much sooner. Models from before the parameter
        // (and gateways that do not know it) turn it down, and go without.
        var extras = new Dictionary<string, JsonNode?> { ["output_config"] = new JsonObject { ["effort"] = "low" } };
        var text = new StringBuilder();
        string? stop = null;
        var data = await ParameterMemory.Send(url + "|" + model, extras, async left =>
        {
            text.Clear();
            stop = null;
            // Room for the translation and for the thinking current models do before it (it counts against the limit);
            // the reply is read as it is written, so a long one does not run into a time limit.
            // No temperature: current models take only their default.
            var body = new JsonObject
            {
                ["model"] = model, ["max_tokens"] = 32000, ["system"] = system, ["stream"] = true,
                ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = user }),
            };
            foreach (var (key, value) in left) body[key] = value?.DeepClone();
            return await Http.Stream(Http.Request(url, headers: new() { ["x-api-key"] = apiKey, ["anthropic-version"] = "2023-06-01" }, json: body), payload =>
            {
                if (OpenAIChatProvider.TryParse(payload) is not { } piece) return;
                switch (piece["type"] is JsonValue kind && kind.TryGetValue<string>(out var type) ? type : null)
                {
                    case "content_block_delta":
                        if (piece["delta"] is JsonObject delta && delta["type"]?.GetValue<string>() == "text_delta" && delta["text"] is JsonValue part
                            && part.TryGetValue<string>(out var written)) text.Append(written);
                        StreamProgress.Report(text.Length);
                        break;
                    case "message_delta":
                        if (piece["delta"]?["stop_reason"] is JsonValue reason && reason.TryGetValue<string>(out var why)) stop = why;
                        break;
                    case "error":
                        throw OpenAIChatProvider.StreamFailure(piece["error"] ?? piece);
                }
            }, cancel) ?? [];
        });
        var reply = text.ToString();
        if (data.Length > 0)
        {
            // Answered in one piece (a gateway that does not stream).
            if (Http.Json(data) is not JsonObject obj || obj["content"] is not JsonArray content)
                throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply: " + Http.Prefix(data));
            reply = string.Concat(content.OfType<JsonObject>().Where(c => c["type"]?.GetValue<string>() == "text").Select(c => c["text"]?.GetValue<string>() ?? ""));
            stop = obj["stop_reason"]?.GetValueKind() == JsonValueKind.String ? obj["stop_reason"]!.GetValue<string>() : null;
        }
        if (stop == "refusal") throw new ProviderError(ProviderError.Kinds.Refused, "stop_reason: refusal");
        if (stop == "max_tokens")
            throw new ProviderError(ProviderError.Kinds.Truncated, "the reply was cut off at the model's output limit (stop_reason: max_tokens)");
        return reply;
    }
}

/// <summary>Google's Gemini API.</summary>
public sealed class GeminiProvider(string apiKey, string model, ProviderLimits limits) : ChatModel
{
    public string? ModelName => model;
    public override ProviderLimits Limits => limits;

    /// <summary>How little a model is asked to think before translating, for the models that think by default: Gemini
    /// 2.5 Flash takes a budget (0: none), Gemini 3 and later a level. Other models are told nothing.</summary>
    public static JsonObject? ThinkingConfig(string model)
    {
        var name = model.ToLowerInvariant();
        if (name.Contains("2.5-flash")) return new JsonObject { ["thinkingBudget"] = 0 };
        if (Regex.IsMatch(name, @"gemini-([3-9]|\d{2})")) return new JsonObject { ["thinkingLevel"] = "low" };
        return null;
    }

    public override async Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        var name = model.StartsWith("models/") ? model[7..] : model;
        var url = $"https://generativelanguage.googleapis.com/v1beta/models/{Uri.EscapeDataString(name)}:streamGenerateContent?alt=sse";
        var extras = new Dictionary<string, JsonNode?>();
        if (ThinkingConfig(name) is { } thinking) extras["thinkingConfig"] = thinking;
        var text = new StringBuilder();
        string? finish = null, blocked = null;
        bool answered = false;
        // One answer, or one piece of an answer as it is written.
        void Take(JsonObject piece)
        {
            if (piece["promptFeedback"]?["blockReason"] is JsonValue block && block.TryGetValue<string>(out var reason)) blocked = reason;
            if (piece["candidates"] is not JsonArray { Count: > 0 } candidates || candidates[0] is not JsonObject candidate) return;
            answered = true;
            foreach (var part in (candidate["content"]?["parts"] as JsonArray ?? []).OfType<JsonObject>())
            {
                if (part["thought"] is JsonValue thought && thought.TryGetValue<bool>(out var isThought) && isThought) continue;
                if (part["text"] is JsonValue v && v.TryGetValue<string>(out var s)) text.Append(s);
            }
            if (candidate["finishReason"] is JsonValue f && f.TryGetValue<string>(out var why)) finish = why;
        }
        var data = await ParameterMemory.Send(url, extras, async left =>
        {
            text.Clear();
            finish = blocked = null;
            answered = false;
            var generation = new JsonObject { ["responseMimeType"] = "application/json", ["temperature"] = 0.2 };
            foreach (var (key, value) in left) generation[key] = value?.DeepClone();
            var body = new JsonObject
            {
                ["systemInstruction"] = new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = system }) },
                ["contents"] = new JsonArray(new JsonObject { ["role"] = "user", ["parts"] = new JsonArray(new JsonObject { ["text"] = user }) }),
                ["generationConfig"] = generation,
            };
            return await Http.Stream(Http.Request(url, headers: new() { ["x-goog-api-key"] = apiKey }, json: body), payload =>
            {
                if (OpenAIChatProvider.TryParse(payload) is not { } piece) return;
                if (piece["error"] is { } error) throw OpenAIChatProvider.StreamFailure(error);
                Take(piece);
                StreamProgress.Report(text.Length);
            }, cancel) ?? [];
        });
        if (data.Length > 0)
        {
            // Answered in one piece: one object, or a list of the pieces.
            var json = Http.Json(data);
            foreach (var piece in json is JsonArray list ? list.OfType<JsonObject>() : json is JsonObject one ? [one] : []) Take(piece);
        }
        // Stopped by the content review: before the model saw the text, or while it answered.
        if (blocked != null) throw new ProviderError(ProviderError.Kinds.Refused, $"blockReason: {blocked}");
        var reply = text.ToString();
        if (finish is "SAFETY" or "PROHIBITED_CONTENT" or "BLOCKLIST" or "SPII" or "RECITATION" && string.IsNullOrWhiteSpace(reply))
            throw new ProviderError(ProviderError.Kinds.Refused, $"finishReason: {finish}");
        if (finish == "MAX_TOKENS")
            throw new ProviderError(ProviderError.Kinds.Truncated, "the reply was cut off at the model's output limit (finishReason: MAX_TOKENS)");
        if (!answered || reply.Length == 0) throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply: " + Http.Prefix(data));
        return reply;
    }
}

/// <summary>Azure OpenAI: a deployment URL with an API version, and an api-key header.</summary>
public sealed class AzureOpenAIProvider(string resource, string apiKey, string deployment, string apiVersion, ProviderLimits limits) : ChatModel
{
    public string? ModelName => deployment;
    public override ProviderLimits Limits => limits;

    public override Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        var url = $"{resource.TrimEnd('/')}/openai/deployments/{deployment}/chat/completions?api-version={apiVersion}";
        // A deployment may be a reasoning model, which takes no temperature: sent, and left out when turned down.
        var chat = new OpenAIChatProvider(url, null, deployment, 0.2, null, new() { ["api-key"] = apiKey }, limits, ["temperature"]);
        return chat.Complete(system, user, cancel);
    }
}

/// <summary>A provider with a different number of parallel requests (设置 ▸ 翻译 ▸ 并发数).</summary>
public sealed class ConcurrencyOverride(ITranslationProvider inner, int concurrency) : ITranslationProvider
{
    public ProviderLimits Limits => inner.Limits with { Concurrency = concurrency };
    public Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel) => inner.Translate(items, context, cancel);
    public Task<List<GlossaryEntry>> ExtractTerms(string excerpt, TranslationContext context, CancellationToken cancel) => inner.ExtractTerms(excerpt, context, cancel);
    public Task Prewarm() => inner.Prewarm();
    public string? ModelName => inner.ModelName;
}

/// <summary>OpenAI-style APIs live under /v1: an address given as a bare host means its /v1; one with a path is used as given.</summary>
public static class OpenAIBaseUrl
{
    public static readonly HashSet<string> Options = ["--openai-base-url", "--openai-compatible-base-url"];

    public static string Normalized(string raw)
    {
        var @base = raw.Trim().TrimEnd('/');
        if (!Uri.TryCreate(@base, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host)) return @base;
        return uri.AbsolutePath is "" or "/" ? @base + "/v1" : @base;
    }

    /// <summary>The other spelling to try when listing models.</summary>
    public static string Alternative(string raw)
    {
        var normalized = Normalized(raw);
        var given = raw.Trim().TrimEnd('/');
        if (normalized != given) return given;
        return given.EndsWith("/v1") ? given : given + "/v1";
    }
}
