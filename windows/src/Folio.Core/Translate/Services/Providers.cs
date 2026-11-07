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
public sealed record TranslationContext(string SourceLanguage, string TargetLanguage, string? Title, string? Summary, List<GlossaryEntry> Glossary);

/// <summary>One text to translate and what kind of text it is.</summary>
public sealed record TranslationItem(string Text, BlockKind Kind)
{
    public bool IsShort => Kind is BlockKind.Heading or BlockKind.TableCell or BlockKind.Title;
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
}

/// <summary>Why a request failed. Detail is what the error classifier reads.</summary>
public sealed class ProviderError : Exception
{
    public enum Kinds { Http, Network, InvalidResponse, Cancelled, Process, AgentSetup, Refused }

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
        - Each value is one piece of text; keep it one piece (no line breaks).
        """);
        prompt.Replace("\r\n", "\n");
        if (!string.IsNullOrEmpty(context.Title)) prompt.Append($"\n\nPaper title: {context.Title}");
        if (!string.IsNullOrEmpty(context.Summary)) prompt.Append($"\nAbstract: {context.Summary[..Math.Min(1500, context.Summary.Length)]}");
        if (context.Glossary.Count > 0)
            prompt.Append($"\n\nGlossary ({source} → {target}):\n").Append(string.Join("\n", context.Glossary.Select(g => $"- {g.Source} → {g.Target}")));
        return prompt.ToString();
    }

    static readonly JsonSerializerOptions Unescaped = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>The user message: {"1": "…", "2": "…"} in reading order, with a note on which items are short.</summary>
    public static string UserMessage(List<TranslationItem> items)
    {
        string Json(string s) => JsonSerializer.Serialize(s, Unescaped);
        var message = "{" + string.Join(", ", items.Select((item, i) => $"{Json((i + 1).ToString())}: {Json(item.Text)}")) + "}";
        var shortItems = items.Select((item, i) => (item, i)).Where(p => p.item.IsShort).Select(p => (p.i + 1).ToString()).ToList();
        if (shortItems.Count > 0) message += "\n\nShort items (headings or table cells): " + string.Join(", ", shortItems);
        return message;
    }

    /// <summary>Reads the reply. Missing keys come back as null.</summary>
    public static List<string?> Parse(string reply, int count)
    {
        var obj = JsonObjectIn(reply) ?? LenientObject(reply);
        if (obj == null) return Enumerable.Repeat<string?>(null, count).ToList();
        return Enumerable.Range(1, count).Select(key =>
        {
            if (!obj.TryGetPropertyValue(key.ToString(), out var value) || value == null) return null;
            return value is JsonValue v && v.TryGetValue<string>(out var s) ? s : value.ToJsonString();
        }).ToList();
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
        You build glossaries for translating academic papers into {{target}}. From the excerpt the user sends, pick the technical terms whose translation must stay consistent (concepts, task names, phrases of the field), at most 40, and give the established {{target}} translation of each.
        Leave out names of models, methods, datasets, metrics and software, and abbreviations, which stay untranslated.
        Reply with only JSON: {"terms": [{"source": "...", "target": "..."}]}
        """.Replace("\r\n", "\n");
    }

    public static List<GlossaryEntry> ParseTerms(string reply)
    {
        if (JsonObjectIn(reply)?["terms"] is not JsonArray terms) return [];
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
    public static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        MaxConnectionsPerServer = 16,
        AutomaticDecompression = DecompressionMethods.All,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    })
    { Timeout = Timeout.InfiniteTimeSpan };

    public static HttpRequestMessage Request(string url, HttpMethod? method = null, Dictionary<string, string>? headers = null, JsonNode? json = null)
    {
        var request = new HttpRequestMessage(method ?? HttpMethod.Post, url);
        foreach (var (key, value) in headers ?? []) request.Headers.TryAddWithoutValidation(key, value);
        if (json != null) request.Content = new StringContent(json.ToJsonString(), Encoding.UTF8, "application/json");
        return request;
    }

    public static async Task<byte[]> Send(HttpRequestMessage request, CancellationToken cancel, double timeoutSeconds = 180)
    {
        var uri = request.RequestUri!;
        string host = uri.IsDefaultPort ? uri.Host : $"{uri.Host}:{uri.Port}";
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        try
        {
            using var response = await Client.SendAsync(request, timeout.Token);
            var data = await response.Content.ReadAsByteArrayAsync(timeout.Token);
            int status = (int)response.StatusCode;
            if (status is < 200 or >= 300)
            {
                var body = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 2000));
                bool refused = status is 400 or 403 or 422 or 451 && ProviderError.IsContentRefusal(body);
                double? retry = response.Headers.RetryAfter?.Delta?.TotalSeconds;
                if (refused) throw new ProviderError(ProviderError.Kinds.Refused, $"Error code: {status} - {body}", host) { RetryAfter = retry };
                throw new ProviderError(ProviderError.Kinds.Http, $"Error code: {status} - {body}", host, status) { RetryAfter = retry };
            }
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

/// <summary>A chat model that takes a system prompt and a user message and returns text.</summary>
public abstract class ChatModel : ITranslationProvider
{
    public abstract ProviderLimits Limits { get; }
    public abstract Task<string> Complete(string system, string user, CancellationToken cancel);

