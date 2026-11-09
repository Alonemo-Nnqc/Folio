using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Folio.Core.Translate.Services;

namespace Folio.Core.Agent;

// Port of macos/.../FolioAgent/AgentIntegrations.swift and AgentDetection.swift, with the agents' Windows locations.
// Paths starting with % are expanded (%APPDATA%, %LOCALAPPDATA%); others are relative to the home folder.

public enum EntryStyle { Standard, ClaudeCode, Opencode, CopilotCli }
public enum WritePolicy { ExistingFile, ExistingFolder, EveryExistingFolder }
public enum YamlStyle { CommandArgs, Goose }

public abstract record McpTarget
{
    public sealed record ClaudeCode : McpTarget;
    public sealed record Codex : McpTarget;
    public sealed record JsonFile(string Path, string Key, EntryStyle Style) : McpTarget;
    public sealed record JsonAny(string[] Paths, string Key, EntryStyle Style, WritePolicy Policy) : McpTarget;
    public sealed record Toml(string Path) : McpTarget;
    public sealed record Yaml(string Path, string Key, YamlStyle Style) : McpTarget;
    public sealed record OpenClaw : McpTarget;
}

/// <summary>An AI agent Folio can configure.</summary>
public sealed record AgentDescriptor(string Id, string Name, string[] Apps, string[] Commands, McpTarget? Mcp, string[] SkillFolders, string? SkillNote)
{
    public string[][] VersionArguments { get; init; } = [["--version"]];
    public bool SupportsSkills => SkillFolders.Length > 0;
}

public sealed record AgentStatus(AgentDescriptor Descriptor, bool IsDetected, string? Location, string? Version, bool IsApp, bool McpInstalled,
                                 bool SkillInstalled, bool McpNeedsUpdate, string? McpConfigPath, string? SkillFolder)
{
    public string Id => Descriptor.Id;
}

public sealed class AgentIntegrationError(string message) : Exception(message);

/// <summary>Detects agents and adds / removes Folio's MCP server and skill in their configuration.</summary>
public sealed class AgentIntegrator(string home, string cliPath, bool useAgentCommands = true)
{
    public const string ServerName = "folio";
    public string Home { get; } = home;
    public string CliPath { get; } = cliPath;
    public bool VerifiesCommands { get; init; } = true;
    /// <summary>Replaces PATH and the usual install folders (tests).</summary>
    public List<string>? CommandFoldersOverride { get; init; }

    public const string SharedSkillsFolder = ".agents/skills";

