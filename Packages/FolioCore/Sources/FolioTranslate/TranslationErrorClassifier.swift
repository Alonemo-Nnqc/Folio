import Foundation

/// Why a translation failed, derived from the engine's error text.
public enum TranslationFailureReason: String, Sendable, Hashable, CaseIterable {
    case authentication
    case quota
    case network
    case modelNotFound
    case serverError
    case configuration
    case engineBroken
    case encryptedPDF
    case outOfMemory
    case diskFull
    case appleTranslationUnavailable
    case unknown
}

public struct TranslationFailure: Sendable, Hashable {
    public var reason: TranslationFailureReason
    /// Clear Chinese message naming the one cause found, with the server, model or status code when known.
    public var message: String
    /// The engine's own (English) error summary.
    public var rawMessage: String
}

/// Maps raw pdf2zh_next / BabelDOC / HTTP errors to one specific Chinese message: not "the key is invalid,
/// expired or lacks permission" but which of them, from the status code and wording the service sent.
public enum TranslationErrorClassifier {
    /// HTTP status codes only count in an HTTP context: log timestamps (`11:41:50,429`)
    /// and traceback line numbers (`line 401`) must not match.
    private static func http(_ code: Int) -> [String] {
        [#"error code: "# + "\(code)", #"status(_code)?["']?[=: ]+"# + "\(code)", #"\b"# + "\(code)" + #" (client|server) error"#,
         "http \(code)", "http/1.1 \(code)"]
    }

    private static let balance = http(402) + ["insufficient.?balance", "insufficient_quota", String(localized: "余额不足", bundle: .module), "payment required",
                                              "exceeded your current quota", "quota exceeded", "credit"]
    private static let rateLimit = http(429) + ["too many requests", "rate[ -]limit", "ratelimiterror", "rate_limit_exceeded"]
    private static let forbidden = http(403) + ["forbidden", "permissiondenied", "permission denied", "not have access"]
    private static let badKey = http(401) + ["unauthori[sz]ed", "invalid.?api.?key", "incorrect api key", "authenticationerror",
                                             "api key not valid", "invalid.?auth"]

