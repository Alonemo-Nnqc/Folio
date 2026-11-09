using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Folio.Core.Translate.Services;

// Port of macos/.../FolioTranslate/Services/LocalAgents.swift, AgentModels.swift and Support/ShellEnvironment.swift.
// On Windows the agents are npm shims (claude.cmd …), native installers' .exe files or scripts on PATH.

/// <summary>Coding agents that can translate from the command line with the user's own login, no key needed in Folio.</summary>
public enum LocalAgent { Claude, Codex, Gemini, Grok, Antigravity, Copilot, Cursor, Qwen, Opencode, Kiro, Cline, Kimi, Droid, Amp, Goose, Pi, Hermes, Openclaw, Deepseek }

public static partial class LocalAgents
{
    public static readonly LocalAgent[] All = Enum.GetValues<LocalAgent>();

    public static string Command(this LocalAgent agent) => agent.Commands()[0];

    /// <summary>Names the command goes by, most specific first.</summary>
    public static string[] Commands(this LocalAgent agent) => agent switch
    {
        LocalAgent.Claude => ["claude"],
        LocalAgent.Codex => ["codex"],
        LocalAgent.Gemini => ["gemini"],
        LocalAgent.Grok => ["grok"],
        LocalAgent.Antigravity => ["agy"],
        LocalAgent.Copilot => ["copilot"],
        LocalAgent.Cursor => ["cursor-agent", "agent"],
        LocalAgent.Qwen => ["qwen"],
        LocalAgent.Opencode => ["opencode"],
        LocalAgent.Kiro => ["kiro-cli"],
        LocalAgent.Cline => ["cline"],
        LocalAgent.Kimi => ["kimi"],
        LocalAgent.Droid => ["droid"],
        LocalAgent.Amp => ["amp"],
        LocalAgent.Goose => ["goose"],
        LocalAgent.Pi => ["pi"],
        LocalAgent.Hermes => ["hermes"],
        LocalAgent.Openclaw => ["openclaw"],
        _ => ["dsh"],
    };

    public static string ServiceId(this LocalAgent agent) => agent switch
    {
        LocalAgent.Claude => "claudecode",
        LocalAgent.Codex => "codex",
        LocalAgent.Gemini => "geminicli",
        LocalAgent.Grok => "grokcli",
        LocalAgent.Antigravity => "antigravitycli",
        LocalAgent.Copilot => "copilotcli",
        LocalAgent.Cursor => "cursoragent",
        LocalAgent.Qwen => "qwencode",
        LocalAgent.Opencode => "opencode",
        LocalAgent.Kiro => "kirocli",
        LocalAgent.Cline => "clinecli",
        LocalAgent.Kimi => "kimicli",
        LocalAgent.Droid => "droidcli",
        LocalAgent.Amp => "ampcli",
        LocalAgent.Goose => "gooseagent",
        LocalAgent.Pi => "picli",
        LocalAgent.Hermes => "hermesagent",
        LocalAgent.Openclaw => "openclawagent",
        _ => "deepseekharness",
    };

    /// <summary>The thinking levels the command takes, lowest first (empty: it has no such option).</summary>
    public static string[] EffortLevels(this LocalAgent agent) => agent switch
    {
        LocalAgent.Claude or LocalAgent.Antigravity => ["low", "medium", "high", "xhigh", "max"],
        LocalAgent.Codex => ["minimal", "low", "medium", "high", "xhigh", "max"],
        LocalAgent.Grok => ["low", "medium", "high"],
        LocalAgent.Pi => ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
        LocalAgent.Hermes => ["none", "minimal", "low", "medium", "high", "xhigh", "max"],
        _ => [],
    };

    /// <summary>The level used until the user chooses: translating needs little thinking.</summary>
    public static string? DefaultEffort(this LocalAgent agent) => agent switch
    {
        LocalAgent.Claude or LocalAgent.Antigravity or LocalAgent.Codex or LocalAgent.Grok or LocalAgent.Hermes => "low",
        LocalAgent.Pi => "off",
        _ => null,
    };

    [GeneratedRegex(@"(?:[-:](low|medium|high|xhigh|thinking)|:(off|minimal|max))$")]
    private static partial Regex LevelInName();

    /// <summary>The level a model's own name says ("gemini-3.8-flash-high", "provider/model:high").</summary>
    public static string? EffortInModelName(string? model)
    {
        if (model == null) return null;
        var m = LevelInName().Match(model.Trim().ToLowerInvariant());
        if (!m.Success) return null;
        return m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value;
    }

    /// <summary>Naming a model takes the level with it: agy accepts --effort only for its default model.</summary>
    public static bool ModelDecidesEffort(this LocalAgent agent) => agent == LocalAgent.Antigravity;

    static List<string> EffortArguments(LocalAgent agent, string? effort, string? model)
    {
        bool named = !string.IsNullOrWhiteSpace(model);
        if (EffortInModelName(model) != null || (agent.ModelDecidesEffort() && named)) return [];
        var level = effort ?? agent.DefaultEffort();
        if (string.IsNullOrEmpty(level)) return [];
        return agent switch
        {
            LocalAgent.Claude or LocalAgent.Antigravity => ["--effort", level],
            LocalAgent.Codex => ["-c", $"model_reasoning_effort=\"{level}\""],
            LocalAgent.Grok => ["--reasoning-effort", level],
            LocalAgent.Pi => ["--thinking", level],
            LocalAgent.Hermes => ["--reasoning", level],
            _ => [],
        };
    }

    /// <summary>For a command name other programs use too: what its --help has to say.</summary>
    static (string Pattern, int Within)? Signature(LocalAgent agent, string command) => (agent, command) switch
    {
        (LocalAgent.Cursor, "agent") => ("(?i)cursor", 200),
        (LocalAgent.Pi, _) => ("(?i)coding (assistant|agent)", 400),
        (LocalAgent.Amp, _) => (@"(?i)\bamp\b", 2000),
        (LocalAgent.Droid, _) => ("(?i)droid|factory", 2000),
        (LocalAgent.Goose, _) => ("(?i)session|recipe", 4000),
        (LocalAgent.Hermes, _) => ("(?i)hermes agent", 8000),
        (LocalAgent.Kimi, _) => ("(?i)kimi", 2000),
        (LocalAgent.Deepseek, _) => ("(?i)deepseek", 2000),
        _ => null,
    };

    static readonly ConcurrentDictionary<string, bool> Genuine = new();