    public static readonly List<AgentDescriptor> Catalog =
    [
        new("claude-code", "Claude Code", [], ["claude"], new McpTarget.ClaudeCode(), [".claude/skills"], null),
        new("claude-desktop", Loc.S("Claude 桌面版"), ["%LOCALAPPDATA%/AnthropicClaude/claude.exe", "%LOCALAPPDATA%/Programs/Claude/Claude.exe"], [],
            new McpTarget.JsonFile("%APPDATA%/Claude/claude_desktop_config.json", "mcpServers", EntryStyle.Standard), [],
            Loc.S("Claude 桌面版的技能需在 设置 ▸ 功能 ▸ 技能 中上传，可用下方\"导出技能包…\"生成。")),
        new("codex", "Codex", [], ["codex"], new McpTarget.Codex(), [SharedSkillsFolder], null),
        new("gemini-cli", "Gemini CLI", [], ["gemini"], new McpTarget.JsonFile(".gemini/settings.json", "mcpServers", EntryStyle.Standard),
            [SharedSkillsFolder, ".gemini/skills"], null),
        new("copilot-cli", "GitHub Copilot CLI", [], ["copilot"], new McpTarget.JsonFile(".copilot/mcp-config.json", "mcpServers", EntryStyle.CopilotCli),
            [SharedSkillsFolder, ".copilot/skills"], null),
        new("cursor", "Cursor CLI", [], ["cursor-agent"], new McpTarget.JsonFile(".cursor/mcp.json", "mcpServers", EntryStyle.Standard),
            [SharedSkillsFolder, ".cursor/skills", ".claude/skills", ".codex/skills"], null),
        new("kiro", "Kiro CLI", [], ["kiro-cli"], new McpTarget.JsonFile(".kiro/settings/mcp.json", "mcpServers", EntryStyle.Standard), [".kiro/skills"], null),
        new("cline", "Cline CLI", [], ["cline"],
            new McpTarget.JsonAny([".cline/data/settings/cline_mcp_settings.json", "%APPDATA%/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json"],
                "mcpServers", EntryStyle.Standard, WritePolicy.ExistingFolder), [".cline/skills"], null) { VersionArguments = [["--version"], ["version"]] },
        new("opencode", "opencode", [], ["opencode"],
            new McpTarget.JsonAny([".config/opencode/opencode.json", ".config/opencode/opencode.jsonc"], "mcp", EntryStyle.Opencode, WritePolicy.ExistingFile),
            [SharedSkillsFolder, ".config/opencode/skills", ".claude/skills"], null),
        new("antigravity", "Antigravity", ["%LOCALAPPDATA%/Programs/Antigravity/Antigravity.exe"], ["agy", "antigravity"],
            new McpTarget.JsonAny([".gemini/config/mcp_config.json", ".gemini/antigravity/mcp_config.json"], "mcpServers", EntryStyle.Standard, WritePolicy.ExistingFolder),
            [".gemini/config/skills", ".gemini/antigravity/skills", ".gemini/antigravity-cli/skills"], null),
        new("qwen-code", "Qwen Code", [], ["qwen"], new McpTarget.JsonFile(".qwen/settings.json", "mcpServers", EntryStyle.Standard), [".qwen/skills"], null),
        // The ids below are the LocalAgent names, so these rows share the translation services' logos.
        new("pi", "Pi", [], ["pi"], new McpTarget.JsonFile(".pi/agent/mcp.json", "mcpServers", EntryStyle.Standard), [".pi/agent/skills", SharedSkillsFolder], null),
        new("grok", "Grok CLI", [], ["grok"], new McpTarget.Toml(".grok/config.toml"), [".grok/skills"], null),
        new("hermes", "Hermes Agent", [], ["hermes"], new McpTarget.Yaml(".hermes/config.yaml", "mcp_servers", YamlStyle.CommandArgs), [".hermes/skills"], null),
        new("openclaw", "OpenClaw", [], ["openclaw"], new McpTarget.OpenClaw(), [".openclaw/skills", SharedSkillsFolder], null),
        // Kimi Code moved from ~/.kimi to ~/.kimi-code.
        new("kimi", "Kimi Code", [], ["kimi"], new McpTarget.JsonAny([".kimi-code/mcp.json", ".kimi/mcp.json"], "mcpServers", EntryStyle.Standard, WritePolicy.ExistingFolder),
            [".kimi-code/skills", SharedSkillsFolder], null),
        new("droid", "Droid", [], ["droid"], new McpTarget.JsonFile(".factory/mcp.json", "mcpServers", EntryStyle.ClaudeCode), [".factory/skills"], null),
        new("amp", "Amp", [], ["amp"], new McpTarget.JsonAny([".config/amp/settings.json", ".config/amp/settings.jsonc"], "amp.mcpServers", EntryStyle.Standard, WritePolicy.ExistingFile),
            [SharedSkillsFolder, ".config/agents/skills", ".config/amp/skills"], null),
        new("goose", "goose", [], ["goose"], new McpTarget.Yaml("%APPDATA%/Block/goose/config/config.yaml", "extensions", YamlStyle.Goose), [SharedSkillsFolder], null),
        // Found like the others; it documents no place for a user's MCP servers or skills yet.
        new("deepseek", "DeepSeek Harness", [], ["dsh"], null, [], Loc.S("DeepSeek Harness 暂未提供用户级的 MCP 与技能配置位置。")),
    ];

    static readonly string[] RetiredSkillFolders = [".codex/skills"];

    /// <summary>A catalog path made absolute.</summary>
    public string Resolve(string path) =>
        path.StartsWith('%') ? Path.GetFullPath(Environment.ExpandEnvironmentVariables(path)) : Path.GetFullPath(Path.Combine(Home, path));

    /// <summary>For display: ~\… under the home folder.</summary>
    public string Display(string path)
    {
        var full = Resolve(path);
        return full.StartsWith(Home, StringComparison.OrdinalIgnoreCase) ? "~" + full[Home.TrimEnd('\\', '/').Length..] : full;
    }

    // MARK: Detection

    List<string> CommandFolders => CommandFoldersOverride ?? ShellEnvironment.SearchFolders();

    string? FindCommand(string name)
    {
        foreach (var folder in CommandFolders)
            foreach (var extension in ShellEnvironment.Extensions)
            {
                var path = Path.Combine(folder, name + extension);
                if (File.Exists(path)) return path;
            }
        return null;
    }

