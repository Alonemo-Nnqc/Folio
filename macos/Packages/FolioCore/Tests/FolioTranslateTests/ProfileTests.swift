import Foundation
import os
import Testing
@testable import FolioTranslate

/// Keys in memory instead of the Keychain.
final class MemorySecrets: SecretStoring {
    private let values = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    func get(serviceID: String, option: String) throws -> String? { values.withLock { $0["\(serviceID)|\(option)"] } }
    func set(_ value: String, serviceID: String, option: String) throws { values.withLock { $0["\(serviceID)|\(option)"] = value } }
    func delete(serviceID: String, option: String) throws { values.withLock { $0["\(serviceID)|\(option)"] = nil } }
}

@Suite struct ProfileTests {
    let service = TranslationServiceCatalog.service(id: "openaicompatible")!

    @Test func switchingBetweenProvidersSwapsFieldsAndKeys() throws {
        let secrets = MemorySecrets()
        let key = "--openai-compatible-api-key", url = "--openai-compatible-base-url", model = "--openai-compatible-model"
        // The user has DeepSeek configured and saves it.
        try secrets.set("sk-deepseek", serviceID: service.id, option: key)
        let deepseek = try TranslationProfiles.capture(
            name: "DeepSeek", service: service, fields: [url: "https://api.deepseek.com/v1", model: "deepseek-chat", "--x": ""], secrets: secrets)
        #expect(deepseek.fields == [url: "https://api.deepseek.com/v1", model: "deepseek-chat"], "empty values are not kept")
        // A second provider, with its own key.
        let moonshot = TranslationProfile(name: "Moonshot", serviceID: service.id, fields: [url: "https://api.moonshot.cn/v1", model: "kimi-k2"])
        try TranslationProfiles.recordSecret("sk-moonshot", option: key, in: moonshot, secrets: secrets)

        var fields = try TranslationProfiles.apply(moonshot, service: service, secrets: secrets)
        #expect(fields[url] == "https://api.moonshot.cn/v1")
        #expect(try secrets.get(serviceID: service.id, option: key) == "sk-moonshot")
        fields = try TranslationProfiles.apply(deepseek, service: service, secrets: secrets)
        #expect(fields[model] == "deepseek-chat")
        #expect(try secrets.get(serviceID: service.id, option: key) == "sk-deepseek")

        // A profile without a key clears the previous provider's key.
        let local = TranslationProfile(name: "vLLM", serviceID: service.id, fields: [url: "http://localhost:8000/v1"])
        _ = try TranslationProfiles.apply(local, service: service, secrets: secrets)
        #expect(try secrets.get(serviceID: service.id, option: key) == nil)

        try TranslationProfiles.deleteSecrets(of: moonshot, service: service, secrets: secrets)
        #expect(try secrets.get(serviceID: moonshot.secretOwner, option: key) == nil)
        #expect(try secrets.get(serviceID: deepseek.secretOwner, option: key) == "sk-deepseek", "other profiles keep theirs")
    }

    @Test func suggestedNamesComeFromTheHost() {
        let url = "--openai-compatible-base-url"
        let existing = [TranslationProfile(name: "api.deepseek.com", serviceID: service.id)]
        #expect(TranslationProfiles.suggestedName(service: service, fields: [url: "https://api.moonshot.cn/v1"], existing: existing) == "api.moonshot.cn")
        #expect(TranslationProfiles.suggestedName(service: service, fields: [url: "https://api.deepseek.com/v1"], existing: existing) == "api.deepseek.com 2")
        #expect(TranslationProfiles.suggestedName(service: service, fields: [:], existing: []) == service.displayName)
        #expect(TranslationProfiles.supportsProfiles(service))
        #expect(!TranslationProfiles.supportsProfiles(TranslationServiceCatalog.service(id: TranslationServiceCatalog.appleServiceID)!))
    }
}