    public virtual async Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel)
    {
        var reply = await Complete(LLMBatch.SystemPrompt(context), LLMBatch.UserMessage(items), cancel);
        var parsed = LLMBatch.Parse(reply, items.Count);
        if (parsed.All(p => p == null) && (ProviderError.IsDecline(reply) || ProviderError.IsContentRefusal(reply)))
            throw new ProviderError(ProviderError.Kinds.Refused, "declined: " + reply[..Math.Min(300, reply.Length)]);
        if (parsed.Any(p => p == null))
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "the reply is missing translations: " + reply[..Math.Min(300, reply.Length)]);
        return parsed.Select(p => p!).ToList();
    }

    public async Task<List<GlossaryEntry>> ExtractTerms(string excerpt, TranslationContext context, CancellationToken cancel) =>
        LLMBatch.ParseTerms(await Complete(LLMBatch.TermsPrompt(context), excerpt, cancel));
}

/// <summary>OpenAI Chat Completions and the many services compatible with it.</summary>
public sealed class OpenAIChatProvider(string endpoint, string? apiKey, string model, double? temperature, Dictionary<string, JsonNode?>? extraBody,
                                       Dictionary<string, string>? extraHeaders, ProviderLimits limits) : ChatModel
{
    public override ProviderLimits Limits => limits;

    public override async Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "system", ["content"] = system }, new JsonObject { ["role"] = "user", ["content"] = user }),
            ["stream"] = false,
        };
        if (temperature is { } t) body["temperature"] = t;
        foreach (var (key, value) in extraBody ?? []) body[key] = value?.DeepClone();
        var headers = new Dictionary<string, string>(extraHeaders ?? []);
        if (!string.IsNullOrEmpty(apiKey)) headers["Authorization"] = $"Bearer {apiKey}";
        var data = await Http.Send(Http.Request(endpoint, headers: headers, json: body), cancel);
        if (Http.Json(data) is not JsonObject obj || obj["choices"] is not JsonArray { Count: > 0 } choices || choices[0]?["message"] is not JsonObject message)
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply: " + Http.Prefix(data));
        var finish = choices[0]?["finish_reason"]?.GetValueKind() == JsonValueKind.String ? choices[0]!["finish_reason"]!.GetValue<string>() : null;
        string? content = message["content"] switch
        {
            JsonValue v when v.TryGetValue<string>(out var s) => s,
            JsonArray parts => string.Concat(parts.OfType<JsonObject>().Select(p => p["text"]?.GetValue<string>() ?? "")),
            _ => null,
        };
        if (finish is "content_filter" or "safety" && string.IsNullOrWhiteSpace(content))
            throw new ProviderError(ProviderError.Kinds.Refused, $"finish_reason: {finish}");
        return content ?? throw new ProviderError(ProviderError.Kinds.InvalidResponse, "empty reply");
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
    public override ProviderLimits Limits => limits;

    public override async Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        var body = new JsonObject
        {
            ["model"] = model, ["max_tokens"] = 8192, ["system"] = system,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = user }),
        };
        var data = await Http.Send(Http.Request(@base.TrimEnd('/') + "/v1/messages",
            headers: new() { ["x-api-key"] = apiKey, ["anthropic-version"] = "2023-06-01" }, json: body), cancel);
        if (Http.Json(data) is not JsonObject obj || obj["content"] is not JsonArray content)
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply: " + Http.Prefix(data));
        return string.Concat(content.OfType<JsonObject>().Where(c => c["type"]?.GetValue<string>() == "text").Select(c => c["text"]?.GetValue<string>() ?? ""));
    }
}

/// <summary>Google's Gemini API.</summary>
public sealed class GeminiProvider(string apiKey, string model, ProviderLimits limits) : ChatModel
{
    public override ProviderLimits Limits => limits;

    public override async Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        var name = model.StartsWith("models/") ? model[7..] : model;
        var body = new JsonObject
        {
            ["systemInstruction"] = new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = system }) },
            ["contents"] = new JsonArray(new JsonObject { ["role"] = "user", ["parts"] = new JsonArray(new JsonObject { ["text"] = user }) }),
            ["generationConfig"] = new JsonObject { ["responseMimeType"] = "application/json", ["temperature"] = 0.2 },
        };
        var data = await Http.Send(Http.Request($"https://generativelanguage.googleapis.com/v1beta/models/{Uri.EscapeDataString(name)}:generateContent",
            headers: new() { ["x-goog-api-key"] = apiKey }, json: body), cancel);
        if (Http.Json(data) is not JsonObject obj || obj["candidates"] is not JsonArray { Count: > 0 } candidates
            || candidates[0]?["content"]?["parts"] is not JsonArray parts)
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply: " + Http.Prefix(data));
        return string.Concat(parts.OfType<JsonObject>().Select(p => p["text"]?.GetValue<string>() ?? ""));
    }
}

/// <summary>Azure OpenAI: a deployment URL with an API version, and an api-key header.</summary>
public sealed class AzureOpenAIProvider(string resource, string apiKey, string deployment, string apiVersion, ProviderLimits limits) : ChatModel
{
    public override ProviderLimits Limits => limits;

    public override Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        var url = $"{resource.TrimEnd('/')}/openai/deployments/{deployment}/chat/completions?api-version={apiVersion}";
        var chat = new OpenAIChatProvider(url, null, deployment, null, null, new() { ["api-key"] = apiKey }, limits);
        return chat.Complete(system, user, cancel);
    }
}

/// <summary>A provider with a different number of parallel requests (设置 ▸ 翻译 ▸ 并发数).</summary>
public sealed class ConcurrencyOverride(ITranslationProvider inner, int concurrency) : ITranslationProvider
{
    public ProviderLimits Limits => inner.Limits with { Concurrency = concurrency };
    public Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel) => inner.Translate(items, context, cancel);
    public Task<List<GlossaryEntry>> ExtractTerms(string excerpt, TranslationContext context, CancellationToken cancel) => inner.ExtractTerms(excerpt, context, cancel);
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
