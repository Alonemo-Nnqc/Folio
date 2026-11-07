using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Engine;

namespace Folio.Core.Translate.Services;

// Port of macos/.../FolioTranslate/Services/MachineProviders.swift (Apple's on-device translation has no Windows counterpart).

/// <summary>Translates items one at a time with a function.</summary>
public abstract class SingleTextProvider : ITranslationProvider
{
    public abstract ProviderLimits Limits { get; }
    public abstract Task<string> TranslateOne(string text, TranslationContext context, CancellationToken cancel);

    public virtual Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel) =>
        TranslateEach(items, context, cancel);

    public async Task<List<string>> TranslateEach(List<TranslationItem> items, TranslationContext context, CancellationToken cancel)
    {
        var results = new List<string>();
        bool cjk = new[] { "zh", "ja", "ko" }.Any(p => context.TargetLanguage.ToLowerInvariant().StartsWith(p));
        foreach (var item in items)
        {
            // Services cap the length of one text: long paragraphs go sentence by sentence.
            var parts = new List<string>();
            foreach (var chunk in Chunks(item.Text, Limits.BatchCharacters)) parts.Add(await TranslateOne(chunk, context, cancel));
            results.Add(string.Join(cjk ? "" : " ", parts));
        }
        return results;
    }

    /// <summary>The text in pieces of at most <paramref name="limit"/> characters, cut after sentences (or words).</summary>
    public static List<string> Chunks(string text, int limit)
    {
        if (text.Length <= limit) return [text];
        var sentences = Regex.Split(text, @"(?<=[.!?。！？])\s+").Select((s, i) => i == 0 ? s : " " + s).ToList();
        var result = new List<string>();
        var current = new StringBuilder();
        void Flush()
        {
            var t = current.ToString().Trim();
            if (t.Length > 0) result.Add(t);
            current.Clear();
        }
        foreach (var sentence in sentences)
        {
            if (current.Length + sentence.Length > limit) Flush();
            if (sentence.Length > limit)
            {
                foreach (var word in sentence.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                {
                    if (current.Length + word.Length + 1 > limit) Flush();
                    if (current.Length > 0) current.Append(' ');
                    current.Append(word);
                }
            }
            else current.Append(sentence);
        }
        Flush();
        return result;
    }
}

public static class LanguageCodes
{
    public static string Google(string code) => code.ToLowerInvariant() switch
    {
        "zh" or "zh-cn" or "zh-hans" => "zh-CN",
        "zh-tw" or "zh-hant" or "zh-hk" => "zh-TW",
        _ => code,
    };

    public static string Microsoft(string code) => code.ToLowerInvariant() switch
    {
        "zh" or "zh-cn" or "zh-hans" => "zh-Hans",
        "zh-tw" or "zh-hant" or "zh-hk" => "zh-Hant",
        _ => code,
    };

    public static string DeepL(string code, bool target) => code.ToLowerInvariant() switch
    {
        "zh" or "zh-cn" or "zh-hans" => target ? "ZH-HANS" : "ZH",
        "zh-tw" or "zh-hant" or "zh-hk" => target ? "ZH-HANT" : "ZH",
        "en" => target ? "EN-US" : "EN",
        "pt" => target ? "PT-PT" : "PT",
        _ => code.ToUpperInvariant(),
    };

    public static string Tencent(string code) => code.ToLowerInvariant() switch
    {
        "zh" or "zh-cn" or "zh-hans" => "zh",
        "zh-tw" or "zh-hant" or "zh-hk" => "zh-TW",
        _ => code,
    };

    public static string Qwen(string code) => code.ToLowerInvariant() switch
    {
        "zh" or "zh-cn" or "zh-hans" => "Chinese",
        "zh-tw" or "zh-hant" or "zh-hk" => "Traditional Chinese",
        _ => LanguageNames.English(code),
    };
}

