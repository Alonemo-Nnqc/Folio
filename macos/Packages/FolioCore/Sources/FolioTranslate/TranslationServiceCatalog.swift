import Foundation

/// One setting of a translation service.
public struct TranslationServiceField: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case text, secret, url, number, toggle
    }

    /// Storage key (settings and Keychain account), e.g. `--openai-api-key`. The keys date from the pdf2zh_next
    /// engine and are kept so existing settings, profiles and keys carry over.
    public let option: String
    public let title: String
    public let kind: Kind
    public let isRequired: Bool
    /// Used when the user leaves the field empty.
    public let defaultValue: String?
    public let placeholder: String?
    /// Rarely needed settings the UI may hide behind "高级".
    public let isAdvanced: Bool

    public var id: String { option }
    public var isSecret: Bool { kind == .secret }

    public init(option: String, title: String, kind: Kind = .text, isRequired: Bool = false,
                defaultValue: String? = nil, placeholder: String? = nil, isAdvanced: Bool = false) {
        self.option = option
        self.title = title
        self.kind = kind
        self.isRequired = isRequired
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.isAdvanced = isAdvanced
    }
}

/// How a service is called.
public enum TranslationBackend: Sendable, Hashable {
    /// OpenAI Chat Completions, at `defaultBase` unless the service has a Base URL field.
    case openAI(defaultBase: String)
    case azureOpenAI
    case anthropic
    case gemini
    /// Qwen-MT: a translation model behind the OpenAI-compatible API, one text per request.
    case qwenMT
    case deepL
    case azureTranslator
    case tencent
    case googleWeb
    case bingWeb
    case apple
    /// A coding agent installed on this Mac, run from the command line.
    case agent(LocalAgent)
    /// A user command: text on stdin, translation on stdout.
    case command
}

/// A translation service offered in Folio's settings.
public struct TranslationService: Sendable, Hashable, Identifiable {
    public enum Category: String, Sendable, Hashable, CaseIterable {
        case free, local, agent, llm, machine
    }

    /// Stable identifier (also the Keychain account prefix), e.g. `openai`.
    public let id: String
    public let displayName: String
    public let backend: TranslationBackend
    public let category: Category
    public let fields: [TranslationServiceField]
    /// A short hint shown under the service picker.
    public let note: String?

    /// Usable without an account or key.
    public var isFree: Bool { category == .free || category == .local || category == .agent }
    /// Runs entirely on this Mac.
    public var isLocal: Bool { category == .local }
    /// A large language model: translates whole batches with context and a glossary.
    public var isLLM: Bool {
        switch backend {
        case .openAI, .azureOpenAI, .anthropic, .gemini, .agent: true
        default: false
        }
    }
    public var requiredFields: [TranslationServiceField] { fields.filter(\.isRequired) }
    public var secretFields: [TranslationServiceField] { fields.filter(\.isSecret) }

    public init(id: String, displayName: String, backend: TranslationBackend, category: Category,
                fields: [TranslationServiceField] = [], note: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.backend = backend
        self.category = category
        self.fields = fields
        self.note = note
    }
}

/// Every translation service of the native engine.
public enum TranslationServiceCatalog {
    public static let appleServiceID = "apple"
    /// Title of every service's model field; file names and profile summaries look the field up by it.
    public static let modelFieldTitle = String(localized: "模型", bundle: .module)
    public static let defaultServiceID = "google"
    /// Services of the pdf2zh_next engine that are gone, and what users of them get instead.
    public static let replacements: [String: String] = [
        "siliconflowfree": "google", "anythingllm": "openaicompatible", "dify": "openaicompatible", "xinference": "openaicompatible",
    ]

    public static func service(id: String) -> TranslationService? {
        all.first { $0.id == id }
    }

    /// The service for a stored id, following replacements of removed services.
    public static func resolve(_ id: String) -> TranslationService {
        service(id: id) ?? service(id: replacements[id] ?? defaultServiceID) ?? all[0]
    }

    // MARK: Field helpers

