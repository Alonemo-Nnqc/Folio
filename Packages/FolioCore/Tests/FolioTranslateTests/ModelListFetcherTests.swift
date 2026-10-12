import Foundation
import Testing
@testable import FolioTranslate

@Suite struct ModelListFetcherTests {
    @Test func everyListedServiceExistsWithThatModelField() {
        for (id, endpoint) in ModelListFetcher.endpoints {
            let service = TranslationServiceCatalog.service(id: id)
            #expect(service != nil, "unknown service \(id)")
            #expect(service?.fields.contains { $0.option == endpoint.modelOption } == true, "\(id) has no \(endpoint.modelOption)")
            if let base = endpoint.baseOption { #expect(service?.fields.contains { $0.option == base } == true, "\(id): \(base)") }
            if let key = endpoint.keyOption { #expect(service?.fields.contains { $0.option == key } == true, "\(id): \(key)") }
        }
        #expect(ModelListFetcher.supports(serviceID: "deepseek", modelOption: "--deepseek-model"))
        #expect(!ModelListFetcher.supports(serviceID: "bing", modelOption: "--deepseek-model"))
    }

    @Test func openAIRequestUsesBaseURLAndBearerKey() throws {
        let endpoint = ModelListFetcher.endpoints["openaicompatible"]!
        let request = try ModelListFetcher.makeRequest(endpoint, fieldValues: ["--openai-compatible-base-url": "https://example.com/v1/"],
                                                       secrets: ["--openai-compatible-api-key": "sk-test"])
        #expect(request.url?.absoluteString == "https://example.com/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(throws: ModelListFetcher.FetchError.missingBaseURL) {
            try ModelListFetcher.makeRequest(endpoint, fieldValues: [:], secrets: ["--openai-compatible-api-key": "k"])
        }
        let keyless = try ModelListFetcher.makeRequest(endpoint, fieldValues: ["--openai-compatible-base-url": "http://localhost:1234/v1"], secrets: [:])
        #expect(keyless.value(forHTTPHeaderField: "Authorization") == nil, "local servers need no key")
        #expect(throws: ModelListFetcher.FetchError.missingKey) {
            try ModelListFetcher.makeRequest(ModelListFetcher.endpoints["deepseek"]!, fieldValues: [:], secrets: [:])
        }
    }

    @Test func localServicesNeedNoKey() throws {
        let ollama = try ModelListFetcher.makeRequest(ModelListFetcher.endpoints["ollama"]!, fieldValues: [:], secrets: [:])
        #expect(ollama.url?.absoluteString == "http://localhost:11434/api/tags")
        let xinference = try ModelListFetcher.makeRequest(ModelListFetcher.endpoints["xinference"]!,
                                                          fieldValues: ["--xinference-host": "http://box:9997"], secrets: [:])
        #expect(xinference.url?.absoluteString == "http://box:9997/v1/models")
    }

    @Test func parsesEachShape() throws {
        let openAI = Data(#"{"data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"},{"id":"gpt-4o"}]}"#.utf8)
        #expect(try ModelListFetcher.parse(openAI, api: .openAI(defaultBase: nil)) == ["gpt-4o", "gpt-4o-mini"])
        let ollama = Data(#"{"models":[{"name":"qwen2.5:7b"},{"name":"gemma2:latest"}]}"#.utf8)
        #expect(try ModelListFetcher.parse(ollama, api: .ollama) == ["gemma2:latest", "qwen2.5:7b"])
        let gemini = Data(#"{"models":[{"name":"models/gemini-2.0-flash","supportedGenerationMethods":["generateContent"]},{"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]}]}"#.utf8)
        #expect(try ModelListFetcher.parse(gemini, api: .gemini) == ["gemini-2.0-flash"])
        #expect(throws: ModelListFetcher.FetchError.unreadable) { try ModelListFetcher.parse(Data("[]".utf8), api: .ollama) }
    }

    /// FOLIO_LIVE=1: a real OpenAI-compatible listing that needs no key (OpenRouter).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FOLIO_LIVE"] == "1"))
    func liveOpenAICompatibleListing() async throws {
        let models = try await ModelListFetcher.fetch(serviceID: "openaicompatible",
                                                      fieldValues: ["--openai-compatible-base-url": "https://openrouter.ai/api/v1"],
                                                      secrets: [:])
        #expect(models.count > 20)
        #expect(models.contains { $0.contains("gpt") || $0.contains("claude") })
    }
}