static class Form
{
    /// <summary>Percent-encodes for a form body (everything but unreserved characters).</summary>
    public static string Encode(string value) => Uri.EscapeDataString(value);
}

/// <summary>Google Translate's public web endpoint (the one browser extensions use).</summary>
public sealed class GoogleWebProvider : SingleTextProvider
{
    public override ProviderLimits Limits { get; } = new(4500, 25, 4, false, 1.5, 0.001);

    string Query(TranslationContext context) =>
        $"client=gtx&sl={LanguageCodes.Google(context.SourceLanguage)}&tl={LanguageCodes.Google(context.TargetLanguage)}&dt=t";

    /// <summary>Several texts in one request (translate_a/t takes any number of q): far fewer requests, far fewer refusals.</summary>
    public override async Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel)
    {
        if (items.Count <= 1) return await TranslateEach(items, context, cancel);
        var request = new HttpRequestMessage(HttpMethod.Post, "https://translate.googleapis.com/translate_a/t?" + Query(context))
        {
            Content = new StringContent(string.Join("&", items.Select(i => "q=" + Form.Encode(i.Text))), Encoding.UTF8, "application/x-www-form-urlencoded"),
        };
        var data = await Http.Send(request, cancel, 60);
        if (Http.Json(data) is JsonArray array && array.Count == items.Count)
        {
            var texts = array.Select(e => e switch
            {
                JsonValue v when v.TryGetValue<string>(out var s) => s,
                JsonArray a when a.Count > 0 && a[0] is JsonValue first && first.TryGetValue<string>(out var s) => s,
                _ => null,
            }).ToList();
            if (texts.All(t => t != null)) return texts!;
        }
        return await TranslateEach(items, context, cancel);
    }

    public override async Task<string> TranslateOne(string text, TranslationContext context, CancellationToken cancel)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, "https://translate.googleapis.com/translate_a/single?" + Query(context))
        {
            Content = new StringContent("q=" + Form.Encode(text), Encoding.UTF8, "application/x-www-form-urlencoded"),
        };
        var data = await Http.Send(request, cancel, 30);
        if (Http.Json(data) is not JsonArray array || array.Count == 0 || array[0] is not JsonArray sentences)
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply from Google");
        return string.Concat(sentences.Select(s => s is JsonArray a && a.Count > 0 && a[0] is JsonValue v && v.TryGetValue<string>(out var t) ? t : ""));
    }
}

/// <summary>Bing Translator's web endpoint (no key): a token from the translator page, then one text per request.</summary>
public sealed class BingWebProvider : SingleTextProvider
{
    public override ProviderLimits Limits { get; } = new(950, 20, 8, false, 1.8, 0.0035);

    sealed record Session(string Ig, string Iid, string Key, string Token, string Host);
    static Session? _session;
    static DateTime _expiry = DateTime.MinValue;
    static readonly object Lock = new();
    const string Agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0";

