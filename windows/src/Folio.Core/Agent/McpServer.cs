using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;

namespace Folio.Core.Agent;

// Ports of MCPServer.swift, StdioTransport.swift, MCPPrompts.swift and MCPSelfCheck.swift.

/// <summary>A Model Context Protocol server over stdio exposing the library tools and prompts. Serves both the modern
/// era (version in every request's _meta, server/discover) and the legacy one (initialize handshake). Requests run
/// concurrently and can be cancelled with notifications/cancelled.</summary>
public sealed class McpServer(LibraryToolbox toolbox)
{
    public static readonly string[] ModernVersions = ["2026-07-28"];
    public static readonly string[] LegacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
    public static string[] SupportedProtocolVersions => [.. ModernVersions, .. LegacyVersions];
    public const string ServerVersion = "2.6";
    const string VersionKey = "io.modelcontextprotocol/protocolVersion";
    const string ServerInfoKey = "io.modelcontextprotocol/serverInfo";
    static JsonObject ServerInfo => new() { ["name"] = "folio", ["title"] = "Folio 文献库", ["version"] = ServerVersion };

    readonly ConcurrentDictionary<string, CancellationTokenSource> _running = new();
    readonly ConcurrentDictionary<string, bool> _cancelled = new();
    readonly SemaphoreSlim _toolboxLock = new(1, 1);
    volatile bool _legacySession;
    bool? _lastListedWrites;
    readonly object _stateLock = new();

    public const string Instructions =
        "Folio is the user's reference manager on Windows (like Zotero): their papers, PDFs, highlights and notes. " +
        "Everything you say about the user's library must come from these tools — never invent papers or citation details. " +
        "Find papers with search_library (2–4 distinctive keywords; retry with other words, filters such as author / " +
        "year_from, or include_fulltext), confirm with get_item, read with read_fulltext (use `query` to jump to the " +
        "relevant passages) and get_annotations, cite with format_citations (copy the text exactly as returned) and " +
        "export with export_references. Add or organise papers only when the user asks. Ask before delete_tag, " +
        "delete_group and move_to_trash. Item references can be ids from results, DOIs or citation keys.";

    /// <summary>Serves stdin / stdout until stdin closes. Protocol output goes to the original stdout only; anything
    /// else written to Console.Out goes to stderr, so a stray print can never corrupt the stream.</summary>
    public async Task Run()
    {
        var output = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
        Console.SetOut(Console.Error);
        var writeLock = new SemaphoreSlim(1, 1);
        async Task Send(JsonNode message)
        {
            await writeLock.WaitAsync();
            try { await output.WriteLineAsync(Json.WireLine(message)); }
            catch (IOException) { }
            finally { writeLock.Release(); }
        }
        Log($"Folio MCP server {ServerVersion} started");
        using var stop = new CancellationTokenSource();
        var watcher = Task.Run(() => WatchToolList(Send, stop.Token));
        var tasks = new List<Task>();
        await foreach (var line in Lines(Console.OpenStandardInput()))
            tasks.Add(Task.Run(async () => { if (await Receive(line) is { } response) await Send(response); }));
        await Task.WhenAll(tasks);
        stop.Cancel();
        try { await watcher; } catch { }
    }

    /// <summary>Lines split on LF bytes only (U+2028 may appear raw inside JSON strings).</summary>
    public static async IAsyncEnumerable<string> Lines(Stream input)
    {
        var buffer = new byte[65536];
        var line = new MemoryStream();
        int n;
        while ((n = await input.ReadAsync(buffer)) > 0)
        {
            int start = 0;
            for (int i = 0; i < n; i++)
            {
                if (buffer[i] != (byte)'\n') continue;
                line.Write(buffer, start, i - start);
                start = i + 1;
                var bytes = line.ToArray();
                line.SetLength(0);
                int length = bytes.Length > 0 && bytes[^1] == (byte)'\r' ? bytes.Length - 1 : bytes.Length;
                if (length > 0) yield return Encoding.UTF8.GetString(bytes, 0, length);
            }
            line.Write(buffer, start, n - start);
        }
        if (line.Length > 0) yield return Encoding.UTF8.GetString(line.ToArray());
    }

    public static void Log(string text) => Console.Error.WriteLine($"[folio-mcp] {text}");

    /// <summary>Handles one line; returns the response (null for notifications, responses and cancelled requests).</summary>
    public async Task<JsonNode?> Receive(string line)
    {
        JsonNode? message;
        try { message = JsonNode.Parse(line); }
        catch { return Error(null, -32700, "Parse error"); }
        if (message is JsonArray batch)
        {
            var responses = new JsonArray();
            foreach (var entry in batch) if (await Response(entry) is { } r) responses.Add(r);
            return responses.Count > 0 ? responses : null;
        }
        return await Response(message);
    }

