using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using Folio.Core.Translate;
using Folio.Core.Translate.Layout;
using Folio.Core.Translate.Services;

namespace Folio.Core.Tests;

/// <summary>What the engine does with services that turn parameters down, cut replies off, skip texts or give them
/// back untranslated (the same cases as the macOS suite ServiceAdaptationTests).</summary>
public class ServiceAdaptationTests
{
    static readonly TranslationContext Context = new("en", "zh", null, null, []);
    static readonly ProviderLimits Limits = new(2600, 30, 8, true);

    /// <summary>A chat model answering as the test says.</summary>
    sealed class Scripted(Func<string, string> answer) : ChatModel
    {
        public List<string> Asked = [];
        public override ProviderLimits Limits => ServiceAdaptationTests.Limits;
        public override Task<string> Complete(string system, string user, CancellationToken cancel)
        {
            lock (Asked) Asked.Add(user);
            return Task.FromResult(answer(user));
        }
    }

    [Fact]
    public void RepliesInOtherShapesAreRead()
    {
        Assert.Equal(["甲", "乙"], LLMBatch.Parse("""{"translations": {"1": "甲", "2": "乙"}}""", 2));
        Assert.Equal(["甲", "乙"], LLMBatch.Parse("""["甲", "乙"]""", 2));
        Assert.Equal(["甲", "乙"], LLMBatch.Parse("""{"1": {"translation": "甲"}, "02": "乙"}""", 2));
        Assert.Equal(["甲"], LLMBatch.Parse("```json\n{\"1\": \"甲\"}\n```", 1));
        // A list of another length says nothing about which text is which.
        Assert.Equal([null, null], LLMBatch.Parse("""["甲"]""", 2));
    }

    [Fact]
    public void WhatAModelThoughtAloudIsNotTheAnswer()
    {
        Assert.Equal(["对"], LLMBatch.Parse("<think>Draft: {\"1\": \"wrong\"} — let me use ```json fences```.</think>\n{\"1\": \"对\"}", 1));
        Assert.Equal(["对"], LLMBatch.Parse("reasoning with \"1\": \"draft\" …</think>{\"1\": \"对\"}", 1));
    }

    [Fact]
    public async Task OnlyTheTextsLeftOutAreAskedAgain()
    {
        // Of three texts the second is skipped; asked for alone, it comes.
        var model = new Scripted(user => user.Contains("\"3\"") ? """{"1": "一", "3": "三"}""" : """{"1": "二"}""");
        var items = new[] { "one", "two", "three" }.Select(t => new TranslationItem(t, BlockKind.Paragraph)).ToList();
        Assert.Equal(["一", "二", "三"], await model.Translate(items, Context, CancellationToken.None));
        Assert.Equal(2, model.Asked.Count);
        Assert.Contains("two", model.Asked[1]);
        Assert.DoesNotContain("three", model.Asked[1]);
    }

    [Fact]
    public async Task AParameterTurnedDownIsLeftOutAndRemembered()
    {
        var sent = new List<List<string>>();
        Task<byte[]> Send(Dictionary<string, JsonNode?> extras)
        {
            sent.Add([.. extras.Keys]);
            if (extras.ContainsKey("temperature"))
                throw ProviderError.HttpStatus(400, "Error code: 400 - Unsupported value: 'temperature' does not support 0.2 with this model.");
            return Task.FromResult(Encoding.UTF8.GetBytes("ok"));
        }
        var key = "test://" + Guid.NewGuid();
        var extras = new Dictionary<string, JsonNode?> { ["temperature"] = 0.2, ["reasoning_effort"] = "low" };
        Assert.Equal("ok", Encoding.UTF8.GetString(await ParameterMemory.Send(key, extras, Send)));
        Assert.Equal(2, sent.Count);
        Assert.Equal(["reasoning_effort"], sent[1]);
        // And not sent with it a second time.
        await ParameterMemory.Send(key, extras, Send);
        Assert.Equal(3, sent.Count);
        Assert.Equal(["reasoning_effort"], sent[2]);
    }

    [Fact]
    public async Task AFailureThatIsNotAboutParametersKeepsItsOwnMessage()
    {
        var key = "test://" + Guid.NewGuid();
        var error = await Assert.ThrowsAsync<ProviderError>(() => ParameterMemory.Send(key, new() { ["temperature"] = 0.2 },
            _ => throw ProviderError.HttpStatus(400, "Error code: 400 - This model's maximum context length is 4096 tokens.")));
        Assert.Contains("maximum context length", error.Detail);
        // Nothing was learned about the parameter: the failure had another reason.
        Assert.Empty(ParameterMemory.Refused(key));
    }