    /// <summary>Several short texts in one request, a line each; if the lines do not come back one for one, each goes alone.</summary>
    public override async Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel)
    {
        if (items.Count <= 1 || items.Any(i => i.Text.Contains('\n'))) return await TranslateEach(items, context, cancel);
        var reply = await TranslateOne(string.Join("\n", items.Select(i => i.Text)), context, cancel);
        var lines = reply.Split('\n');
        return lines.Length == items.Count ? lines.ToList() : await TranslateEach(items, context, cancel);
    }

    static async Task<Session> FetchSession(CancellationToken cancel)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, "https://www.bing.com/translator");
        request.Headers.TryAddWithoutValidation("User-Agent", Agent);
        var page = Encoding.UTF8.GetString(await Http.Send(request, cancel, 20));
        var ig = Regex.Match(page, @"IG:""([^""]+)""");
        var helper = Regex.Match(page, @"params_AbusePreventionHelper\s*=\s*\[\s*(\d+)\s*,\s*""([^""]+)""");
        if (!ig.Success || !helper.Success) throw new ProviderError(ProviderError.Kinds.InvalidResponse, "Bing translator page changed", "www.bing.com");
        var iid = Regex.Match(page, @"data-iid=""(translator\.\d+)""");
        return new Session(ig.Groups[1].Value, iid.Success ? iid.Groups[1].Value : "translator.5028", helper.Groups[1].Value, helper.Groups[2].Value, "www.bing.com");
    }

    public override async Task<string> TranslateOne(string text, TranslationContext context, CancellationToken cancel)
    {
        Session? session;
        lock (Lock) session = DateTime.UtcNow < _expiry ? _session : null;
        if (session == null)
        {
            session = await FetchSession(cancel);
            lock (Lock) { _session = session; _expiry = DateTime.UtcNow.AddMinutes(20); }
        }
        var form = new Dictionary<string, string>
        {
            ["fromLang"] = LanguageCodes.Microsoft(context.SourceLanguage), ["to"] = LanguageCodes.Microsoft(context.TargetLanguage),
            ["text"] = text, ["token"] = session.Token, ["key"] = session.Key, ["tryFetchingGenderDebiasedTranslations"] = "true",
        };
        var request = new HttpRequestMessage(HttpMethod.Post, $"https://{session.Host}/ttranslatev3?isVertical=1&IG={session.Ig}&IID={session.Iid}")
        {
            Content = new StringContent(string.Join("&", form.Select(kv => $"{kv.Key}={Form.Encode(kv.Value)}")), Encoding.UTF8, "application/x-www-form-urlencoded"),
        };
        request.Headers.TryAddWithoutValidation("User-Agent", Agent);
        var data = await Http.Send(request, cancel, 30);
        try
        {
            if (JsonNode.Parse(data) is JsonArray { Count: > 0 } array && array[0]?["translations"] is JsonArray { Count: > 0 } translations
                && translations[0]?["text"] is JsonValue v && v.TryGetValue<string>(out var result))
                return result;
        }
        catch (JsonException) { }
        // An expired token answers with an error object: fetch a new one next time.
        lock (Lock) _session = null;
        throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply from Bing: " + Http.Prefix(data, 200));
    }
}

/// <summary>The Microsoft Translator v3 API on an Azure resource. Placeholders travel as notranslate spans.</summary>
public sealed class MicrosoftTranslatorProvider(string key, string? region, string endpoint) : ITranslationProvider
{
    public ProviderLimits Limits { get; } = new(9000, 50, 4, false);

    public async Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel)
    {
        var @base = (string.IsNullOrEmpty(endpoint) ? "https://api.cognitive.microsofttranslator.com" : endpoint).TrimEnd('/');
        var headers = new Dictionary<string, string> { ["Ocp-Apim-Subscription-Key"] = key };
        if (!string.IsNullOrEmpty(region)) headers["Ocp-Apim-Subscription-Region"] = region;
        var url = $"{@base}/translate?api-version=3.0&from={LanguageCodes.Microsoft(context.SourceLanguage)}&to={LanguageCodes.Microsoft(context.TargetLanguage)}&textType=html";
        var body = new JsonArray(items.Select(i => (JsonNode)new JsonObject { ["Text"] = Html(i.Text) }).ToArray());
        var data = await Http.Send(Http.Request(url, headers: headers, json: body), cancel, 60);
        if (Http.Json(data) is not JsonArray array || array.Count != items.Count)
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply from Microsoft Translator");
        return array.Select(entry => entry?["translations"] is JsonArray { Count: > 0 } t && t[0]?["text"] is JsonValue v && v.TryGetValue<string>(out var s)
            ? Plain(s) : throw new ProviderError(ProviderError.Kinds.InvalidResponse, "missing translation")).ToList();
    }

    public static string Html(string text)
    {
        var escaped = text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
        return Placeholders.Replace(escaped, n => $"<span class=\"notranslate\">{{v{n}}}</span>");
    }

    public static string Plain(string html)
    {
        var text = Regex.Replace(html, @"<span class=""notranslate"">\s*([^<]*?)\s*</span>", "$1");
        text = Regex.Replace(text, "<[^>]+>", "");
        return text.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&quot;", "\"").Replace("&#39;", "'").Replace("&amp;", "&");
    }
}

