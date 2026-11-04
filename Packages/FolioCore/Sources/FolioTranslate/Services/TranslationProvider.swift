import Foundation

/// A term and its fixed translation.
public struct GlossaryEntry: Sendable, Hashable, Codable {
    public var source: String
    public var target: String

    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

/// What every request knows about the paper being translated.
struct TranslationContext: Sendable {
    var sourceLanguage: String
    var targetLanguage: String
    var title: String?
    var summary: String?
    var glossary: [GlossaryEntry]
}

/// One text to translate and what kind of text it is.
struct TranslationItem: Sendable, Hashable {
    var text: String
    var kind: BlockKind

    var isShort: Bool { kind == .heading || kind == .tableCell || kind == .title }
}

/// How a provider likes its work: how much text per request and how many requests at once.
struct ProviderLimits: Sendable {
    var batchCharacters: Int
    var batchItems: Int
    var concurrency: Int
    /// Sends the paper's title, abstract and glossary with each batch (large language models).
    var usesContext: Bool
    /// What a request usually takes, until this job has measured it: to keep progress moving while requests run.
    var startupSeconds: Double = 1.5
    var secondsPerCharacter: Double = 0.01
}

/// A translation backend.
protocol TranslationProvider: Sendable {
    var limits: ProviderLimits { get }
    /// Translations of `items`, in order.
    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> [String]
    /// Terms of the field with their translations, from an excerpt of the paper (large language models only).
    func extractTerms(from excerpt: String, context: TranslationContext) async throws -> [GlossaryEntry]
}

extension TranslationProvider {
    func extractTerms(from excerpt: String, context: TranslationContext) async throws -> [GlossaryEntry] { [] }
}

/// Why a request failed. `description` is what the error classifier reads.
struct ProviderError: Error, LocalizedError, Sendable {
    /// `agentSetup`: the agent cannot work until the user does something (signs in, chooses a model, updates it).
    /// `refused`: the service's content review would not translate this text.
    enum Kind: Sendable, Equatable { case http(Int), network, invalidResponse, cancelled, process, agentSetup, refused }
    var kind: Kind
    var detail: String
    var host: String?

    var errorDescription: String? { detail }

    /// Worth trying again: rate limits, server errors, dropped connections, unreadable replies.
    var isRetryable: Bool {
        switch kind {
        case .http(let status): status == 429 || status == 408 || status >= 500
        case .network, .invalidResponse, .process: true
        case .cancelled, .agentSetup, .refused: false
        }
    }

