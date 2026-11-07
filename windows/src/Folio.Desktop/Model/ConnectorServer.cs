using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using Folio.Core;
using Folio.Core.Connector;
using Folio.Core.Retrieval;
using static Folio.Core.Connector.ConnectorProtocol;

namespace Folio.App;

/// <summary>The local service the browser extension saves through: 127.0.0.1:23120, extension origins only.</summary>
public sealed class ConnectorServer(AppModel model)
{
    public enum ServerState { Stopped, Running, Failed }

    TcpListener? _listener;
    CancellationTokenSource? _cts;
    public ServerState State { get; private set; } = ServerState.Stopped;
    public string? FailureReason { get; private set; }
    /// <summary>Last request per browser ("Chrome", "Edge" …), for Settings ▸ Browser.</summary>
    public Dictionary<string, DateTime> LastSeen { get; } = [];
    public event Action? StateChanged;

    static int PortNumber => int.TryParse(Environment.GetEnvironmentVariable("FOLIO_CONNECTOR_PORT"), out var p) && p > 0 ? p : ConnectorProtocol.Port;

    public void Start()
    {
        if (_listener != null) return;
        try
        {
            var listener = new TcpListener(IPAddress.Loopback, PortNumber);
            listener.Start();
            _listener = listener;
            _cts = new CancellationTokenSource();
            State = ServerState.Running;
            FailureReason = null;
            AcceptLoop(listener, _cts.Token).Fire();
        }
        catch (SocketException e)
        {
            State = ServerState.Failed;
            FailureReason = e.SocketErrorCode == SocketError.AddressAlreadyInUse
                ? Loc.S("端口 %@ 已被占用（是否打开了另一个 Folio？）", PortNumber.ToString())
                : e.Message + " " + Loc.S("Windows 安全中心或杀毒软件可能拦截了端口 %@。", PortNumber.ToString());
        }
        StateChanged?.Invoke();
    }

    public void Stop()
    {
        _cts?.Cancel();
        _listener?.Stop();
        _listener = null;
        State = ServerState.Stopped;
        StateChanged?.Invoke();
    }

