import Foundation
import Testing
@testable import FolioTranslate

@Suite struct NamingTests {
    func service(_ id: String) -> TranslationService { TranslationServiceCatalog.service(id: id)! }

    @Test func providerAndModelNameTheVersion() {
        let deepseek = TranslationNaming.Provider(service: service("deepseek"), fields: ["--deepseek-model": "deepseek-chat"], profileName: nil)
        #expect(TranslationNaming.baseName(original: "Zhang_2026_Spectral", kind: .mono, language: "简体中文", provider: deepseek, existing: [])
                == "Zhang_2026_Spectral (简体中文 translation · DeepSeek · deepseek-chat)")
        // A configuration's name is used; notes like "（免费）" are dropped; a model equal to the name is not repeated.
        let moonshot = TranslationNaming.Provider(service: service("openaicompatible"),
                                                  fields: ["--openai-compatible-model": "kimi-k2"], profileName: "Moonshot")
        #expect(TranslationNaming.baseName(original: "P", kind: .dual, language: "简体中文", provider: moonshot, existing: [])
                == "P (bilingual · Moonshot · kimi-k2)")
        let google = TranslationNaming.Provider(service: service("google"), fields: [:], profileName: nil)
        #expect(google.name == "Google" && google.model == nil)
        #expect(TranslationNaming.baseName(original: "P", kind: .mono, language: "简体中文", provider: google, existing: []) == "P (简体中文 translation · Google)")
        let defaultModel = TranslationNaming.Provider(service: service("ollama"), fields: [:], profileName: nil)
        #expect(defaultModel.name == "Ollama" && defaultModel.model == "gemma2", "the default model when none is filled in")
    }

    @Test func theSameProviderAgainGetsTheTimeNotANumber() {
        let google = TranslationNaming.Provider(name: "Google", model: nil)
        var components = DateComponents(year: 2026, month: 10, day: 15, hour: 14, minute: 32)
        components.timeZone = .current
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let name = TranslationNaming.baseName(original: "P", kind: .mono, language: "简体中文", provider: google,
                                              existing: ["P (简体中文 translation · Google)"], date: date)
        #expect(name == "P (简体中文 translation · Google · Oct 15 14.32)")
        #expect(!name.contains(" 2"))
    }
}