    public static bool IsGenuine(this LocalAgent agent, string path, string command)
    {
        if (Signature(agent, command) is not { } signature) return true;
        var key = $"{agent}|{path}";
        if (Genuine.TryGetValue(key, out var known)) return known;
        // A first start can take long (a large script, an antivirus scan): no answer in time says nothing about whose command it is.
        if (CommandProbe.Run(path, ["--help"], 30) is not { } result) return true;
        var head = result.Output[..Math.Min(signature.Within, result.Output.Length)];
        return Genuine[key] = Regex.IsMatch(head, signature.Pattern);
    }

    /// <summary>The command on this computer: customPath when it exists, else the first match on PATH and the usual install folders.</summary>
    public static string? Locate(this LocalAgent agent, string? customPath = null)
    {
        if (!string.IsNullOrWhiteSpace(customPath))
        {
            var expanded = Environment.ExpandEnvironmentVariables(customPath.Trim().Trim('"'));
            if (expanded.StartsWith('~')) expanded = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), expanded[1..].TrimStart('/', '\\'));
            return File.Exists(expanded) ? expanded : null;
        }
        var folders = ShellEnvironment.SearchFolders();
        foreach (var command in agent.Commands())
            foreach (var folder in folders)
                foreach (var extension in ShellEnvironment.Extensions)
                {
                    var path = Path.Combine(folder, command + extension);
                    if (File.Exists(path) && IsGenuine(agent, path, command)) return path;
                }
        return null;
    }

    /// <summary>The installed agents, in catalog order.</summary>
    public static List<LocalAgent> Installed()
    {
        var found = new bool[All.Length];
        Parallel.For(0, All.Length, k => found[k] = All[k].Locate() != null);
        return All.Where((_, k) => found[k]).ToList();
    }

    public static string? Version(this LocalAgent agent, string path)
    {
        if (CommandProbe.Run(path, ["--version"], 25) is not { Status: 0 } result) return null;
        return CommandProbe.VersionIn(result.Output);
    }

    /// <summary>Arguments for one request. The prompt goes to stdin unless PromptArgument (it then comes last).
    /// CombineSystem: the agent has no option for a system prompt.</summary>
    public static (List<string> Arguments, bool PromptArgument, bool CombineSystem) Arguments(this LocalAgent agent, string? model, string? effort, string system, string outputFile)
    {
        model = string.IsNullOrWhiteSpace(model) ? null : model.Trim();
        var thinking = EffortArguments(agent, effort, model);
        List<string> WithModel(List<string> args, string flag) { if (model != null) args.AddRange([flag, model]); return args; }
        switch (agent)
        {
            case LocalAgent.Claude:
                return (WithModel(["-p", "--output-format", "json", "--tools", "", "--no-session-persistence", "--strict-mcp-config",
                                   "--disable-slash-commands", "--system-prompt", system, .. thinking], "--model"), false, false);
            case LocalAgent.Codex:
                return ([.. WithModel(["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                                       "-c", "mcp_servers={}", "-o", outputFile, .. thinking], "-m"), "-"], false, true);
            case LocalAgent.Gemini:
                return ([.. WithModel(["-o", "json", "-e", "none"], "-m"), "-p", " "], false, true);
            case LocalAgent.Grok:
                return ([.. WithModel(["--output-format", "plain", "--no-subagents", "--disable-web-search", "--no-plan", "--max-turns", "1", "--verbatim", .. thinking], "-m"), "-p"], true, true);
            case LocalAgent.Antigravity:
                return ([.. WithModel(["--output-format", "text", "--sandbox", "--disable-slash-commands", .. thinking], "--model"), "-p"], true, true);
            case LocalAgent.Copilot:
                return ([.. WithModel(["-s"], "--model"), "-p"], true, true);
            case LocalAgent.Qwen:
                return ([.. WithModel([], "-m"), "-p", " "], false, true);
            case LocalAgent.Opencode:
                return (WithModel(["run"], "-m"), true, true);
            case LocalAgent.Cursor:
                return (WithModel(["-p", "--output-format", "text"], "--model"), true, true);
            case LocalAgent.Kiro:
                return (WithModel(["chat", "--no-interactive"], "--model"), true, true);
            case LocalAgent.Cline:
                return (WithModel(["--json", "-p"], "-m"), true, true);
            case LocalAgent.Kimi:
                return ([.. WithModel(["--quiet"], "-m"), "-p"], true, true);
            case LocalAgent.Droid:
                return (WithModel(["exec", "-o", "text"], "-m"), true, true);
            case LocalAgent.Amp:
                return (["-x"], true, true);
            case LocalAgent.Goose:
                return ([.. WithModel(["run", "--no-session", "-q"], "--model"), "-t"], true, true);
            case LocalAgent.Pi:
                return (WithModel(["-p", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-prompt-templates",
                                   "--no-context-files", "--no-mcp", "--offline", "--system-prompt", system, .. thinking], "--model"), true, false);
            case LocalAgent.Hermes:
                return ([.. WithModel(["--ignore-rules", .. thinking], "-m"), "-z"], true, true);
            case LocalAgent.Openclaw:
                return ([.. WithModel(["infer", "model", "run", "--local", "--json"], "--model"), "--prompt"], true, true);
            default:
                // "-": the task from stdin, so a long prompt never meets a command line's limit.
                return (["--profile", "headless", "-"], false, true);
        }
    }

    /// <summary>The model's answer in what the command printed.</summary>
    public static string Answer(this LocalAgent agent, string stdout, string outputFile)
    {
        switch (agent)
        {
            case LocalAgent.Claude:
            {
                var obj = TryObject(stdout.Trim()) ?? LLMBatch.JsonObjectIn(stdout);
                if (obj == null) return stdout;
                if (obj["is_error"] is JsonValue e && e.TryGetValue<bool>(out var isError) && isError)
                    throw new ProviderError(ProviderError.Kinds.Process, Str(obj["result"]) ?? stdout);
                return Str(obj["result"]) ?? stdout;
            }
            case LocalAgent.Codex:
                try { return File.ReadAllText(outputFile, Encoding.UTF8); } catch { return stdout; }
            case LocalAgent.Gemini:
                return LLMBatch.JsonObjectIn(stdout) is { } g && Str(g["response"]) is { } response ? response : stdout;
            case LocalAgent.Openclaw:
            {
                if (LLMBatch.JsonObjectIn(stdout) is not { } obj) return stdout;
                if (obj["ok"] is JsonValue ok && ok.TryGetValue<bool>(out var good) && !good)
                    throw new ProviderError(ProviderError.Kinds.Process, Str(obj["error"]) ?? Str(obj["message"]) ?? stdout);
                return obj["outputs"] is JsonArray outputs ? string.Join("\n", outputs.Select(o => Str(o?["text"])).OfType<string>()) : stdout;
            }
            case LocalAgent.Cline:
                foreach (var line in stdout.Split('\n', StringSplitOptions.RemoveEmptyEntries).Reverse())
                    if (TryObject(line) is { } obj && Str(obj["type"]) == "run_result" && Str(obj["text"]) is { } text) return text;
                return stdout;
            default:
                return stdout;
        }
    }

    internal static string? Str(JsonNode? node) => node is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    static JsonObject? TryObject(string text)
    {
        try { return JsonNode.Parse(text) as JsonObject; } catch { return null; }
    }
}

/// <summary>What a failed agent run means: something to wait out, something the user has to set up, or a mishap worth another try.</summary>
public static class AgentFailure
{
    public static ProviderError Setup(LocalAgent agent, string text) =>
        new(ProviderError.Kinds.AgentSetup, $"agent-setup {agent.Command()}: " + FirstMeaningfulLine(text));

    public static bool RefusesTheLevel(string text) => Regex.IsMatch(text,
        @"(--effort|--reasoning(-effort)?|--thinking|reasoning[_ ]effort)[^\n]{0,60}(not supported|unsupported|conflicts?|invalid|unknown)|(not supported|unsupported|conflicts? with|invalid|unknown)[^\n]{0,60}(--effort|--reasoning|--thinking|reasoning[_ ]effort)",
        RegexOptions.IgnoreCase);

    public static ProviderError Classify(string text, LocalAgent agent)
    {
        var clean = StripAnsi(text);
        var said = FirstMeaningfulLine(clean);
        if (clean.Contains("{\"") || clean.Contains("{\n")) clean = said;
        var detail = $"agent {agent.Command()}: " + said;
        bool Has(string pattern) => Regex.IsMatch(clean, pattern, RegexOptions.IgnoreCase);
        // Codex has already reconnected five times by then: retrying the batch only makes the translation look stuck.
        // Usually its provider's address is wrong (a relay without /v1 answers with its web page).
        if (agent == LocalAgent.Codex && Has(@"stream disconnected before completion|stream closed before response\.completed"))
            return new ProviderError(ProviderError.Kinds.AgentSetup, ("agent-setup codex: stream-disconnected " + (AgentModels.CodexCustomProvider()?.BaseUrl ?? "")).TrimEnd());
        if (ProviderError.IsContentRefusal(clean)) return new ProviderError(ProviderError.Kinds.Refused, detail);
        if (Has(@"too many requests|rate.?limit|\b429\b|resource.?exhausted")) return ProviderError.HttpStatus(429, detail);
        if (Has(@"\b(http|status|code)[ :=]*402\b|insufficient.?(balance|quota|credit)|out of credits|usage limit|quota exceeded|exceeded your"))
            return ProviderError.HttpStatus(402, detail);
        if (RefusesTheLevel(clean)) return Setup(agent, clean);
        if (Has(@"(model|deployment)[^\n]{0,80}(not found|does not exist|not available|not supported|unavailable|invalid)|unknown model|invalid model|no such model"))
            return ProviderError.HttpStatus(404, detail + " model_not_found");
        if (Has(@"not (logged|signed) in|please (log|sign) ?in|log ?in (first|required)|run .{0,30}(login|auth)|no inference provider|not authenticated|authentication (is )?(required|failed)|unauthori[sz]ed|\b401\b|invalid.?api.?key|no api key|missing api key|set an api key|not configured|no (provider|model) (is )?(configured|selected)|first.?run|onboard|error authenticating|failed to authenticate|oauth|session expired|ineligible|no longer supported|migrate to"))
            return Setup(agent, clean);
        if (Has(@"unknown (option|flag|argument)|unrecognized (option|argument)|unexpected argument|invalid option|no such option|update required|please (update|upgrade)|command line is too long"))
            return Setup(agent, clean);
        var code = Regex.Match(clean, @"(?i)\bHTTP[ /:]*(?:1\.1 )?(\d{3})\b");
        if (code.Success && int.TryParse(code.Groups[1].Value, out var status)) return ProviderError.HttpStatus(status, detail + $" http {status}");
        return new ProviderError(ProviderError.Kinds.Process, detail);
    }

    /// <summary>An error printed as if it were the answer (exit status 0).</summary>
    public static ProviderError? InReply(string reply, LocalAgent agent)
    {
        var clean = StripAnsi(reply).Trim();
        if (clean.Length == 0) return new ProviderError(ProviderError.Kinds.InvalidResponse, $"agent {agent.Command()}: empty reply");
        if (clean.Contains('{') || !Regex.IsMatch(clean, @"(?i)^(api error|error\b|http[ /]?\d{3}|\w*error:|request failed|failed to)")) return null;
        return Classify(clean, agent);
    }

    public static string StripAnsi(string text) => Regex.Replace(text, @"\u001B\[[0-9;?]*[ -/]*[@-~]", "");

    public static string FirstMeaningfulLine(string text)
    {
        var cleaned = Regex.Replace(text, @"^exit -?\d+:\s*", "");
        if (TranslationErrorClassifier.FirstMatch(@"""(?:message|error|detail|result)""\s*:\s*""((?:[^""\\]|\\.)+)""", cleaned) is { } message)
            return message[..Math.Min(400, message.Length)];
        var lines = cleaned.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0 && !l.StartsWith("at ")).ToList();
        // Codex prints the prompt back before its errors; its own lines say "ERROR:".
        if (lines.LastOrDefault(l => l.StartsWith("ERROR:")) is { } marked) lines = [marked];
        var line = lines.FirstOrDefault(l => Regex.IsMatch(l, @"(?i)error|fail|denied|not |no |invalid|too many|unknown|please|http \d")) ?? lines.FirstOrDefault() ?? text;
        line = Regex.Replace(line, @"^(?i)(error:\s*)+", "");
        return line[..Math.Min(400, line.Length)];
    }
}

/// <summary>Translates with a local agent: large batches (each call starts the agent), a few at a time.</summary>
public sealed class AgentProvider(LocalAgent agent, string executable, string? model, string? effort) : ChatModel
{
    bool _usualLevelRefused;
    public override ProviderLimits Limits { get; } = new(5000, 60, 4, true, 8, 0.006);

    public override async Task<string> Complete(string system, string user, CancellationToken cancel)
    {
        try
        {
            return await Complete(system, user, Volatile.Read(ref _usualLevelRefused) ? "" : effort, cancel);
        }
        catch (ProviderError e) when (effort == null && !Volatile.Read(ref _usualLevelRefused) && AgentFailure.RefusesTheLevel(e.Detail))
        {
            // The usual level is our idea, not the user's: it must never stop a model they chose from working.
            Volatile.Write(ref _usualLevelRefused, true);
            return await Complete(system, user, "", cancel);
        }
    }

    async Task<string> Complete(string system, string user, string? level, CancellationToken cancel)
    {
        var outputFile = Path.Combine(Path.GetTempPath(), $"folio-agent-{Guid.NewGuid()}.txt");
        try
        {
            var (arguments, promptArgument, combine) = agent.Arguments(model, level, system, outputFile);
            var prompt = combine ? system + "\n\n---\n\nTranslate this JSON object:\n" + user : user;
            try
            {
                var stdout = await LocalProcess.Run([executable, .. arguments, .. promptArgument ? [prompt] : Array.Empty<string>()],
                                                    promptArgument ? "" : prompt, 600, cancel,
                                                    agent == LocalAgent.Deepseek ? DeepseekHarness.Environment() : null);
                var reply = AgentFailure.StripAnsi(agent.Answer(stdout, outputFile));
                if (AgentFailure.InReply(reply, agent) is { } failure) throw failure;
                return reply;
            }
            catch (ProviderError e) when (e.Kind == ProviderError.Kinds.Process)
            {
                throw AgentFailure.Classify(e.Detail, agent);
            }
        }
        finally
        {
            try { File.Delete(outputFile); } catch { }
        }
    }
}

/// <summary>Where commands are found: PATH as the user's terminal has it (the registry's, not only this process's),
/// plus the folders installers use.</summary>
public static class ShellEnvironment
{
    public static string[] Extensions => OperatingSystem.IsWindows() ? [".exe", ".cmd", ".bat", ".com", ".ps1", ""] : [""];

    static readonly object EnvironmentLock = new();
    static Dictionary<string, string>? _terminal;
    static DateTime _terminalFailed;

    /// <summary>Forget what was read: the user may just have installed something or changed their profile.</summary>
    public static void Reset()
    {
        lock (EnvironmentLock) { _terminal = null; _terminalFailed = default; }
    }

    /// <summary>What the user's PowerShell profile adds to the environment (API keys, a proxy, a Node version manager's PATH):
    /// a terminal has it and an app started from the desktop does not. Read once; empty without a profile.</summary>
    public static Dictionary<string, string> TerminalEnvironment()
    {
        if (!OperatingSystem.IsWindows()) return [];
        lock (EnvironmentLock)
        {
            if (_terminal != null) return _terminal;
            if (DateTime.UtcNow - _terminalFailed < TimeSpan.FromMinutes(1)) return [];
            var read = ReadTerminalEnvironment();
            if (read == null) { _terminalFailed = DateTime.UtcNow; return []; }
            return _terminal = read;
        }
    }

    static Dictionary<string, string>? ReadTerminalEnvironment()
    {
        var documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        bool HasProfile(string folder) => Directory.Exists(Path.Combine(documents, folder))
            && Directory.EnumerateFiles(Path.Combine(documents, folder), "*profile.ps1").Any();
        // The shell whose profile exists: PowerShell 7, then Windows PowerShell.
        string? shell = HasProfile("PowerShell") ? "pwsh.exe" : HasProfile("WindowsPowerShell") ? "powershell.exe" : null;
        if (shell == null) return [];
        const string marker = "__FOLIO_ENV__";
        // Base64 of JSON between markers: a profile may print greetings, and the console's code page must not touch the values.
        var script = "$e=@{};Get-ChildItem env:|ForEach-Object{$e[$_.Name]=$_.Value};" +
                     $"'{marker}'+[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($e|ConvertTo-Json -Compress)))+'{marker}'";
        try
        {
            var info = new ProcessStartInfo(shell) { RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in new[] { "-NoLogo", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script }) info.ArgumentList.Add(a);
            using var process = Process.Start(info);
            if (process == null) return null;
            process.StandardInput.Close();
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(TimeSpan.FromSeconds(15)))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                return null;
            }
            if (!output.Wait(2000)) return null;
            var m = Regex.Match(output.Result, marker + "([A-Za-z0-9+/=]+)" + marker);
            if (!m.Success) return null;
            var json = JsonNode.Parse(Convert.FromBase64String(m.Groups[1].Value)) as JsonObject;
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var (key, value) in json ?? []) if (LocalAgents.Str(value) is { } text) result[key] = text;
            return result;
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// <summary>Folders named after each installed version, newest first: where version managers keep Node and global npm commands.</summary>
    static IEnumerable<string> VersionFolders(string parent, string suffix = "")
    {
        try
        {
            return Directory.Exists(parent)
                ? Directory.EnumerateDirectories(parent).OrderByDescending(d => d, StringComparer.OrdinalIgnoreCase).Select(d => Path.Combine(d, suffix))
                : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    public static List<string> SearchFolders()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var paths = new List<string>();
        void Add(string? list)
        {
            if (string.IsNullOrEmpty(list)) return;
            paths.AddRange(list.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries).Select(p => Environment.ExpandEnvironmentVariables(p.Trim().Trim('"'))));
        }
        Add(Environment.GetEnvironmentVariable("PATH"));
        if (OperatingSystem.IsWindows())
        {
            // Installed since Folio started: the registry has it, this process does not.
            Add(Environment.GetEnvironmentVariable("Path", EnvironmentVariableTarget.User));
            Add(Environment.GetEnvironmentVariable("Path", EnvironmentVariableTarget.Machine));
            Add(TerminalEnvironment().GetValueOrDefault("PATH"));
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            paths.AddRange([
                Path.Combine(appData, "npm"), Path.Combine(home, ".local", "bin"), Path.Combine(home, ".bun", "bin"),
                Path.Combine(home, "scoop", "shims"), Path.Combine(local, "Microsoft", "WinGet", "Links"), Path.Combine(home, ".cargo", "bin"),
                Path.Combine(local, "pnpm"), Path.Combine(home, ".deno", "bin"), Path.Combine(local, "Programs", "cursor-agent"),
                Path.Combine(home, ".volta", "bin"), Path.Combine(local, "Volta", "bin"), Path.Combine(home, ".opencode", "bin"),
                Path.Combine(home, ".claude", "local"), Path.Combine(home, ".grok", "bin"), Path.Combine(home, ".cursor", "bin"), Path.Combine(home, ".kimi", "bin"),
                Path.Combine(home, ".kiro", "bin"), Path.Combine(home, ".factory", "bin"), Path.Combine(home, ".amp", "bin"), Path.Combine(home, ".antigravity", "antigravity", "bin"),
                Path.Combine(home, "scoop", "apps", "nodejs", "current"), Path.Combine(home, "scoop", "apps", "nodejs-lts", "current"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs"),
            ]);
            if (Environment.GetEnvironmentVariable("NVM_SYMLINK") is { Length: > 0 } nvmLink) paths.Add(nvmLink);
            // A global npm install lives in the folder of each Node version a version manager keeps; pip's scripts in each Python's.
            paths.AddRange(VersionFolders(Environment.GetEnvironmentVariable("NVM_HOME") is { Length: > 0 } nvm ? nvm : Path.Combine(appData, "nvm")));
            paths.AddRange(VersionFolders(Path.Combine(appData, "fnm", "node-versions"), "installation"));
            paths.AddRange(VersionFolders(Path.Combine(appData, "Python"), "Scripts"));
            paths.AddRange(VersionFolders(Path.Combine(local, "Programs", "Python"), "Scripts"));
        }
        else
        {
            paths.AddRange([Path.Combine(home, ".local/bin"), Path.Combine(home, ".bun/bin"), Path.Combine(home, ".npm-global/bin"),
                "/opt/homebrew/bin", "/usr/local/bin", Path.Combine(home, ".cargo/bin"), Path.Combine(home, ".opencode/bin")]);
        }
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return paths.Where(p => p.Length > 0 && seen.Add(p.TrimEnd('\\', '/'))).ToList();
    }

    /// <summary>What the agent would see in the user's terminal: their environment, PATH completed, no colours.</summary>
    public static Dictionary<string, string> Environment_()
    {
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables())
            env[(string)e.Key] = (string?)e.Value ?? "";
        // What the terminal has on top: a key or a proxy set in the PowerShell profile works here as it does there.
        foreach (var (key, value) in TerminalEnvironment())
            if (key is not ("PATH" or "PSModulePath" or "PSExecutionPolicyPreference")) env[key] = value;
        foreach (var key in new[] { "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT", "CODEX_SANDBOX", "TERM_PROGRAM", "TERM_PROGRAM_VERSION" })
            env.Remove(key);
        env["NO_COLOR"] = "1";
        env["TERM"] = "dumb";
        // Agents run in an empty folder of Folio's, with their tools off: Gemini CLI would refuse it as "not trusted".
        env["GEMINI_CLI_TRUST_WORKSPACE"] = "true";
        env["PATH"] = string.Join(Path.PathSeparator, SearchFolders());
        if (!OperatingSystem.IsWindows())
        {
            env["LANG"] = "en_US.UTF-8";
            env["LC_ALL"] = "en_US.UTF-8";
        }
        return env;
    }
}

/// <summary>cmd.exe does not read arguments the way programs do: \" means nothing to it, so what it runs is written out for it.</summary>
public static class CommandLine
{
    /// <summary>The line for cmd /s /c: each part in its own quotes, in which cmd's special characters mean nothing.</summary>
    public static string ForCmd(IEnumerable<string> parts) =>
        string.Join(' ', parts.Select(part =>
        {
            // cmd.exe ends a command at a line break: there is no way to pass one through it.
            var text = part.Replace("\r\n", " ").Replace('\n', ' ').Replace('\r', ' ');
            return "\"" + text.Replace("\"", "\"\"") + "\"";
        }));

    /// <summary>Fills in the arguments; those for cmd.exe go as they are, since escaping them for a normal program would break them.</summary>
    public static void Apply(ProcessStartInfo info, IReadOnlyList<string> arguments)
    {
        if (arguments.Count == 4 && arguments[0] == "/d" && arguments[1] == "/s" && arguments[2] == "/c")
            info.Arguments = $"/d /s /c \"{arguments[3]}\"";
        else
            foreach (var a in arguments) info.ArgumentList.Add(a);
    }
}

/// <summary>Runs a command with text on stdin and returns its stdout. npm's .cmd shims are run through the script
/// they start (node.exe and its arguments), so prompts never pass through cmd.exe's quoting.</summary>
public static class LocalProcess
{
    static readonly ConcurrentDictionary<int, Process> Running = new();

    public static void TerminateAll()
    {
        foreach (var process in Running.Values)
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
    }

    /// <summary>The program and arguments that run <paramref name="command"/> (a .cmd shim becomes what it starts), and the
    /// variables the shim sets for it. Through cmd.exe only as a last resort: its line stops at 8191 characters, and a prompt is longer.</summary>
    public static (string File, List<string> Arguments, Dictionary<string, string> Environment) Resolve(IReadOnlyList<string> command)
    {
        var file = command[0];
        var rest = command.Skip(1).ToList();
        var none = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var extension = Path.GetExtension(file).ToLowerInvariant();
        if (extension is ".cmd" or ".bat" && File.Exists(file))
        {
            var folder = Path.GetDirectoryName(file)!;
            var text = File.ReadAllText(file);
            // npm: "%_prog%"  "%dp0%\node_modules\@scope\pkg\cli.js" %*  (the script need not have an extension: cline's is bin\cline).
            // pnpm: "%~dp0\node.exe" "%~dp0\..\pkg\cli.js" %*
            var script = Regex.Match(text, @"(?:%_prog%|\bnode(?:\.exe)?)""?\s+""%~?dp0%?\\([^""]+)""", RegexOptions.IgnoreCase);
            if (script.Success) return (NodeBeside(folder), [Path.GetFullPath(Path.Combine(folder, script.Groups[1].Value)), .. rest], none);
            // Any other shim of the usual shape: SET lines, then one program with its arguments and %*.
            // Pi's: "%node%" "%~dp0pi-launcher.js" %*   DeepSeek Harness's: "%~dp0..\..\DeepSeek Harness.exe" --expose-internals "%~dp0..\cli.js" %*
            if (BatchShim.Read(file, text) is { } shim) return (shim.Program, [.. shim.Arguments, .. rest], shim.Environment);
            script = Regex.Match(text, @"""%~?dp0%?\\?([^""]+?\.(?:js|mjs|cjs))""", RegexOptions.IgnoreCase);
            if (script.Success) return (NodeBeside(folder), [Path.GetFullPath(Path.Combine(folder, script.Groups[1].Value)), .. rest], none);
            // A shim starting an .exe next to it: "%dp0%\bin\tool.exe" %*  (not the check for node.exe that npm's shims start with).
            var exe = Regex.Match(text, @"""%~?dp0%?\\?([^""]+?\.exe)""\s+%\*", RegexOptions.IgnoreCase);
            if (exe.Success) return (Path.GetFullPath(Path.Combine(folder, exe.Groups[1].Value)), rest, none);
            // A shim starting another one (yarn's global folder).
            var inner = Regex.Match(text, @"""%~?dp0%?\\?([^""]+?\.cmd)""", RegexOptions.IgnoreCase);
            if (inner.Success && Path.GetFullPath(Path.Combine(folder, inner.Groups[1].Value)) is var next && File.Exists(next) && !next.Equals(file, StringComparison.OrdinalIgnoreCase))
                return Resolve([next, .. rest]);
            return (CommandShell, ["/d", "/s", "/c", CommandLine.ForCmd([file, .. rest])], none);
        }
        if (extension == ".ps1") return ("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", file, .. rest], none);
        return (file, rest, none);
    }

    static string NodeBeside(string folder)
    {
        var node = Path.Combine(folder, "node.exe");
        return File.Exists(node) ? node : FindOnPath("node") ?? "node";
    }

    public static string CommandShell => Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";

    internal static string? FindOnPath(string name)
    {
        foreach (var folder in ShellEnvironment.SearchFolders())
            foreach (var extension in ShellEnvironment.Extensions)
            {
                var path = Path.Combine(folder, name + extension);
                if (File.Exists(path)) return path;
            }
        return null;
    }

    public static async Task<string> Run(IReadOnlyList<string> command, string input, double timeout, CancellationToken cancel,
                                         IReadOnlyDictionary<string, string>? environment = null)
    {
        var work = Path.Combine(Path.GetTempPath(), "folio-translate-work");
        Directory.CreateDirectory(work);
        var (file, arguments, shimEnvironment) = Resolve(command);
        var info = new ProcessStartInfo(file)
        {
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false,
            CreateNoWindow = true, WorkingDirectory = work,
            StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false), StandardInputEncoding = new UTF8Encoding(false),
        };
        CommandLine.Apply(info, arguments);
        info.Environment.Clear();
        foreach (var (k, v) in ShellEnvironment.Environment_()) info.Environment[k] = v;
        foreach (var (k, v) in shimEnvironment) info.Environment[k] = v;
        foreach (var (k, v) in environment ?? new Dictionary<string, string>()) info.Environment[k] = v;
        Process process;
        try { process = Process.Start(info) ?? throw new InvalidOperationException(); }
        catch (Exception e)
        {
            // The command is there; what it needs to run is not: "pi.cmd not found" would send the user looking in the wrong place.
            if (file == "node")
                throw new ProviderError(ProviderError.Kinds.AgentSetup, $"agent-setup {Path.GetFileNameWithoutExtension(command[0])}: " + Loc.S("没有找到它依赖的 Node.js"));
            throw new ProviderError(ProviderError.Kinds.Process, $"command '{command[0]}' not found: {e.Message}");
        }
        Running[process.Id] = process;
        try
        {
            var stdout = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
            var stderr = process.StandardError.ReadToEndAsync(CancellationToken.None);
            _ = Task.Run(async () =>
            {
                try
                {
                    await process.StandardInput.WriteAsync(input);
                    process.StandardInput.Close();
                }
                catch { }
            });
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            limit.CancelAfter(TimeSpan.FromSeconds(timeout));
            try { await process.WaitForExitAsync(limit.Token); }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                if (cancel.IsCancellationRequested) throw new ProviderError(ProviderError.Kinds.Cancelled, "cancelled");
                throw new ProviderError(ProviderError.Kinds.Network, $"timed out after {(int)timeout} s");
            }
            // A helper the command left running may keep the pipes open: their end is not awaited for long.
            await Task.WhenAny(Task.WhenAll(stdout, stderr), Task.Delay(2000));
            var output = stdout.IsCompletedSuccessfully ? stdout.Result : "";
            var errors = stderr.IsCompletedSuccessfully ? stderr.Result : "";
            if (process.ExitCode != 0)
            {
                var printed = output.Length <= 2400 ? output : output[..1600] + "\n" + output[^800..];
                var message = (errors.Length > 1500 ? errors[^1500..] : errors) + "\n" + printed;
                throw new ProviderError(ProviderError.Kinds.Process, $"exit {process.ExitCode}: " + message);
            }
            if (output.Trim().Length == 0 && errors.Length > 0)
                throw new ProviderError(ProviderError.Kinds.Process, "exit 0: " + (errors.Length > 1500 ? errors[^1500..] : errors));
            return output;
        }
        finally
        {
            Running.TryRemove(process.Id, out _);
            process.Dispose();
        }
    }
}

/// <summary>What a batch shim runs, read the way cmd.exe would for the simple shape installers write: SET lines (also behind
/// IF [NOT] EXIST), then one program with its arguments and %*. Anything cleverer (GOTO, CALL, pipes) is left to cmd.exe.</summary>
public static partial class BatchShim
{
    public sealed record Launch(string Program, List<string> Arguments, Dictionary<string, string> Environment);

    [GeneratedRegex(@"^set\s+""?([^=\s""]+)=([^""]*)""?\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex SetLine();
    [GeneratedRegex(@"^if\s+(not\s+)?exist\s+""([^""]+)""\s+(set\s.+)$", RegexOptions.IgnoreCase)]
    private static partial Regex IfExistLine();
    [GeneratedRegex(@"""([^""]*)""|(\S+)")]
    private static partial Regex Token();

    public static Launch? Read(string file, string text)
    {
        var folder = Path.GetDirectoryName(Path.GetFullPath(file))! + Path.DirectorySeparatorChar;
        var set = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string Expand(string value)
        {
            value = Regex.Replace(value, "%~dp0", _ => folder, RegexOptions.IgnoreCase);
            return Regex.Replace(value, @"%([^%\s]+)%", m =>
                set.TryGetValue(m.Groups[1].Value, out var v) ? v : Environment.GetEnvironmentVariable(m.Groups[1].Value) ?? m.Value);
        }
        bool Apply(string line)
        {
            var m = SetLine().Match(line);
            if (!m.Success) return false;
            set[m.Groups[1].Value] = Expand(m.Groups[2].Value);
            return true;
        }
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimStart('@').Trim();
            if (line.Length == 0 || line.StartsWith("::") || Regex.IsMatch(line, @"^(rem\b|echo\b|setlocal\b|title\b|chcp\b)", RegexOptions.IgnoreCase)) continue;
            if (line.Contains("%*")) return Command(line, Expand, set);
            if (Apply(line)) continue;
            var condition = IfExistLine().Match(line);
            if (condition.Success)
            {
                var path = Expand(condition.Groups[2].Value);
                bool exists = File.Exists(path) || Directory.Exists(path);
                if (exists != condition.Groups[1].Success && !Apply(condition.Groups[3].Value.Trim())) return null;
                continue;
            }
            // GOTO, CALL, a block: more than a list of settings before the command.
            return null;
        }
        return null;
    }

    static Launch? Command(string line, Func<string, string> expand, Dictionary<string, string> set)
    {
        // Pipes, redirections and chained commands need cmd.exe itself.
        bool quoted = false;
        foreach (var c in line)
        {
            if (c == '"') quoted = !quoted;
            else if (!quoted && c is '&' or '|' or '<' or '>') return null;
        }
        var tokens = Token().Matches(line).Select(m => m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value).ToList();
        if (tokens.Count < 2 || tokens[^1] != "%*" || tokens.Take(tokens.Count - 1).Any(t => t.Contains("%*"))) return null;
        var parts = tokens.Take(tokens.Count - 1).Select(t => expand(t)).ToList();
        if (parts.Any(p => Regex.IsMatch(p, "%[^%]+%"))) return null;
        var program = parts[0];
        if (!Path.IsPathRooted(program))
        {
            if (program.Contains('\\') || program.Contains('/')) return null;
            program = LocalProcess.FindOnPath(program) ?? "";
            if (program.Length == 0) return null;
        }
        program = Path.GetFullPath(program);
        if (!File.Exists(program) || Path.GetExtension(program).ToLowerInvariant() is ".cmd" or ".bat") return null;
        var arguments = parts.Skip(1).Select(p => Path.IsPathRooted(p) && p.Contains("..") ? Path.GetFullPath(p) : p).ToList();
        return new Launch(program, arguments, set);
    }
}

/// <summary>DeepSeek Harness keeps the API key entered on its Models page in its credentials file, which only its desktop
/// app reads: the headless profile takes DEEPSEEK_API_KEY from the environment it is started in. Folio hands it that key,
/// to that process only, unless the environment already has one.</summary>
public static partial class DeepseekHarness
{
    const string KeyName = "DEEPSEEK_API_KEY";

    static string Home => System.Environment.GetEnvironmentVariable("DSH_HOME") is { Length: > 0 } home
        ? home : Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), ".dsh");

    public static Dictionary<string, string> Environment()
    {
        if (!string.IsNullOrEmpty(System.Environment.GetEnvironmentVariable(KeyName))
            || !string.IsNullOrEmpty(ShellEnvironment.TerminalEnvironment().GetValueOrDefault(KeyName))) return [];
        try
        {
            var file = Path.Combine(Home, ".credentials.yaml");
            return File.Exists(file) && StoredKey(File.ReadAllText(file)) is { } key ? new() { [KeyName] = key } : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    [GeneratedRegex(@"^refs:[ \t]*\r?\n((?:[ \t]+[^\n]*\r?\n?)*)", RegexOptions.Multiline)]
    private static partial Regex RefsSection();

    /// <summary>The key under "refs:" in the credentials file.</summary>
    public static string? StoredKey(string yaml)
    {
        var refs = RefsSection().Match(yaml);
        if (!refs.Success) return null;
        var line = Regex.Match(refs.Groups[1].Value, $@"(?m)^[ \t]+{KeyName}:[ \t]*[""']?([^""'\s]+)[""']?[ \t]*\r?$");
        return line.Success ? line.Groups[1].Value : null;
    }
}

/// <summary>Runs a command briefly to see what it says (its --help, its --version).</summary>
public static class CommandProbe
{
    public sealed record Result(int Status, string Output);

    public static Result? Run(string executable, string[] arguments, double timeout)
    {
        try
        {
            var (file, args, shimEnvironment) = LocalProcess.Resolve([executable, .. arguments]);
            var info = new ProcessStartInfo(file)
            {
                RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, UseShellExecute = false, CreateNoWindow = true,
                StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false),
            };
            CommandLine.Apply(info, args);
            info.Environment.Clear();
            foreach (var (k, v) in ShellEnvironment.Environment_()) info.Environment[k] = v;
            foreach (var (k, v) in shimEnvironment) info.Environment[k] = v;
            using var process = Process.Start(info);
            if (process == null) return null;
            process.StandardInput.Close();
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(TimeSpan.FromSeconds(timeout)))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                return null;
            }
            Task.WaitAll([output, errors], 2000);
            return new Result(process.ExitCode, (output.IsCompletedSuccessfully ? output.Result : "") + (errors.IsCompletedSuccessfully ? errors.Result : ""));
        }
        catch
        {
            return null;
        }
    }

    /// <summary>The first version number in a --version answer.</summary>
    public static string? VersionIn(string output)
    {
        var m = Regex.Match(output, @"\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.]+)?");
        return m.Success ? m.Value : null;
    }
}

