import Foundation
import Testing
@testable import FolioTranslate

@Suite struct ReasoningEffortTests {
    func args(_ service: String, _ fields: [String: String], secrets: [String: String] = [:]) throws -> [String] {
        let request = TranslationRequest(input: URL(filePath: "/tmp/a.pdf"), outputDirectory: URL(filePath: "/tmp"),
                                         serviceID: service, fieldValues: fields, secrets: secrets)
        return try TranslationArgumentBuilder.build(request).arguments
    }

    @Test func choicesFollowTheModel() {
        guard case let .choices(gpt5, d5) = ReasoningEffort.support(serviceID: "openai", fields: ["--openai-model": "gpt-5-mini"]) else {
            Issue.record("gpt-5 should reason"); return
        }
        #expect(gpt5.map(\.value) == ["minimal", "low", "medium", "high"])
        #expect(d5 == "medium")
        guard case let .choices(o3, _) = ReasoningEffort.support(serviceID: "openai", fields: ["--openai-model": "o3"]) else {
            Issue.record("o3 should reason"); return
        }
        #expect(o3.map(\.value) == ["low", "medium", "high"])
        #expect(ReasoningEffort.support(serviceID: "openai", fields: [:]) == .unsupportedModel, "default gpt-4o-mini")
        #expect(ReasoningEffort.support(serviceID: "bing", fields: [:]) == .none)
        if case let .choices(deepseek, _) = ReasoningEffort.support(serviceID: "deepseek", fields: [:]) {
            #expect(deepseek.map(\.value) == ["", "off", "high", "max"])
        } else { Issue.record("deepseek") }
    }

    @Test func defaultMediumIsSentForReasoningModels() throws {
        let line = try args("openai", ["--openai-model": "gpt-5"], secrets: ["--openai-api-key": "k"])
        #expect(line.contains("--openai-send-reasoning-effort"))
        #expect(line.firstIndex(of: "--openai-reasoning-effort").map { line[$0 + 1] } == "medium")
    }

    @Test func nothingIsSentForModelsThatCannotReason() throws {
        let line = try args("openai", ["--openai-model": "gpt-4o", "--openai-reasoning-effort": "high",
                                       "--openai-send-reasoning-effort": "true"], secrets: ["--openai-api-key": "k"])
        #expect(!line.contains("--openai-reasoning-effort"))
        #expect(!line.contains("--openai-send-reasoning-effort"))
    }

    @Test func deepseekMapsToThinkingMode() throws {
        var fields: [String: String] = [:]
        ReasoningEffort.set("max", serviceID: "deepseek", fields: &fields)
        let on = try args("deepseek", fields, secrets: ["--deepseek-api-key": "k"])
        #expect(on.firstIndex(of: "--deepseek-thinking-mode").map { on[$0 + 1] } == "enabled")
        #expect(on.firstIndex(of: "--deepseek-reasoning-effort").map { on[$0 + 1] } == "max")
        ReasoningEffort.set("off", serviceID: "deepseek", fields: &fields)
        let off = try args("deepseek", fields, secrets: ["--deepseek-api-key": "k"])
        #expect(off.firstIndex(of: "--deepseek-thinking-mode").map { off[$0 + 1] } == "disabled")
        #expect(!off.contains("--deepseek-reasoning-effort"))
    }

    @Test func compatibleEndpointsDefaultToNotSending() throws {
        let line = try args("openaicompatible", ["--openai-compatible-base-url": "http://x/v1", "--openai-compatible-model": "qwen3"],
                            secrets: ["--openai-compatible-api-key": "k"])
        #expect(!line.contains("--openai-compatible-send-reasoning-effort"))
        var fields = ["--openai-compatible-base-url": "http://x/v1", "--openai-compatible-model": "qwen3"]
        ReasoningEffort.set("high", serviceID: "openaicompatible", fields: &fields)
        let high = try args("openaicompatible", fields, secrets: ["--openai-compatible-api-key": "k"])
        #expect(high.contains("--openai-compatible-send-reasoning-effort"))
    }
}