    [Fact]
    public void TheNamedParameterGoesFirst()
    {
        Assert.Equal("reasoning_effort", ParameterMemory.Rejected("Error code: 400 - unknown field \"reasoning_effort\"", ["temperature", "reasoning_effort"]));
        Assert.Null(ParameterMemory.Rejected("Error code: 400 - model overloaded", ["temperature"]));
    }

    [Fact]
    public void GeminiIsToldToThinkLittleOnlyWhereItCan()
    {
        Assert.Equal(0, GeminiProvider.ThinkingConfig("gemini-2.5-flash")?["thinkingBudget"]?.GetValue<int>());
        Assert.Equal("low", GeminiProvider.ThinkingConfig("gemini-3-flash-preview")?["thinkingLevel"]?.GetValue<string>());
        Assert.Null(GeminiProvider.ThinkingConfig("gemini-2.5-pro"));
        Assert.Null(GeminiProvider.ThinkingConfig("gemini-2.0-flash"));
    }

    [Fact]
    public void ASentenceGivenBackAsItWentIsNoticed()
    {
        const string source = "Domain generalization aims to train models that work on unseen domains.";
        Assert.True(TranslationJob.IsUntranslated(source, source, "zh"));
        Assert.True(TranslationJob.IsUntranslated("", source, "zh"));
        Assert.True(TranslationJob.IsUntranslated("Domain generalization aims at training models.", source, "zh"));
        Assert.False(TranslationJob.IsUntranslated("域泛化旨在训练在未见域上有效的模型。", source, "zh"));
        // Names and short labels may well stay as they are.
        Assert.False(TranslationJob.IsUntranslated("ResNet-50", "ResNet-50", "zh"));
        Assert.False(TranslationJob.IsUntranslated("ImageNet Top-1", "ImageNet Top-1", "zh"));
        // Into a language in the same script, only the very same text counts.
        Assert.True(TranslationJob.IsUntranslated(source, source, "fr"));
        Assert.False(TranslationJob.IsUntranslated("La généralisation de domaine vise à entraîner des modèles.", source, "fr"));
    }

    [Fact]
    public void TheUsualLowLevelIsFoliosOwnIdea()
    {
        var provider = ProviderFactory.Make("openai", new Dictionary<string, string> { ["--openai-model"] = "gpt-5" },
                                            new Dictionary<string, string> { ["--openai-api-key"] = "k" }, null);
        var chat = Assert.IsType<OpenAIChatProvider>(provider);
        Assert.Equal("low", chat.ExtraBody["reasoning_effort"]?.GetValue<string>());
        Assert.Contains("reasoning_effort", chat.Optional);
        var chosen = Assert.IsType<OpenAIChatProvider>(ProviderFactory.Make("openai",
            new Dictionary<string, string> { ["--openai-model"] = "gpt-5", ["--openai-reasoning-effort"] = "high" },
            new Dictionary<string, string> { ["--openai-api-key"] = "k" }, null));
        Assert.Equal("high", chosen.ExtraBody["reasoning_effort"]?.GetValue<string>());
        Assert.DoesNotContain("reasoning_effort", chosen.Optional);
    }