/// <summary>DeepL API (Free keys end in ":fx"). Placeholders travel as XML tags DeepL keeps.</summary>
public sealed class DeepLProvider(string key) : ITranslationProvider
{
    public ProviderLimits Limits { get; } = new(25000, 50, 3, false);

    public async Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel)
    {
        var host = key.EndsWith(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com";
        var body = new JsonObject
        {
            ["text"] = new JsonArray(items.Select(i => (JsonNode)Placeholders.Replace(Escape(i.Text), n => $"<x id=\"{n}\"/>")).ToArray()),
            ["target_lang"] = LanguageCodes.DeepL(context.TargetLanguage, true),
            ["source_lang"] = LanguageCodes.DeepL(context.SourceLanguage, false),
            ["tag_handling"] = "xml", ["ignore_tags"] = new JsonArray("x"),
        };
        if (context.Title != null) body["context"] = context.Title;
        var data = await Http.Send(Http.Request(host + "/v2/translate", headers: new() { ["Authorization"] = $"DeepL-Auth-Key {key}" }, json: body), cancel, 90);
        if (Http.Json(data)?["translations"] is not JsonArray translations || translations.Count != items.Count)
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply from DeepL");
        return translations.Select(entry =>
        {
            var text = entry?["text"]?.GetValue<string>() ?? "";
            var restored = Regex.Replace(text, @"<x id=""(\d+)""\s*/>", "{v$1}");
            return restored.Replace("&lt;", "<").Replace("&gt;", ">").Replace("&amp;", "&");
        }).ToList();
    }

    static string Escape(string text) => text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
}

/// <summary>Tencent Cloud Machine Translation (TextTranslateBatch), signed with TC3-HMAC-SHA256.</summary>
public sealed class TencentProvider(string secretId, string secretKey, string region) : ITranslationProvider
{
    public ProviderLimits Limits { get; } = new(5000, 20, 3, false);

    public async Task<List<string>> Translate(List<TranslationItem> items, TranslationContext context, CancellationToken cancel)
    {
        const string host = "tmt.tencentcloudapi.com";
        var body = new JsonObject
        {
            ["Source"] = LanguageCodes.Tencent(context.SourceLanguage), ["Target"] = LanguageCodes.Tencent(context.TargetLanguage),
            ["ProjectId"] = 0, ["SourceTextList"] = new JsonArray(items.Select(i => (JsonNode)i.Text).ToArray()),
        };
        var payload = Encoding.UTF8.GetBytes(body.ToJsonString());
        long timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var date = DateTimeOffset.FromUnixTimeSeconds(timestamp).UtcDateTime.ToString("yyyy-MM-dd");
        static string Sha256(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));
        static byte[] Hmac(byte[] key, string message) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(message));
        var canonical = $"POST\n/\n\ncontent-type:application/json; charset=utf-8\nhost:{host}\nx-tc-action:texttranslatebatch\n\ncontent-type;host;x-tc-action\n" + Sha256(payload);
        var scope = $"{date}/tmt/tc3_request";
        var toSign = $"TC3-HMAC-SHA256\n{timestamp}\n{scope}\n" + Sha256(Encoding.UTF8.GetBytes(canonical));
        var signingKey = Hmac(Hmac(Hmac(Encoding.UTF8.GetBytes("TC3" + secretKey), date), "tmt"), "tc3_request");
        var signature = Convert.ToHexStringLower(Hmac(signingKey, toSign));
        var authorization = $"TC3-HMAC-SHA256 Credential={secretId}/{scope}, SignedHeaders=content-type;host;x-tc-action, Signature={signature}";
        var request = new HttpRequestMessage(HttpMethod.Post, $"https://{host}") { Content = new ByteArrayContent(payload) };
        request.Content.Headers.TryAddWithoutValidation("Content-Type", "application/json; charset=utf-8");
        foreach (var (k, v) in new Dictionary<string, string>
                 {
                     ["X-TC-Action"] = "TextTranslateBatch", ["X-TC-Version"] = "2018-03-21", ["X-TC-Timestamp"] = timestamp.ToString(),
                     ["X-TC-Region"] = region, ["Authorization"] = authorization,
                 })
            request.Headers.TryAddWithoutValidation(k, v);
        var data = await Http.Send(request, cancel, 60);
        if (Http.Json(data)?["Response"] is not JsonObject response)
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply from Tencent Cloud");
        if (response["Error"] is JsonObject error)
        {
            var code = error["Code"]?.GetValue<string>() ?? "";
            int status = code.Contains("AuthFailure") ? 401 : code.Contains("LimitExceeded") || code.Contains("RequestLimit") ? 429 : 400;
            throw ProviderError.HttpStatus(status, $"Error code: {status} - {code}: {error["Message"]?.GetValue<string>() ?? ""}", host);
        }
        if (response["TargetTextList"] is not JsonArray list || list.Count != items.Count)
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "missing translations from Tencent Cloud");
        return list.Select(t => t?.GetValue<string>() ?? "").ToList();
    }
}

