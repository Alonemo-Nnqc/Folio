import Foundation
import Testing
@testable import FolioTranslate

@Suite struct ReasoningEffortTests {
    /// The extra request body the provider sends.
    func body(_ service: String, _ fields: [String: String], secrets: [String: String] = [:]) throws -> [String: any Sendable] {
        let provider = try ProviderFactory.make(serviceID: service, fields: fields, secrets: secrets, concurrency: nil)
        return (provider as? OpenAIChatProvider)?.extraBody ?? [:]
    }

    @Test func choicesFollowTheModel() {
        guard case let .choices(gpt5, d5) = ReasoningEffort.support(serviceID: "openai", fields: ["--openai-model": "gpt-5-mini"]) else {
            Issue.record("gpt-5 should reason"); return
        }
        #expect(gpt5.map(\.value) == ["minimal", "low", "medium", "high", "xhigh"])
        // Later generations behind a compatible endpoint get the same range.
        guard case let .choices(gpt6, d6) = ReasoningEffort.support(serviceID: "openaicompatible", fields: ["--openai-compatible-model": "gpt-6.1-sol"]) else {
            Issue.record("gpt-6 reasons"); return
        }
        #expect(gpt6.map(\.value) == ["minimal", "low", "medium", "high", "xhigh"] && d6 == "medium")
        #expect(d5 == "medium")
        guard case let .choices(o3, _) = ReasoningEffort.support(serviceID: "openai", fields: ["--openai-model": "o3"]) else {
            Issue.record("o3 should reason"); return
        }
        #expect(o3.map(\.value) == ["low", "medium", "high"])
        #expect(ReasoningEffort.support(serviceID: "openai", fields: ["--openai-model": "gpt-4o-mini"]) == .unsupportedModel)
        #expect(ReasoningEffort.support(serviceID: "bing", fields: [:]) == .none)
        if case let .choices(deepseek, _) = ReasoningEffort.support(serviceID: "deepseek", fields: [:]) {
            #expect(deepseek.map(\.value) == ["", "off", "high", "max"])
        } else { Issue.record("deepseek") }
    }

    @Test func defaultMediumIsSentForReasoningModels() throws {
        let extra = try body("openai", ["--openai-model": "gpt-5"], secrets: ["--openai-api-key": "k"])
        #expect(extra["reasoning_effort"] as? String == "medium")
    }

    @Test func nothingIsSentForModelsThatCannotReason() throws {
        let extra = try body("openai", ["--openai-model": "gpt-4o", "--openai-reasoning-effort": "high"], secrets: ["--openai-api-key": "k"])
        #expect(extra["reasoning_effort"] == nil)
    }

    @Test func deepseekMapsToThinkingMode() throws {
        var fields: [String: String] = [:]
        ReasoningEffort.set("max", serviceID: "deepseek", fields: &fields)
        let on = try body("deepseek", fields, secrets: ["--deepseek-api-key": "k"])
        #expect((on["thinking"] as? [String: String])?["type"] == "enabled")
        #expect(on["reasoning_effort"] as? String == "max")
        ReasoningEffort.set("off", serviceID: "deepseek", fields: &fields)
        let off = try body("deepseek", fields, secrets: ["--deepseek-api-key": "k"])
        #expect((off["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(off["reasoning_effort"] == nil)
    }

    @Test func compatibleEndpointsDefaultToNotSending() throws {
        let plain = try body("openaicompatible", ["--openai-compatible-base-url": "http://x/v1", "--openai-compatible-model": "qwen3"],
                             secrets: ["--openai-compatible-api-key": "k"])
        #expect(plain["reasoning_effort"] == nil)
        var fields = ["--openai-compatible-base-url": "http://x/v1", "--openai-compatible-model": "qwen3"]
        ReasoningEffort.set("high", serviceID: "openaicompatible", fields: &fields)
        let high = try body("openaicompatible", fields, secrets: ["--openai-compatible-api-key": "k"])
        #expect(high["reasoning_effort"] as? String == "high")
    }
}
