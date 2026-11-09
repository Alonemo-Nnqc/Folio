using System.Globalization;
using System.Text.RegularExpressions;

namespace Folio.Core.Translate.Services;

// Port of macos/.../FolioTranslate/TranslationServiceCatalog.swift and TranslationNaming.swift.
// Apple's on-device translation is the one service without a Windows counterpart.

public enum FieldKind { Text, Secret, Url, Number, Toggle }

/// <summary>One setting of a translation service. Option is the storage key (settings and secret store), as on macOS.</summary>
public sealed record TranslationServiceField(string Option, string Title, FieldKind Kind = FieldKind.Text, bool IsRequired = false,
                                             string? DefaultValue = null, string? Placeholder = null, bool IsAdvanced = false)
{
    public bool IsSecret => Kind == FieldKind.Secret;
}

/// <summary>How a service is called.</summary>
public abstract record TranslationBackend
{
    public sealed record OpenAI(string DefaultBase) : TranslationBackend;
    public sealed record AzureOpenAI : TranslationBackend;
    public sealed record Anthropic : TranslationBackend;
    public sealed record Gemini : TranslationBackend;
    public sealed record QwenMT : TranslationBackend;
    public sealed record DeepL : TranslationBackend;
    public sealed record AzureTranslator : TranslationBackend;
    public sealed record Tencent : TranslationBackend;
    public sealed record GoogleWeb : TranslationBackend;
    public sealed record BingWeb : TranslationBackend;
    public sealed record Agent(LocalAgent Which) : TranslationBackend;
    public sealed record Command : TranslationBackend;
}

public enum ServiceCategory { Free, Local, Agent, Llm, Machine }

/// <summary>A translation service offered in Folio's settings.</summary>
public sealed record TranslationService(string Id, string DisplayName, TranslationBackend Backend, ServiceCategory Category,
                                        List<TranslationServiceField> Fields, string? Note = null)
{
    public bool IsFree => Category is ServiceCategory.Free or ServiceCategory.Local or ServiceCategory.Agent;
    public bool IsLocal => Category == ServiceCategory.Local;
    public bool IsLLM => Backend is TranslationBackend.OpenAI or TranslationBackend.AzureOpenAI or TranslationBackend.Anthropic
        or TranslationBackend.Gemini or TranslationBackend.Agent;
    public IEnumerable<TranslationServiceField> RequiredFields => Fields.Where(f => f.IsRequired);
    public IEnumerable<TranslationServiceField> SecretFields => Fields.Where(f => f.IsSecret);
    public TranslationServiceField? ModelField => Fields.FirstOrDefault(f => f.Title == TranslationServiceCatalog.ModelFieldTitle);
}

/// <summary>Every translation service of the native engine.</summary>
public static class TranslationServiceCatalog
{
    public static string ModelFieldTitle => Loc.S("模型");
    public const string DefaultServiceId = "google";

    /// <summary>Services that are gone (or, on Windows, not available), and what users of them get instead.</summary>
    public static readonly Dictionary<string, string> Replacements = new()
    {
        ["siliconflowfree"] = "google", ["anythingllm"] = "openaicompatible", ["dify"] = "openaicompatible", ["xinference"] = "openaicompatible",
        ["apple"] = "google",
    };

    public static TranslationService? Service(string id) => All.FirstOrDefault(s => s.Id == id);

    public static TranslationService Resolve(string id) =>
        Service(id) ?? Service(Replacements.GetValueOrDefault(id, DefaultServiceId)) ?? All[0];

