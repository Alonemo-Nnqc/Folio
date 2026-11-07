import Foundation

/// A chat model that takes a system prompt and a user message and returns text.
protocol ChatModel: TranslationProvider {
    func complete(system: String, user: String) async throws -> String
}

extension ChatModel {
    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> [String] {
        let reply = try await complete(system: LLMBatch.systemPrompt(context), user: LLMBatch.userMessage(items))
        let parsed = LLMBatch.parse(reply, count: items.count)
        if parsed.allSatisfy({ $0 == nil }), ProviderError.isDecline(reply) || ProviderError.isContentRefusal(reply) {
            throw ProviderError(kind: .refused, detail: "declined: " + String(reply.prefix(300)))
        }
        if parsed.contains(where: { $0 == nil }) {
            throw ProviderError(kind: .invalidResponse, detail: "the reply is missing translations: " + String(reply.prefix(300)))
        }
        return parsed.map { $0! }
    }

    func extractTerms(from excerpt: String, context: TranslationContext) async throws -> [GlossaryEntry] {
        LLMBatch.parseTerms(try await complete(system: LLMBatch.termsPrompt(context), user: excerpt))
    }
}

/// OpenAI Chat Completions and the many services compatible with it.
struct OpenAIChatProvider: ChatModel {
    var endpoint: URL
    var apiKey: String?
    var model: String
    var temperature: Double?
    /// Extra body fields (reasoning effort, thinking switches).
    var extraBody: [String: Any & Sendable] = [:]
    var extraHeaders: [String: String] = [:]
    var limits: ProviderLimits

    func complete(system: String, user: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "stream": false,
        ]
        if let temperature { body["temperature"] = temperature }
        for (key, value) in extraBody { body[key] = value }
        var headers = extraHeaders
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        let data = try await HTTP.send(HTTP.request(endpoint, headers: headers, json: body))
        guard let object = try HTTP.json(data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply: " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        let finish = choices.first?["finish_reason"] as? String
        let content = (message["content"] as? String) ?? (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        if finish == "content_filter" || finish == "safety", (content ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw ProviderError(kind: .refused, detail: "finish_reason: \(finish ?? "")")
        }
        if let content { return content }
        throw ProviderError(kind: .invalidResponse, detail: "empty reply")
    }

    /// `{base}/chat/completions`; a bare host means its `/v1`, as other clients assume.
    static func chatURL(base: String) -> URL? {
        let normalized = OpenAIBaseURL.normalized(base)
        return URL(string: normalized.hasSuffix("/chat/completions") ? normalized : normalized + "/chat/completions")
    }
}

/// Anthropic's Messages API.
struct AnthropicProvider: ChatModel {
    var base: URL
    var apiKey: String
    var model: String
    var limits: ProviderLimits

    func complete(system: String, user: String) async throws -> String {
        let body: [String: Any] = [
            "model": model, "max_tokens": 8192, "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        let data = try await HTTP.send(HTTP.request(base.appending(path: "v1/messages"),
                                                     headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"], json: body))
        guard let object = try HTTP.json(data) as? [String: Any], let content = object["content"] as? [[String: Any]] else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply: " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }
}

/// Google's Gemini API.
struct GeminiProvider: ChatModel {
    var apiKey: String
    var model: String
    var limits: ProviderLimits

    func complete(system: String, user: String) async throws -> String {
        let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent") else {
            throw ProviderError(kind: .invalidResponse, detail: "invalid model \(model)")
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.2],
        ]
        let data = try await HTTP.send(HTTP.request(url, headers: ["x-goog-api-key": apiKey], json: body))
        guard let object = try HTTP.json(data) as? [String: Any], let candidates = object["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply: " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}

/// Azure OpenAI: a deployment URL with an API version, and an `api-key` header.
struct AzureOpenAIProvider: ChatModel {
    var resource: String
    var apiKey: String
    var deployment: String
    var apiVersion: String
    var limits: ProviderLimits

    func complete(system: String, user: String) async throws -> String {
        let base = resource.hasSuffix("/") ? String(resource.dropLast()) : resource
        guard let url = URL(string: "\(base)/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)") else {
            throw ProviderError(kind: .invalidResponse, detail: "invalid Azure endpoint \(resource)")
        }
        let chat = OpenAIChatProvider(endpoint: url, apiKey: nil, model: deployment, extraHeaders: ["api-key": apiKey], limits: limits)
        return try await chat.complete(system: system, user: user)
    }
}