    /// What services say when their content review stops a text (not a problem with the request or the account).
    static func isContentRefusal(_ text: String) -> Bool {
        text.range(of: #"content[_ \-]?(filter|policy|management|moderation|risk|safety)|data_inspection_failed|inappropriate[_ ]content|sensitive[_ ]words?|content exists risk|responsible ?ai|policy violation|violat(es|ion)[^\n]{0,40}(policy|guidelines|usage)|prohibited content|blocked (by|due to)[^\n]{0,30}(safety|policy|moderation)|finish_reason"?\s*[:=]\s*"?(content_filter|safety)|内容(审核|安全|风险)|敏感(词|内容|信息)|不合规|违规"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// A model declining in words instead of translating.
    static func isDecline(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(I('m| am) sorry|I can(no|')t (help|assist|translate|comply|provide)|I won'?t|Sorry, (but )?I can|抱歉|对不起，?我无法|我无法(协助|翻译|提供))"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// Seconds the server asked to wait (`Retry-After`).
    var retryAfter: Double?
}

// MARK: - Languages

enum LanguageNames {
    /// English name of a language code, for prompts.
    static func english(_ code: String) -> String {
        switch code.lowercased() {
        case "zh", "zh-cn", "zh-hans": "Simplified Chinese"
        case "zh-tw", "zh-hant", "zh-hk": "Traditional Chinese"
        case "en": "English"
        case "ja": "Japanese"
        case "ko": "Korean"
        case "fr": "French"
        case "de": "German"
        case "es": "Spanish"
        case "it": "Italian"
        case "pt": "Portuguese"
        case "ru": "Russian"
        case "ar": "Arabic"
        default: Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }
}

// MARK: - Large language model batches

/// The batch protocol shared by every large language model and agent: a JSON object of numbered texts in, the
/// same keys with translations out.
enum LLMBatch {
    static func systemPrompt(_ context: TranslationContext) -> String {
        let source = LanguageNames.english(context.sourceLanguage), target = LanguageNames.english(context.targetLanguage)
        var prompt = """
        You are an expert translator of academic papers. Translate each value of the JSON object the user sends from \(source) into \(target).

        Rules:
        - Reply with only a JSON object that has exactly the same keys, each mapped to its translation. No explanations, no code fences.
        - Placeholders like {v1}, {v2} stand for formulas. Keep every one of them exactly as written and put it where it belongs in the translated sentence.
        - {v0} is not a formula: it marks where the text breaks across a column or a page. Keep it once, at the corresponding point of your translation.
        - The values are consecutive passages of the paper, in reading order.
        - Keep citations ([12], [3, 7], Smith et al. (2020)), URLs, code, numbers and units unchanged.
        - Keep names of models, methods, datasets, metrics, software and abbreviations (e.g. ResNet-50, CLIP, mIoU, ImageNet, GAN) in their original form.
        - Use the established terminology of the field and translate terms consistently; follow the glossary.
        - Headings, table cells and other short items: translate concisely, without adding final punctuation.
        - Write fluent, natural \(target) academic prose. Do not add, omit or explain anything.
        - Each value is one piece of text; keep it one piece (no line breaks).
        """
        if let title = context.title, !title.isEmpty { prompt += "\n\nPaper title: \(title)" }
        if let summary = context.summary, !summary.isEmpty { prompt += "\nAbstract: \(summary.prefix(1500))" }
        if !context.glossary.isEmpty {
            prompt += "\n\nGlossary (\(source) → \(target)):\n" + context.glossary.map { "- \($0.source) → \($0.target)" }.joined(separator: "\n")
        }
        return prompt
    }

    /// The user message: `{"1": "…", "2": "…"}` in reading order (sorted keys would read "1, 10, 11, …, 2"), with a note
    /// on which items are short.
    static func userMessage(_ items: [TranslationItem]) -> String {
        func json(_ string: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        var message = "{" + items.enumerated().map { "\(json(String($0.offset + 1))): \(json($0.element.text))" }.joined(separator: ", ") + "}"
        let short = items.enumerated().filter { $0.element.isShort }.map { String($0.offset + 1) }
        if !short.isEmpty { message += "\n\nShort items (headings or table cells): " + short.joined(separator: ", ") }
        return message
    }

    /// Reads the reply. Missing keys come back as nil.
    static func parse(_ reply: String, count: Int) -> [String?] {
        guard let object = jsonObject(in: reply) ?? lenientObject(in: reply) else { return Array(repeating: nil, count: count) }
        return (1...max(count, 1)).prefix(count).map { key in
            if let value = object[String(key)] as? String { return value }
            if let value = object[String(key)] { return "\(value)" }
            return nil
        }
    }

    /// The first JSON object in `text` (models sometimes wrap it in code fences or add a sentence).
    static func jsonObject(in text: String) -> [String: Any]? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let whole = (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) as? [String: Any] { return whole }
        if let fence = candidate.range(of: "```") {
            candidate = String(candidate[fence.upperBound...])
            if let newline = candidate.firstIndex(of: "\n") { candidate = String(candidate[candidate.index(after: newline)...]) }
            if let end = candidate.range(of: "```") { candidate = String(candidate[..<end.lowerBound]) }
        }
        // Reasoning models may print their thinking first.
        if let think = candidate.range(of: "</think>") { candidate = String(candidate[think.upperBound...]) }
        guard let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"), start < end else { return nil }
        let json = String(candidate[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    /// `{"1": "…", "2": "…"}` whose values break JSON (a model writing "quotes" inside a translation): each value
    /// runs from its key to the last quote before the next key.
    static func lenientObject(in text: String) -> [String: Any]? {
        let pattern = try! NSRegularExpression(pattern: #""(\d+)"\s*:\s*""#)
        let ns = text as NSString
        let keys = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !keys.isEmpty else { return nil }
        var object: [String: Any] = [:]
        for (i, match) in keys.enumerated() {
            let start = match.range.location + match.range.length
            let limit = i + 1 < keys.count ? keys[i + 1].range.location : ns.length
            let chunk = ns.substring(with: NSRange(location: start, length: limit - start))
            guard let close = chunk.range(of: "\"", options: .backwards) else { continue }
            var value = String(chunk[..<close.lowerBound])
            value = value.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
            object[ns.substring(with: match.range(at: 1))] = value
        }
        return object.isEmpty ? nil : object
    }

    static func termsPrompt(_ context: TranslationContext) -> String {
        let target = LanguageNames.english(context.targetLanguage)
        return """
        You build glossaries for translating academic papers into \(target). From the excerpt the user sends, pick the technical terms whose translation must stay consistent (concepts, task names, phrases of the field), at most 40, and give the established \(target) translation of each.
        Leave out names of models, methods, datasets, metrics and software, and abbreviations, which stay untranslated.
        Reply with only JSON: {"terms": [{"source": "...", "target": "..."}]}
        """
    }

    static func parseTerms(_ reply: String) -> [GlossaryEntry] {
        guard let object = jsonObject(in: reply), let terms = object["terms"] as? [[String: Any]] else { return [] }
        return terms.compactMap { term in
            guard let source = term["source"] as? String, let target = term["target"] as? String,
                  !source.isEmpty, !target.isEmpty, source.count < 80 else { return nil }
            return GlossaryEntry(source: source, target: target)
        }
    }
}

// MARK: - HTTP

enum HTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: configuration)
    }()

    /// Sends `request`; non-2xx answers and transport failures become `ProviderError`s.
    static func send(_ request: URLRequest) async throws -> Data {
        // With its port: on one machine that is what tells services apart.
        let host: String? = request.url.flatMap { url -> String? in
            guard let name = url.host() else { return nil }
            return url.port.map { "\(name):\($0)" } ?? name
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError(kind: .invalidResponse, detail: "no HTTP response", host: host)
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(decoding: data.prefix(2000), as: UTF8.self)
                let refused = [400, 403, 422, 451].contains(http.statusCode) && ProviderError.isContentRefusal(body)
                var error = ProviderError(kind: refused ? .refused : .http(http.statusCode), detail: "Error code: \(http.statusCode) - \(body)", host: host)
                if let retry = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(retry) { error.retryAfter = seconds }
                throw error
            }
            return data
        } catch let error as ProviderError {
            throw error
        } catch is CancellationError {
            throw ProviderError(kind: .cancelled, detail: "cancelled", host: host)
        } catch let error as URLError {
            if error.code == .cancelled { throw ProviderError(kind: .cancelled, detail: "cancelled", host: host) }
            throw ProviderError(kind: .network, detail: networkDetail(error), host: host)
        }
    }

    /// URLError in the words the classifier knows.
    static func networkDetail(_ error: URLError) -> String {
        let host = error.failingURL?.host() ?? ""
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: return "nodename nor servname provided, or not known: \(host)"
        case .cannotConnectToHost: return "Connection refused: \(host)"
        case .timedOut: return "Connection timed out: \(host)"
        case .networkConnectionLost: return "Connection reset: server disconnected: \(host)"
        case .notConnectedToInternet: return "Network is unreachable"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "SSLError: \(host)"
        default: return "Connection error: \(error.localizedDescription) \(host)"
        }
    }

    static func json(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) } catch {
            throw ProviderError(kind: .invalidResponse, detail: "unreadable reply: " + String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    static func request(_ url: URL, method: String = "POST", headers: [String: String] = [:], json body: Any? = nil,
                        timeout: TimeInterval = 180) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}

// MARK: - Placeholders

enum Placeholders {
    /// `{v1}` as written, or as a translator mangled it (`{ v1 }`, `｛v1｝`, `{V1}`).
    static let pattern = try! NSRegularExpression(pattern: #"[{｛]\s*[vV]\s*(\d+)\s*[}｝]"#)

    /// Rewrites each placeholder with `transform(n)`.
    static func replace(in text: String, _ transform: (Int) -> String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(Int(ns.substring(with: match.range(at: 1))) ?? 0)
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }

    static func numbers(in text: String) -> [Int] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) }
    }
}