/// <summary>Qwen-MT: a translation model behind DashScope's OpenAI-compatible API, with its translation options.</summary>
public sealed class QwenMTProvider(string endpoint, string apiKey, string model, string? domains) : SingleTextProvider
{
    public override ProviderLimits Limits { get; } = new(3000, 1, 6, false);

    public override async Task<string> TranslateOne(string text, TranslationContext context, CancellationToken cancel)
    {
        var options = new JsonObject
        {
            ["source_lang"] = LanguageCodes.Qwen(context.SourceLanguage), ["target_lang"] = LanguageCodes.Qwen(context.TargetLanguage),
        };
        var glossary = context.Glossary.Where(g => text.Contains(g.Source, StringComparison.OrdinalIgnoreCase)).ToList();
        if (glossary.Count > 0)
            options["terms"] = new JsonArray(glossary.Select(g => (JsonNode)new JsonObject { ["source"] = g.Source, ["target"] = g.Target }).ToArray());
        options["domains"] = !string.IsNullOrEmpty(domains) ? domains
            : "The text is from an academic paper. Use formal academic language and the established terminology of the field. Keep placeholders like {v1} unchanged.";
        var body = new JsonObject
        {
            ["model"] = model, ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = text }), ["translation_options"] = options,
        };
        var data = await Http.Send(Http.Request(endpoint, headers: new() { ["Authorization"] = $"Bearer {apiKey}" }, json: body), cancel);
        if (Http.Json(data)?["choices"] is not JsonArray { Count: > 0 } choices || choices[0]?["message"]?["content"] is not JsonValue v || !v.TryGetValue<string>(out var content))
            throw new ProviderError(ProviderError.Kinds.InvalidResponse, "unexpected reply from Qwen-MT");
        return content;
    }
}

/// <summary>A user command: the text on stdin, the translation on stdout (run by cmd.exe on Windows).</summary>
public sealed class CommandProvider(string command, double timeout) : SingleTextProvider
{
    public override ProviderLimits Limits { get; } = new(3000, 1, 4, false);

    public override async Task<string> TranslateOne(string text, TranslationContext context, CancellationToken cancel)
    {
        // The user's own command line, as they would type it: cmd.exe reads it, quotes and all.
        var shell = OperatingSystem.IsWindows() ? new[] { LocalProcess.CommandShell, "/d", "/s", "/c", command } : new[] { "/bin/sh", "-c", command };
        var output = await LocalProcess.Run(shell, text, timeout, cancel);
        return output.Trim();
    }
}
