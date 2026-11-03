import CryptoKit
import Foundation

/// Translates items one at a time with a function, several at once.
protocol SingleTextProvider: TranslationProvider {
    func translateOne(_ text: String, context: TranslationContext) async throws -> String
}

extension SingleTextProvider {
    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> [String] {
        var results: [String] = []
        for item in items {
            // Services cap the length of one text: long paragraphs go sentence by sentence.
            var parts: [String] = []
            for chunk in Self.chunks(item.text, limit: limits.batchCharacters) { parts.append(try await translateOne(chunk, context: context)) }
            let cjk = ["zh", "ja", "ko"].contains { context.targetLanguage.lowercased().hasPrefix($0) }
            results.append(parts.joined(separator: cjk ? "" : " "))
        }
        return results
    }

    /// `text` in pieces of at most `limit` characters, cut after sentences (or, failing that, words).
    static func chunks(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence { sentences.append(sentence) }
        }
        var result: [String] = []
        var current = ""
        func flush() {
            if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
            current = ""
        }
        for sentence in sentences {
            if current.count + sentence.count > limit { flush() }
            if sentence.count > limit {
                for word in sentence.split(separator: " ") {
                    if current.count + word.count + 1 > limit { flush() }
                    current += (current.isEmpty ? "" : " ") + word
                }
            } else {
                current += sentence
            }
        }
        flush()
        return result
    }
}

enum LanguageCodes {
    static func google(_ code: String) -> String {
        switch code.lowercased() {
        case "zh", "zh-cn", "zh-hans": "zh-CN"
        case "zh-tw", "zh-hant", "zh-hk": "zh-TW"
        default: code
        }
    }

    static func microsoft(_ code: String) -> String {
        switch code.lowercased() {
        case "zh", "zh-cn", "zh-hans": "zh-Hans"
        case "zh-tw", "zh-hant", "zh-hk": "zh-Hant"
        default: code
        }
    }

    static func deepL(_ code: String, target: Bool) -> String {
        switch code.lowercased() {
        case "zh", "zh-cn", "zh-hans": target ? "ZH-HANS" : "ZH"
        case "zh-tw", "zh-hant", "zh-hk": target ? "ZH-HANT" : "ZH"
        case "en": target ? "EN-US" : "EN"
        case "pt": target ? "PT-PT" : "PT"
        default: code.uppercased()
        }
    }

    static func tencent(_ code: String) -> String {
        switch code.lowercased() {
        case "zh", "zh-cn", "zh-hans": "zh"
        case "zh-tw", "zh-hant", "zh-hk": "zh-TW"
        default: code
        }
    }

    static func qwen(_ code: String) -> String {
        switch code.lowercased() {
        case "zh", "zh-cn", "zh-hans": "Chinese"
        case "zh-tw", "zh-hant", "zh-hk": "Traditional Chinese"
        default: LanguageNames.english(code)
        }
    }
}

/// Google Translate's public web endpoint (the one browser extensions use), one text per request.
struct GoogleWebProvider: SingleTextProvider {
    var limits = ProviderLimits(batchCharacters: 4500, batchItems: 1, concurrency: 6, usesContext: false)

    func translateOne(_ text: String, context: TranslationContext) async throws -> String {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            .init(name: "client", value: "gtx"), .init(name: "sl", value: LanguageCodes.google(context.sourceLanguage)),
            .init(name: "tl", value: LanguageCodes.google(context.targetLanguage)), .init(name: "dt", value: "t"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        request.httpBody = Data(("q=" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)).utf8)
        let data = try await HTTP.send(request)
        guard let array = try HTTP.json(data) as? [Any], let sentences = array.first as? [Any] else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply from Google")
        }
        return sentences.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }
}

/// Bing Translator's web endpoint (no key): a token from the translator page, then one text per request.
struct BingWebProvider: SingleTextProvider {
    var limits = ProviderLimits(batchCharacters: 950, batchItems: 1, concurrency: 4, usesContext: false)
    private static let session = SessionCache()

    struct Session: Sendable {
        var ig: String, iid: String, key: String, token: String, host: String
    }