    static TranslationServiceField ApiKey(string option, string title = "API Key") => new(option, title, FieldKind.Secret, true);
    static TranslationServiceField Model(string option, string? value, bool required = false) => new(option, ModelFieldTitle, IsRequired: required, DefaultValue: value, Placeholder: value);
    static TranslationServiceField BaseUrl(string option, string? value = null, bool required = false, string? placeholder = null) =>
        new(option, "Base URL", FieldKind.Url, required, value, placeholder ?? value);
    static TranslationServiceField Temperature(string option) => new(option, "Temperature", FieldKind.Number, Placeholder: "0.2", IsAdvanced: true);
    static TranslationServiceField AgentPath(string option, string command) =>
        new(option, Loc.S("可执行文件路径"), Placeholder: Loc.S("自动查找 %@", command), IsAdvanced: true);
    static TranslationServiceField AgentModel(string option, string? placeholder = null, string? value = null) =>
        new(option, ModelFieldTitle, DefaultValue: value, Placeholder: placeholder ?? Loc.S("默认"));

    static List<TranslationService>? _all;
    static string? _allCulture;

    /// <summary>The catalog, in the current interface language.</summary>
    public static List<TranslationService> All
    {
        get
        {
            var culture = Loc.IsEnglish ? "en" : "zh";
            if (_all != null && _allCulture == culture) return _all;
            _allCulture = culture;
            return _all = Build();
        }
    }

    static TranslationService AgentService(string id, string name, LocalAgent agent, List<TranslationServiceField> fields, string note) =>
        new(id, name, new TranslationBackend.Agent(agent), ServiceCategory.Agent, fields, note);

