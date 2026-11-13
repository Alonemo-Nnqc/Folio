import Foundation

/// 划词翻译: one passage selected in the reader, translated by any service of the catalog.
public enum SelectionTranslator {
    /// The longest passage sent in one request; a longer selection is cut there.
    public static let maximumLength = 6000

    public enum Failure: Error, LocalizedError, Sendable {
        case empty
        case message(String)

        public var errorDescription: String? {
            switch self {
            case .empty: String(localized: "服务没有返回译文", bundle: .module)
            case .message(let text): text
            }
        }
    }

    /// The selection as one passage: hyphenated line breaks joined, lines of a paragraph run together, paragraphs kept.
    public static func normalized(_ text: String) -> String {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { paragraph -> String in
                var joined = ""
                for line in paragraph.split(separator: "\n", omittingEmptySubsequences: true) {
                    let part = line.trimmingCharacters(in: .whitespaces)
                    guard !part.isEmpty else { continue }
                    if joined.hasSuffix("-"), let first = part.first, first.isLowercase {
                        joined.removeLast()
                        joined += part
                    } else if joined.isEmpty {
                        joined = part
                    } else {
                        // CJK text runs on without a space.
                        let cjk = joined.last.map(isCJK) == true || part.first.map(isCJK) == true
                        joined += cjk ? part : " " + part
                    }
                }
                return joined.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
        return String(paragraphs.joined(separator: "\n\n").prefix(maximumLength))
    }

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }

    /// A translation and who made it.
    public struct Result: Sendable, Equatable {
        public var text: String
        public var serviceID: String
        /// The service asked first, when it was rate-limited and another free one stepped in.
        public var fellBackFrom: String?
    }

    /// Free services that stand in for one another when one is rate-limited, in order.
    static var standIns: [String] {
        ["google", "bing"] + (AppleSystemTranslator.isSupportedOnThisSystem ? [TranslationServiceCatalog.appleServiceID] : [])
    }

    /// Services rate-limited lately: skipped (when a stand-in may be used) until the time given.
    nonisolated(unsafe) private static var coolingUntil: [String: Date] = [:]
    private static let lock = NSLock()

    private static func isCooling(_ id: String) -> Bool { lock.withLock { (coolingUntil[id] ?? .distantPast) > Date() } }
    private static func cool(_ id: String, seconds: Double) { lock.withLock { coolingUntil[id] = Date().addingTimeInterval(seconds) } }

    /// Worth another try, or a stand-in: rate limits, overloaded or unreachable servers, refusals of the free web endpoints.
    private static func isTransient(_ error: ProviderError) -> Bool {
        switch error.kind {
        case .http(let status): return status == 429 || status == 403 || status == 408 || status >= 500
        case .network, .invalidResponse: return true
        default: return false
        }
    }

    // MARK: Getting ready (SEL-20)

    /// When each service was last got ready: a mouse-down every second need not start a task every time.
    nonisolated(unsafe) private static var preparedAt: [String: Date] = [:]

    /// Gets `serviceID` ready for a translation without sending any text: its connection opened (DNS, TCP, TLS) and any
    /// token fetched, so the request made when the mouse comes up starts on a warm connection. With `fallback`, the first
    /// free service standing in for it too. Returns at once; cheap enough for every mouse-down (each host is warmed at
    /// most every 30 seconds, tokens are kept until shortly before they run out).
    public static func prewarm(serviceID: String, fields: [String: String] = [:], secrets: [String: String] = [:], fallback: Bool = false) {
        var ids = [TranslationServiceCatalog.resolve(serviceID).id]
        if fallback, let standIn = standIns.first(where: { $0 != ids[0] }) { ids.append(standIn) }
        for id in ids {
            let due = lock.withLock {
                guard Date().timeIntervalSince(preparedAt[id] ?? .distantPast) > 5 else { return false }
                preparedAt[id] = Date()
                return true
            }
            guard due, let provider = try? ProviderFactory.make(serviceID: id, fields: id == serviceID ? fields : [:],
                                                                secrets: id == serviceID ? secrets : [:], concurrency: nil) else { continue }
            Task.detached(priority: .utility) { await provider.prewarm() }
        }
    }

    /// Waits for `prewarm` to finish (measurements and tests).
    public static func prewarmed(serviceID: String, fields: [String: String] = [:], secrets: [String: String] = [:]) async {
        guard let provider = try? ProviderFactory.make(serviceID: serviceID, fields: fields, secrets: secrets, concurrency: nil) else { return }
        await provider.prewarm()
    }

    // MARK: Translations made lately

    /// Every passage translated lately, shared by every reader of the app: the same passage again (in another document,
    /// in a popover closed and opened again) comes back at once.
    static let cache = LRUCache<String, Result>(capacity: 500)

