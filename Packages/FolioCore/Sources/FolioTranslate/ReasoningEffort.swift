import Foundation

/// Reasoning effort as offered by each service (TRANS-03). The choices depend on the provider and,
/// for OpenAI-style APIs, on the model: GPT-5 accepts minimal…high, the o-series low…high, and
/// non-reasoning models (GPT-4o …) reject the parameter, so nothing is sent for them.
public enum ReasoningEffort {
    public struct Choice: Sendable, Hashable, Identifiable {
        /// Stored value; "" = leave it to the service.
        public let value: String
        public let title: String
        public var id: String { value }
    }

    public enum Support: Sendable, Equatable {
        /// The service has no reasoning control in pdf2zh_next.
        case none
        /// The service has one, but the chosen model does not reason.
        case unsupportedModel
        case choices([Choice], default: String)
    }

    /// Where the choice is stored: the option holding the value (fields keyed by CLI option).
    static let valueOption: [String: String] = [
        "openai": "--openai-reasoning-effort",
        "openaicompatible": "--openai-compatible-reasoning-effort",
        "deepseek": "--deepseek-reasoning-effort",
        "siliconflow": "--siliconflow-enable-thinking",
    ]

    /// Options that only exist to switch the parameter on; Folio sets them itself.
    public static let managedOptions: Set<String> = [
        "--openai-reasoning-effort", "--openai-send-reasoning-effort",
        "--openai-compatible-reasoning-effort", "--openai-compatible-send-reasoning-effort",
        "--deepseek-reasoning-effort", "--deepseek-thinking-mode",
        "--siliconflow-enable-thinking", "--siliconflow-send-enable-thinking-param",
    ]

    static let modelOption: [String: String] = [
        "openai": "--openai-model", "openaicompatible": "--openai-compatible-model",
    ]

    private static func choice(_ value: String, _ title: String) -> Choice { Choice(value: value, title: title) }

    /// OpenAI's levels, lowest to highest.
    private static let fullRange = [choice("minimal", "最低"), choice("low", "低"), choice("medium", "中"), choice("high", "高"),
                                    choice("xhigh", "极高")]

    public static func support(serviceID: String, fields: [String: String]) -> Support {
        switch serviceID {
        case "openai", "openaicompatible":
            let fallback = TranslationServiceCatalog.service(id: serviceID)?.fields
                .first { $0.option == modelOption[serviceID] }?.defaultValue ?? ""
            let model = (fields[modelOption[serviceID]!] ?? "").trimmingCharacters(in: .whitespaces)
            let name = (model.isEmpty ? fallback : model).lowercased()
            // Strip a provider prefix such as "openai/gpt-5" used by gateways.
            let bare = name.split(separator: "/").last.map(String.init) ?? name
            // GPT-5 and later (gpt-5.x, gpt-6…): the full range, up to xhigh.
            if bare.range(of: #"^gpt-([5-9]|\d{2})"#, options: .regularExpression) != nil {
                return .choices(fullRange, default: "medium")
            }
            if bare.range(of: #"^o[1-9]"#, options: .regularExpression) != nil {
                return .choices([choice("low", "低"), choice("medium", "中"), choice("high", "高")], default: "medium")
            }
            if bare.hasPrefix("gpt-4") || bare.hasPrefix("gpt-3") || bare.hasPrefix("chatgpt") {
                return .unsupportedModel
            }
            // Other models behind a compatible endpoint: offer the common levels, but let the user
            // keep the parameter off because many servers reject it.
            if serviceID == "openaicompatible" {
                return .choices([choice("", "不设置")] + fullRange, default: "")
            }
            return .unsupportedModel
        case "deepseek":
            return .choices([choice("", "默认"), choice("off", "关闭思考"), choice("high", "高"), choice("max", "最高")],
                            default: "")
        case "siliconflow":
            return .choices([choice("", "默认"), choice("on", "开启思考"), choice("off", "关闭思考")], default: "")
        default:
            return .none
        }
    }

    /// The stored choice, or the service's default when nothing was chosen.
    public static func current(serviceID: String, fields: [String: String]) -> String? {
        guard case let .choices(choices, defaultValue) = support(serviceID: serviceID, fields: fields),
              let option = valueOption[serviceID] else { return nil }
        let stored = fields[option] ?? defaultValue
        return choices.contains { $0.value == stored } ? stored : defaultValue
    }

    /// Stores a choice in the field map (UI).
    public static func set(_ value: String, serviceID: String, fields: inout [String: String]) {
        guard let option = valueOption[serviceID] else { return }
        fields[option] = value
    }

    /// Turns the stored choice into the CLI options pdf2zh_next expects, including the "send"
    /// switches; drops everything when the model cannot reason (run before building a request).
    public static func apply(serviceID: String, to fields: [String: String]) -> [String: String] {
        var result = fields
        for option in managedOptions { result[option] = nil }
        guard let value = current(serviceID: serviceID, fields: fields), !value.isEmpty else { return result }
        switch serviceID {
        case "openai":
            result["--openai-reasoning-effort"] = value
            result["--openai-send-reasoning-effort"] = "true"
        case "openaicompatible":
            result["--openai-compatible-reasoning-effort"] = value
            result["--openai-compatible-send-reasoning-effort"] = "true"
        case "deepseek":
            if value == "off" {
                result["--deepseek-thinking-mode"] = "disabled"
            } else {
                result["--deepseek-thinking-mode"] = "enabled"
                result["--deepseek-reasoning-effort"] = value
            }
        case "siliconflow":
            result["--siliconflow-send-enable-thinking-param"] = "true"
            if value == "on" { result["--siliconflow-enable-thinking"] = "true" }
        default:
            break
        }
        return result
    }
}
