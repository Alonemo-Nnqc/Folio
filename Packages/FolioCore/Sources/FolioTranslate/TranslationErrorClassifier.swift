import Foundation

/// Why a translation failed, derived from the engine's error text.
public enum TranslationFailureReason: String, Sendable, Hashable, CaseIterable {
    case authentication
    case quota
    case network
    case configuration
    case engineBroken
    case encryptedPDF
    case outOfMemory
    case appleTranslationUnavailable
    case unknown
}

public struct TranslationFailure: Sendable, Hashable {
    public var reason: TranslationFailureReason
    /// Clear Chinese message for the user.
    public var message: String
    /// The engine's own (English) error summary.
    public var rawMessage: String
}

/// Maps raw pdf2zh_next / BabelDOC / HTTP errors to clear Chinese messages.
public enum TranslationErrorClassifier {
    private static let rules: [(TranslationFailureReason, [String])] = [
        (.appleTranslationUnavailable, [#"FOLIO_APPLE_TRANSLATE:"#]),
        (.quota, [#"\b429\b"#, "too many requests", "rate.?limit", "quota", "insufficient.?balance", "余额不足",
                  #"\b402\b"#, "payment required", "exceeded your current"]),
        (.authentication, [#"\b401\b"#, "unauthori[sz]ed", "invalid.?api.?key", "incorrect api key", "authenticationerror",
                           "api key not valid", "invalid.?auth", #"\b403\b"#, "forbidden", "permissiondenied"]),
        (.engineBroken, ["modulenotfounderror", "no module named", "cannot import name", "importerror", "bad interpreter",
                         #"dyld\["#, "library not loaded"]),
        (.configuration, ["is required", "invalid clitranslator", "not found at", "command '.*' not found", "invalid arguments"]),
        (.encryptedPDF, ["password", "encrypted"]),
        (.outOfMemory, ["memoryerror", "out of memory"]),
        (.network, ["connection error", "connecterror", "connecttimeout", "readtimeout", "timed out", "timeout error",
                    "name or service not known", "nodename nor servname", "failed to establish a new connection",
                    "max retries exceeded", "network is unreachable", "connection refused", "connection reset",
                    "sslerror", "ssl: ", "proxyerror", "temporary failure in name resolution", "no reachable upstream",
                    "remoteprotocolerror", "server disconnected"]),
    ]

    public static func classify(message: String, details: String? = nil, logTail: [String] = []) -> TranslationFailure {
        let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let haystack = ([raw, details ?? ""] + logTail).joined(separator: "\n").lowercased()
        for (reason, patterns) in rules {
            for pattern in patterns where haystack.range(of: pattern.lowercased(), options: .regularExpression) != nil {
                return TranslationFailure(reason: reason, message: text(for: reason, raw: raw, haystack: haystack), rawMessage: raw)
            }
        }
        return TranslationFailure(reason: .unknown, message: text(for: .unknown, raw: raw, haystack: haystack), rawMessage: raw)
    }

    static func text(for reason: TranslationFailureReason, raw: String, haystack: String) -> String {
        switch reason {
        case .authentication:
            return "翻译服务拒绝了请求：API Key 无效、已过期或没有权限。请在设置的“翻译”页检查 Key。"
        case .quota:
            return "翻译服务额度不足或请求过于频繁（限流）。请稍后重试、降低 QPS，或换用其他服务。"
        case .network:
            return "无法连接翻译服务，请检查网络或代理设置后重试。"
        case .configuration:
            return "翻译服务配置不完整：\(shortened(raw))"
        case .engineBroken:
            return "翻译组件已损坏，请在设置的“翻译”页重新安装组件。"
        case .encryptedPDF:
            return "PDF 已加密或受密码保护，无法翻译。"
        case .outOfMemory:
            return "内存不足，翻译被中止。请尝试只翻译部分页码。"
        case .appleTranslationUnavailable:
            if haystack.contains("not-installed") || haystack.contains("notinstalled") {
                return "Apple 系统翻译缺少所需语言。请在“系统设置 › 通用 › 语言与地区 › 翻译语言”中下载源语言和目标语言后重试。"
            }
            return "Apple 系统翻译不支持当前的语言组合。"
        case .unknown:
            return raw.isEmpty ? "翻译失败。" : "翻译失败：\(shortened(raw))"
        }
    }

    static func shortened(_ text: String, limit: Int = 200) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return firstLine.count > limit ? String(firstLine.prefix(limit)) + "…" : firstLine
    }
}