    async Task<JsonNode?> Response(JsonNode? message)
    {
        if (message?["method"].Str() is not { } method) return null;
        var parameters = message["params"] as JsonObject ?? [];
        var id = message["id"];
        if (id == null || id.GetValueKind() == System.Text.Json.JsonValueKind.Null)
        {
            Notification(method, parameters);
            return null;
        }
        var key = id.ToJsonString();
        using var cancel = new CancellationTokenSource();
        _running[key] = cancel;
        try
        {
            var response = await Handle(method, parameters, id.DeepClone(), cancel.Token);
            return _cancelled.TryRemove(key, out _) ? null : response;
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            _cancelled.TryRemove(key, out _);
            return null;
        }
        finally { _running.TryRemove(key, out _); }
    }

    void Notification(string method, JsonObject parameters)
    {
        switch (method)
        {
            case "notifications/cancelled":
                if (parameters["requestId"] is { } requestId && _running.TryGetValue(requestId.ToJsonString(), out var cts))
                {
                    _cancelled[requestId.ToJsonString()] = true;
                    cts.Cancel();
                }
                break;
            case "notifications/initialized":
                _legacySession = true;
                break;
        }
    }

    async Task<T> WithToolbox<T>(Func<T> body)
    {
        await _toolboxLock.WaitAsync();
        try { toolbox.Refresh(); return body(); }
        finally { _toolboxLock.Release(); }
    }

    async Task<JsonNode> Handle(string method, JsonObject parameters, JsonNode id, CancellationToken cancel)
    {
        var requested = parameters["_meta"]?[VersionKey].Str();
        bool modern = requested != null;
        if (requested != null && !SupportedProtocolVersions.Contains(requested))
            return Error(id, -32022, "Unsupported protocol version",
                new JsonObject { ["supported"] = Json.Strings(SupportedProtocolVersions), ["requested"] = requested });
        JsonNode Reply(JsonObject result, bool cacheable = false)
        {
            if (modern)
            {
                result["resultType"] = "complete";
                var meta = result["_meta"] as JsonObject ?? [];
                meta[ServerInfoKey] = ServerInfo;
                result["_meta"] = meta;
                if (cacheable)
                {
                    result["ttlMs"] = 30_000;
                    result["cacheScope"] = "private";
                }
            }
            return new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(), ["result"] = result };
        }

        switch (method)
        {
            case "initialize":
            {
                var asked = parameters["protocolVersion"].Str() ?? LegacyVersions[0];
                var version = LegacyVersions.Contains(asked) ? asked : LegacyVersions[0];
                var writes = await WithToolbox(() => toolbox.Configuration.AllowWrites);
                _legacySession = true;
                lock (_stateLock) _lastListedWrites = writes;
                return Reply(new JsonObject
                {
                    ["protocolVersion"] = version,
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = true }, ["prompts"] = new JsonObject { ["listChanged"] = false } },
                    ["serverInfo"] = ServerInfo, ["instructions"] = Instructions,
                });
            }
            case "server/discover":
                return Reply(new JsonObject
                {
                    ["supportedVersions"] = Json.Strings(SupportedProtocolVersions),
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject(), ["prompts"] = new JsonObject() },
                    ["instructions"] = Instructions,
                }, true);
            case "ping" or "logging/setLevel":
                return Reply([]);
            case "tools/list":
            {
                var (tools, writes) = await WithToolbox(() => (toolbox.Tools.Select(t => (JsonNode)t.McpDescription).ToList(), toolbox.Configuration.AllowWrites));
                lock (_stateLock) _lastListedWrites = writes;
                return Reply(new JsonObject { ["tools"] = new JsonArray([.. tools]) }, true);
            }
            case "tools/call":
            {
                if (parameters["name"].Str() is not { } name) return Error(id, -32602, "Missing tool name");
                if (ToolCatalog.Tool(name) == null) return Error(id, -32602, $"Unknown tool: {name}. Call tools/list for the available tools.");
                try
                {
                    await WithToolbox(() => 0);
                    var output = await toolbox.Call(name, parameters["arguments"]?.DeepClone(), cancel);
                    cancel.ThrowIfCancellationRequested();
                    return Reply(new JsonObject
                    {
                        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = Json.Encode(Json.Pruned(output)) }), ["isError"] = false,
                    });
                }
                catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw; }
                catch (Exception e)
                {
                    // Tool failures go back to the model (isError) so it can correct itself.
                    return Reply(new JsonObject { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = e.Message }), ["isError"] = true });
                }
            }
            case "prompts/list":
                return Reply(new JsonObject { ["prompts"] = new JsonArray([.. McpPrompts.All.Select(p => (JsonNode)p.ListEntry)]) }, true);
            case "prompts/get":
            {
                var name = parameters["name"].Str();
                if (name == null || McpPrompts.Prompt(name) is not { } prompt) return Error(id, -32602, $"Unknown prompt: {name ?? ""}");
                try { return Reply(prompt.Messages(parameters["arguments"] as JsonObject ?? [])); }
                catch (ToolError e) { return Error(id, -32602, e.Message); }
            }
            case "resources/list":
                return Reply(new JsonObject { ["resources"] = new JsonArray() }, true);
            case "resources/templates/list":
                return Reply(new JsonObject { ["resourceTemplates"] = new JsonArray() }, true);
            default:
                return Error(id, -32601, $"Method not found: {method}");
        }
    }

    /// <summary>Legacy sessions are told when 设置 ▸ AI ▸ 允许 AI 修改文献库 changes the tool list.</summary>
    async Task WatchToolList(Func<JsonNode, Task> send, CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            try { await Task.Delay(3000, stop); } catch (OperationCanceledException) { return; }
            if (!_legacySession) continue;
            var writes = await WithToolbox(() => toolbox.Configuration.AllowWrites);
            bool changed;
            lock (_stateLock)
            {
                changed = _lastListedWrites is { } last && last != writes;
                if (changed) _lastListedWrites = writes;
            }
            if (changed) await send(new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/tools/list_changed" });
        }
    }

    public static JsonNode Error(JsonNode? id, int code, string message, JsonNode? data = null)
    {
        var error = new JsonObject { ["code"] = code, ["message"] = message };
        if (data != null) error["data"] = data;
        return new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = error };
    }
}

