import Foundation

/// A chat model that takes a system prompt and a user message and returns text.
protocol ChatModel: TranslationProvider {
    func complete(system: String, user: String) async throws -> String
}

extension ChatModel {
    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> [String] {
        let system = LLMBatch.systemPrompt(context)
        let reply = try await complete(system: system, user: LLMBatch.userMessage(items))
        var parsed = LLMBatch.parse(reply, count: items.count)
        if parsed.allSatisfy({ $0 == nil }) {
            if ProviderError.isDecline(reply) || ProviderError.isContentRefusal(reply) {
                throw ProviderError(kind: .refused, detail: "declined: " + String(reply.prefix(300)))
            }
            throw ProviderError(kind: .invalidResponse, detail: "the reply is missing translations: " + String(reply.prefix(300)))
        }
        // What came back is kept. Only the texts a model left out are asked for again: one skipped of thirty does not
        // make it translate the other twenty-nine a second time.
        var rounds = 0
        while parsed.contains(where: { $0 == nil }), rounds < 2 {
            rounds += 1
            let missing = parsed.indices.filter { parsed[$0] == nil }
            let more = LLMBatch.parse(try await complete(system: system, user: LLMBatch.userMessage(missing.map { items[$0] })), count: missing.count)
            for (k, index) in missing.enumerated() { parsed[index] = more[k] }
            if more.allSatisfy({ $0 == nil }) { break }
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
    var modelName: String? { model }
    var endpoint: URL
    var apiKey: String?
    var model: String
    var temperature: Double?
    /// Extra body fields (reasoning effort, thinking switches).
    var extraBody: [String: Any & Sendable] = [:]
    /// Body fields (`temperature` and names in `extraBody`) that are Folio's own idea, not the user's choice: left out
    /// when a model or server turns them down (`ParameterMemory`).
    var optional: Set<String> = []
    var extraHeaders: [String: String] = [:]
    var limits: ProviderLimits

    func prewarm() async { await HTTP.warm(endpoint) }

    func complete(system: String, user: String) async throws -> String {
        var fixed: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        // The reply is read as it is written. A server that cannot do that answers in one piece (or, turning the
        // parameter down, is asked again without it).
        var extras: [String: Any] = ["stream": true]
        if let temperature {
            if optional.contains("temperature") { extras["temperature"] = temperature } else { fixed["temperature"] = temperature }
        }
        for (key, value) in extraBody {
            if optional.contains(key) { extras[key] = value } else { fixed[key] = value }
        }
        var headers = extraHeaders
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        let body = fixed, sent = headers
        var content: String?, finish: String?
        let data = try await ParameterMemory.send(key: endpoint.absoluteString + "|" + model, extras: extras) { extras in
            content = nil
            finish = nil
            var json = body.merging(extras) { _, extra in extra }
            if json["stream"] == nil { json["stream"] = false }
            let whole = try await HTTP.stream(HTTP.request(endpoint, headers: sent, json: json)) { event in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(event.utf8))) as? [String: Any] else { return }
                if let error = object["error"] { throw Self.streamFailure(error) }
                guard let choice = (object["choices"] as? [[String: Any]])?.first else { return }
                if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String { content = (content ?? "") + piece }
                if let reason = choice["finish_reason"] as? String { finish = reason }
                // Thinking counts as a sign of life, not as part of the answer.
                StreamProgress.report(content?.count ?? 0)
            }
            return whole ?? Data()
        }
        if !data.isEmpty {
            // Answered in one piece.
            guard let object = try HTTP.json(data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any] else {
                throw ProviderError(kind: .invalidResponse, detail: "unexpected reply: " + String(decoding: data.prefix(300), as: UTF8.self))
            }
            finish = choices.first?["finish_reason"] as? String
            content = (message["content"] as? String) ?? (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
        if finish == "content_filter" || finish == "safety", (content ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            throw ProviderError(kind: .refused, detail: "finish_reason: \(finish ?? "")")
        }
        // Cut off at the output limit: what is there ends in the middle of a text.
        if finish == "length" { throw ProviderError(kind: .truncated, detail: "the reply was cut off at the model's output limit (finish_reason: length)") }
        if let content { return content }
        throw ProviderError(kind: .invalidResponse, detail: "empty reply")
    }

    /// An error a server sends in the middle of a stream (the status was already 200).
    static func streamFailure(_ error: Any) -> ProviderError {
        let text = ((error as? [String: Any])?["message"] as? String) ?? "\(error)"
        if ProviderError.isContentRefusal(text) { return ProviderError(kind: .refused, detail: "stream error: \(text)") }
        let busy = text.range(of: "overloaded|rate.?limit|too many requests|capacity|busy", options: [.regularExpression, .caseInsensitive]) != nil
        return ProviderError(kind: busy ? .http(429) : .invalidResponse, detail: (busy ? "Error code: 429 - " : "stream error: ") + text)
    }

    /// `{base}/chat/completions`; a bare host means its `/v1`, as other clients assume.
    static func chatURL(base: String) -> URL? {
        let normalized = OpenAIBaseURL.normalized(base)
        return URL(string: normalized.hasSuffix("/chat/completions") ? normalized : normalized + "/chat/completions")
    }
}

/// Anthropic's Messages API.
struct AnthropicProvider: ChatModel {
    var modelName: String? { model }
    var base: URL
    var apiKey: String
    var model: String
    var limits: ProviderLimits

    func prewarm() async { await HTTP.warm(base) }

    func complete(system: String, user: String) async throws -> String {
        // Room for the translation and for the thinking current models do before it (it counts against the limit);
        // the reply is read as it is written, so a long one does not run into a time limit.
        // No temperature: current models take only their default.
        let body: [String: Any] = [
            "model": model, "max_tokens": 32000, "system": system, "stream": true,
            "messages": [["role": "user", "content": user]],
        ]
        // Translating needs little deliberation: a low effort answers much sooner. Models from before the parameter
        // (and gateways that do not know it) turn it down, and go without.
        let extras: [String: Any] = ["output_config": ["effort": "low"]]
        let url = base.appending(path: "v1/messages"), key = apiKey
        var text = "", stop: String?
        let data = try await ParameterMemory.send(key: url.absoluteString + "|" + model, extras: extras) { extras in
            text = ""
            stop = nil
            let request = try HTTP.request(url, headers: ["x-api-key": key, "anthropic-version": "2023-06-01"], json: body.merging(extras) { _, extra in extra })
            let whole = try await HTTP.stream(request) { event in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(event.utf8))) as? [String: Any] else { return }
                switch object["type"] as? String {
                case "content_block_delta":
                    if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let piece = delta["text"] as? String { text += piece }
                    StreamProgress.report(text.count)
                case "message_delta":
                    if let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String { stop = reason }
                case "error":
                    throw OpenAIChatProvider.streamFailure(object["error"] ?? event)
                default:
                    break
                }
            }
            return whole ?? Data()
        }
        if !data.isEmpty {
            // Answered in one piece (a gateway that does not stream).
            guard let object = try HTTP.json(data) as? [String: Any], let content = object["content"] as? [[String: Any]] else {
                throw ProviderError(kind: .invalidResponse, detail: "unexpected reply: " + String(decoding: data.prefix(300), as: UTF8.self))
            }
            text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            stop = object["stop_reason"] as? String
        }
        switch stop {
        case "refusal":
            throw ProviderError(kind: .refused, detail: "stop_reason: refusal")
        case "max_tokens":
            throw ProviderError(kind: .truncated, detail: "the reply was cut off at the model's output limit (stop_reason: max_tokens)")
        default:
            return text
        }
    }
}

