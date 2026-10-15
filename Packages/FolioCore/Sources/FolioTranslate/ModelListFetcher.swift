import Foundation

/// Lists the models a translation service offers, so the user can pick one instead of typing it.
/// Uses each provider's own listing endpoint with the key and base URL entered in settings.
public enum ModelListFetcher {
    enum API: Sendable, Equatable {
        /// `GET {base}/models` → `{"data": [{"id": …}]}` (OpenAI and the many compatible services).
        case openAI(defaultBase: String?, query: String? = nil)
        /// `GET {host}/api/tags` → `{"models": [{"name": …}]}`.
        case ollama
        /// `GET …/v1beta/models?key=` → `{"models": [{"name": "models/…", "supportedGenerationMethods": […]}]}`.
        case gemini
    }

    struct Endpoint: Sendable {
        var api: API
        var modelOption: String
        var baseOption: String?
        var keyOption: String?
        /// Local or self-hosted endpoints often need no key.
        var keyRequired = true
    }

    static let endpoints: [String: Endpoint] = [
        "openai": .init(api: .openAI(defaultBase: "https://api.openai.com/v1"), modelOption: "--openai-model",
                        baseOption: "--openai-base-url", keyOption: "--openai-api-key"),
        "deepseek": .init(api: .openAI(defaultBase: "https://api.deepseek.com"), modelOption: "--deepseek-model",
                          keyOption: "--deepseek-api-key"),
        "siliconflow": .init(api: .openAI(defaultBase: "https://api.siliconflow.cn/v1", query: "type=text&sub_type=chat"),
                             modelOption: "--siliconflow-model", baseOption: "--siliconflow-base-url",
                             keyOption: "--siliconflow-api-key"),
        "openaicompatible": .init(api: .openAI(defaultBase: nil), modelOption: "--openai-compatible-model",
                                  baseOption: "--openai-compatible-base-url", keyOption: "--openai-compatible-api-key",
                                  keyRequired: false),
        "aliyundashscope": .init(api: .openAI(defaultBase: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
                                 modelOption: "--aliyun-dashscope-model", baseOption: "--aliyun-dashscope-base-url",
                                 keyOption: "--aliyun-dashscope-api-key"),
        "qwenmt": .init(api: .openAI(defaultBase: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
                        modelOption: "--qwenmt-model", baseOption: "--qwenmt-base-url", keyOption: "--qwenmt-api-key"),
        "modelscope": .init(api: .openAI(defaultBase: "https://api-inference.modelscope.cn/v1"),
                            modelOption: "--modelscope-model", keyOption: "--modelscope-api-key"),
        "zhipu": .init(api: .openAI(defaultBase: "https://open.bigmodel.cn/api/paas/v4"), modelOption: "--zhipu-model",
                       keyOption: "--zhipu-api-key"),
        "groq": .init(api: .openAI(defaultBase: "https://api.groq.com/openai/v1"), modelOption: "--groq-model",
                      keyOption: "--groq-api-key"),
        "grok": .init(api: .openAI(defaultBase: "https://api.x.ai/v1"), modelOption: "--grok-model",
                      keyOption: "--grok-api-key"),
        "xinference": .init(api: .openAI(defaultBase: "http://localhost:9997/v1"), modelOption: "--xinference-model",
                            baseOption: "--xinference-host"),
        "ollama": .init(api: .ollama, modelOption: "--ollama-model", baseOption: "--ollama-host"),
        "gemini": .init(api: .gemini, modelOption: "--gemini-model", keyOption: "--gemini-api-key"),
    ]

    public enum FetchError: Error, LocalizedError, Sendable, Equatable {
        case missingBaseURL
        case missingKey
        case unauthorized
        case http(Int)
        case unreadable
        case empty

        public var errorDescription: String? {
            switch self {
            case .missingBaseURL: String(localized: "请先填写服务地址（Base URL）。", bundle: .module)
            case .missingKey: String(localized: "请先填写 API Key。", bundle: .module)
            case .unauthorized: String(localized: "API Key 无效或没有权限（401 / 403）。", bundle: .module)
            case .http(let code): String(localized: "服务返回错误 \(code)。", bundle: .module)
            case .unreadable: String(localized: "无法识别服务返回的模型列表。", bundle: .module)
            case .empty: String(localized: "服务没有返回任何模型。", bundle: .module)
            }
        }
    }

    /// Whether a model field of this service can be filled from a fetched list.
    public static func supports(serviceID: String, modelOption: String) -> Bool {
        endpoints[serviceID]?.modelOption == modelOption
    }

    /// Fetches model ids, sorted. `fieldValues` / `secrets` are keyed by CLI option, as in `TranslationRequest`.
    /// An OpenAI-style address is tried as given and with `/v1` (`OpenAIBaseURL`); the first that lists models wins,
    /// otherwise the error of the address the engine will use is reported.
    public static func fetch(serviceID: String, fieldValues: [String: String], secrets: [String: String],
                             session: URLSession = .shared) async throws -> [String] {
        guard let endpoint = endpoints[serviceID] else { return [] }
        var firstError: Error?
        for request in try makeRequests(endpoint, fieldValues: fieldValues, secrets: secrets) {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw [401, 403].contains(http.statusCode) ? FetchError.unauthorized : FetchError.http(http.statusCode)
                }
                let models = try parse(data, api: endpoint.api)
                guard !models.isEmpty else { throw FetchError.empty }
                return models
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? FetchError.empty
    }

    /// The requests to try, most likely first.
    static func makeRequests(_ endpoint: Endpoint, fieldValues: [String: String], secrets: [String: String]) throws -> [URLRequest] {
        let first = try makeRequest(endpoint, fieldValues: fieldValues, secrets: secrets)
        guard case .openAI = endpoint.api, let option = endpoint.baseOption, OpenAIBaseURL.options.contains(option),
              let base = fieldValues[option], !base.isEmpty else { return [first] }
        // The other spelling of the address: with /v1 if it was given without, as given if /v1 was added.
        var values = fieldValues
        values[option] = OpenAIBaseURL.alternative(base)
        guard let second = try? makeRequest(endpoint, fieldValues: values, secrets: secrets, normalizing: false),
              second.url != first.url else { return [first] }
        return [first, second]
    }

    static func makeRequest(_ endpoint: Endpoint, fieldValues: [String: String], secrets: [String: String],
                            normalizing: Bool = true) throws -> URLRequest {
        func value(_ option: String?) -> String? {
            guard let option else { return nil }
            let text = (secrets[option] ?? fieldValues[option])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        let key = value(endpoint.keyOption)
        if endpoint.keyOption != nil && endpoint.keyRequired && key == nil { throw FetchError.missingKey }
        var url: URL?
        switch endpoint.api {
        case let .openAI(defaultBase, query):
            guard var base = value(endpoint.baseOption) ?? defaultBase else { throw FetchError.missingBaseURL }
            if normalizing, let option = endpoint.baseOption, OpenAIBaseURL.options.contains(option) { base = OpenAIBaseURL.normalized(base) }
            while base.hasSuffix("/") { base.removeLast() }
            // Xinference's host is given without the /v1 prefix.
            if endpoint.baseOption == "--xinference-host", !base.hasSuffix("/v1") { base += "/v1" }
            url = URL(string: base + "/models" + (query.map { "?" + $0 } ?? ""))
        case .ollama:
            var host = value(endpoint.baseOption) ?? "http://localhost:11434"
            while host.hasSuffix("/") { host.removeLast() }
            url = URL(string: host + "/api/tags")
        case .gemini:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "pageSize", value: "200")]
            url = components.url
        }
        guard let url else { throw FetchError.missingBaseURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if case .openAI = endpoint.api, let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }

    static func parse(_ data: Data, api: API) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.unreadable }
        var names: [String]
        switch api {
        case .openAI:
            guard let list = object["data"] as? [[String: Any]] else { throw FetchError.unreadable }
            names = list.compactMap { $0["id"] as? String }
        case .ollama:
            guard let list = object["models"] as? [[String: Any]] else { throw FetchError.unreadable }
            names = list.compactMap { $0["name"] as? String }
        case .gemini:
            guard let list = object["models"] as? [[String: Any]] else { throw FetchError.unreadable }
            names = list.filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") ?? true }
                .compactMap { ($0["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
        }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// OpenAI-style APIs live under `/v1`. Like other clients (Cherry Studio, most OpenAI SDK setups), an address given
/// as a bare host — "https://api.example.com" — means its `/v1`; an address with a path is used as given. Some
/// gateways answer a request outside their routes with 401, which looked like a wrong API key.
public enum OpenAIBaseURL {
    /// The address options this applies to (not Azure, whose paths differ).
    public static let options: Set<String> = ["--openai-base-url", "--openai-compatible-base-url"]

    public static func normalized(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), url.host() != nil, url.path().isEmpty || url.path() == "/" else { return base }
        return base + "/v1"
    }

    /// The other spelling to try when listing models: with `/v1` for an address that has another path, without it
    /// for one that ends in `/v1` because Folio added it.
    static func alternative(_ raw: String) -> String {
        let normalized = normalized(raw)
        var given = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while given.hasSuffix("/") { given.removeLast() }
        if normalized != given { return given }
        return given.hasSuffix("/v1") ? given : given + "/v1"
    }
}