    static List<TranslationService> Build() =>
    [
        // Free
        new("google", Loc.S("Google（免费）"), new TranslationBackend.GoogleWeb(), ServiceCategory.Free, [],
            Loc.S("无需 Key，频繁使用可能被限流")),
        new("bing", Loc.S("Microsoft（免费）"), new TranslationBackend.BingWeb(), ServiceCategory.Free, [],
            Loc.S("无需 Key")),
        // On this computer
        new("ollama", "Ollama", new TranslationBackend.OpenAI("http://localhost:11434/v1"), ServiceCategory.Local,
        [
            new("--ollama-host", Loc.S("服务地址"), FieldKind.Url, DefaultValue: "http://localhost:11434", Placeholder: "http://localhost:11434"),
            Model("--ollama-model", "qwen3:8b", true),
        ], Loc.S("需在本机运行 Ollama 并下载模型")),
        new("lmstudio", "LM Studio", new TranslationBackend.OpenAI("http://localhost:1234/v1"), ServiceCategory.Local,
        [
            new("--lmstudio-host", Loc.S("服务地址"), FieldKind.Url, DefaultValue: "http://localhost:1234", Placeholder: "http://localhost:1234"),
            Model("--lmstudio-model", null, true),
        ], Loc.S("需在 LM Studio 中载入模型并启动本地服务")),
        // Agents
        AgentService("claudecode", "Claude Code", LocalAgent.Claude,
            [AgentModel("--claude-code-model", "haiku / sonnet / opus", "haiku"), AgentPath("--claude-code-path", "claude")], null),
        AgentService("codex", "Codex", LocalAgent.Codex, [AgentModel("--codex-model"), AgentPath("--codex-path", "codex")], null),
        AgentService("geminicli", "Gemini CLI", LocalAgent.Gemini, [AgentModel("--gemini-cli-model"), AgentPath("--gemini-cli-path", "gemini")], null),
        AgentService("qwencode", "Qwen Code", LocalAgent.Qwen, [AgentModel("--qwen-code-model"), AgentPath("--qwen-code-path", "qwen")], null),
        AgentService("opencode", "opencode", LocalAgent.Opencode, [AgentModel("--opencode-model", "provider/model"), AgentPath("--opencode-path", "opencode")], null),
        AgentService("cursoragent", "Cursor CLI", LocalAgent.Cursor, [AgentModel("--cursor-agent-model"), AgentPath("--cursor-agent-path", "cursor-agent")],
            Loc.S("需单独安装 Cursor CLI（Cursor 应用不含此命令）")),
        AgentService("grokcli", "Grok CLI", LocalAgent.Grok, [AgentModel("--grok-cli-model"), AgentPath("--grok-cli-path", "grok")], null),
        AgentService("antigravitycli", "Antigravity CLI", LocalAgent.Antigravity, [AgentModel("--antigravity-cli-model"), AgentPath("--antigravity-cli-path", "agy")],
            null),
        AgentService("copilotcli", "GitHub Copilot CLI", LocalAgent.Copilot, [AgentModel("--copilot-cli-model"), AgentPath("--copilot-cli-path", "copilot")], null),
        AgentService("kirocli", "Kiro CLI", LocalAgent.Kiro, [AgentModel("--kiro-cli-model"), AgentPath("--kiro-cli-path", "kiro-cli")], null),
        AgentService("clinecli", "Cline CLI", LocalAgent.Cline, [AgentModel("--cline-cli-model"), AgentPath("--cline-cli-path", "cline")], null),
        AgentService("kimicli", "Kimi CLI", LocalAgent.Kimi, [AgentModel("--kimi-cli-model"), AgentPath("--kimi-cli-path", "kimi")], null),
        AgentService("droidcli", "Factory Droid", LocalAgent.Droid, [AgentModel("--droid-model"), AgentPath("--droid-path", "droid")], null),
        AgentService("ampcli", "Amp", LocalAgent.Amp, [AgentPath("--amp-path", "amp")], Loc.S("模型由 Amp 决定")),
        AgentService("gooseagent", "goose", LocalAgent.Goose, [AgentModel("--goose-model"), AgentPath("--goose-path", "goose")], null),
        AgentService("picli", "pi", LocalAgent.Pi, [AgentModel("--pi-model", "provider/model"), AgentPath("--pi-path", "pi")], null),
        AgentService("hermesagent", "Hermes Agent", LocalAgent.Hermes, [AgentModel("--hermes-model"), AgentPath("--hermes-path", "hermes")],
            Loc.S("需先运行 hermes model 选择模型")),
        AgentService("openclawagent", "OpenClaw", LocalAgent.Openclaw, [AgentModel("--openclaw-model", "provider/model"), AgentPath("--openclaw-path", "openclaw")],
            null),
        AgentService("deepseekharness", "DeepSeek Harness", LocalAgent.Deepseek, [AgentPath("--deepseek-harness-path", "dsh")],
            Loc.S("模型由 dsh 的配置决定")),
        // Large language models
        new("openai", "OpenAI", new TranslationBackend.OpenAI("https://api.openai.com/v1"), ServiceCategory.Llm,
        [
            ApiKey("--openai-api-key"), Model("--openai-model", "gpt-5-mini"), BaseUrl("--openai-base-url", placeholder: "https://api.openai.com/v1"),
            new("--openai-reasoning-effort", Loc.S("推理强度"), IsAdvanced: true), Temperature("--openai-temperature"),
        ]),
        new("anthropic", "Anthropic Claude", new TranslationBackend.Anthropic(), ServiceCategory.Llm,
        [
            ApiKey("--anthropic-api-key"), Model("--anthropic-model", "claude-haiku-5-5"), BaseUrl("--anthropic-base-url", placeholder: "https://api.anthropic.com"),
        ]),
        new("gemini", "Gemini", new TranslationBackend.Gemini(), ServiceCategory.Llm, [ApiKey("--gemini-api-key"), Model("--gemini-model", "gemini-2.5-flash")]),
        new("deepseek", "DeepSeek", new TranslationBackend.OpenAI("https://api.deepseek.com"), ServiceCategory.Llm,
        [
            ApiKey("--deepseek-api-key"), Model("--deepseek-model", "deepseek-chat"), new("--deepseek-reasoning-effort", Loc.S("推理强度"), IsAdvanced: true),
        ]),
        new("aliyundashscope", Loc.S("阿里云百炼（通义千问）"), new TranslationBackend.OpenAI("https://dashscope.aliyuncs.com/compatible-mode/v1"), ServiceCategory.Llm,
        [
            ApiKey("--aliyun-dashscope-api-key"), Model("--aliyun-dashscope-model", "qwen-plus-latest"),
            BaseUrl("--aliyun-dashscope-base-url", "https://dashscope.aliyuncs.com/compatible-mode/v1"), Temperature("--aliyun-dashscope-temperature"),
        ]),
        new("qwenmt", Loc.S("通义千问 MT"), new TranslationBackend.QwenMT(), ServiceCategory.Machine,
        [
            ApiKey("--qwenmt-api-key"), Model("--qwenmt-model", "qwen-mt-plus"), BaseUrl("--qwenmt-base-url", "https://dashscope.aliyuncs.com/compatible-mode/v1"),
            new("--ali-domains", Loc.S("领域提示"), Placeholder: Loc.S("默认：学术论文风格"), IsAdvanced: true),
        ]),
        new("zhipu", Loc.S("智谱 AI"), new TranslationBackend.OpenAI("https://open.bigmodel.cn/api/paas/v4"), ServiceCategory.Llm,
            [ApiKey("--zhipu-api-key"), Model("--zhipu-model", "glm-4-flash")]),
        new("siliconflow", Loc.S("SiliconFlow 硅基流动"), new TranslationBackend.OpenAI("https://api.siliconflow.cn/v1"), ServiceCategory.Llm,
        [
            ApiKey("--siliconflow-api-key"), Model("--siliconflow-model", "Qwen/Qwen2.5-7B-Instruct"), BaseUrl("--siliconflow-base-url", "https://api.siliconflow.cn/v1"),
            new("--siliconflow-enable-thinking", Loc.S("思考"), IsAdvanced: true),
        ]),
        new("modelscope", Loc.S("ModelScope 魔搭"), new TranslationBackend.OpenAI("https://api-inference.modelscope.cn/v1"), ServiceCategory.Llm,
            [ApiKey("--modelscope-api-key"), Model("--modelscope-model", "Qwen/Qwen2.5-32B-Instruct")]),
        new("groq", "Groq", new TranslationBackend.OpenAI("https://api.groq.com/openai/v1"), ServiceCategory.Llm,
            [ApiKey("--groq-api-key"), Model("--groq-model", "llama-3.3-70b-versatile")]),
        new("grok", "xAI Grok", new TranslationBackend.OpenAI("https://api.x.ai/v1"), ServiceCategory.Llm, [ApiKey("--grok-api-key"), Model("--grok-model", "grok-3-mini")]),
        new("azureopenai", "Azure OpenAI", new TranslationBackend.AzureOpenAI(), ServiceCategory.Llm,
        [
            ApiKey("--azure-openai-api-key"), BaseUrl("--azure-openai-base-url", required: true, placeholder: Loc.S("https://<资源名>.openai.azure.com")),
            Model("--azure-openai-model", "gpt-4o-mini"),
            new("--azure-openai-api-version", Loc.S("API 版本"), DefaultValue: "2024-10-21", Placeholder: "2024-10-21", IsAdvanced: true),
        ]),
        new("openaicompatible", Loc.S("OpenAI 兼容接口"), new TranslationBackend.OpenAI(""), ServiceCategory.Llm,
        [
            BaseUrl("--openai-compatible-base-url", required: true, placeholder: "https://example.com/v1"),
            new("--openai-compatible-api-key", "API Key", FieldKind.Secret), Model("--openai-compatible-model", null, true),
            new("--openai-compatible-reasoning-effort", Loc.S("推理强度"), IsAdvanced: true), Temperature("--openai-compatible-temperature"),
        ], Loc.S("兼容 OpenAI Chat Completions 的任意服务")),
        // Machine translation
        new("deepl", "DeepL", new TranslationBackend.DeepL(), ServiceCategory.Machine, [ApiKey("--deepl-auth-key", "Auth Key")],
            Loc.S("支持免费版（:fx 结尾）与专业版 Key")),
        new("azure", Loc.S("Azure 翻译"), new TranslationBackend.AzureTranslator(), ServiceCategory.Machine,
        [
            ApiKey("--azure-api-key"), new("--azure-region", Loc.S("区域"), Placeholder: "eastasia"),
            new("--azure-endpoint", "Endpoint", FieldKind.Url, DefaultValue: "https://api.cognitive.microsofttranslator.com",
                Placeholder: "https://api.cognitive.microsofttranslator.com", IsAdvanced: true),
        ]),
        new("tencentmechinetranslation", Loc.S("腾讯云机器翻译"), new TranslationBackend.Tencent(), ServiceCategory.Machine,
        [
            new("--tencentcloud-secret-id", "SecretId", FieldKind.Secret, true), new("--tencentcloud-secret-key", "SecretKey", FieldKind.Secret, true),
            new("--tencentcloud-region", Loc.S("地域"), DefaultValue: "ap-guangzhou", Placeholder: "ap-guangzhou", IsAdvanced: true),
        ]),
        new("clitranslator", Loc.S("自定义命令行翻译器"), new TranslationBackend.Command(), ServiceCategory.Machine,
        [
            new("--clitranslator-command", Loc.S("命令"), IsRequired: true, Placeholder: "my-translator --from en --to zh"),
            new("--clitranslator-timeout", Loc.S("超时（秒）"), FieldKind.Number, DefaultValue: "60", Placeholder: "60"),
        ], Loc.S("原文经标准输入传入，译文由标准输出返回")),
    ];
}