/// Google's Gemini API.
struct GeminiProvider: ChatModel {
    var modelName: String? { model }
    var apiKey: String
    var model: String
    var limits: ProviderLimits

    func prewarm() async { await HTTP.warm(URL(string: "https://generativelanguage.googleapis.com/")!) }

    /// How little a model is asked to think before translating, for the models that think by default: Gemini 2.5
    /// Flash takes a budget (0: none), Gemini 3 and later a level. Other models are told nothing.
    static func thinkingConfig(model: String) -> [String: Any]? {
        let name = model.lowercased()
        if name.contains("2.5-flash") { return ["thinkingBudget": 0] }
        if name.range(of: #"gemini-([3-9]|\d{2})"#, options: .regularExpression) != nil { return ["thinkingLevel": "low"] }
        return nil
    }

    func complete(system: String, user: String) async throws -> String {
        let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):streamGenerateContent?alt=sse") else {
            throw ProviderError(kind: .invalidResponse, detail: "invalid model \(model)")
        }
        let extras: [String: Any] = Self.thinkingConfig(model: name).map { ["thinkingConfig": $0] } ?? [:]
        let key = apiKey
        var text = "", finish: String?, blocked: String?, answered = false
        /// One answer, or one piece of an answer as it is written.
        func take(_ object: [String: Any]) {
            if let reason = (object["promptFeedback"] as? [String: Any])?["blockReason"] as? String { blocked = reason }
            guard let candidate = (object["candidates"] as? [[String: Any]])?.first else { return }
            answered = true
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            text += parts.compactMap { $0["thought"] as? Bool == true ? nil : $0["text"] as? String }.joined()
            if let reason = candidate["finishReason"] as? String { finish = reason }
        }
        let data = try await ParameterMemory.send(key: url.absoluteString, extras: extras) { extras in
            text = ""
            finish = nil
            blocked = nil
            answered = false
            let generation: [String: Any] = ["responseMimeType": "application/json", "temperature": 0.2]
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
                "generationConfig": generation.merging(extras) { _, extra in extra },
            ]
            let whole = try await HTTP.stream(HTTP.request(url, headers: ["x-goog-api-key": key], json: body)) { event in
                guard let object = (try? JSONSerialization.jsonObject(with: Data(event.utf8))) as? [String: Any] else { return }
                if let error = object["error"] { throw OpenAIChatProvider.streamFailure(error) }
                take(object)
                StreamProgress.report(text.count)
            }
            return whole ?? Data()
        }
        if !data.isEmpty {
            // Answered in one piece: one object, or a list of the pieces.
            let json = try HTTP.json(data)
            for object in (json as? [[String: Any]]) ?? [(json as? [String: Any]) ?? [:]] { take(object) }
        }
        // Stopped by the content review: before the model saw the text, or while it answered.
        if let blocked { throw ProviderError(kind: .refused, detail: "blockReason: \(blocked)") }
        switch finish {
        case "SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION":
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ProviderError(kind: .refused, detail: "finishReason: \(finish ?? "")")
            }
        case "MAX_TOKENS":
            throw ProviderError(kind: .truncated, detail: "the reply was cut off at the model's output limit (finishReason: MAX_TOKENS)")
        default:
            break
        }
        guard answered, !text.isEmpty else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply: " + String(decoding: data.prefix(300), as: UTF8.self))
        }
        return text
    }
}

/// Azure OpenAI: a deployment URL with an API version, and an `api-key` header.
struct AzureOpenAIProvider: ChatModel {
    var modelName: String? { deployment }
    var resource: String
    var apiKey: String
    var deployment: String
    var apiVersion: String
    var limits: ProviderLimits

    func prewarm() async { if let url = URL(string: resource) { await HTTP.warm(url) } }

    func complete(system: String, user: String) async throws -> String {
        let base = resource.hasSuffix("/") ? String(resource.dropLast()) : resource
        guard let url = URL(string: "\(base)/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)") else {
            throw ProviderError(kind: .invalidResponse, detail: "invalid Azure endpoint \(resource)")
        }
        // A deployment may be a reasoning model, which takes no temperature: sent, and left out when turned down.
        let chat = OpenAIChatProvider(endpoint: url, apiKey: nil, model: deployment, temperature: 0.2, optional: ["temperature"],
                                      extraHeaders: ["api-key": apiKey], limits: limits)
        return try await chat.complete(system: system, user: user)
    }
}