    (string Location, string? Version, bool IsApp)? Installation(AgentDescriptor d)
    {
        foreach (var app in d.Apps)
        {
            var path = Resolve(app);
            if (!File.Exists(path)) continue;
            string? version = null;
            try { version = FileVersionInfo.GetVersionInfo(path).ProductVersion; } catch { }
            return (path, version, true);
        }
        foreach (var command in d.Commands)
        {
            if (FindCommand(command) is not { } path) continue;
            if (!VerifiesCommands) return (path, null, false);
            // "pi", "goose", "amp" are also the names of unrelated programs.
            if (Enum.GetValues<LocalAgent>().Where(a => a.Commands().Contains(command)).Any(a => !a.IsGenuine(path, command))) continue;
            foreach (var arguments in d.VersionArguments)
                if (CommandProbe.Run(path, arguments, 8) is { Status: 0 } result) return (path, CommandProbe.VersionIn(result.Output), false);
        }
        return null;
    }

    public List<AgentStatus> Detect()
    {
        var results = new AgentStatus[Catalog.Count];
        Parallel.For(0, Catalog.Count, i => results[i] = Status(Catalog[i]));
        return [.. results];
    }

    public AgentStatus Status(AgentDescriptor d)
    {
        var installation = Installation(d);
        var entry = InstalledCommand(d);
        bool stale = entry != null && !string.Equals(entry, CliPath, StringComparison.OrdinalIgnoreCase) && !File.Exists(entry);
        var skillFolder = d.SkillFolders.FirstOrDefault(f => IsOurs(SkillFile(f)));
        return new AgentStatus(d, installation != null, installation?.Location, installation?.Version, installation?.IsApp ?? false, entry != null,
                               skillFolder != null, stale, ConfigPath(d), skillFolder);
    }

    // MARK: MCP

    public string? ConfigPath(AgentDescriptor d) => d.Mcp switch
    {
        null => null,
        McpTarget.ClaudeCode => Display(".claude.json"),
        McpTarget.Codex => Display(".codex/config.toml"),
        McpTarget.JsonFile j => Display(j.Path),
        McpTarget.JsonAny a => a.Paths.FirstOrDefault(p => CommandInJson(p, a.Key, a.Style) != null) is { } found ? Display(found)
            : Targets(a.Paths, a.Policy).Select(Display).FirstOrDefault(),
        McpTarget.Toml t => Display(t.Path),
        McpTarget.Yaml y => Display(y.Path),
        McpTarget.OpenClaw => Display(".openclaw/openclaw.json"),
        _ => null,
    };

    public string? InstalledCommand(AgentDescriptor d) => d.Mcp switch
    {
        McpTarget.ClaudeCode => CommandInJson(".claude.json", "mcpServers", EntryStyle.ClaudeCode),
        McpTarget.Codex => TomlCommand(CodexConfig),
        McpTarget.Toml t => TomlCommand(Resolve(t.Path)),
        McpTarget.Yaml y => File.Exists(Resolve(y.Path)) ? YamlServers.Value(y.Style == YamlStyle.Goose ? "cmd" : "command", File.ReadAllText(Resolve(y.Path)), y.Key, ServerName) : null,
        McpTarget.OpenClaw => OpenClawCommand(),
        McpTarget.JsonFile j => CommandInJson(j.Path, j.Key, j.Style),
        McpTarget.JsonAny a => a.Paths.Select(p => CommandInJson(p, a.Key, a.Style)).FirstOrDefault(c => c != null),
        _ => null,
    };