    static func cacheKey(_ passage: String, serviceID: String, fields: [String: String], from source: String, to target: String) -> String {
        let options = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1}")
        return [serviceID, source.lowercased(), target.lowercased(), options, passage].joined(separator: "\u{2}")
    }

    /// The translation of `text` made lately by `serviceID`, if there is one: no request, no waiting.
    public static func cached(_ text: String, serviceID: String, fields: [String: String], from source: String, to target: String) -> Result? {
        let passage = normalized(text)
        guard !passage.isEmpty else { return nil }
        return cache[cacheKey(passage, serviceID: TranslationServiceCatalog.resolve(serviceID).id, fields: fields, from: source, to: target)]
    }

    /// The translation of `text`, from the translations made lately when it is one of them (unless `useCache` is false:
    /// translating again). A rate-limited request is tried again shortly; still refused, and with `fallback`, another free
    /// service translates it (and the limited one rests for a minute). Errors come back in plain words.
    public static func translate(_ text: String, serviceID: String, fields: [String: String], secrets: [String: String],
                                 from source: String, to target: String, fallback: Bool = true, useCache: Bool = true,
                                 standInFields: @Sendable (String) -> [String: String] = { _ in [:] }) async throws -> Result {
        let passage = normalized(text)
        guard !passage.isEmpty else { throw Failure.empty }
        if useCache, let hit = cache[cacheKey(passage, serviceID: serviceID, fields: fields, from: source, to: target)] { return hit }
        let result = try await translateNow(passage, serviceID: serviceID, fields: fields, secrets: secrets, from: source, to: target,
                                            fallback: fallback, standInFields: standInFields)
        // Under the service that made it: a stand-in's translation does not stand for the service asked first.
        let usedFields = result.serviceID == serviceID ? fields : standInFields(result.serviceID)
        cache[cacheKey(passage, serviceID: result.serviceID, fields: usedFields, from: source, to: target)] = Result(text: result.text, serviceID: result.serviceID)
        return result
    }

    private static func translateNow(_ passage: String, serviceID: String, fields: [String: String], secrets: [String: String],
                                     from source: String, to target: String, fallback: Bool,
                                     standInFields: @Sendable (String) -> [String: String]) async throws -> Result {
        var order = [serviceID]
        if fallback { order += standIns.filter { $0 != serviceID } }
        // A service that was just rate-limited is not asked again right away while a stand-in can answer.
        if fallback, isCooling(serviceID), order.count > 1 { order.append(order.removeFirst()) }
        var firstError: Error?
        for (index, id) in order.enumerated() {
            if index > 0, isCooling(id) { continue }
            do {
                let text = try await attempt(passage, serviceID: id, fields: id == serviceID ? fields : standInFields(id),
                                             secrets: id == serviceID ? secrets : [:], from: source, to: target)
                return Result(text: text, serviceID: id, fellBackFrom: id == serviceID ? nil : serviceID)
            } catch let error as ProviderError where isTransient(error) {
                cool(id, seconds: error.retryAfter.map { min(max($0, 20), 300) } ?? 60)
                if firstError == nil { firstError = error }
                continue
            } catch {
                // Not a passing problem (a key missing, an agent not installed…): say so, unless a stand-in already failed too.
                if index == 0 { throw describe(error) }
                continue
            }
        }
        if let error = firstError as? ProviderError, case .http(429) = error.kind {
            throw Failure.message(String(localized: "翻译服务暂时限流，请稍后再试，或在 设置 ▸ 划词翻译 中换用其他服务", bundle: .module))
        }
        throw describe(firstError ?? Failure.empty)
    }

    /// One service, with up to two quick retries of a passing problem.
    private static func attempt(_ passage: String, serviceID: String, fields: [String: String], secrets: [String: String],
                                from source: String, to target: String) async throws -> String {
        let provider = try ProviderFactory.make(serviceID: serviceID, fields: fields, secrets: secrets, concurrency: nil)
        let context = TranslationContext(sourceLanguage: source, targetLanguage: target, title: nil, summary: nil, glossary: [])
        // Paragraphs go as separate items, so every service keeps them apart.
        let items = passage.components(separatedBy: "\n\n").map {
            TranslationItem(text: $0, kind: $0.count < 60 && !$0.contains(". ") ? .heading : .paragraph)
        }
        var delays: [Double] = [0.7, 1.8]
        while true {
            do {
                let reply = try await provider.translate(items, context: context)
                let result = reply.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                guard !result.isEmpty else { throw Failure.empty }
                return result
            } catch let error as ProviderError where isTransient(error) && !delays.isEmpty {
                if error.kind == .cancelled { throw CancellationError() }
                let wait = min(error.retryAfter ?? delays.removeFirst(), 3)
                try await Task.sleep(for: .seconds(wait))
            } catch let error as ProviderError where error.kind == .cancelled {
                throw CancellationError()
            }
        }
    }

    private static func describe(_ error: Error) -> Error {
        switch error {
        case is Failure, is CancellationError: return error
        case let error as TranslationConfigurationError: return Failure.message(error.errorDescription ?? "\(error)")
        case let error as ProviderError:
            let detail = error.detail + (error.host.map { " https://\($0)/" } ?? "")
            return Failure.message(TranslationErrorClassifier.classify(message: detail).message)
        default: return Failure.message(TranslationErrorClassifier.classify(message: "\(error)").message)
        }
    }
}