    actor SessionCache {
        var session: Session?
        var expiry = Date.distantPast
        func current() -> Session? { Date() < expiry ? session : nil }
        func store(_ value: Session) {
            session = value
            expiry = Date().addingTimeInterval(20 * 60)
        }
        func clear() { session = nil }
    }

    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func fetchSession() async throws -> Session {
        var request = URLRequest(url: URL(string: "https://www.bing.com/translator")!, timeoutInterval: 20)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let data = try await HTTP.send(request)
        let page = String(decoding: data, as: UTF8.self)
        func first(_ pattern: String) -> String? {
            page.firstMatch(of: try! Regex(pattern)).flatMap { $0.output.count > 1 ? $0.output[1].substring.map(String.init) : nil }
        }
        guard let ig = first(#"IG:"([^"]+)""#),
              let helper = page.firstMatch(of: /params_AbusePreventionHelper\s*=\s*\[\s*(\d+)\s*,\s*"([^"]+)"/) else {
            throw ProviderError(kind: .invalidResponse, detail: "Bing translator page changed", host: "www.bing.com")
        }
        let iid = first(#"data-iid="(translator\.\d+)""#) ?? "translator.5028"
        return Session(ig: ig, iid: iid, key: String(helper.output.1), token: String(helper.output.2), host: "www.bing.com")
    }

    func translateOne(_ text: String, context: TranslationContext) async throws -> String {
        let session: Session
        if let cached = await Self.session.current() { session = cached } else {
            session = try await Self.fetchSession()
            await Self.session.store(session)
        }
        var components = URLComponents(string: "https://\(session.host)/ttranslatev3")!
        components.queryItems = [.init(name: "isVertical", value: "1"), .init(name: "IG", value: session.ig), .init(name: "IID", value: session.iid)]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
        let form = ["fromLang": LanguageCodes.microsoft(context.sourceLanguage), "to": LanguageCodes.microsoft(context.targetLanguage),
                    "text": text, "token": session.token, "key": session.key, "tryFetchingGenderDebiasedTranslations": "true"]
        request.httpBody = Data(form.map { "\($0.key)=\(encode($0.value))" }.joined(separator: "&").utf8)
        let data = try await HTTP.send(request)
        guard let array = try? HTTP.json(data) as? [[String: Any]], let translations = array.first?["translations"] as? [[String: Any]],
              let result = translations.first?["text"] as? String else {
            // An expired token answers with an error object: fetch a new one next time.
            await Self.session.clear()
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply from Bing: " + String(decoding: data.prefix(200), as: UTF8.self))
        }
        return result
    }
}

/// The Microsoft Translator v3 API: Edge's free endpoint (token from edge.microsoft.com) or an Azure resource.
/// Placeholders travel as `<span class="notranslate">`, which the API leaves alone.
struct MicrosoftTranslatorProvider: TranslationProvider {
    enum Access: Sendable {
        case edge
        case azure(key: String, region: String?, endpoint: String)
    }

    var access: Access
    var limits = ProviderLimits(batchCharacters: 9000, batchItems: 50, concurrency: 4, usesContext: false)
    private static let tokenCache = TokenCache()

