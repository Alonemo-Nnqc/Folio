using System.Text;
using System.Text.Json.Nodes;

namespace Folio.Core.Agent;

// Port of macos/.../FolioAgent/AgentCLI.swift. On Windows `-` as the JSON argument reads it from standard input
// (PowerShell and cmd.exe strip the double quotes of a JSON argument).

/// <summary>folio-cli: the MCP server, plus every tool as a command for agents that can run shell commands but have no MCP.</summary>
public static class AgentCli
{
    public const string Usage = """
    folio-cli — Folio 文献库的 AI 接口

    用法：
      folio-cli mcp                          以 stdio 方式运行 MCP 服务器（供 Claude、Codex、Cursor 等智能体使用）
      folio-cli tools [--json]               列出所有工具（--json 输出参数结构）
      folio-cli call <工具> ['<JSON 参数>' | -]  调用任一工具，结果为 JSON（- 从标准输入读取参数）
      folio-cli search <关键词…> [--fulltext] [--limit N]
      folio-cli get <条目 id | DOI | 引用键>
      folio-cli cite <条目…> [--style apa|gbt7714|ieee|mla|chicago|harvard|vancouver|nature|bibtex] [--in-text]
      folio-cli export [--format bibtex|ris|csljson] [--collection <分组/标签>] [-o <文件>]
      folio-cli add <DOI | arXiv ID | ISBN | PDF 路径> [--group <分组>]
      folio-cli open <条目> [--page N]
      folio-cli status                       文献库位置、条目数量、是否允许修改（排查连接问题）
      folio-cli agents                       本机智能体及 Folio MCP / 技能的安装状态
      folio-cli agents add|remove <智能体 id> [--mcp-only | --skill-only]

    选项：--library <目录> 使用指定文献库；--read-only 只允许读取。
    """;

    /// <summary>The path of this folio-cli (or, from the app, the one next to Folio.exe).</summary>
    public static string ExecutablePath => Path.Combine(AppContext.BaseDirectory, OperatingSystem.IsWindows() ? "folio-cli.exe" : "folio-cli");

