import Foundation

/// One setting of a translation service, mapped to a pdf2zh_next CLI option.
public struct TranslationServiceField: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case text, secret, url, number, toggle
    }

    /// The CLI option, e.g. `--openai-api-key`.
    public let option: String
    public let title: String
    public let kind: Kind
    public let isRequired: Bool
    /// pdf2zh_next's own default (used when the user leaves the field empty).
    public let defaultValue: String?
    public let placeholder: String?
    /// Rarely needed settings the UI may hide behind "高级".
    public let isAdvanced: Bool

    public var id: String { option }
    public var isSecret: Bool { kind == .secret }

    /// Environment variable pdf2zh_next reads for this option
    /// (`--openai-api-key` → `PDF2ZH_OPENAI_API_KEY`). Secrets are passed this way
    /// so they never appear in the process arguments (visible in `ps`).
    public var environmentName: String {
        "PDF2ZH_" + option.drop { $0 == "-" }.replacingOccurrences(of: "-", with: "_").uppercased()
    }

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

/// A translation service offered in Folio's settings.
public struct TranslationService: Sendable, Hashable, Identifiable {
    /// Stable identifier (also the Keychain account prefix), e.g. `openai`.
    public let id: String
    public let displayName: String
    /// The pdf2zh_next switch selecting the service, e.g. `--openai`.
    public let cliSwitch: String
    /// Usable without an account or key.
    public let isFree: Bool
    /// Runs entirely on this Mac (no network needed for translation).
    public let isLocal: Bool
    public let fields: [TranslationServiceField]
    /// A short hint shown under the service picker.
    public let note: String?

    public var requiredFields: [TranslationServiceField] { fields.filter(\.isRequired) }
    public var secretFields: [TranslationServiceField] { fields.filter(\.isSecret) }

    public init(id: String, displayName: String, cliSwitch: String, isFree: Bool = false, isLocal: Bool = false,
                fields: [TranslationServiceField] = [], note: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.cliSwitch = cliSwitch
        self.isFree = isFree
        self.isLocal = isLocal
        self.fields = fields
        self.note = note
    }
}

/// Every translation service supported by pdf2zh_next 2.9.0, plus Apple's
/// offline system translation (implemented through `--clitranslator`).
public enum TranslationServiceCatalog {
    public static let appleServiceID = "apple"
    public static let defaultServiceID = "siliconflowfree"

    public static func service(id: String) -> TranslationService? {
        all.first { $0.id == id }
    }

    // MARK: Field helpers

    private static func apiKey(_ option: String, title: String = "API Key") -> TranslationServiceField {
        .init(option: option, title: title, kind: .secret, isRequired: true)
    }

    private static func model(_ option: String, default value: String?, required: Bool = false) -> TranslationServiceField {
        .init(option: option, title: "模型", isRequired: required, defaultValue: value, placeholder: value)
    }

    private static func baseURL(_ option: String, default value: String? = nil, required: Bool = false, placeholder: String? = nil) -> TranslationServiceField {
        .init(option: option, title: "Base URL", kind: .url, isRequired: required, defaultValue: value, placeholder: placeholder ?? value)
    }

    private static func jsonMode(_ option: String) -> TranslationServiceField {
        .init(option: option, title: "启用 JSON 模式", kind: .toggle, isAdvanced: true)
    }

    // MARK: Catalog