    /// <summary>Chat Completions on this machine's loopback address: one request, answered as the test says.</summary>
    static async Task<(string Url, Task<List<string>> Bodies)> Serve(Func<string, (int Status, string Json)> answer, int requests)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var bodies = Task.Run(async () =>
        {
            var seen = new List<string>();
            for (int n = 0; n < requests; n++)
            {
                using var client = await listener.AcceptTcpClientAsync();
                var stream = client.GetStream();
                var buffer = new List<byte>();
                var chunk = new byte[65536];
                int headerEnd = -1, length = 0;
                while (true)
                {
                    int read = await stream.ReadAsync(chunk);
                    if (read <= 0) break;
                    buffer.AddRange(chunk.AsSpan(0, read).ToArray());
                    var text = Encoding.UTF8.GetString(buffer.ToArray());
                    if (headerEnd < 0)
                    {
                        headerEnd = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                        if (headerEnd < 0) continue;
                        var line = text[..headerEnd].Split("\r\n").FirstOrDefault(l => l.StartsWith("content-length:", StringComparison.OrdinalIgnoreCase));
                        length = line == null ? 0 : int.Parse(line.Split(':')[1].Trim());
                    }
                    if (buffer.Count - Encoding.UTF8.GetByteCount(text[..(headerEnd + 4)]) >= length) break;
                }
                var all = Encoding.UTF8.GetString(buffer.ToArray());
                var body = all[(headerEnd + 4)..];
                seen.Add(body);
                var (status, json) = answer(body);
                var payload = Encoding.UTF8.GetBytes(json);
                var head = Encoding.UTF8.GetBytes($"HTTP/1.1 {status} {(status == 200 ? "OK" : "Error")}\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(head);
                await stream.WriteAsync(payload);
                await stream.FlushAsync();
            }
            listener.Stop();
            return seen;
        });
        return ($"http://127.0.0.1:{port}/v1/chat/completions", bodies);
    }

    static string Chat(string content, string finish = "stop") =>
        new JsonObject { ["choices"] = new JsonArray(new JsonObject { ["message"] = new JsonObject { ["role"] = "assistant", ["content"] = content }, ["finish_reason"] = finish }) }.ToJsonString();

    [Fact]
    public async Task AModelThatTakesNoTemperatureStillTranslates()
    {
        var (url, bodies) = await Serve(body => body.Contains("\"temperature\"")
            ? (400, """{"error": {"message": "Unsupported value: 'temperature' does not support 0.2 with this model."}}""")
            : (200, Chat("""{"1": "好"}""")), 2);
        var provider = new OpenAIChatProvider(url, "k", "m", 0.2, null, null, Limits, ["temperature"]);
        Assert.Equal(["好"], await provider.Translate([new TranslationItem("fine", BlockKind.Paragraph)], Context, CancellationToken.None));
        var seen = await bodies;
        Assert.Contains("\"temperature\"", seen[0]);
        Assert.DoesNotContain("\"temperature\"", seen[1]);
    }

    [Fact]
    public async Task AReplyCutOffIsToldFromAnUnreadableOne()
    {
        var (url, _) = await Serve(_ => (200, Chat("""{"1": "被截""", "length")), 1);
        var provider = new OpenAIChatProvider(url, "k", "m", null, null, null, Limits);
        var error = await Assert.ThrowsAsync<ProviderError>(() => provider.Translate([new TranslationItem("one", BlockKind.Paragraph)], Context, CancellationToken.None));
        Assert.Equal(ProviderError.Kinds.Truncated, error.Kind);
        Assert.False(error.IsRetryable);
    }
}

/// <summary>Replies are read as they are written, and what a translation will take is said before it starts.</summary>
public class StreamingAndEstimateTests
{
    static readonly TranslationContext Context = new("en", "zh", null, null, []);
    static readonly ProviderLimits Limits = new(2600, 30, 8, true);

    /// <summary>One request, answered as an event stream: the lines, a moment apart.</summary>
    static (string Url, Task Done) ServeEvents(string path, params string[] lines)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var done = Task.Run(async () =>
        {
            using var client = await listener.AcceptTcpClientAsync();
            var stream = client.GetStream();
            var buffer = new byte[65536];
            var text = "";
            // The whole request: its head, then as many bytes as it says.
            while (true)
            {
                int read = await stream.ReadAsync(buffer);
                if (read <= 0) break;
                text += Encoding.UTF8.GetString(buffer, 0, read);
                int head = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                if (head < 0) continue;
                var length = text[..head].Split("\r\n").FirstOrDefault(l => l.StartsWith("content-length:", StringComparison.OrdinalIgnoreCase));
                if (Encoding.UTF8.GetByteCount(text[(head + 4)..]) >= (length == null ? 0 : int.Parse(length.Split(':')[1].Trim()))) break;
            }
            await stream.WriteAsync(Encoding.UTF8.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"));
            foreach (var line in lines)
            {
                await stream.WriteAsync(Encoding.UTF8.GetBytes(line + "\n\n"));
                await stream.FlushAsync();
                await Task.Delay(20);
            }
            listener.Stop();
        });
        return ($"http://127.0.0.1:{port}{path}", done);
    }

    static string Delta(string content) =>
        "data: " + new JsonObject { ["choices"] = new JsonArray(new JsonObject { ["delta"] = new JsonObject { ["content"] = content } }) }.ToJsonString();

