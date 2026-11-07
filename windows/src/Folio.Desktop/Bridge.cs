using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Folio.Core;
using Microsoft.Web.WebView2.Core;

namespace Folio.App;

/// <summary>Arguments of a call from the page.</summary>
public sealed class Args(JsonElement? value, IReadOnlyList<string>? droppedPaths = null)
{
    /// <summary>Paths of the files passed along with the message (a drop on the page).</summary>
    public IReadOnlyList<string> DroppedPaths { get; } = droppedPaths ?? [];
    public HostWindow? Window { get; init; }

    public bool Has(string name) => value is { ValueKind: JsonValueKind.Object } v && v.TryGetProperty(name, out var p) && p.ValueKind != JsonValueKind.Null;
    JsonElement Get(string name) => value is { ValueKind: JsonValueKind.Object } v && v.TryGetProperty(name, out var p) ? p : default;
    public string Str(string name) => Get(name).ValueKind == JsonValueKind.String ? Get(name).GetString()! : throw new ArgumentException($"Missing argument {name}");
    public string? OptStr(string name) => Get(name).ValueKind == JsonValueKind.String ? Get(name).GetString() : null;
    public int Int(string name) => Get(name).GetInt32();
    public int? OptInt(string name) => Get(name).ValueKind == JsonValueKind.Number ? Get(name).GetInt32() : null;
    public double Num(string name) => Get(name).GetDouble();
    public bool Bool(string name, bool fallback = false) => Get(name).ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => fallback };
    public List<string> Strs(string name) => Get(name).ValueKind == JsonValueKind.Array ? Get(name).EnumerateArray().Select(e => e.GetString()!).ToList() : [];
    public JsonElement Raw(string name) => Get(name);
    public JsonNode? Node(string name) => Get(name).ValueKind == JsonValueKind.Undefined ? null : JsonSerializer.SerializeToNode(Get(name));
}

/// <summary>
/// The page and the app talk through WebView2 messages, as JSON:
/// page → app {id, method, params}, answered with {id, result} or {id, error};
/// app → page {event, data}; app → page {request, method, params}, answered with {reply, result}.
/// Calls run on the interface thread.
/// </summary>
public sealed class Bridge(HostWindow window)
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DictionaryKeyPolicy = null,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static readonly Dictionary<string, Func<Args, Task<object?>>> Methods = [];

    public static void On(string method, Func<Args, object?> handler) => Methods[method] = a => Task.FromResult(handler(a));
    public static void OnAsync(string method, Func<Args, Task<object?>> handler) => Methods[method] = handler;
    public static void OnAsync(string method, Func<Args, Task> handler) => Methods[method] = async a => { await handler(a); return null; };

    readonly ConcurrentDictionary<int, TaskCompletionSource<JsonElement>> _requests = new();
    int _nextRequest;
    bool _ready;
    readonly Queue<string> _pending = new();
    public CoreWebView2? Core { get; set; }

    public void MarkReady()
    {
        _ready = true;
        while (_pending.Count > 0) Send(_pending.Dequeue());
    }

    void Post(string json)
    {
        if (!App.Ui.HasThreadAccess) { App.Ui.TryEnqueue(() => Post(json)); return; }
        if (_ready && Core != null) Send(json); else _pending.Enqueue(json);
    }

    /// <summary>A window closing has nobody left to tell.</summary>
    void Send(string json)
    {
        try { Core?.PostWebMessageAsJson(json); }
        catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException) { Core = null; }
    }

    /// <summary>The page is waiting for this one: it never queues behind the page's being ready.</summary>
    void Answer(string json)
    {
        if (App.Ui.HasThreadAccess) Send(json);
        else App.Ui.TryEnqueue(() => Send(json));
    }

    public void Emit(string name, object? data) => Post(JsonSerializer.Serialize(new { @event = name, data }, Json));

    /// <summary>Asks the page something (a dialog) and waits for the answer.</summary>
    public Task<JsonElement> Request(string method, object? parameters)
    {
        int id = Interlocked.Increment(ref _nextRequest);
        var answer = new TaskCompletionSource<JsonElement>();
        _requests[id] = answer;
        Post(JsonSerializer.Serialize(new { request = id, method, @params = parameters }, Json));
        return answer.Task;
    }

    public async void Receive(CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonElement? id = null;
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var root = doc.RootElement.Clone();
            if (root.TryGetProperty("reply", out var reply))
            {
                if (_requests.TryRemove(reply.GetInt32(), out var waiting))
                    waiting.SetResult(root.TryGetProperty("result", out var answer) ? answer : default);
                return;
            }
            id = root.GetProperty("id");
            var method = root.GetProperty("method").GetString()!;
            if (!Methods.TryGetValue(method, out var handler)) throw new InvalidOperationException($"No method {method}");
            List<string>? paths = null;
            if (e.AdditionalObjects is { Count: > 0 } objects)
                paths = objects.OfType<CoreWebView2File>().Select(f => f.Path).ToList();
            var args = new Args(root.TryGetProperty("params", out var p) ? p : null, paths) { Window = window };
            var result = await handler(args);
            Answer(JsonSerializer.Serialize(new { id = id.Value.GetInt32(), result }, Json));
        }
        catch (Exception ex)
        {
            if (ex is not ArgumentException) CrashLog.Write(ex);
            if (id is { } known) Answer(JsonSerializer.Serialize(new { id = known.GetInt32(), error = ex.Message }, Json));
        }
    }
}