    actor TokenCache {
        var token: String?
        var expiry = Date.distantPast
        func current() -> String? { Date() < expiry ? token : nil }
        func store(_ value: String) {
            token = value
            expiry = Date().addingTimeInterval(8 * 60)
        }
    }

    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> [String] {
        var base: String
        var headers: [String: String] = [:]
        switch access {
        case .edge:
            base = "https://api-edge.cognitive.microsofttranslator.com"
            let token: String
            if let cached = await Self.tokenCache.current() {
                token = cached
            } else {
                let data = try await HTTP.send(HTTP.request(URL(string: "https://edge.microsoft.com/translate/auth")!, method: "GET", timeout: 20))
                token = String(decoding: data, as: UTF8.self)
                await Self.tokenCache.store(token)
            }
            headers["Authorization"] = "Bearer \(token)"
        case .azure(let key, let region, let endpoint):
            base = endpoint.isEmpty ? "https://api.cognitive.microsofttranslator.com" : endpoint
            headers["Ocp-Apim-Subscription-Key"] = key
            if let region, !region.isEmpty { headers["Ocp-Apim-Subscription-Region"] = region }
        }
        if base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + "/translate")!
        components.queryItems = [
            .init(name: "api-version", value: "3.0"), .init(name: "from", value: LanguageCodes.microsoft(context.sourceLanguage)),
            .init(name: "to", value: LanguageCodes.microsoft(context.targetLanguage)), .init(name: "textType", value: "html"),
        ]
        let body = items.map { ["Text": Self.html($0.text)] }
        let data = try await HTTP.send(HTTP.request(components.url!, headers: headers, json: body, timeout: 60))
        guard let array = try HTTP.json(data) as? [[String: Any]], array.count == items.count else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply from Microsoft Translator")
        }
        return try array.map { entry in
            guard let translations = entry["translations"] as? [[String: Any]], let text = translations.first?["text"] as? String else {
                throw ProviderError(kind: .invalidResponse, detail: "missing translation")
            }
            return Self.plain(text)
        }
    }

    static func html(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return Placeholders.replace(in: escaped) { "<span class=\"notranslate\">{v\($0)}</span>" }
    }

    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<span class="notranslate">\s*([^<]*?)\s*</span>"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// DeepL API (Free keys end in ":fx"). Placeholders travel as XML tags DeepL keeps.
struct DeepLProvider: TranslationProvider {
    var key: String
    var limits = ProviderLimits(batchCharacters: 25000, batchItems: 50, concurrency: 3, usesContext: false)

    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> [String] {
        let host = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        var body: [String: Any] = [
            "text": items.map { Placeholders.replace(in: Self.escape($0.text)) { "<x id=\"\($0)\"/>" } },
            "target_lang": LanguageCodes.deepL(context.targetLanguage, target: true),
            "source_lang": LanguageCodes.deepL(context.sourceLanguage, target: false),
            "tag_handling": "xml", "ignore_tags": ["x"],
        ]
        if let title = context.title { body["context"] = title }
        let data = try await HTTP.send(HTTP.request(URL(string: host + "/v2/translate")!, headers: ["Authorization": "DeepL-Auth-Key \(key)"],
                                                     json: body, timeout: 90))
        guard let object = try HTTP.json(data) as? [String: Any], let translations = object["translations"] as? [[String: Any]],
              translations.count == items.count else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply from DeepL")
        }
        return translations.map { entry in
            let text = entry["text"] as? String ?? ""
            let restored = text.replacingOccurrences(of: #"<x id="(\d+)"\s*/>"#, with: "{v$1}", options: .regularExpression)
            return restored.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Tencent Cloud Machine Translation (TextTranslateBatch), signed with TC3-HMAC-SHA256.
struct TencentProvider: TranslationProvider {
    var secretID: String
    var secretKey: String
    var region: String
    var limits = ProviderLimits(batchCharacters: 5000, batchItems: 20, concurrency: 3, usesContext: false)

    func translate(_ items: [TranslationItem], context: TranslationContext) async throws -> [String] {
        let host = "tmt.tencentcloudapi.com"
        let body: [String: Any] = [
            "Source": LanguageCodes.tencent(context.sourceLanguage), "Target": LanguageCodes.tencent(context.targetLanguage),
            "ProjectId": 0, "SourceTextList": items.map(\.text),
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let timestamp = Int(Date().timeIntervalSince1970)
        let date = { () -> String in
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
        }()
        func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func hmac(_ key: Data, _ message: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))) }
        let canonical = "POST\n/\n\ncontent-type:application/json; charset=utf-8\nhost:\(host)\nx-tc-action:texttranslatebatch\n\ncontent-type;host;x-tc-action\n" + sha256(payload)
        let scope = "\(date)/tmt/tc3_request"
        let toSign = "TC3-HMAC-SHA256\n\(timestamp)\n\(scope)\n" + sha256(Data(canonical.utf8))
        let signingKey = hmac(hmac(hmac(Data("TC3\(secretKey)".utf8), date), "tmt"), "tc3_request")
        let signature = hmac(signingKey, toSign).map { String(format: "%02x", $0) }.joined()
        let authorization = "TC3-HMAC-SHA256 Credential=\(secretID)/\(scope), SignedHeaders=content-type;host;x-tc-action, Signature=\(signature)"
        var request = URLRequest(url: URL(string: "https://\(host)")!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = payload
        for (key, value) in ["Content-Type": "application/json; charset=utf-8", "Host": host, "X-TC-Action": "TextTranslateBatch",
                             "X-TC-Version": "2018-03-21", "X-TC-Timestamp": String(timestamp), "X-TC-Region": region,
                             "Authorization": authorization] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data = try await HTTP.send(request)
        guard let object = try HTTP.json(data) as? [String: Any], let response = object["Response"] as? [String: Any] else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply from Tencent Cloud")
        }
        if let error = response["Error"] as? [String: Any] {
            let code = error["Code"] as? String ?? ""
            let status = code.contains("AuthFailure") ? 401 : code.contains("LimitExceeded") || code.contains("RequestLimit") ? 429 : 400
            throw ProviderError(kind: .http(status), detail: "Error code: \(status) - \(code): \(error["Message"] as? String ?? "")", host: host)
        }
        guard let list = response["TargetTextList"] as? [String], list.count == items.count else {
            throw ProviderError(kind: .invalidResponse, detail: "missing translations from Tencent Cloud")
        }
        return list
    }
}

/// Qwen-MT: a translation model behind DashScope's OpenAI-compatible API, with its translation options.
struct QwenMTProvider: SingleTextProvider {
    var endpoint: URL
    var apiKey: String
    var model: String
    var domains: String?
    var limits = ProviderLimits(batchCharacters: 3000, batchItems: 1, concurrency: 6, usesContext: false)