    [Fact]
    public async Task AReplyIsReadAsItIsWritten()
    {
        // In the middle of a text: a character Unicode calls a line end, which is not the end of an event.
        var (url, done) = ServeEvents("/v1/chat/completions", Delta("{\"1\": \"流式"), Delta("回复\u2028第二行"), Delta("\", \"2\": \"另"), Delta("一段\"}"),
            """data: {"choices": [{"delta": {}, "finish_reason": "stop"}]}""", "data: [DONE]");
        var provider = new OpenAIChatProvider(url, "k", "m", null, null, null, Limits);
        var seen = new List<int>();
        StreamProgress.Sink = n => { lock (seen) seen.Add(n); };
        var texts = await provider.Translate([new TranslationItem("one", BlockKind.Paragraph), new TranslationItem("two", BlockKind.Paragraph)], Context, CancellationToken.None);
        StreamProgress.Sink = null;
        await done;
        Assert.Equal(["流式回复\u2028第二行", "另一段"], texts);
        Assert.True(seen.Count >= 4 && seen.SequenceEqual(seen.OrderBy(n => n)) && seen[^1] > seen[0], string.Join(",", seen));
    }

    [Fact]
    public async Task AnErrorInTheMiddleOfAStreamIsAnError()
    {
        var (url, _) = ServeEvents("/v1/chat/completions", Delta("{\"1\": \"半"), """data: {"error": {"message": "The engine is currently overloaded"}}""");
        var provider = new OpenAIChatProvider(url, "k", "m", null, null, null, Limits);
        var error = await Assert.ThrowsAsync<ProviderError>(() => provider.Translate([new TranslationItem("one", BlockKind.Paragraph)], Context, CancellationToken.None));
        Assert.True(error.Kind == ProviderError.Kinds.Http && error.Status == 429 && error.IsRetryable);
    }

    [Fact]
    public async Task ClaudeStreamsItsReplyToo()
    {
        var (url, _) = ServeEvents("/v1/messages",
            "event: message_start", """data: {"type": "message_start", "message": {"content": []}}""",
            """data: {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "hm"}}""",
            """data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "{\"1\": \"克劳"}}""",
            """data: {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "德\"}"}}""",
            """data: {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}""", """data: {"type": "message_stop"}""");
        var provider = new AnthropicProvider(url[..^"/v1/messages".Length], "k", "claude-test", Limits);
        Assert.Equal(["克劳德"], await provider.Translate([new TranslationItem("one", BlockKind.Paragraph)], Context, CancellationToken.None));
    }

    [Fact]
    public void PricesGoByTheModelsName()
    {
        Assert.Equal(0.25, TranslationPricing.Price("gpt-5-mini")?.Input);
        Assert.Equal(4.50, TranslationPricing.Price("openai/gpt-5.4-mini-2026-03-01")?.Output);
        Assert.Equal(2.50, TranslationPricing.Price("gpt-5.4")?.Input);
        Assert.Equal(0.50, TranslationPricing.Price("claude-haiku-5-5")?.Output);
        Assert.Null(TranslationPricing.Price("some-local-model"));
    }

    [Fact]
    public void EstimatesAreSaidInALine()
    {
        Loc.Override = "zh-Hans";
        Assert.Null(TranslationEstimator.Text(new TranslationEstimate()));
        Assert.Contains("缓存", TranslationEstimator.Text(new TranslationEstimate { TotalCharacters = 900 }));
        Assert.Contains("3.1 万", TranslationEstimator.Text(new TranslationEstimate { Characters = 31_000, TotalCharacters = 31_000, ByCharacter = true }));
        var paid = TranslationEstimator.Text(new TranslationEstimate { Characters = 30_000, TotalCharacters = 30_000, InputTokens = 18_400, OutputTokens = 12_000, Cost = 0.0312 });
        Assert.Contains("1.8 万", paid);
        Assert.Contains("$0.03", paid);
        Assert.Contains("0.01", TranslationEstimator.Text(new TranslationEstimate { Characters = 900, TotalCharacters = 900, InputTokens = 1200, OutputTokens = 500, Cost = 0.0004 }));
        Assert.DoesNotContain("$", TranslationEstimator.Text(new TranslationEstimate { Characters = 900, TotalCharacters = 900, InputTokens = 1200, OutputTokens = 500 }));
    }
}
