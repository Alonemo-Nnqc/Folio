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

    /// The translation of `text` with the service's current values; errors come back in plain words.
    public static func translate(_ text: String, serviceID: String, fields: [String: String], secrets: [String: String],
                                 from source: String, to target: String) async throws -> String {
        let passage = normalized(text)
        guard !passage.isEmpty else { throw Failure.empty }
        do {
            let provider = try ProviderFactory.make(serviceID: serviceID, fields: fields, secrets: secrets, concurrency: nil)
            let context = TranslationContext(sourceLanguage: source, targetLanguage: target, title: nil, summary: nil, glossary: [])
            // Paragraphs go as separate items, so every service keeps them apart.
            let paragraphs = passage.components(separatedBy: "\n\n")
            let items = paragraphs.map { TranslationItem(text: $0, kind: $0.count < 60 && !$0.contains(". ") ? .heading : .paragraph) }
            let reply = try await provider.translate(items, context: context)
            let result = reply.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !result.isEmpty else { throw Failure.empty }
            return result
        } catch let error as Failure {
            throw error
        } catch let error as TranslationConfigurationError {
            throw Failure.message(error.errorDescription ?? "\(error)")
        } catch let error as ProviderError {
            if error.kind == .cancelled { throw CancellationError() }
            let detail = error.detail + (error.host.map { " https://\($0)/" } ?? "")
            throw Failure.message(TranslationErrorClassifier.classify(message: detail).message)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.message(TranslationErrorClassifier.classify(message: "\(error)").message)
        }
    }
}
