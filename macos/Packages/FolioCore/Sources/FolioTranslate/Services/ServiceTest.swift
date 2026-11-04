import Foundation

/// Tries a service with one short sentence, so a wrong key, a sign-in that is missing or an outdated gateway shows up in
/// settings rather than halfway through a paper.
public enum TranslationServiceTest {
    public struct Outcome: Sendable, Equatable {
        public var succeeded: Bool
        /// The translation, or what went wrong in plain words.
        public var message: String
    }

    public static func run(serviceID: String, fields: [String: String], secrets: [String: String], language: String = "zh") async -> Outcome {
        do {
            let provider = try ProviderFactory.make(serviceID: serviceID, fields: fields, secrets: secrets, concurrency: nil)
            let context = TranslationContext(sourceLanguage: "en", targetLanguage: language, title: nil, summary: nil, glossary: [])
            let reply = try await provider.translate([TranslationItem(text: "The model achieves high accuracy on {v1} images.", kind: .paragraph)], context: context)
            guard let text = reply.first, !text.isEmpty else { return Outcome(succeeded: false, message: String(localized: "服务没有返回译文", bundle: .module)) }
            return Outcome(succeeded: true, message: text)
        } catch let error as TranslationConfigurationError {
            return Outcome(succeeded: false, message: error.errorDescription ?? "\(error)")
        } catch let error as ProviderError {
            let detail = error.detail + (error.host.map { " https://\($0)/" } ?? "")
            return Outcome(succeeded: false, message: TranslationErrorClassifier.classify(message: detail).message)
        } catch {
            return Outcome(succeeded: false, message: TranslationErrorClassifier.classify(message: "\(error)").message)
        }
    }
}