    async Task AcceptLoop(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(ct); }
            catch { return; }
            Handle(client).Fire();
        }
    }

    async Task Handle(TcpClient client)
    {
        using var _ = client;
        var stream = client.GetStream();
        var buffer = new byte[64 * 1024];
        int length = 0;
        Request? request = null;
        while (true)
        {
            if (length == buffer.Length) Array.Resize(ref buffer, Math.Min(buffer.Length * 2, MaxBodyBytes + 64 * 1024));
            int read;
            try { read = await stream.ReadAsync(buffer.AsMemory(length, buffer.Length - length)); }
            catch { return; }
            if (read == 0) return;
            length += read;
            var (state, parsed, error) = Parse(buffer, length);
            if (state == ParseState.Incomplete) continue;
            if (state == ParseState.Invalid)
            {
                await Send(stream, Response.Error(error!, error!.Contains("large") ? 413 : 400), null);
                return;
            }
            request = parsed;
            break;
        }
        Response response;
        try { response = await Route(request!); }
        catch (Exception e) { response = Response.Error(e.Message, 500); }
        await Send(stream, response, request!.HeaderValue("origin"));
    }

    static async Task Send(NetworkStream stream, Response response, string? origin)
    {
        var withCors = response with { Headers = new(response.Headers.Concat(CorsHeaders(origin)).GroupBy(h => h.Key).Select(g => g.Last())) };
        try { await stream.WriteAsync(withCors.Serialized()); } catch { }
    }

    Task<T> OnUi<T>(Func<Task<T>> work)
    {
        var tcs = new TaskCompletionSource<T>();
        model.RunOnUi(async () =>
        {
            try { tcs.SetResult(await work()); } catch (Exception e) { tcs.SetException(e); }
        });
        return tcs.Task;
    }

    async Task<Response> Route(Request request)
    {
        if (request.Method == "OPTIONS")
            return IsAllowedOrigin(request.HeaderValue("origin")) ? new Response(204, []) : Response.Error("Forbidden", 403);
        if (Reject(request) is { } rejection) return rejection;
        NoteBrowser(request.HeaderValue("user-agent"));
        return (request.Method, request.Path) switch
        {
            ("GET", "/ping") => Response.Json(new JsonObject
            {
                ["name"] = "Folio", ["version"] = Updater.CurrentVersion, ["apiVersion"] = ApiVersion,
                ["extensionVersion"] = BrowserExtensions.BundledVersion, ["library"] = Path.GetFileName(model.Library.Root.TrimEnd('\\', '/')),
                ["platform"] = "windows",
            }),
            ("GET", "/collections") => await OnUi(() => Task.FromResult(Collections())),
            ("POST", "/save") => request.Json() is { } body ? await Save(body) : Response.Error("Invalid JSON", 400),
            ("POST", "/saveItems") => request.Json() is { } body ? await SaveItems(body) : Response.Error("Invalid JSON", 400),
            ("POST", "/attach") => await Attach(request),
            ("POST", "/savePDF") => await SavePdf(request),
            ("POST", "/pdfFailed") => PdfFailed(request),
            ("POST", "/reveal") => await OnUi(() =>
            {
                if (request.Query.GetValueOrDefault("item") is not { } id || !model.Snapshot.Items.ContainsKey(id)) return Task.FromResult(Response.Error("Unknown item", 404));
                App.BringToFront();
                model.Reveal(id);
                return Task.FromResult(Response.Json(new JsonObject { ["status"] = "shown" }));
            }),
            _ => Response.Error("Not found", 404),
        };
    }

    void NoteBrowser(string? ua)
    {
        if (ua == null) return;
        var name = ua.Contains("Edg/") ? "Edge" : ua.Contains("Firefox/") ? "Firefox" : ua.Contains("OPR/") ? "Opera" : ua.Contains("Chrome/") ? "Chrome" : Loc.S("浏览器");
        lock (LastSeen) LastSeen[name] = DateTime.Now;
    }

    Response Collections()
    {
        var s = model.Snapshot;
        var groups = new JsonArray(s.GroupsForMenus().Select(g =>
        {
            var o = new JsonObject { ["id"] = g.Group.Id, ["name"] = g.Group.Name, ["depth"] = g.Depth };
            if (g.Group.ColorHex != null) o["color"] = g.Group.ColorHex;
            return (JsonNode)o;
        }).ToArray());
        return Response.Json(new JsonObject
        {
            ["groups"] = groups,
            ["currentGroupId"] = model.Scope.GroupId,
            ["tags"] = new JsonArray(s.Tags.Select(t => (JsonNode)t.Name).ToArray()),
        });
    }

    string? ValidGroup(string? id) => id != null && model.Snapshot.GroupsById.ContainsKey(id) ? id : null;

    async Task<Response> Save(JsonNode body)
    {
        if (MetadataFrom(body["item"]) is not { } page) return Response.Error(Loc.S("没有识别到文献信息"), 400);
        var groupId = ValidGroup(body["groupId"]?.ToString());
        var metadata = page;
        bool lookedUp = false;
        if ((body["resolve"]?.GetValue<bool>() ?? true) && (page.Doi ?? page.ArxivId ?? page.Isbn) is { } identifier
            && await model.Importer.Engine.Resolve(identifier) is ResolveResult.Found found)
        {
            metadata = Merge(found.Metadata, page);
            lookedUp = true;
        }
        var library = model.Library;
        var outcome = library.CreateItem(metadata, groupId);
        var itemId = outcome.Id;
        var status = outcome is CreateOutcome.Created ? "created" : "duplicate";
        if (outcome is CreateOutcome.Duplicate && groupId != null) library.AddItems([itemId], groupId, false);
        ApplyTags(body["tags"] as JsonArray, itemId);
        var title = library.Item(itemId)?.Title ?? metadata.Title;
        model.Toasts.Show(status == "created" ? Loc.S("已从浏览器保存「%@」", title) : Loc.S("「%@」已在文献库中", title), "globe",
                          Loc.S("显示"), () => model.Reveal(itemId));
        return Response.Json(new JsonObject
        {
            ["status"] = status, ["itemId"] = itemId, ["title"] = title,
            ["group"] = groupId == null ? null : model.Snapshot.GroupsById.GetValueOrDefault(groupId)?.Name, ["lookedUp"] = lookedUp,
        });
    }

    async Task<Response> SaveItems(JsonNode body)
    {
        var entries = (body["items"] as JsonArray ?? []).Take(200)
            .Select(e => (Identifier: e?["identifier"]?.ToString().Trim() ?? "", Title: e?["title"]?.ToString()))
            .Where(e => e.Identifier.Length > 0).ToList();
        if (entries.Count == 0) return Response.Error(Loc.S("没有可保存的文献"), 400);
        var groupId = ValidGroup(body["groupId"]?.ToString());
        var engine = model.Importer.Engine;
        var lookups = new ResolveResult[entries.Count];
        using (var gate = new SemaphoreSlim(4))
            await Task.WhenAll(entries.Select(async (e, i) =>
            {
                await gate.WaitAsync();
                try { lookups[i] = await engine.Resolve(e.Identifier); } finally { gate.Release(); }
            }));
        var results = new JsonArray();
        var saved = new List<(string Id, Metadata Metadata)>();
        var library = model.Library;
        for (int i = 0; i < entries.Count; i++)
        {
            var o = new JsonObject { ["identifier"] = entries[i].Identifier, ["title"] = entries[i].Title };
            switch (lookups[i])
            {
                case ResolveResult.Found found:
                    try
                    {
                        var outcome = library.CreateItem(found.Metadata, groupId);
                        o["status"] = outcome is CreateOutcome.Created ? "created" : "duplicate";
                        if (outcome is CreateOutcome.Duplicate && groupId != null) library.AddItems([outcome.Id], groupId, false);
                        ApplyTags(body["tags"] as JsonArray, outcome.Id);
                        o["itemId"] = outcome.Id;
                        o["title"] = found.Metadata.Title;
                        saved.Add((outcome.Id, found.Metadata));
                    }
                    catch (Exception e) { o["status"] = "failed"; o["error"] = e.Message; }
                    break;
                case ResolveResult.NetworkError:
                    o["status"] = "failed"; o["error"] = Loc.S("网络错误，请稍后重试"); break;
                default:
                    o["status"] = "failed"; o["error"] = Loc.S("数据源中没有找到"); break;
            }
            results.Add(o);
        }
        int created = results.Count(r => r?["status"]?.ToString() == "created");
        int existing = results.Count(r => r?["status"]?.ToString() == "duplicate");
        if (saved.Count > 0)
        {
            var first = saved[0].Id;
            model.Toasts.Show(existing > 0 ? Loc.S("已从浏览器保存 %lld 篇，%lld 篇已在文献库中", created, existing) : Loc.S("已从浏览器保存 %lld 篇文献", created),
                              "globe", Loc.S("显示"), () => model.Reveal(first));
        }
        if (body["pdf"]?.GetValue<bool>() == true && saved.Count > 0) AttachOpenAccessPdfs(saved).Fire();
        return Response.Json(new JsonObject { ["results"] = results, ["group"] = groupId == null ? null : model.Snapshot.GroupsById.GetValueOrDefault(groupId)?.Name });
    }

    async Task AttachOpenAccessPdfs(List<(string Id, Metadata Metadata)> items)
    {
        int attached = 0;
        foreach (var (id, metadata) in items)
        {
            if (model.Library.Files(id).Any(f => f.IsPdf)) continue;
            if (await OpenAccessPdf.Locate(metadata.Doi, metadata.ArxivId, model.Settings.CrossrefMailto) is not { } url) continue;
            try
            {
                var file = await OpenAccessPdf.Download(url, model.Settings.CrossrefMailto);
                if (model.Library.AddFiles([file], id, model.Settings.AutoRenameFiles).FirstOrDefault() is AddFileOutcome.Added) attached++;
                try { Directory.Delete(Path.GetDirectoryName(file)!, true); } catch { }
            }
            catch { }
        }
        if (attached > 0)
        {
            model.Importer.IndexFulltext();
            model.Toasts.Show(Loc.S("已为 %lld 篇文献下载 PDF", attached), "download");
        }
    }

    void ApplyTags(JsonArray? names, string itemId)
    {
        foreach (var name in names ?? [])
        {
            if (name?.ToString().Trim() is not { Length: > 0 } clean) continue;
            model.Library.SetTag(model.Library.EnsureTag(clean), [itemId], true);
        }
    }

    Response PdfFailed(Request request)
    {
        var reason = request.Json()?["message"]?.ToString() ?? Loc.S("下载失败");
        var title = request.Query.GetValueOrDefault("item") is { } id ? model.Library.Item(id)?.Title : null;
        model.Toasts.Show(Loc.S("「%@」的 PDF 未能保存：%@", title ?? Loc.S("条目"), reason), "warning");
        return Response.Json(new JsonObject { ["status"] = "noted" });
    }

    async Task<Response> Attach(Request request)
    {
        if (request.Query.GetValueOrDefault("item") is not { } itemId || model.Library.Item(itemId) == null) return Response.Error("Unknown item", 404);
        if (!OpenAccessPdf.IsPdf(request.Body)) return Response.Error(Loc.S("下载的文件不是 PDF（可能需要登录或订阅）"), 400);
        var path = await TemporaryFile(request.Body, request.Query.GetValueOrDefault("filename"));
        try
        {
            var outcome = model.Library.AddFiles([path], itemId, model.Settings.AutoRenameFiles).FirstOrDefault();
            model.Importer.IndexFulltext();
            switch (outcome)
            {
                case AddFileOutcome.Added:
                    model.Toasts.Show(Loc.S("已为「%@」附加 PDF", model.Library.Item(itemId)?.Title ?? Loc.S("条目")), "attach");
                    return Response.Json(new JsonObject { ["status"] = "added" });
                case AddFileOutcome.Duplicate: return Response.Json(new JsonObject { ["status"] = "duplicate" });
                case AddFileOutcome.Failed f: return Response.Error(f.Reason, 500);
                default: return Response.Error("Nothing attached", 500);
            }
        }
        finally { try { Directory.Delete(Path.GetDirectoryName(path)!, true); } catch { } }
    }

    async Task<Response> SavePdf(Request request)
    {
        if (!OpenAccessPdf.IsPdf(request.Body)) return Response.Error(Loc.S("这不是 PDF 文件"), 400);
        var path = await TemporaryFile(request.Body, request.Query.GetValueOrDefault("filename"));
        var groupId = ValidGroup(request.Query.GetValueOrDefault("groupId"));
        await OnUi(async () => { await model.Importer.ImportFiles([path], groupId); return true; });
        Task.Delay(30_000).ContinueWith(_ => { try { Directory.Delete(Path.GetDirectoryName(path)!, true); } catch { } }).Fire();
        return Response.Json(new JsonObject { ["status"] = "importing", ["group"] = groupId == null ? null : model.Snapshot.GroupsById.GetValueOrDefault(groupId)?.Name });
    }

    static async Task<string> TemporaryFile(byte[] data, string? name)
    {
        var folder = Path.Combine(Path.GetTempPath(), $"folio-web-{Guid.NewGuid()}");
        Directory.CreateDirectory(folder);
        string decoded;
        try { decoded = Uri.UnescapeDataString(name ?? ""); } catch { decoded = name ?? ""; }
        var fileName = FileNamer.Sanitize(decoded);
        if (fileName.Length == 0) fileName = "download";
        if (!fileName.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) fileName += ".pdf";
        var path = Path.Combine(folder, fileName);
        await File.WriteAllBytesAsync(path, data);
        return path;
    }
}
