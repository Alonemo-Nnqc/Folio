import FolioCore
import FolioTranslate
import Foundation
import os
import Testing

@Suite struct SettingsPackageTests {
    nonisolated final class Secrets: SecretStoring {
        let values = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
        func get(serviceID: String, option: String) throws -> String? { values.withLock { $0["\(serviceID).\(option)"] } }
        func set(_ value: String, serviceID: String, option: String) throws { values.withLock { $0["\(serviceID).\(option)"] = value } }
        func delete(serviceID: String, option: String) throws { values.withLock { $0["\(serviceID).\(option)"] = nil } }
    }

    private let key = "--openai-compatible-api-key", url = "--openai-compatible-base-url", service = "openaicompatible"

    private func stores() -> SettingsPackage.Stores {
        let name = "FolioSettingsPackageTests-\(UUID().uuidString)"
        return .init(defaults: UserDefaults(suiteName: name)!, domain: name, translation: Secrets(), journals: Secrets(),
                     glossary: GlossaryStore(url: FileManager.default.temporaryDirectory.appending(path: name + ".json")))
    }

    @Test func settingsKeysAndGlossaryMove() throws {
        let a = stores(), b = stores()
        defer { [a, b].forEach { $0.defaults.removePersistentDomain(forName: $0.domain) } }
        let profile = TranslationProfile(id: "P", name: "DeepSeek", serviceID: service, fields: [url: "https://api.deepseek.com"])
        a.defaults.set(false, forKey: "showReadingRings")
        a.defaults.set(5, forKey: "translationParallelTotal")
        a.defaults.set("dark", forKey: "appearance")
        a.defaults.set("/Volumes/x/Folio", forKey: "libraryPath")
        a.defaults.set([service: [url: "https://api.deepseek.com"]], forKey: "translationFields")
        a.defaults.set(try JSONEncoder().encode([profile]), forKey: "translationProfiles")
        var options = TranslationOptions()
        options.langOut = "ja"
        options.glossaryFile = URL(filePath: "/tmp/x.csv")
        a.defaults.set(try JSONEncoder().encode(options), forKey: "translationOptions")
        a.defaults.set(["en"], forKey: "AppleLanguages")
        a.defaults.set(["TB Is Shown": 1, "data": Data([1])], forKey: "NSToolbar Configuration FolioLibrary")
        a.defaults.set("oa", forKey: "openAlexAPIKey")
        try a.translation.set("sk-1", serviceID: service, option: key)
        try a.translation.set("sk-p", serviceID: profile.secretOwner, option: key)
        try a.journals.set("es", serviceID: "easyscholar", option: "secretKey")
        a.glossary.save(GlossaryTerm(source: "attention", target: "注意力", language: "zh"))
        b.glossary.save(GlossaryTerm(source: "Attention", target: "关注", language: "zh-CN"))
        b.glossary.save(GlossaryTerm(source: "mask", target: "掩码", language: "zh"))
        b.defaults.set(["bing": ["x": "y"]], forKey: "translationFields")

        let data = try SettingsPackage.data(from: a, password: "pw")
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("sk-1") && !text.contains("libraryPath") && !text.contains("x.csv") && !text.contains("\"oa\""))
        let package = try SettingsPackage(data)
        #expect(package.hasSecrets && package.secrets(password: "no") == nil)
        try package.apply(to: b, secrets: package.secrets(password: "pw"))
        #expect(b.defaults.object(forKey: "showReadingRings") as? Bool == false)
        #expect(b.defaults.integer(forKey: "translationParallelTotal") == 5 && b.defaults.string(forKey: "appearance") == "dark")
        #expect(b.defaults.string(forKey: "libraryPath") == nil)
        #expect(b.defaults.dictionary(forKey: "translationFields") as? [String: [String: String]] == [service: [url: "https://api.deepseek.com"], "bing": ["x": "y"]])
        #expect(try JSONDecoder().decode([TranslationProfile].self, from: b.defaults.data(forKey: "translationProfiles")!) == [profile])
        let moved = try JSONDecoder().decode(TranslationOptions.self, from: b.defaults.data(forKey: "translationOptions")!)
        #expect(moved.langOut == "ja" && moved.glossaryFile == nil)
        #expect(b.defaults.stringArray(forKey: "AppleLanguages") == ["en"])
        #expect((b.defaults.dictionary(forKey: "NSToolbar Configuration FolioLibrary")?["data"] as? Data) == Data([1]))
        #expect(try b.translation.get(serviceID: service, option: key) == "sk-1" && b.translation.get(serviceID: "profile.P", option: key) == "sk-p")
        #expect(try b.journals.get(serviceID: "easyscholar", option: "secretKey") == "es" && b.defaults.string(forKey: "openAlexAPIKey") == "oa")
        #expect(b.glossary.terms().map(\.target) == ["注意力", "掩码"])
    }

    @Test func withoutKeysTheKeysHereStayWhereTheyWereFor() throws {
        let a = stores(), b = stores()
        defer { [a, b].forEach { $0.defaults.removePersistentDomain(forName: $0.domain) } }
        a.defaults.set([service: [url: "https://elsewhere.example"]], forKey: "translationFields")
        b.defaults.set([service: [url: "https://api.mine.com"]], forKey: "translationFields")
        try b.translation.set("sk-mine", serviceID: service, option: key)
        let package = try SettingsPackage(SettingsPackage.data(from: a, password: nil))
        #expect(!package.hasSecrets)
        try package.apply(to: b, secrets: nil)
        #expect((b.defaults.dictionary(forKey: "translationFields") as? [String: [String: String]])?[service]?[url] == "https://api.mine.com")
        #expect(try b.translation.get(serviceID: service, option: key) == "sk-mine")
    }

    /// Something of the wrong kind is left out; what Windows wrote is read.
    @Test func settingsOfWindows() throws {
        let b = stores()
        defer { b.defaults.removePersistentDomain(forName: b.domain) }
        let text = #"{"platform":"windows","values":{"showReadingRings":false,"appearance":7,"inkLineWidth":3.5,"translationParallelJobs":3,"translationProfiles":[{"id":"Q","name":"n","serviceID":"openaicompatible","fields":{}}],"translationOptions":{"langIn":"en","langOut":"zh","outputs":"mono","dualLayout":"sideBySide"},"language":""},"platformValues":{"language":"x"},"glossary":[]}"#
        try SettingsPackage(Data(text.utf8)).apply(to: b, secrets: nil)
        #expect(b.defaults.object(forKey: "showReadingRings") as? Bool == false && b.defaults.object(forKey: "appearance") == nil)
        #expect(b.defaults.double(forKey: "inkLineWidth") == 3.5 && b.defaults.integer(forKey: "translationParallelJobs") == 3)
        #expect(try JSONDecoder().decode(TranslationOptions.self, from: b.defaults.data(forKey: "translationOptions")!).outputs == .mono)
        #expect(throws: (any Error).self) { try SettingsPackage(Data("[]".utf8)) }
    }
}