    private static func apiKey(_ option: String, title: String = "API Key") -> TranslationServiceField {
        .init(option: option, title: title, kind: .secret, isRequired: true)
    }

    private static func model(_ option: String, default value: String?, required: Bool = false) -> TranslationServiceField {
        .init(option: option, title: TranslationServiceCatalog.modelFieldTitle, isRequired: required, defaultValue: value, placeholder: value)
    }

    private static func baseURL(_ option: String, default value: String? = nil, required: Bool = false, placeholder: String? = nil) -> TranslationServiceField {
        .init(option: option, title: "Base URL", kind: .url, isRequired: required, defaultValue: value, placeholder: placeholder ?? value)
    }

    private static func temperature(_ option: String) -> TranslationServiceField {
        .init(option: option, title: "Temperature", kind: .number, placeholder: "0.2", isAdvanced: true)
    }

    private static func agentPath(_ option: String, command: String) -> TranslationServiceField {
        .init(option: option, title: String(localized: "可执行文件路径", bundle: .module),
              placeholder: String(localized: "自动查找 \(command)", bundle: .module), isAdvanced: true)
    }

    // MARK: Catalog

    public static let all: [TranslationService] = [
        // Free
        .init(id: "google", displayName: String(localized: "Google（免费）", bundle: .module), backend: .googleWeb, category: .free,
              note: String(localized: "无需 Key，频繁使用可能被限流", bundle: .module)),
        .init(id: "bing", displayName: String(localized: "Microsoft（免费）", bundle: .module), backend: .bingWeb, category: .free,
              note: String(localized: "无需 Key", bundle: .module)),
        // On this Mac
        .init(id: appleServiceID, displayName: String(localized: "Apple 系统翻译（离线）", bundle: .module), backend: .apple, category: .local,
              note: String(localized: "完全离线，首次使用需下载语言包", bundle: .module)),
        .init(id: "ollama", displayName: "Ollama", backend: .openAI(defaultBase: "http://localhost:11434/v1"), category: .local, fields: [
            .init(option: "--ollama-host", title: String(localized: "服务地址", bundle: .module), kind: .url,
                  defaultValue: "http://localhost:11434", placeholder: "http://localhost:11434"),
            model("--ollama-model", default: "qwen3:8b", required: true),
        ], note: String(localized: "需在本机运行 Ollama 并下载模型", bundle: .module)),
        .init(id: "lmstudio", displayName: "LM Studio", backend: .openAI(defaultBase: "http://localhost:1234/v1"), category: .local, fields: [
            .init(option: "--lmstudio-host", title: String(localized: "服务地址", bundle: .module), kind: .url,
                  defaultValue: "http://localhost:1234", placeholder: "http://localhost:1234"),
            model("--lmstudio-model", default: nil, required: true),
        ], note: String(localized: "需在 LM Studio 中载入模型并启动本地服务", bundle: .module)),
        // Agents
        .init(id: "claudecode", displayName: "Claude Code", backend: .agent(.claude), category: .agent, fields: [
            .init(option: "--claude-code-model", title: TranslationServiceCatalog.modelFieldTitle, defaultValue: "haiku", placeholder: "haiku / sonnet / opus"),
            agentPath("--claude-code-path", command: "claude"),
        ]),
        .init(id: "workbuddy", displayName: "WorkBuddy", backend: .agent(.workbuddy), category: .agent, fields: [
            .init(option: "--workbuddy-api-key", title: "CodeBuddy API Key", kind: .secret,
                  placeholder: String(localized: "在 copilot.tencent.com/profile 生成", bundle: .module)),
            .init(option: "--workbuddy-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: "auto / glm-5.1 / kimi-k2.5"),
            .init(option: "--workbuddy-site", title: String(localized: "站点", bundle: .module),
                  placeholder: String(localized: "留空为国内版；国际版填 international", bundle: .module), isAdvanced: true),
            agentPath("--workbuddy-path", command: "codebuddy"),
        ], note: String(localized: "使用 WorkBuddy 自带的 CodeBuddy 命令行。WorkBuddy 应用里的登录不能给其他程序使用，请在 copilot.tencent.com/profile 生成 API Key 填在这里。", bundle: .module)),
        .init(id: "codex", displayName: "Codex", backend: .agent(.codex), category: .agent, fields: [
            .init(option: "--codex-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--codex-path", command: "codex"),
        ]),
        .init(id: "geminicli", displayName: "Gemini CLI", backend: .agent(.gemini), category: .agent, fields: [
            .init(option: "--gemini-cli-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--gemini-cli-path", command: "gemini"),
        ]),
        .init(id: "qwencode", displayName: "Qwen Code", backend: .agent(.qwen), category: .agent, fields: [
            .init(option: "--qwen-code-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--qwen-code-path", command: "qwen"),
        ]),
        .init(id: "opencode", displayName: "opencode", backend: .agent(.opencode), category: .agent, fields: [
            .init(option: "--opencode-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: "provider/model"),
            agentPath("--opencode-path", command: "opencode"),
        ]),
        .init(id: "cursoragent", displayName: "Cursor CLI", backend: .agent(.cursor), category: .agent, fields: [
            .init(option: "--cursor-agent-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--cursor-agent-path", command: "cursor-agent"),
        ], note: String(localized: "需单独安装 Cursor CLI（Cursor 应用不含此命令）", bundle: .module)),
        .init(id: "grokcli", displayName: "Grok CLI", backend: .agent(.grok), category: .agent, fields: [
            .init(option: "--grok-cli-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--grok-cli-path", command: "grok"),
        ]),
        .init(id: "antigravitycli", displayName: "Antigravity CLI", backend: .agent(.antigravity), category: .agent, fields: [
            .init(option: "--antigravity-cli-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--antigravity-cli-path", command: "agy"),
        ]),
        .init(id: "copilotcli", displayName: "GitHub Copilot CLI", backend: .agent(.copilot), category: .agent, fields: [
            .init(option: "--copilot-cli-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--copilot-cli-path", command: "copilot"),
        ]),
        .init(id: "kirocli", displayName: "Kiro CLI", backend: .agent(.kiro), category: .agent, fields: [
            .init(option: "--kiro-cli-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--kiro-cli-path", command: "kiro-cli"),
        ]),
        .init(id: "clinecli", displayName: "Cline CLI", backend: .agent(.cline), category: .agent, fields: [
            .init(option: "--cline-cli-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--cline-cli-path", command: "cline"),
        ]),
        .init(id: "kimicli", displayName: "Kimi CLI", backend: .agent(.kimi), category: .agent, fields: [
            .init(option: "--kimi-cli-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--kimi-cli-path", command: "kimi"),
        ]),
        .init(id: "droidcli", displayName: "Factory Droid", backend: .agent(.droid), category: .agent, fields: [
            .init(option: "--droid-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--droid-path", command: "droid"),
        ]),
        .init(id: "ampcli", displayName: "Amp", backend: .agent(.amp), category: .agent, fields: [
            agentPath("--amp-path", command: "amp"),
        ], note: String(localized: "模型由 Amp 决定", bundle: .module)),
        .init(id: "gooseagent", displayName: "goose", backend: .agent(.goose), category: .agent, fields: [
            .init(option: "--goose-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--goose-path", command: "goose"),
        ]),
        .init(id: "picli", displayName: "pi", backend: .agent(.pi), category: .agent, fields: [
            .init(option: "--pi-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: "provider/model"),
            agentPath("--pi-path", command: "pi"),
        ]),
        .init(id: "hermesagent", displayName: "Hermes Agent", backend: .agent(.hermes), category: .agent, fields: [
            .init(option: "--hermes-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: String(localized: "默认", bundle: .module)),
            agentPath("--hermes-path", command: "hermes"),
        ], note: String(localized: "需先运行 hermes model 选择模型", bundle: .module)),
        .init(id: "openclawagent", displayName: "OpenClaw", backend: .agent(.openclaw), category: .agent, fields: [
            .init(option: "--openclaw-model", title: TranslationServiceCatalog.modelFieldTitle, placeholder: "provider/model"),
            agentPath("--openclaw-path", command: "openclaw"),
        ]),
        .init(id: "deepseekharness", displayName: "DeepSeek Harness", backend: .agent(.deepseek), category: .agent, fields: [
            agentPath("--deepseek-harness-path", command: "dsh"),
        ], note: String(localized: "模型由 dsh 的配置决定", bundle: .module)),
        // Large language models
        .init(id: "openai", displayName: "OpenAI", backend: .openAI(defaultBase: "https://api.openai.com/v1"), category: .llm, fields: [
            apiKey("--openai-api-key"),
            model("--openai-model", default: "gpt-5-mini"),
            baseURL("--openai-base-url", placeholder: "https://api.openai.com/v1"),
            .init(option: "--openai-reasoning-effort", title: String(localized: "推理强度", bundle: .module), isAdvanced: true),
            temperature("--openai-temperature"),
        ]),
        .init(id: "anthropic", displayName: "Anthropic Claude", backend: .anthropic, category: .llm, fields: [
            apiKey("--anthropic-api-key"),
            model("--anthropic-model", default: "claude-haiku-5-5"),
            baseURL("--anthropic-base-url", placeholder: "https://api.anthropic.com"),
        ]),
        .init(id: "gemini", displayName: "Gemini", backend: .gemini, category: .llm, fields: [
            apiKey("--gemini-api-key"),
            model("--gemini-model", default: "gemini-2.5-flash"),
        ]),
        .init(id: "deepseek", displayName: "DeepSeek", backend: .openAI(defaultBase: "https://api.deepseek.com"), category: .llm, fields: [
            apiKey("--deepseek-api-key"),
            model("--deepseek-model", default: "deepseek-chat"),
            .init(option: "--deepseek-reasoning-effort", title: String(localized: "推理强度", bundle: .module), isAdvanced: true),
        ]),
        .init(id: "aliyundashscope", displayName: String(localized: "阿里云百炼（通义千问）", bundle: .module),
              backend: .openAI(defaultBase: "https://dashscope.aliyuncs.com/compatible-mode/v1"), category: .llm, fields: [
            apiKey("--aliyun-dashscope-api-key"),
            model("--aliyun-dashscope-model", default: "qwen-plus-latest"),
            baseURL("--aliyun-dashscope-base-url", default: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
            temperature("--aliyun-dashscope-temperature"),
        ]),
        .init(id: "qwenmt", displayName: String(localized: "通义千问 MT", bundle: .module), backend: .qwenMT, category: .machine, fields: [
            apiKey("--qwenmt-api-key"),
            model("--qwenmt-model", default: "qwen-mt-plus"),
            baseURL("--qwenmt-base-url", default: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
            .init(option: "--ali-domains", title: String(localized: "领域提示", bundle: .module), placeholder: String(localized: "默认：学术论文风格", bundle: .module), isAdvanced: true),
        ]),
        .init(id: "zhipu", displayName: String(localized: "智谱 AI", bundle: .module), backend: .openAI(defaultBase: "https://open.bigmodel.cn/api/paas/v4"),
              category: .llm, fields: [
            apiKey("--zhipu-api-key"),
            model("--zhipu-model", default: "glm-4-flash"),
        ]),
        .init(id: "siliconflow", displayName: String(localized: "SiliconFlow 硅基流动", bundle: .module),
              backend: .openAI(defaultBase: "https://api.siliconflow.cn/v1"), category: .llm, fields: [
            apiKey("--siliconflow-api-key"),
            model("--siliconflow-model", default: "Qwen/Qwen2.5-7B-Instruct"),
            baseURL("--siliconflow-base-url", default: "https://api.siliconflow.cn/v1"),
            .init(option: "--siliconflow-enable-thinking", title: String(localized: "思考", bundle: .module), isAdvanced: true),
        ]),
        .init(id: "modelscope", displayName: String(localized: "ModelScope 魔搭", bundle: .module),
              backend: .openAI(defaultBase: "https://api-inference.modelscope.cn/v1"), category: .llm, fields: [
            apiKey("--modelscope-api-key"),
            model("--modelscope-model", default: "Qwen/Qwen2.5-32B-Instruct"),
        ]),
        .init(id: "groq", displayName: "Groq", backend: .openAI(defaultBase: "https://api.groq.com/openai/v1"), category: .llm, fields: [
            apiKey("--groq-api-key"),
            model("--groq-model", default: "llama-3.3-70b-versatile"),
        ]),
        .init(id: "grok", displayName: "xAI Grok", backend: .openAI(defaultBase: "https://api.x.ai/v1"), category: .llm, fields: [
            apiKey("--grok-api-key"),
            model("--grok-model", default: "grok-3-mini"),
        ]),
        .init(id: "azureopenai", displayName: "Azure OpenAI", backend: .azureOpenAI, category: .llm, fields: [
            apiKey("--azure-openai-api-key"),
            baseURL("--azure-openai-base-url", required: true, placeholder: String(localized: "https://<资源名>.openai.azure.com", bundle: .module)),
            model("--azure-openai-model", default: "gpt-4o-mini"),
            .init(option: "--azure-openai-api-version", title: String(localized: "API 版本", bundle: .module), defaultValue: "2024-10-21", placeholder: "2024-10-21", isAdvanced: true),
        ]),
        .init(id: "openaicompatible", displayName: String(localized: "OpenAI 兼容接口", bundle: .module), backend: .openAI(defaultBase: ""), category: .llm, fields: [
            baseURL("--openai-compatible-base-url", required: true, placeholder: "https://example.com/v1"),
            .init(option: "--openai-compatible-api-key", title: "API Key", kind: .secret),
            model("--openai-compatible-model", default: nil, required: true),
            .init(option: "--openai-compatible-reasoning-effort", title: String(localized: "推理强度", bundle: .module), isAdvanced: true),
            temperature("--openai-compatible-temperature"),
        ], note: String(localized: "兼容 OpenAI Chat Completions 的任意服务", bundle: .module)),
        // Machine translation
        .init(id: "deepl", displayName: "DeepL", backend: .deepL, category: .machine, fields: [
            apiKey("--deepl-auth-key", title: "Auth Key"),
        ], note: String(localized: "支持免费版（:fx 结尾）与专业版 Key", bundle: .module)),
        .init(id: "azure", displayName: String(localized: "Azure 翻译", bundle: .module), backend: .azureTranslator, category: .machine, fields: [
            apiKey("--azure-api-key"),
            .init(option: "--azure-region", title: String(localized: "区域", bundle: .module), placeholder: "eastasia"),
            .init(option: "--azure-endpoint", title: "Endpoint", kind: .url,
                  defaultValue: "https://api.cognitive.microsofttranslator.com", placeholder: "https://api.cognitive.microsofttranslator.com", isAdvanced: true),
        ]),
        .init(id: "tencentmechinetranslation", displayName: String(localized: "腾讯云机器翻译", bundle: .module), backend: .tencent, category: .machine, fields: [
            .init(option: "--tencentcloud-secret-id", title: "SecretId", kind: .secret, isRequired: true),
            .init(option: "--tencentcloud-secret-key", title: "SecretKey", kind: .secret, isRequired: true),
            .init(option: "--tencentcloud-region", title: String(localized: "地域", bundle: .module), defaultValue: "ap-guangzhou", placeholder: "ap-guangzhou", isAdvanced: true),
        ]),
        .init(id: "clitranslator", displayName: String(localized: "自定义命令行翻译器", bundle: .module), backend: .command, category: .machine, fields: [
            .init(option: "--clitranslator-command", title: String(localized: "命令", bundle: .module), isRequired: true, placeholder: "my-translator --from en --to zh"),
            .init(option: "--clitranslator-timeout", title: String(localized: "超时（秒）", bundle: .module), kind: .number, defaultValue: "60", placeholder: "60"),
        ], note: String(localized: "原文经标准输入传入，译文由标准输出返回", bundle: .module)),
    ]
}