    private static let rules: [(TranslationFailureReason, [String])] = [
        (.appleTranslationUnavailable, [#"FOLIO_APPLE_TRANSLATE:"#]),
        (.modelNotFound, ["model_not_found", #"model[^\n]{0,80}(does not exist|not found|not exist)"#, "no such model",
                          "unknown model", "invalid model", String(localized: "模型不存在", bundle: .module)]),
        (.quota, rateLimit + balance),
        (.authentication, badKey + forbidden),
        (.engineBroken, ["modulenotfounderror", "no module named", "cannot import name", "importerror", "bad interpreter",
                         #"dyld\["#, "library not loaded"]),
        (.configuration, ["is required", "invalid clitranslator", "not found at", "command '.*' not found", "invalid arguments",
                          "context_length_exceeded", "maximum context length"] + http(400)),
        (.encryptedPDF, ["password", "encrypted"]),
        (.outOfMemory, ["memoryerror", "out of memory"]),
        (.diskFull, ["no space left on device", "disk full"]),
        (.serverError, http(500) + http(502) + http(503) + http(504) + ["internal server error", "bad gateway",
                                                                        "service unavailable", "gateway timeout", "overloaded"]),
        (.network, ["connection error", "connecterror", "connecttimeout", "readtimeout", "timed out", "timeout error",
                    "name or service not known", "nodename nor servname", "failed to establish a new connection",
                    "max retries exceeded", "network is unreachable", "connection refused", "connection reset",
                    "sslerror", "ssl: ", "proxyerror", "temporary failure in name resolution", "no reachable upstream",
                    "remoteprotocolerror", "server disconnected"]),
    ]

    public static func classify(message: String, details: String? = nil, logTail: [String] = []) -> TranslationFailure {
        let raw = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = ([raw, details ?? ""] + logTail).joined(separator: "\n")
        let haystack = original.lowercased()
        for (reason, patterns) in rules where matches(haystack, patterns) {
            return TranslationFailure(reason: reason, message: text(for: reason, raw: raw, haystack: haystack, original: original),
                                      rawMessage: raw)
        }
        return TranslationFailure(reason: .unknown, message: text(for: .unknown, raw: raw, haystack: haystack, original: original),
                                  rawMessage: raw)
    }

    private static func matches(_ haystack: String, _ patterns: [String]) -> Bool {
        patterns.contains { haystack.range(of: $0.lowercased(), options: .regularExpression) != nil }
    }

    static func text(for reason: TranslationFailureReason, raw: String, haystack: String, original: String) -> String {
        let found = host(in: original)
        // A space on each side of a Latin name inside Chinese text, none before punctuation.
        let host = found.map { " \($0)" } ?? "", hostThen = found.map { String(localized: " \($0) ", bundle: .module) } ?? ""
        func code(_ codes: [Int]) -> String { statusCode(in: haystack, among: codes).map { String(localized: "（\(String($0))）", bundle: .module) } ?? "" }
        switch reason {
        case .authentication:
            if matches(haystack, forbidden) {
                return String(localized: "翻译服务拒绝访问\(code([403]))：这个 API Key 没有使用该服务或模型的权限", bundle: .module)
            }
            if haystack.contains("expired") { return String(localized: "API Key 已过期\(code([401]))，请在 设置 ▸ 翻译 中换用新的 Key", bundle: .module) }
            return String(localized: "API Key 无效\(code([401]))，请在 设置 ▸ 翻译 中检查是否填写正确", bundle: .module)
        case .quota:
            if matches(haystack, balance) { return String(localized: "翻译服务的账户余额或额度已用完\(code([402, 429]))，请充值或换用其他服务", bundle: .module) }
            return String(localized: "请求过于频繁，被翻译服务限流\(code([429]))，请调低 设置 ▸ 翻译 ▸ 每秒请求数，稍后重试", bundle: .module)
        case .modelNotFound:
            let name = model(in: original).map { " \($0)" } ?? ""
            return String(localized: "模型\(name) 不存在或无权使用，请在 设置 ▸ 翻译 中检查模型名称", bundle: .module)
        case .serverError:
            return String(localized: "翻译服务\(hostThen)暂时出错\(code([500, 502, 503, 504]))，这是服务端的问题，请稍后重试", bundle: .module)
        case .network:
            if matches(haystack, ["nodename nor servname", "name or service not known", "temporary failure in name resolution"]) {
                return String(localized: "找不到服务器\(host)，请检查 Base URL 是否正确", bundle: .module)
            }
            if haystack.contains("connection refused") {
                return String(localized: "服务器\(hostThen)拒绝连接：服务没有运行或端口不对（本地服务如 Ollama 需要先启动）", bundle: .module)
            }
            if matches(haystack, ["sslerror", "ssl: ", "certificate"]) { return String(localized: "与服务器\(hostThen)的安全连接（SSL）失败，请检查代理或证书设置", bundle: .module) }
            if haystack.contains("proxyerror") { return String(localized: "代理服务器连接失败，请检查代理设置", bundle: .module) }
            if matches(haystack, ["timed out", "timeout", "connecttimeout", "readtimeout"]) {
                return String(localized: "连接服务器\(hostThen)超时，网络较慢或需要代理", bundle: .module)
            }
            if matches(haystack, ["connection reset", "server disconnected", "remoteprotocolerror"]) {
                return String(localized: "服务器\(hostThen)中断了连接，请稍后重试", bundle: .module)
            }
            if haystack.contains("network is unreachable") { return String(localized: "网络不可用，请检查网络连接", bundle: .module) }
            return String(localized: "无法连接翻译服务\(host)，请检查网络", bundle: .module)
        case .configuration:
            if matches(haystack, ["context_length_exceeded", "maximum context length"]) {
                return String(localized: "文本超过了模型的上下文长度，请换用上下文更长的模型", bundle: .module)
            }
            if matches(haystack, http(400)) {
                return String(localized: "翻译服务不接受这次请求\(code([400]))：\(shortened(serviceMessage(in: original) ?? raw))", bundle: .module)
            }
            return String(localized: "翻译服务配置不完整：\(shortened(raw))", bundle: .module)
        case .engineBroken:
            if let module = firstMatch(#"no module named '([\w.]+)'"#, in: original) {
                return String(localized: "翻译组件缺少 Python 模块 \(module)，请在 设置 ▸ 翻译 中重新安装组件", bundle: .module)
            }
            if let package = firstMatch(#"cannot import name '[^']+' from '([\w.]+)'"#, in: original) {
                return String(localized: "翻译组件的依赖 \(package) 版本不匹配，请在 设置 ▸ 翻译 中重新安装组件", bundle: .module)
            }
            return String(localized: "翻译组件无法运行，请在 设置 ▸ 翻译 中重新安装组件", bundle: .module)
        case .encryptedPDF:
            return String(localized: "PDF 已加密或受密码保护，无法翻译", bundle: .module)
        case .outOfMemory:
            return String(localized: "内存不足，翻译被中止，请只翻译部分页码", bundle: .module)
        case .diskFull:
            return String(localized: "磁盘空间不足，无法保存译文", bundle: .module)
        case .appleTranslationUnavailable:
            if haystack.contains("not-installed") || haystack.contains("notinstalled") {
                return String(localized: "Apple 系统翻译缺少所需语言，请在 系统设置 ▸ 通用 ▸ 语言与地区 ▸ 翻译语言 中下载后重试", bundle: .module)
            }
            return String(localized: "Apple 系统翻译不支持当前的语言组合", bundle: .module)
        case .unknown:
            return raw.isEmpty ? String(localized: "翻译失败", bundle: .module) : String(localized: "翻译失败：\(shortened(raw))", bundle: .module)
        }
    }

    /// The server the request went to: `host='api.x.com'` (urllib3 / httpx) or a URL.
    static func host(in text: String) -> String? {
        firstMatch(#"host='([^']+)'"#, in: text) ?? firstMatch(#"https?://([A-Za-z0-9.\-]+(?::\d+)?)"#, in: text)
    }

    /// The model the service named: "The model `x` does not exist", "model 'x' not found", "model: x".
    static func model(in text: String) -> String? {
        firstMatch(#"model[\s:=]*[`'"]([^`'"\s]+)[`'"]"#, in: text)
    }

    /// The service's own explanation inside a JSON error body: 'message': '…'.
    static func serviceMessage(in text: String) -> String? {
        firstMatch(#"['"]message['"]\s*:\s*['"]([^'"]+)['"]"#, in: text)
    }

    static func statusCode(in haystack: String, among codes: [Int]) -> Int? {
        codes.first { matches(haystack, http($0)) }
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func shortened(_ text: String, limit: Int = 200) -> String {
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        return firstLine.count > limit ? String(firstLine.prefix(limit)) + "…" : firstLine
    }
}