/// <summary>MCP prompts: ready-made requests the user can pick in an agent's slash-command menu.</summary>
public sealed record McpPrompt(string Name, string Title, string Description, List<(string Name, string Description, bool Required)> Arguments,
                               Func<Dictionary<string, string>, string> Text)
{
    public JsonObject ListEntry => new()
    {
        ["name"] = Name, ["title"] = Title, ["description"] = Description,
        ["arguments"] = new JsonArray([.. Arguments.Select(a => (JsonNode)new JsonObject { ["name"] = a.Name, ["description"] = a.Description, ["required"] = a.Required })]),
    };

    public JsonObject Messages(JsonObject values)
    {
        var strings = new Dictionary<string, string>();
        foreach (var a in Arguments)
        {
            var value = values[a.Name].Str()?.Trim() ?? "";
            if (value.Length == 0 && a.Required) throw new ToolError($"Missing argument \"{a.Name}\".");
            strings[a.Name] = value;
        }
        return new JsonObject
        {
            ["description"] = Description,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = new JsonObject { ["type"] = "text", ["text"] = Text(strings) } }),
        };
    }
}

public static class McpPrompts
{
    public static readonly List<McpPrompt> All =
    [
        new("find_paper", "在 Folio 中查找论文", "根据模糊的描述在 Folio 文献库中找到对应的论文",
            [("description", "对论文的描述，例如“那篇用 Mamba 做视网膜血管分割的”", true)],
            a => $"Find the paper in my Folio library that matches this description: {a["description"]}\n\n" +
                 "Use search_library with several short keyword queries (topic words, acronyms, an author's family name, a year); " +
                 "try include_fulltext and filters if nothing convincing turns up. Confirm with get_item. If several papers fit, " +
                 "list them (title, first author, year) and ask me which one. Answer in my language and include the folio:// link."),
        new("cite_papers", "引用 Folio 中的论文", "生成指定格式的参考文献列表和文中引用",
            [("papers", "要引用的论文（标题、关键词、DOI 或引用键，多篇用分号隔开）", true),
             ("style", "引用格式：apa、gbt7714、ieee、mla、chicago、harvard、vancouver、nature 或 bibtex（默认 apa）", false)],
            a =>
            {
                var style = a["style"].Length == 0 ? "apa" : a["style"];
                return $"Cite these papers from my Folio library in the {style} style: {a["papers"]}\n\n" +
                       "Find each one with search_library (ask me if a description matches several papers), then call format_citations " +
                       $"with all of them, style \"{style}\" and mode \"both\". Give me the reference list and the in-text citations exactly " +
                       "as returned — do not reformat them. Tell me about any paper you could not find.";
            }),
        new("summarize_paper", "总结 Folio 中的论文", "阅读论文全文和你的批注，给出带页码的总结，可保存到笔记",
            [("paper", "论文（标题、关键词、DOI 或引用键）", true), ("focus", "可选：重点关注的方面，例如“方法”“实验设置”", false)],
            a =>
            {
                var focus = a["focus"].Length == 0 ? "" : $" Focus on: {a["focus"]}.";
                return $"Summarize this paper from my Folio library: {a["paper"]}.{focus}\n\n" +
                       "Find it with search_library and get_item, read it with read_fulltext (page ranges; follow next_start_page), and " +
                       "look at what I highlighted with get_annotations. Cite page numbers. Answer in my language. At the end, offer to " +
                       "save the summary to the paper's note with set_note (mode \"append\").";
            }),
    ];