    public static async Task<int> Main(string[] arguments)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        var args = Strip(Strip(arguments.ToList(), "--library", true), "--read-only", false);
        var configuration = AgentConfiguration.Resolve(arguments);
        if (args.Count == 0 || args[0] is "help" or "--help" or "-h") { Console.WriteLine(Usage); return 0; }
        var command = args[0];
        var rest = args.Skip(1).ToList();
        if (command is "version" or "--version") { Console.WriteLine($"folio-cli {McpServer.ServerVersion}"); return 0; }
        if (command == "mcp")
        {
            // The server always starts, so the agent can connect and hear why the library is unavailable.
            await new McpServer(new LibraryToolbox(() => AgentConfiguration.Resolve(arguments))).Run();
            return 0;
        }
        if (command == "status") return Status(configuration);
        if (command == "agents") return Agents(rest);
        LibraryToolbox toolbox;
        try { toolbox = new LibraryToolbox(configuration); }
        catch (Exception e)
        {
            Error($"无法打开文献库 {configuration.LibraryRoot}：{e.Message}");
            return 2;
        }
        switch (command)
        {
            case "tools":
                if (rest.Contains("--json")) Console.WriteLine(Json.Encode(new JsonArray([.. toolbox.Tools.Select(t => (JsonNode)t.McpDescription)]), true));
                else foreach (var tool in toolbox.Tools) Console.WriteLine($"{tool.Name}{(tool.Writes ? "  [修改]" : "")}\n    {tool.Description.Replace("\n", " ")}\n");
                return 0;
            case "call":
            {
                if (rest.Count == 0) { Error("用法：folio-cli call <工具> '<JSON 参数>'"); return 64; }
                if (ParseArguments(rest.Count > 1 ? rest[1] : null) is not { } parsed) return 64;
                return await Run(toolbox, rest[0], parsed);
            }
            case "search":
            {
                int limit = int.TryParse(Value("--limit", rest), out var l) ? l : 20;
                return await Run(toolbox, "search_library", new JsonObject
                {
                    ["query"] = string.Join(" ", Positional(rest, ["--limit"])), ["include_fulltext"] = rest.Contains("--fulltext"), ["limit"] = limit,
                });
            }
            case "get":
                return await Run(toolbox, "get_item", new JsonObject { ["item"] = rest.FirstOrDefault() });
            case "cite":
            {
                bool inText = rest.Contains("--in-text");
                return await Run(toolbox, "format_citations", new JsonObject
                {
                    ["items"] = Json.Strings(Positional(rest, ["--style"])), ["style"] = Value("--style", rest) ?? "apa", ["mode"] = inText ? "both" : "bibliography",
                }, inText ? null : "text");
            }
            case "export":
            {
                var a = new JsonObject { ["format"] = Value("--format", rest) ?? "bibtex" };
                if (Value("--collection", rest) is { } collection) a["collection"] = collection;
                if ((Value("-o", rest) ?? Value("--output", rest)) is { } path) a["path"] = path;
                return await Run(toolbox, "export_references", a, "text");
            }
            case "add":
            {
                if (Positional(rest, ["--group"]).FirstOrDefault() is not { } target) { Error("用法：folio-cli add <DOI | arXiv ID | ISBN | PDF 路径>"); return 64; }
                var a = new JsonObject();
                if (Value("--group", rest) is { } group) a["group"] = group;
                if (File.Exists(Paths.Expand(target)))
                {
                    a["path"] = target;
                    return await Run(toolbox, "add_pdf", a);
                }
                a["identifier"] = target;
                return await Run(toolbox, "add_item_by_identifier", a);
            }
            case "open":
            {
                var a = new JsonObject { ["item"] = Positional(rest, ["--page"]).FirstOrDefault() };
                if (int.TryParse(Value("--page", rest), out var page)) a["page"] = page;
                return await Run(toolbox, "open_in_folio", a);
            }
            default:
                if (ToolCatalog.Tool(command) != null && ParseArguments(rest.FirstOrDefault()) is { } given) return await Run(toolbox, command, given);
                Error($"未知命令：{command}\n\n{Usage}");
                return 64;
        }
    }

    /// <summary>JSON arguments: given, from standard input ("-"), or none.</summary>
    static JsonNode? ParseArguments(string? text)
    {
        if (text == "-") text = Console.In.ReadToEnd();
        if (string.IsNullOrWhiteSpace(text)) return new JsonObject();
        try { return JsonNode.Parse(text) ?? new JsonObject(); }
        catch
        {
            Error($"参数不是合法的 JSON：{text}\n（在 PowerShell 中请用：'{{\"key\": \"value\"}}' | folio-cli call <工具> -）");
            return null;
        }
    }

    static int Status(AgentConfiguration configuration)
    {
        Console.WriteLine($"folio-cli {McpServer.ServerVersion}（MCP 协议 {string.Join(", ", McpServer.SupportedProtocolVersions)}）");
        Console.WriteLine($"可执行文件：{Environment.ProcessPath ?? ExecutablePath}");
        Console.WriteLine($"文献库：{configuration.LibraryRoot}");
        try
        {
            using var library = LibraryToolbox.Open(configuration.LibraryRoot);
            var s = library.Snapshot();
            int active = s.Items.Values.Count(i => !i.IsTrashed);
            Console.WriteLine($"条目：{active}（回收站 {s.Items.Count - active}），分组 {s.GroupsById.Count}，标签 {s.Tags.Count}");
        }
        catch (Exception e)
        {
            Error($"无法打开文献库：{e.Message}");
            return 2;
        }
        Console.WriteLine($"允许 AI 修改文献库：{(configuration.AllowWrites ? "是" : "否（只读）")}");
        Console.WriteLine($"工具：{ToolCatalog.Available(configuration.AllowWrites).Count} 个");
        return 0;
    }

    /// <summary>folio-cli agents [add|remove &lt;id&gt;]: the same integration as 设置 ▸ AI. FOLIO_AGENT_HOME points it at another home (tests).</summary>
    static int Agents(List<string> args)
    {
        var home = Environment.GetEnvironmentVariable("FOLIO_AGENT_HOME") is { Length: > 0 } h ? h : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var integrator = new AgentIntegrator(home, Environment.ProcessPath ?? ExecutablePath);
        if (args.Count == 0)
        {
            foreach (var s in integrator.Detect())
            {
                var mcp = s.Descriptor.Mcp == null ? "—" : s.McpInstalled ? (s.McpNeedsUpdate ? "需更新" : "已安装") : "未安装";
                var skill = !s.Descriptor.SupportsSkills ? "—" : s.SkillInstalled ? $"已安装（{integrator.Display(s.SkillFolder!)}）" : "未安装";
                var found = s.Location != null ? $"\t{s.Location}" + (s.Version != null ? $" {s.Version}" : "") : "";
                Console.WriteLine($"{(s.IsDetected ? "●" : "○")} {s.Descriptor.Id}\t{s.Descriptor.Name}\tMCP：{mcp}\t技能：{skill}" + (s.McpConfigPath != null ? $"\t{s.McpConfigPath}" : "") + found);
            }
            return 0;
        }
        var descriptor = args.Count >= 2 ? AgentIntegrator.Catalog.FirstOrDefault(d => d.Id == args[1]) : null;
        if (args[0] is not ("add" or "remove") || descriptor == null)
        {
            Error($"用法：folio-cli agents add|remove <{string.Join("|", AgentIntegrator.Catalog.Select(d => d.Id))}> [--mcp-only | --skill-only]");
            return 64;
        }
        bool enable = args[0] == "add", failed = false;
        if (!args.Contains("--skill-only") && descriptor.Mcp != null)
        {
            try
            {
                integrator.SetMcp(enable, descriptor);
                Console.WriteLine($"{(enable ? "已添加" : "已移除")} {descriptor.Name} 的 Folio MCP（{integrator.ConfigPath(descriptor)}）");
            }
            catch (Exception e) { Error(e.Message); failed = true; }
        }
        if (!args.Contains("--mcp-only") && descriptor.SupportsSkills)
        {
            try
            {
                integrator.SetSkill(enable, descriptor);
                var folder = integrator.Status(descriptor).SkillFolder;
                Console.WriteLine($"{(enable ? "已安装" : "已移除")} {descriptor.Name} 的 Folio 技能" + (folder != null ? $"（{integrator.Display(folder)}）" : ""));
            }
            catch (Exception e) { Error(e.Message); failed = true; }
        }
        return failed ? 1 : 0;
    }

    static async Task<int> Run(LibraryToolbox toolbox, string name, JsonNode arguments, string? textKey = null)
    {
        try
        {
            var result = await toolbox.Call(name, arguments);
            if (textKey != null && result[textKey].Str() is { } text) Console.Write(text.EndsWith('\n') ? text : text + "\n");
            else Console.WriteLine(Json.Encode(Json.Pruned(result), true));
            return 0;
        }
        catch (Exception e)
        {
            Error(e.Message);
            return 1;
        }
    }

    static string? Value(string option, List<string> args)
    {
        int i = args.IndexOf(option);
        return i >= 0 && i + 1 < args.Count ? args[i + 1] : null;
    }

    static List<string> Positional(List<string> args, HashSet<string> valueOptions)
    {
        var result = new List<string>();
        bool skip = false;
        foreach (var arg in args)
        {
            if (skip) { skip = false; continue; }
            if (valueOptions.Contains(arg)) { skip = true; continue; }
            if (arg.StartsWith("--")) continue;
            result.Add(arg);
        }
        return result;
    }

    static List<string> Strip(List<string> args, string option, bool hasValue)
    {
        int i = args.IndexOf(option);
        if (i < 0) return args;
        args.RemoveRange(i, Math.Min(hasValue ? 2 : 1, args.Count - i));
        return args;
    }

    static void Error(string text) => Console.Error.WriteLine(text);
}