/// <summary>Models a local agent can be asked to use: what its own configuration lists, plus its usual aliases.</summary>
public static class AgentModels
{
    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    static string Read(params string[] parts)
    {
        try { return File.ReadAllText(Path.Combine([Home, .. parts])); } catch { return ""; }
    }

    public static async Task<List<string>> Models(LocalAgent agent, string? executable, CancellationToken cancel = default)
    {
        var models = new List<string>();
        async Task<List<string>> Lines(params string[] arguments)
        {
            if (executable == null) return [];
            try { return (await LocalProcess.Run([executable, .. arguments], "", 30, cancel)).Split('\n').Select(l => l.TrimEnd('\r')).ToList(); }
            catch { return []; }
        }
        switch (agent)
        {
            case LocalAgent.Claude:
                models = ["haiku", "sonnet", "opus"];
                break;
            case LocalAgent.Codex:
            {
                var config = Read(".codex", "config.toml");
                if (Value("model", config) is { } model) models.Add(model);
                if (JsonFile(Path.Combine(Home, ".codex", "models_cache.json"))?["models"] is JsonArray list)
                    models.AddRange(list.OfType<JsonObject>().Where(m => LocalAgents.Str(m["visibility"]) != "hide").Select(m => LocalAgents.Str(m["slug"])).OfType<string>());
                if (Value("model_catalog_json", config) is { } catalog)
                {
                    var path = Path.IsPathRooted(catalog) ? catalog : Path.Combine(Home, ".codex", catalog);
                    if (JsonFile(path)?["models"] is JsonArray more) models.AddRange(more.Select(m => LocalAgents.Str(m?["slug"])).OfType<string>());
                }
                // A provider of the user's own (a relay set up with CC Switch, say) knows best what it serves: a catalog file lists only some.
                if (CodexCustomProvider() is { } provider) models.AddRange(await ProviderModels(provider, cancel));
                break;
            }
            case LocalAgent.Gemini:
            {
                models = ["auto", "gemini-3.1-pro-preview", "gemini-3-pro-preview", "gemini-3.5-flash", "gemini-3-flash-preview", "gemini-3.1-flash-lite", "gemini-2.5-pro", "gemini-2.5-flash"];
                if (JsonFile(Path.Combine(Home, ".gemini", "settings.json")) is JsonObject settings)
                {
                    var name = LocalAgents.Str(settings["model"]?["name"]) ?? LocalAgents.Str(settings["model"]);
                    if (name != null) models.Insert(0, name);
                }
                break;
            }
            case LocalAgent.Qwen:
                models = ["qwen3-coder-plus", "qwen3-coder-flash"];
                break;
            case LocalAgent.Opencode:
                models = (await Lines("models")).Select(l => l.Trim()).Where(l => l.Contains('/') && !l.Contains(' ')).ToList();
                break;
            case LocalAgent.Cursor:
                models = (await Lines("models")).Select(l => l.Split(' ')[0]).Where(l => Regex.IsMatch(l, @"^[a-z0-9][a-z0-9.\-]+$")).ToList();
                if (models.Count == 0) models = ["auto"];
                break;
            case LocalAgent.Grok:
                models = (await Lines("models")).Select(l => Regex.Match(l, @"^\s*[-*]\s+(\S+)")).Where(m => m.Success).Select(m => m.Groups[1].Value).ToList();
                break;
            case LocalAgent.Antigravity:
                models = (await Lines("models")).Where(l => l.Contains('\t')).Select(l => l.Split('\t')[0]).ToList();
                break;
            case LocalAgent.Pi:
                models = (await Lines("--list-models")).Skip(1).Select(l => l.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
                    .Where(c => c.Length >= 2).Select(c => $"{c[0]}/{c[1]}").ToList();
                break;
            case LocalAgent.Openclaw:
                if (executable != null)
                {
                    try
                    {
                        var output = await LocalProcess.Run([executable, "models", "list", "--json"], "", 30, cancel);
                        if (LLMBatch.JsonObjectIn(output)?["models"] is JsonArray list)
                            models = list.Select(m => LocalAgents.Str(m?["key"]) ?? LocalAgents.Str(m?["id"])).OfType<string>().ToList();
                    }
                    catch { }
                }
                break;
            case LocalAgent.Hermes:
            {
                bool inModel = false;
                foreach (var line in Read(".hermes", "config.yaml").Split('\n'))
                {
                    if (line.StartsWith("model:")) { inModel = true; continue; }
                    if (inModel && !line.StartsWith(' ')) break;
                    var m = Regex.Match(line, @"^\s+default:\s*""?([^""\s#]+)");
                    if (inModel && m.Success) models.Add(m.Groups[1].Value);
                }
                break;
            }
        }
        var seen = new HashSet<string>();
        return models.Where(m => m.Length > 0 && seen.Add(m)).ToList();
    }

    /// <summary>Codex's own list of what each model accepts: its thinking levels and the one it uses by default.</summary>
    public static (List<string> Levels, string? Usual)? CodexLevels(string? model)
    {
        var name = string.IsNullOrWhiteSpace(model) ? Value("model", Read(".codex", "config.toml")) : model.Trim();
        if (name == null || JsonFile(Path.Combine(Home, ".codex", "models_cache.json"))?["models"] is not JsonArray list) return null;
        if (list.OfType<JsonObject>().FirstOrDefault(m => LocalAgents.Str(m["slug"]) == name) is not { } entry
            || entry["supported_reasoning_levels"] is not JsonArray levels) return null;
        return (levels.Select(l => LocalAgents.Str(l?["effort"]) ?? LocalAgents.Str(l)).OfType<string>().ToList(), LocalAgents.Str(entry["default_reasoning_level"]));
    }

    static JsonNode? JsonFile(string path)
    {
        try { return JsonNode.Parse(File.ReadAllText(path)); } catch { return null; }
    }

    public sealed record CodexProvider(string Name, string BaseUrl, string? Token);

    /// <summary>The provider codex uses when it is not OpenAI's own: [model_providers.name] in its config.</summary>
    public static CodexProvider? CodexCustomProvider()
    {
        var config = Read(".codex", "config.toml");
        var name = Value("model_provider", config);
        if (string.IsNullOrWhiteSpace(name) || name == "openai") return null;
        var section = $"model_providers.{name}";
        if (SectionValue(config, section, "base_url") is not { Length: > 0 } url) return null;
        var token = SectionValue(config, section, "experimental_bearer_token");
        if (string.IsNullOrEmpty(token) && SectionValue(config, section, "env_key") is { Length: > 0 } variable)
            token = Environment.GetEnvironmentVariable(variable) ?? ShellEnvironment.TerminalEnvironment().GetValueOrDefault(variable);
        return new CodexProvider(name, url.TrimEnd('/'), string.IsNullOrEmpty(token) ? null : token);
    }

    /// <summary>What an OpenAI-compatible provider lists at /models (also under /v1, for an address given without it).</summary>
    static async Task<List<string>> ProviderModels(CodexProvider provider, CancellationToken cancel)
    {
        var urls = new List<string> { provider.BaseUrl + "/models" };
        if (Uri.TryCreate(provider.BaseUrl, UriKind.Absolute, out var uri) && uri.AbsolutePath.Trim('/').Length == 0) urls.Add(provider.BaseUrl + "/v1/models");
        foreach (var url in urls)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, url);
                if (provider.Token != null) request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", provider.Token);
                using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                limit.CancelAfter(TimeSpan.FromSeconds(10));
                using var response = await Http.Client.SendAsync(request, limit.Token);
                if (!response.IsSuccessStatusCode) continue;
                if (JsonNode.Parse(await response.Content.ReadAsStringAsync(limit.Token)) is JsonObject { } body && body["data"] is JsonArray data)
                    return data.Select(m => LocalAgents.Str(m?["id"])).OfType<string>().ToList();
            }
            catch (Exception e) when (e is HttpRequestException or OperationCanceledException or JsonException or InvalidOperationException) { }
        }
        return [];
    }

    /// <summary>key = value under [section] in a TOML file.</summary>
    public static string? SectionValue(string toml, string section, string key)
    {
        bool inside = false;
        foreach (var raw in toml.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith('['))
            {
                inside = line.Trim('[', ']', ' ').Replace("\"", "").Replace("'", "") == section;
                continue;
            }
            if (!inside) continue;
            int eq = line.IndexOf('=');
            if (eq < 0 || line[..eq].Trim() != key) continue;
            return line[(eq + 1)..].Trim().Trim('"', '\'');
        }
        return null;
    }

    /// <summary>key = "value" in a TOML file (top level).</summary>
    public static string? Value(string key, string toml)
    {
        foreach (var raw in toml.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith('[')) break;
            int eq = line.IndexOf('=');
            if (!line.StartsWith(key) || eq < 0 || line[..eq].Trim() != key) continue;
            return line[(eq + 1)..].Trim().Trim('"', '\'');
        }
        return null;
    }
}