    public static McpPrompt? Prompt(string name) => All.FirstOrDefault(p => p.Name == name);
}

/// <summary>Starts folio-cli the way an agent does and talks MCP to it (设置 ▸ AI ▸ 检查 MCP 服务器).</summary>
public static class McpSelfCheck
{
    public sealed class Report
    {
        public string? ProtocolVersion;
        public int ToolCount;
        public int? ItemCount;
        public string? LibraryProblem;
        public TimeSpan Elapsed;
    }

    public static async Task<Report> Run(string cliPath, IReadOnlyList<string>? extraArguments = null, TimeSpan? timeout = null)
    {
        var watch = Stopwatch.StartNew();
        if (!File.Exists(cliPath)) throw new ToolError(Loc.S("找不到 folio-cli：%@", cliPath));
        var info = new ProcessStartInfo(cliPath)
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true,
            StandardOutputEncoding = new UTF8Encoding(false), StandardInputEncoding = new UTF8Encoding(false),
        };
        foreach (var a in extraArguments ?? []) info.ArgumentList.Add(a);
        info.ArgumentList.Add("mcp");
        Process process;
        try { process = Process.Start(info) ?? throw new InvalidOperationException(); }
        catch (Exception e) { throw new ToolError(Loc.S("无法启动 folio-cli：%@", e.Message)); }
        using (process)
        {
            _ = process.StandardError.ReadToEndAsync();
            var requests = new JsonNode[]
            {
                new JsonObject
                {
                    ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = "initialize",
                    ["params"] = new JsonObject { ["protocolVersion"] = "2025-11-25", ["capabilities"] = new JsonObject(), ["clientInfo"] = new JsonObject { ["name"] = "Folio 设置", ["version"] = "1" } },
                },
                new JsonObject { ["jsonrpc"] = "2.0", ["method"] = "notifications/initialized" },
                new JsonObject { ["jsonrpc"] = "2.0", ["id"] = 2, ["method"] = "tools/list" },
                new JsonObject { ["jsonrpc"] = "2.0", ["id"] = 3, ["method"] = "tools/call", ["params"] = new JsonObject { ["name"] = "list_collections", ["arguments"] = new JsonObject() } },
            };
            foreach (var r in requests) await process.StandardInput.WriteAsync(Json.WireLine(r) + "\n");
            await process.StandardInput.FlushAsync();
            var responses = new Dictionary<int, JsonNode>();
            using var limit = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(15));
            try
            {
                while (responses.Count < 3)
                {
                    var line = await process.StandardOutput.ReadLineAsync(limit.Token);
                    if (line == null) break;
                    try { if (JsonNode.Parse(line) is { } m && m["id"].Int() is { } id) responses[id] = m; } catch { }
                }
            }
            catch (OperationCanceledException) { }
            try { process.StandardInput.Close(); } catch { }
            if (!process.HasExited) try { process.Kill(); } catch { }
            if (!responses.TryGetValue(1, out var initialize))
            {
                var reason = process.HasExited ? Loc.S("进程已退出，状态 %d", process.ExitCode) : Loc.S("超时");
                throw new ToolError(Loc.S("folio-cli 没有响应 MCP 握手（%@）。", reason));
            }
            if (initialize["error"]?["message"].Str() is { } error) throw new ToolError(Loc.S("握手失败：%@", error));
            var report = new Report
            {
                ProtocolVersion = initialize["result"]?["protocolVersion"].Str(),
                ToolCount = (responses.GetValueOrDefault(2)?["result"]?["tools"] as JsonArray)?.Count ?? 0,
            };
            if (responses.GetValueOrDefault(3)?["result"] is { } call && (call["content"] as JsonArray)?.FirstOrDefault()?["text"].Str() is { } text)
            {
                if (call["isError"].Bool() == true) report.LibraryProblem = text;
                else try { report.ItemCount = JsonNode.Parse(text)?["all_items"].Int(); } catch { }
            }
            report.Elapsed = watch.Elapsed;
            return report;
        }
    }
}