    public void SetMcp(bool enabled, AgentDescriptor d)
    {
        switch (d.Mcp)
        {
            case null:
                throw new AgentIntegrationError(Loc.S("%@ 不支持 MCP。", d.Name));
            case McpTarget.ClaudeCode:
                if (enabled) { try { RunAgentCommand("claude", ["mcp", "remove", "--scope", "user", ServerName]); } catch { } }
                if (!RunAgentCommand("claude", enabled ? ["mcp", "add", "--scope", "user", ServerName, "--", CliPath, "mcp"] : ["mcp", "remove", "--scope", "user", ServerName]))
                    EditJson(".claude.json", "mcpServers", EntryStyle.ClaudeCode, enabled);
                break;
            case McpTarget.Codex:
                if (enabled) { try { RunAgentCommand("codex", ["mcp", "remove", ServerName]); } catch { } }
                if (!RunAgentCommand("codex", enabled ? ["mcp", "add", ServerName, "--", CliPath, "mcp"] : ["mcp", "remove", ServerName]))
                    EditToml(CodexConfig, enabled);
                break;
            case McpTarget.JsonFile j:
                EditJson(j.Path, j.Key, j.Style, enabled);
                break;
            case McpTarget.JsonAny a:
                if (enabled) foreach (var path in Targets(a.Paths, a.Policy)) EditJson(path, a.Key, a.Style, true);
                else foreach (var path in a.Paths.Where(p => File.Exists(Resolve(p)))) EditJson(path, a.Key, a.Style, false);
                break;
            case McpTarget.Toml t:
                EditToml(Resolve(t.Path), enabled);
                break;
            case McpTarget.Yaml y:
                EditYaml(y, enabled);
                break;
            case McpTarget.OpenClaw:
                if (!RunAgentCommand("openclaw", enabled ? ["mcp", "set", ServerName, Entry(EntryStyle.Standard).Render("", "")] : ["mcp", "unset", ServerName]))
                    throw new AgentIntegrationError(Loc.S("未能添加 %@ 的配置，请检查 %@。", d.Name, Display(".openclaw/openclaw.json")));
                break;
        }
        // Trust but verify: the agent's own tool may have written somewhere else.
        if ((InstalledCommand(d) != null) != enabled)
        {
            var file = ConfigPath(d) ?? Loc.S("其配置文件");
            throw new AgentIntegrationError(enabled ? Loc.S("未能添加 %@ 的配置，请检查 %@。", d.Name, file) : Loc.S("未能移除 %@ 的配置，请检查 %@。", d.Name, file));
        }
    }

    List<string> Targets(string[] paths, WritePolicy policy)
    {
        bool FolderExists(string p) => Directory.Exists(Path.GetDirectoryName(Resolve(p)));
        return policy switch
        {
            WritePolicy.ExistingFile => [paths.FirstOrDefault(p => File.Exists(Resolve(p))) ?? paths[0]],
            WritePolicy.ExistingFolder => [paths.FirstOrDefault(FolderExists) ?? paths[0]],
            _ => paths.Where(FolderExists).DefaultIfEmpty(paths[0]).ToList(),
        };
    }

    /// <summary>Re-points configured agents at the current folio-cli (after Folio moved). Returns their names.</summary>
    public List<string> RepairMovedPaths()
    {
        var names = new List<string>();
        foreach (var status in Detect().Where(s => s.McpNeedsUpdate))
        {
            try { SetMcp(true, status.Descriptor); names.Add(status.Descriptor.Name); } catch { }
        }
        return names;
    }

    /// <summary>The JSON entry other agents need, for "复制 MCP 配置".</summary>
    public string ManualConfiguration => new OrderedJson.Obj([("mcpServers", new OrderedJson.Obj([(ServerName, Entry(EntryStyle.Standard))]))]).Render("", "  ");

    OrderedJson Entry(EntryStyle style)
    {
        var args = new OrderedJson.Arr([new OrderedJson.Str("mcp")]);
        return style switch
        {
            EntryStyle.Standard => new OrderedJson.Obj([("command", new OrderedJson.Str(CliPath)), ("args", args)]),
            EntryStyle.ClaudeCode => new OrderedJson.Obj([("type", new OrderedJson.Str("stdio")), ("command", new OrderedJson.Str(CliPath)), ("args", args), ("env", new OrderedJson.Obj([]))]),
            EntryStyle.Opencode => new OrderedJson.Obj([("type", new OrderedJson.Str("local")), ("command", new OrderedJson.Arr([new OrderedJson.Str(CliPath), new OrderedJson.Str("mcp")])), ("enabled", new OrderedJson.Bool(true))]),
            _ => new OrderedJson.Obj([("type", new OrderedJson.Str("local")), ("command", new OrderedJson.Str(CliPath)), ("args", args), ("env", new OrderedJson.Obj([])),
                                      ("tools", new OrderedJson.Arr([new OrderedJson.Str("*")]))]),
        };
    }

    /// <summary>Runs an agent's CLI; false when it is not installed or commands are off.</summary>
    bool RunAgentCommand(string name, string[] arguments)
    {
        if (!useAgentCommands || FindCommand(name) is not { } path) return false;
        var result = CommandProbe.Run(path, arguments, 30)
                     ?? throw new AgentIntegrationError(Loc.S("%@ %@ 没有在 30 秒内完成。", name, string.Join(" ", arguments.Take(2))));
        if (result.Status != 0 && !arguments.Contains("remove"))
            throw new AgentIntegrationError(Loc.S("%@ %@ 失败：%@", name, string.Join(" ", arguments.Take(2)), result.Output[..Math.Min(300, result.Output.Length)]));
        return true;
    }