/// <summary>Names of translated files: what they are and who translated them, so several versions of one paper tell
/// themselves apart — "论文（简体中文译文 · DeepSeek · deepseek-chat）.pdf".</summary>
public static class TranslationNaming
{
    public sealed record Provider(string Name, string? Model)
    {
        public static Provider Of(TranslationService service, IReadOnlyDictionary<string, string> fields, string? profileName)
        {
            var field = service.ModelField;
            string? model = null;
            if (field != null) model = fields.TryGetValue(field.Option, out var v) && v.Length > 0 ? v : field.DefaultValue;
            return new Provider(profileName ?? NameOf(service), model);
        }

        /// <summary>"DeepSeek · deepseek-chat", or the name alone when there is no model.</summary>
        public string Label => string.IsNullOrEmpty(Model) || string.Equals(Model, Name, StringComparison.OrdinalIgnoreCase) ? Name : $"{Name} · {Model}";
    }

    /// <summary>A service's name for file names: without notes such as "（免费）" / " (free)".</summary>
    public static string NameOf(TranslationService service) => Regex.Replace(service.DisplayName, @"\s*[（(][^）)]*[）)]$", "");

    public enum Kind { Mono, Dual }

    /// <summary>The base name (no extension) for a translated file; a name already taken gets the time of translation.</summary>
    public static string BaseName(string original, Kind kind, string language, Provider provider, ISet<string> existing, DateTime? date = null)
    {
        var what = kind == Kind.Mono ? Loc.S("%@译文", language) : Loc.S("双语对照");
        var name = Loc.S("%@（%@ · %@）", original, what, provider.Label);
        if (!existing.Contains(name)) return name;
        var when = date ?? DateTime.Now;
        // No colons: they are not allowed in Windows file names.
        var time = when.ToString(Loc.S("M月d日 HH.mm").Replace("月", "'月'").Replace("日", "'日'"), CultureInfo.InvariantCulture);
        var timed = Loc.S("%@（%@ · %@ · %@）", original, what, provider.Label, time);
        if (existing.Contains(timed))
        {
            time = when.ToString(Loc.S("M月d日 HH.mm.ss").Replace("月", "'月'").Replace("日", "'日'"), CultureInfo.InvariantCulture);
            timed = Loc.S("%@（%@ · %@ · %@）", original, what, provider.Label, time);
        }
        return timed;
    }
}