    func translateOne(_ text: String, context: TranslationContext) async throws -> String {
        var options: [String: Any] = ["source_lang": LanguageCodes.qwen(context.sourceLanguage), "target_lang": LanguageCodes.qwen(context.targetLanguage)]
        let glossary = context.glossary.filter { text.localizedCaseInsensitiveContains($0.source) }
        if !glossary.isEmpty { options["terms"] = glossary.map { ["source": $0.source, "target": $0.target] } }
        options["domains"] = domains?.isEmpty == false ? domains! : "The text is from an academic paper. Use formal academic language and the established terminology of the field. Keep placeholders like {v1} unchanged."
        let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": text]], "translation_options": options]
        let data = try await HTTP.send(HTTP.request(endpoint, headers: ["Authorization": "Bearer \(apiKey)"], json: body))
        guard let object = try HTTP.json(data) as? [String: Any], let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any], let content = message["content"] as? String else {
            throw ProviderError(kind: .invalidResponse, detail: "unexpected reply from Qwen-MT")
        }
        return content
    }
}

/// Apple's on-device Translation framework, in process.
struct AppleProvider: SingleTextProvider {
    var limits = ProviderLimits(batchCharacters: 3000, batchItems: 1, concurrency: 4, usesContext: false)

    func translateOne(_ text: String, context: TranslationContext) async throws -> String {
        do {
            return try await AppleSystemTranslator.translate(text, from: context.sourceLanguage, to: context.targetLanguage)
        } catch let failure as AppleSystemTranslator.Failure {
            // A missing language does not come back on retry.
            if case .notInstalled = failure { throw ProviderError(kind: .http(400), detail: failure.marker) }
            if case .unsupported = failure { throw ProviderError(kind: .http(400), detail: failure.marker) }
            throw ProviderError(kind: .process, detail: failure.marker)
        }
    }
}

/// A user command: the text on stdin, the translation on stdout.
struct CommandProvider: SingleTextProvider {
    var command: String
    var timeout: TimeInterval
    var limits = ProviderLimits(batchCharacters: 3000, batchItems: 1, concurrency: 4, usesContext: false)

    func translateOne(_ text: String, context: TranslationContext) async throws -> String {
        let output = try await LocalProcess.run(["/bin/sh", "-c", command], input: text, timeout: timeout)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