    string? CommandInJson(string path, string key, EntryStyle style)
    {
        var file = Resolve(path);
        if (!File.Exists(file)) return null;
        try
        {
            var entry = new JsoncDocument(File.ReadAllText(file)).Object()[key]?[ServerName];
            if (entry == null) return null;
            return style == EntryStyle.Opencode ? (entry["command"] as JsonArray)?.FirstOrDefault().Str() : entry["command"].Str();
        }
        catch { return null; }
    }

    /// <summary>Adds or removes Folio's entry, keeping everything else in the file exactly as it was.</summary>
    public void EditJson(string path, string key, EntryStyle style, bool enabled)
    {
        var file = Resolve(path);
        var existing = File.Exists(file) ? File.ReadAllText(file) : null;
        if (existing == null && !enabled) return;
        var document = new JsoncDocument(existing ?? "");
        try { document.SetMember(ServerName, key, enabled ? Entry(style) : null); }
        catch (Exception e) { throw new AgentIntegrationError(Loc.S("无法解析 %@（%@），为避免破坏它，请手动添加：\n%@", file, e.Message, ManualConfiguration)); }
        if (document.Text == existing) return;
        if (existing != null) BackUp(file);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, document.Text);
    }

    static void BackUp(string file)
    {
        var backup = file + ".folio-backup";
        if (!File.Exists(backup)) try { File.Copy(file, backup); } catch { }
    }

    // MARK: Codex TOML

    void EditYaml(McpTarget.Yaml y, bool enabled)
    {
        var file = Resolve(y.Path);
        var existing = File.Exists(file) ? File.ReadAllText(file) : null;
        if (existing == null && !enabled) return;
        var command = YamlServers.Quoted(CliPath);
        string[] fields = y.Style == YamlStyle.Goose
            ? ["enabled: true", "type: stdio", $"name: {ServerName}", "description: Folio library", $"cmd: {command}", "args: [\"mcp\"]", "envs: {}", "env_keys: []", "timeout: 300", "bundled: null", "available_tools: []"]
            : [$"command: {command}", "args: [\"mcp\"]"];
        string text;
        try { text = YamlServers.Edited(existing ?? "", y.Key, ServerName, enabled ? fields : null); }
        catch (YamlServers.Unsupported e) { throw new AgentIntegrationError(Loc.S("无法解析 %@（%@），为避免破坏它，请手动添加：\n%@", file, e.Message, ManualConfiguration)); }
        if (text == existing) return;
        if (existing != null) BackUp(file);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, text);
    }

    string? OpenClawCommand()
    {
        var file = Resolve(".openclaw/openclaw.json");
        if (!File.Exists(file)) return null;
        try { return new JsoncDocument(File.ReadAllText(file)).Object()["mcp"]?["servers"]?[ServerName]?["command"].Str(); }
        catch { return null; }
    }

    string CodexConfig => Resolve(".codex/config.toml");
    static string CodexHeader => $"[mcp_servers.{ServerName}]";

    public string? TomlCommand(string file)
    {
        if (!File.Exists(file)) return null;
        var lines = File.ReadAllText(file).Split('\n');
        int start = Array.FindIndex(lines, l => l.Trim() == CodexHeader);
        if (start < 0) return null;
        foreach (var line in lines.Skip(start + 1))
        {
            var t = line.Trim();
            if (t.StartsWith('[')) break;
            if (!t.StartsWith("command")) continue;
            int quote = t.IndexOfAny(['"', '\'']);
            if (quote < 0) continue;
            char delimiter = t[quote];
            var rest = t[(quote + 1)..];
            if (delimiter == '"')
            {
                var m = Regex.Match(rest, @"^((?:[^""\\]|\\.)*)""");
                if (m.Success) return m.Groups[1].Value.Replace("\\\\", "\\").Replace("\\\"", "\"");
            }
            int end = rest.IndexOf(delimiter);
            return end >= 0 ? rest[..end] : null;
        }
        return "";
    }

    public void EditToml(string file, bool enabled)
    {
        var text = File.Exists(file) ? File.ReadAllText(file) : "";
        if (text.Length > 0) BackUp(file);
        var lines = text.Replace("\r\n", "\n").Split('\n').ToList();
        int start = lines.FindIndex(l => l.Trim() == CodexHeader);
        if (start >= 0)
        {
            int end = start + 1;
            while (end < lines.Count && !lines[end].Trim().StartsWith('[')) end++;
            while (end < lines.Count && lines[end].Trim().StartsWith($"[mcp_servers.{ServerName}."))
            {
                end++;
                while (end < lines.Count && !lines[end].Trim().StartsWith('[')) end++;
            }
            lines.RemoveRange(start, end - start);
        }
        text = string.Join("\n", lines).Trim('\n');
        if (enabled)
        {
            var escaped = CliPath.Replace("\\", "\\\\").Replace("\"", "\\\"");
            text += (text.Length == 0 ? "" : "\n\n") + $"{CodexHeader}\ncommand = \"{escaped}\"\nargs = [\"mcp\"]";
        }
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, text + "\n");
    }

    // MARK: Skills

    string SkillFile(string folder) => Path.Combine(Resolve(folder), FolioSkill.Name, "SKILL.md");

    static bool IsOurs(string file)
    {
        try { return File.Exists(file) && File.ReadAllText(file).Contains(FolioSkill.Marker); } catch { return false; }
    }

    string? SkillTarget(AgentDescriptor d) =>
        d.SkillFolders.FirstOrDefault(f => Directory.Exists(Path.GetDirectoryName(Resolve(f)))) ?? d.SkillFolders.FirstOrDefault();

    /// <summary>Other agents that would no longer see Folio's skill if it were removed for d.</summary>
    public List<AgentDescriptor> AgentsLosingSkill(AgentDescriptor d)
    {
        var removed = d.SkillFolders.Where(f => IsOurs(SkillFile(f))).ToHashSet();
        return Catalog.Where(other =>
        {
            if (other.Id == d.Id) return false;
            var visible = other.SkillFolders.Where(f => IsOurs(SkillFile(f))).ToHashSet();
            return visible.Count > 0 && visible.IsSubsetOf(removed);
        }).ToList();
    }

    public void SetSkill(bool enabled, AgentDescriptor d)
    {
        var target = SkillTarget(d) ?? throw new AgentIntegrationError(d.SkillNote ?? Loc.S("%@ 不支持技能。", d.Name));
        if (enabled)
        {
            var folder = d.SkillFolders.FirstOrDefault(f => IsOurs(SkillFile(f))) ?? target;
            FolioSkill.Write(Path.Combine(Resolve(folder), FolioSkill.Name), CliPath);
            return;
        }
        foreach (var folder in d.SkillFolders)
        {
            var file = SkillFile(folder);
            if (!File.Exists(file)) continue;
            if (!IsOurs(file))
            {
                if (folder == target) throw new AgentIntegrationError(Loc.S("%@ 不是 Folio 安装的技能，未删除。", Path.GetDirectoryName(file)!));
                continue;
            }
            Directory.Delete(Path.GetDirectoryName(file)!, true);
        }
    }

    /// <summary>Writes the skill folder (for agents configured by hand or uploaded as a package).</summary>
    public string ExportSkill(string folder)
    {
        var target = Path.Combine(folder, FolioSkill.Name);
        FolioSkill.Write(target, CliPath);
        return target;
    }

    /// <summary>Refreshes skills Folio installed earlier (new text, or a moved folio-cli). Returns how many were rewritten.</summary>
    public int RefreshInstalledSkills()
    {
        int count = 0;
        foreach (var retired in RetiredSkillFolders.Where(f => IsOurs(SkillFile(f))))
        {
            try
            {
                FolioSkill.Write(Path.Combine(Resolve(SharedSkillsFolder), FolioSkill.Name), CliPath);
                Directory.Delete(Path.GetDirectoryName(SkillFile(retired))!, true);
                count++;
            }
            catch { }
        }
        foreach (var folder in Catalog.SelectMany(c => c.SkillFolders).Distinct().Order())
        {
            var file = SkillFile(folder);
            if (!IsOurs(file)) continue;
            var text = File.ReadAllText(file);
            var referenced = Regex.Match(text, @"([A-Za-z]:\\[^\s""`']*folio-cli(?:\.exe)?)");
            bool ours = text.Contains(CliPath);
            bool orphaned = !referenced.Success || !File.Exists(referenced.Groups[1].Value);
            var target = Path.GetDirectoryName(file)!;
            if (!(ours || orphaned) || FolioSkill.IsCurrent(target, CliPath)) continue;
            try { FolioSkill.Write(target, CliPath); count++; } catch { }
        }
        return count;
    }
}