    /// In the order of the requirements document (TRANS-03).
    public static let all: [TranslationService] = [
        .init(id: "siliconflowfree", displayName: "SiliconFlow 免费", cliSwitch: "--siliconflowfree", isFree: true,
              fields: [jsonMode("--siliconflow-free-enable-json-mode")],
              note: "pdf2zh 项目提供的免费大模型通道，无需注册；高峰期可能限流。"),
        .init(id: "google", displayName: "Google（免费）", cliSwitch: "--google", isFree: true,
              note: "使用 Google 翻译网页接口，无需 Key；频繁使用会被暂时限流（HTTP 429）。"),
        .init(id: "bing", displayName: "Bing（免费）", cliSwitch: "--bing", isFree: true,
              note: "使用 Bing 翻译网页接口，无需 Key；有频率限制。"),
        .init(id: appleServiceID, displayName: "Apple 系统翻译（离线）", cliSwitch: "--clitranslator", isFree: true, isLocal: true,
              note: "使用 macOS 自带的翻译模型，完全离线、免费；需要先在“系统设置 › 通用 › 语言与地区 › 翻译语言”中下载对应语言。"),
        .init(id: "openai", displayName: "OpenAI", cliSwitch: "--openai", fields: [
            apiKey("--openai-api-key"),
            model("--openai-model", default: "gpt-4o-mini"),
            baseURL("--openai-base-url", placeholder: "https://api.openai.com/v1"),
            .init(option: "--openai-timeout", title: "超时（秒）", kind: .number, isAdvanced: true),
            .init(option: "--openai-temperature", title: "Temperature", kind: .number, isAdvanced: true),
            .init(option: "--openai-reasoning-effort", title: "推理强度", placeholder: "minimal / low / medium / high", isAdvanced: true),
            .init(option: "--openai-send-temprature", title: "发送 Temperature 参数", kind: .toggle, isAdvanced: true),
            .init(option: "--openai-send-reasoning-effort", title: "发送推理强度参数", kind: .toggle, isAdvanced: true),
            jsonMode("--openai-enable-json-mode"),
        ]),
        .init(id: "deepseek", displayName: "DeepSeek", cliSwitch: "--deepseek", fields: [
            apiKey("--deepseek-api-key"),
            model("--deepseek-model", default: "deepseek-chat"),
            .init(option: "--deepseek-thinking-mode", title: "思考模式", placeholder: "enabled / disabled", isAdvanced: true),
            .init(option: "--deepseek-reasoning-effort", title: "推理强度", placeholder: "high / max", isAdvanced: true),
            jsonMode("--deepseek-enable-json-mode"),
        ]),
        .init(id: "deepl", displayName: "DeepL", cliSwitch: "--deepl", fields: [
            apiKey("--deepl-auth-key", title: "Auth Key"),
        ]),
        .init(id: "ollama", displayName: "Ollama（本地）", cliSwitch: "--ollama", isFree: true, isLocal: true, fields: [
            model("--ollama-model", default: "gemma2"),
            .init(option: "--ollama-host", title: "服务地址", kind: .url, isRequired: true,
                  defaultValue: "http://localhost:11434", placeholder: "http://localhost:11434"),
            .init(option: "--num-predict", title: "最大生成 Token 数", kind: .number, defaultValue: "2000", isAdvanced: true),
        ], note: "需要先在本机运行 Ollama 并下载模型。"),
        .init(id: "xinference", displayName: "Xinference（本地）", cliSwitch: "--xinference", isFree: true, isLocal: true, fields: [
            model("--xinference-model", default: "gemma-2-it"),
            .init(option: "--xinference-host", title: "服务地址", kind: .url, isRequired: true, placeholder: "http://localhost:9997"),
        ]),
        .init(id: "azureopenai", displayName: "Azure OpenAI", cliSwitch: "--azureopenai", fields: [
            apiKey("--azure-openai-api-key"),
            baseURL("--azure-openai-base-url", required: true, placeholder: "https://<资源名>.openai.azure.com"),
            model("--azure-openai-model", default: "gpt-4o-mini"),
            .init(option: "--azure-openai-api-version", title: "API 版本", defaultValue: "2024-06-01", placeholder: "2024-06-01", isAdvanced: true),
        ]),
        .init(id: "azure", displayName: "Azure 翻译", cliSwitch: "--azure", fields: [
            apiKey("--azure-api-key"),
            .init(option: "--azure-endpoint", title: "Endpoint", kind: .url,
                  defaultValue: "https://api.translator.azure.cn", placeholder: "https://api.translator.azure.cn"),
        ]),
        .init(id: "modelscope", displayName: "ModelScope 魔搭", cliSwitch: "--modelscope", fields: [
            apiKey("--modelscope-api-key"),
            model("--modelscope-model", default: "Qwen/Qwen2.5-32B-Instruct"),
            jsonMode("--modelscope-enable-json-mode"),
        ]),
        .init(id: "zhipu", displayName: "智谱 AI", cliSwitch: "--zhipu", fields: [
            apiKey("--zhipu-api-key"),
            model("--zhipu-model", default: "glm-4-flash"),
            jsonMode("--zhipu-enable-json-mode"),
        ]),
        .init(id: "siliconflow", displayName: "SiliconFlow 硅基流动", cliSwitch: "--siliconflow", fields: [
            apiKey("--siliconflow-api-key"),
            model("--siliconflow-model", default: "Qwen/Qwen2.5-7B-Instruct"),
            baseURL("--siliconflow-base-url", default: "https://api.siliconflow.cn/v1"),
            .init(option: "--siliconflow-enable-thinking", title: "启用思考", kind: .toggle, isAdvanced: true),
            .init(option: "--siliconflow-send-enable-thinking-param", title: "发送思考开关参数", kind: .toggle, isAdvanced: true),
            jsonMode("--siliconflow-enable-json-mode"),
        ]),
        .init(id: "tencentmechinetranslation", displayName: "腾讯云机器翻译", cliSwitch: "--tencentmechinetranslation", fields: [
            .init(option: "--tencentcloud-secret-id", title: "SecretId", kind: .secret, isRequired: true),
            .init(option: "--tencentcloud-secret-key", title: "SecretKey", kind: .secret, isRequired: true),
        ]),
        .init(id: "gemini", displayName: "Gemini", cliSwitch: "--gemini", fields: [
            apiKey("--gemini-api-key"),
            model("--gemini-model", default: "gemini-1.5-flash"),
            jsonMode("--gemini-enable-json-mode"),
        ]),
        .init(id: "anythingllm", displayName: "AnythingLLM", cliSwitch: "--anythingllm", fields: [
            .init(option: "--anythingllm-url", title: "服务地址", kind: .url, isRequired: true, placeholder: "http://localhost:3001"),
            apiKey("--anythingllm-apikey"),
        ]),
        .init(id: "dify", displayName: "Dify", cliSwitch: "--dify", fields: [
            .init(option: "--dify-url", title: "服务地址", kind: .url, isRequired: true, placeholder: "https://api.dify.ai/v1"),
            apiKey("--dify-apikey"),
        ]),
        .init(id: "grok", displayName: "Grok", cliSwitch: "--grok", fields: [
            apiKey("--grok-api-key"),
            model("--grok-model", default: "grok-2-1212"),
            jsonMode("--grok-enable-json-mode"),
        ]),
        .init(id: "groq", displayName: "Groq", cliSwitch: "--groq", fields: [
            apiKey("--groq-api-key"),
            model("--groq-model", default: "llama-3-3-70b-versatile"),
            jsonMode("--groq-enable-json-mode"),
        ]),
        .init(id: "qwenmt", displayName: "通义千问 MT", cliSwitch: "--qwenmt", fields: [
            apiKey("--qwenmt-api-key"),
            model("--qwenmt-model", default: "qwen-mt-plus"),
            baseURL("--qwenmt-base-url", default: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
            .init(option: "--ali-domains", title: "领域提示", placeholder: "默认：学术论文风格", isAdvanced: true),
        ]),
        .init(id: "aliyundashscope", displayName: "阿里云百炼", cliSwitch: "--aliyundashscope", fields: [
            apiKey("--aliyun-dashscope-api-key"),
            model("--aliyun-dashscope-model", default: "qwen-plus-latest"),
            baseURL("--aliyun-dashscope-base-url", default: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
            .init(option: "--aliyun-dashscope-timeout", title: "超时（秒）", kind: .number, defaultValue: "500", isAdvanced: true),
            .init(option: "--aliyun-dashscope-temperature", title: "Temperature", kind: .number, defaultValue: "0.0", isAdvanced: true),
            .init(option: "--aliyun-dashscope-send-temperature", title: "发送 Temperature 参数", kind: .toggle, isAdvanced: true),
            jsonMode("--aliyun-dashscope-enable-json-mode"),
        ]),
        .init(id: "openaicompatible", displayName: "OpenAI 兼容接口", cliSwitch: "--openaicompatible", fields: [
            baseURL("--openai-compatible-base-url", required: true, placeholder: "https://example.com/v1"),
            apiKey("--openai-compatible-api-key"),
            model("--openai-compatible-model", default: "gpt-4o-mini", required: true),
            .init(option: "--openai-compatible-timeout", title: "超时（秒）", kind: .number, isAdvanced: true),
            .init(option: "--openai-compatible-temperature", title: "Temperature", kind: .number, isAdvanced: true),
            .init(option: "--openai-compatible-reasoning-effort", title: "推理强度", placeholder: "minimal / low / medium / high", isAdvanced: true),
            .init(option: "--openai-compatible-send-temperature", title: "发送 Temperature 参数", kind: .toggle, isAdvanced: true),
            .init(option: "--openai-compatible-send-reasoning-effort", title: "发送推理强度参数", kind: .toggle, isAdvanced: true),
            jsonMode("--openai-compatible-enable-json-mode"),
        ], note: "适用于任何兼容 OpenAI Chat Completions 的服务（如 Moonshot、LM Studio、vLLM 等）。"),
        .init(id: "claudecode", displayName: "Claude Code", cliSwitch: "--claudecode", fields: [
            .init(option: "--claude-code-path", title: "claude 可执行文件路径", isRequired: true,
                  defaultValue: "claude", placeholder: "/usr/local/bin/claude"),
            .init(option: "--claude-code-model", title: "模型", defaultValue: "sonnet", placeholder: "sonnet"),
        ], note: "调用本机已登录的 Claude Code 命令行；建议填写 claude 的完整路径。"),
        .init(id: "clitranslator", displayName: "自定义命令行翻译器", cliSwitch: "--clitranslator", fields: [
            .init(option: "--clitranslator-command", title: "命令", isRequired: true, placeholder: "my-translator --from en --to zh"),
            .init(option: "--clitranslator-timeout", title: "超时（秒）", kind: .number, defaultValue: "60", placeholder: "60"),
            .init(option: "--clitranslator-postprocess-command", title: "后处理命令", placeholder: "jq -r .translation", isAdvanced: true),
        ], note: "每段原文通过标准输入传给命令，命令把译文写到标准输出。"),
    ]
}
