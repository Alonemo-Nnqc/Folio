import Foundation

public enum TranslationConfigurationError: Error, LocalizedError, Sendable, Equatable {
    case unknownService(String)
    case missingField(service: String, field: String)
    case agentNotFound(String)
    case appleUnavailable

    public var errorDescription: String? {
        switch self {
        case .unknownService(let id): String(localized: "未知的翻译服务：\(id)", bundle: .module)
        case .missingField(let service, let field): String(localized: "\(service) 需要填写“\(field)”，请在设置的“翻译”页补充。", bundle: .module)
        case .agentNotFound(let command): String(localized: "在这台 Mac 上找不到 \(command)。请先安装并登录，或在 设置 ▸ 翻译 的高级选项里填写它的路径。", bundle: .module)
        case .appleUnavailable: String(localized: "Apple 系统翻译需要 macOS 26 或更高版本。", bundle: .module)
        }
    }
}

enum ProviderFactory {
    /// The provider for `serviceID` with the user's values. `concurrency` overrides the provider's own (QPS option).
    static func make(serviceID: String, fields: [String: String], secrets: [String: String], concurrency: Int?) throws -> TranslationProvider {
        guard let service = TranslationServiceCatalog.service(id: serviceID) else { throw TranslationConfigurationError.unknownService(serviceID) }
        func value(_ option: String) -> String? {
            guard let field = service.fields.first(where: { $0.option == option }) else { return nil }
            let raw = (field.isSecret ? secrets[option] : fields[option])?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw, !raw.isEmpty { return raw }
            return field.defaultValue
        }
        func required(_ option: String) throws -> String {
            if let v = value(option) { return v }
            let title = service.fields.first { $0.option == option }?.title ?? option
            throw TranslationConfigurationError.missingField(service: service.displayName, field: title)
        }
        for field in service.requiredFields { _ = try required(field.option) }
        let modelOption = service.fields.first { $0.title == TranslationServiceCatalog.modelFieldTitle }?.option

        var provider: TranslationProvider
        switch service.backend {
        case .openAI(let defaultBase):
            let local = service.category == .local
            let baseOption = service.fields.first { $0.kind == .url }?.option
            var base = baseOption.flatMap(value) ?? defaultBase
            if local, !base.contains("/v1") { base = OpenAIBaseURL.normalized(base) }
            guard let endpoint = OpenAIChatProvider.chatURL(base: base) else {
                throw TranslationConfigurationError.missingField(service: service.displayName, field: "Base URL")
            }
            let key = service.secretFields.first.flatMap { value($0.option) }
            var extra: [String: any Sendable] = [:]
            let effortFields = ReasoningEffort.apply(serviceID: serviceID, to: fields)
            switch serviceID {
            case "openai":
                if let effort = effortFields["--openai-reasoning-effort"], !effort.isEmpty { extra["reasoning_effort"] = effort }
            case "openaicompatible":
                if let effort = effortFields["--openai-compatible-reasoning-effort"], !effort.isEmpty { extra["reasoning_effort"] = effort }
            case "deepseek":
                if effortFields["--deepseek-thinking-mode"] == "disabled" { extra["thinking"] = ["type": "disabled"] }
                if let effort = effortFields["--deepseek-reasoning-effort"], !effort.isEmpty {
                    extra["thinking"] = ["type": "enabled"]
                    extra["reasoning_effort"] = effort
                }
            case "siliconflow":
                if effortFields["--siliconflow-send-enable-thinking-param"] == "true" {
                    extra["enable_thinking"] = effortFields["--siliconflow-enable-thinking"] == "true"
                }
            case "ollama":
                // Qwen 3 and other reasoning models think at length unless told not to.
                extra["think"] = false
            default: break
            }
            let temperatureOption = service.fields.first { $0.title == "Temperature" }?.option
            let temperature = temperatureOption.flatMap { fields[$0] }.flatMap(Double.init) ?? (extra["reasoning_effort"] == nil ? 0.2 : nil)
            provider = OpenAIChatProvider(endpoint: endpoint, apiKey: key, model: try required(modelOption ?? ""), temperature: temperature,
                                          extraBody: extra,
                                          limits: local ? ProviderLimits(batchCharacters: 1800, batchItems: 20, concurrency: 2, usesContext: true, startupSeconds: 2, secondsPerCharacter: 0.04)
                                                        : ProviderLimits(batchCharacters: 2600, batchItems: 30, concurrency: 8, usesContext: true))
        case .azureOpenAI:
            provider = AzureOpenAIProvider(resource: try required("--azure-openai-base-url"), apiKey: try required("--azure-openai-api-key"),
                                           deployment: try required("--azure-openai-model"),
                                           apiVersion: value("--azure-openai-api-version") ?? "2024-10-21",
                                           limits: ProviderLimits(batchCharacters: 2600, batchItems: 30, concurrency: 8, usesContext: true))
        case .anthropic:
            let base = value("--anthropic-base-url").flatMap(URL.init(string:)) ?? URL(string: "https://api.anthropic.com")!
            provider = AnthropicProvider(base: base, apiKey: try required("--anthropic-api-key"), model: try required("--anthropic-model"),
                                         limits: ProviderLimits(batchCharacters: 2600, batchItems: 30, concurrency: 8, usesContext: true))
        case .gemini:
            provider = GeminiProvider(apiKey: try required("--gemini-api-key"), model: try required("--gemini-model"),
                                      limits: ProviderLimits(batchCharacters: 2600, batchItems: 30, concurrency: 8, usesContext: true))
        case .qwenMT:
            guard let endpoint = OpenAIChatProvider.chatURL(base: value("--qwenmt-base-url") ?? "https://dashscope.aliyuncs.com/compatible-mode/v1") else {
                throw TranslationConfigurationError.missingField(service: service.displayName, field: "Base URL")
            }
            provider = QwenMTProvider(endpoint: endpoint, apiKey: try required("--qwenmt-api-key"), model: try required("--qwenmt-model"),
                                      domains: fields["--ali-domains"])
        case .deepL:
            provider = DeepLProvider(key: try required("--deepl-auth-key"))
        case .azureTranslator:
            provider = MicrosoftTranslatorProvider(access: .azure(key: try required("--azure-api-key"), region: value("--azure-region"),
                                                                   endpoint: value("--azure-endpoint") ?? ""))
        case .tencent:
            provider = TencentProvider(secretID: try required("--tencentcloud-secret-id"), secretKey: try required("--tencentcloud-secret-key"),
                                       region: value("--tencentcloud-region") ?? "ap-guangzhou")
        case .googleWeb:
            provider = GoogleWebProvider()
        case .bingWeb:
            provider = BingWebProvider()
        case .apple:
            guard AppleSystemTranslator.isSupportedOnThisSystem else { throw TranslationConfigurationError.appleUnavailable }
            provider = AppleProvider()
        case .agent(let agent):
            let pathOption = service.fields.first { $0.option.hasSuffix("-path") }?.option
            guard let executable = agent.locate(customPath: pathOption.flatMap { fields[$0] }) else {
                throw TranslationConfigurationError.agentNotFound(agent.command)
            }
            var model = modelOption.flatMap(value)
            // CodeBuddy without a model chosen: a quick one of the account's, not its own default (minutes a page).
            if agent == .codebuddy, model?.isEmpty != false { model = CodeBuddyAccount.quickModel(among: CodeBuddyAccount.models()) }
            provider = AgentProvider(agent: agent, executable: executable, model: model,
                                     effort: ReasoningEffort.agentEffort(serviceID: serviceID, fields: fields))
        case .command:
            provider = CommandProvider(command: try required("--clitranslator-command"),
                                       timeout: value("--clitranslator-timeout").flatMap(Double.init) ?? 60)
        }
        if let concurrency, concurrency > 0 { provider = ConcurrencyOverride(base: provider, concurrency: concurrency) }
        return provider
    }
}

/// A provider with a different number of parallel requests (设置 ▸ 翻译 ▸ 并发数).
struct ConcurrencyOverride: TranslationProvider {
    var base: TranslationProvider
    var concurrency: Int

    var limits: ProviderLimits {
        var limits = base.limits
        limits.concurrency = concurrency
        return limits
    }

    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> [String] {
        try await base.translate(items, context: context)
    }

    func extractTerms(from excerpt: String, context: TranslationContext) async throws -> [GlossaryEntry] {
        try await base.extractTerms(from: excerpt, context: context)
    }

    func prewarm() async { await base.prewarm() }
}
