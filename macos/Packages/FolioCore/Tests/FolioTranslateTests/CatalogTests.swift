import Foundation
import Testing
@testable import FolioTranslate

@Suite struct CatalogTests {
    @Test func identifiersAndOptionsAreUnique() {
        let ids = TranslationServiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for service in TranslationServiceCatalog.all {
            let options = service.fields.map(\.option)
            #expect(Set(options).count == options.count, "\(service.id) has duplicate fields")
        }
    }

    @Test func keysOfExistingSettingsAreKept() {
        // Stored values and Keychain items of the pdf2zh_next era keep working.
        #expect(TranslationServiceCatalog.service(id: "openai")?.secretFields.map(\.option) == ["--openai-api-key"])
        #expect(TranslationServiceCatalog.service(id: "openaicompatible")?.fields.map(\.option).contains("--openai-compatible-base-url") == true)
        #expect(TranslationServiceCatalog.service(id: "deepseek")?.fields.map(\.option).contains("--deepseek-model") == true)
        #expect(TranslationServiceCatalog.service(id: "claudecode")?.fields.map(\.option).contains("--claude-code-model") == true)
    }

    @Test func removedServicesHaveReplacements() {
        #expect(TranslationServiceCatalog.resolve("siliconflowfree").id == "google")
        #expect(TranslationServiceCatalog.resolve("dify").id == "openaicompatible")
        #expect(TranslationServiceCatalog.resolve("nonsense").id == TranslationServiceCatalog.defaultServiceID)
        #expect(TranslationServiceCatalog.resolve("deepl").id == "deepl")
    }

    @Test func freeAndAgentServicesNeedNoSecrets() {
        for service in TranslationServiceCatalog.all where service.isFree {
            #expect(service.secretFields.isEmpty, "\(service.id)")
        }
        for agent in LocalAgent.allCases {
            let service = TranslationServiceCatalog.service(id: agent.serviceID)
            #expect(service != nil, "\(agent) has a service")
            if case .agent(let a)? = service?.backend { #expect(a == agent) } else { Issue.record("\(agent): not an agent service") }
        }
    }

    @Test func everyServiceBuildsAProviderFromItsValues() throws {
        for service in TranslationServiceCatalog.all {
            var fields: [String: String] = [:], secrets: [String: String] = [:]
            for field in service.fields where field.isRequired || field.kind == .url {
                switch field.kind {
                case .secret: secrets[field.option] = "key"
                case .url: fields[field.option] = "https://example.com/v1"
                default: fields[field.option] = field.defaultValue ?? "value"
                }
            }
            do {
                let provider = try ProviderFactory.make(serviceID: service.id, fields: fields, secrets: secrets, concurrency: nil)
                #expect(provider.limits.concurrency >= 1 && provider.limits.batchCharacters >= 500, "\(service.id)")
                #expect(provider.limits.usesContext == service.isLLM || service.backend == .qwenMT, "\(service.id)")
            } catch TranslationConfigurationError.agentNotFound, TranslationConfigurationError.appleUnavailable {
                // Not installed on this Mac: reported, not crashed.
            }
        }
    }

    @Test func missingValuesAreNamed() {
        #expect(throws: TranslationConfigurationError.missingField(service: "OpenAI", field: "API Key")) {
            _ = try ProviderFactory.make(serviceID: "openai", fields: [:], secrets: [:], concurrency: nil)
        }
        #expect(throws: TranslationConfigurationError.unknownService("x")) {
            _ = try ProviderFactory.make(serviceID: "x", fields: [:], secrets: [:], concurrency: nil)
        }
    }

    @Test func concurrencyOverride() throws {
        let provider = try ProviderFactory.make(serviceID: "google", fields: [:], secrets: [:], concurrency: 2)
        #expect(provider.limits.concurrency == 2)
    }
}

@Suite struct OptionsTests {
    @Test func settingsOfOlderVersionsStillLoad() throws {
        // Saved by the pdf2zh_next version: other keys, some gone.
        let old = #"{"langIn":"en","langOut":"ja","outputs":"mono","dualLayout":"alternatingPages","translateTableText":false,"enhanceCompatibility":true,"qps":4,"ignoreCache":false,"extraArguments":[]}"#
        let options = try JSONDecoder().decode(TranslationOptions.self, from: Data(old.utf8))
        #expect(options.langOut == "ja" && options.outputs == .mono && options.dualLayout == .alternatingPages)
        #expect(options.translateTables, "tables are translated by default now")
        #expect(!options.translateReferences && options.concurrency == nil)
        let round = try JSONDecoder().decode(TranslationOptions.self, from: JSONEncoder().encode(options))
        #expect(round == options)
    }

    @Test func pageSelection() {
        #expect(TranslationOptions(pages: nil).pageNumbers(count: 3) == [1, 2, 3])
        #expect(TranslationOptions(pages: "1, 3-5,9").pageNumbers(count: 6) == [1, 3, 4, 5])
        #expect(TranslationOptions(pages: "4-").pageNumbers(count: 6) == [4, 5, 6])
        #expect(TranslationOptions(pages: "x").pageNumbers(count: 6) == [])
    }
}

@Suite struct BatchProtocolTests {
    @Test func parsesRepliesWithFencesThinkingAndMissingKeys() {
        #expect(LLMBatch.parse(#"{"1": "甲", "2": "乙"}"#, count: 2) == ["甲", "乙"])
        #expect(LLMBatch.parse("```json\n{\"1\": \"甲\", \"2\": \"乙\"}\n```", count: 2) == ["甲", "乙"])
        #expect(LLMBatch.parse("<think>{\"x\": 1} hmm</think>\n{\"1\": \"甲\"}", count: 1) == ["甲"])
        #expect(LLMBatch.parse("Here you go: {\"2\": \"乙\"}", count: 2) == [nil, "乙"])
        #expect(LLMBatch.parse("no json", count: 1) == [nil])
        // A JSON reply whose value contains fences (Claude Code's output format).
        let wrapped = #"{"type":"result","result":"```json\n{\"1\": \"甲\"}\n```"}"#
        #expect(LLMBatch.jsonObject(in: wrapped)?["type"] as? String == "result")
    }

    @Test func userMessageNumbersItemsAndMarksShortOnes() throws {
        let message = LLMBatch.userMessage([TranslationItem(text: "Introduction", kind: .heading), TranslationItem(text: "We use {v1}.", kind: .paragraph)])
        let json = String(message.split(separator: "\n\n")[0])
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        #expect(object == ["1": "Introduction", "2": "We use {v1}."])
        #expect(message.contains("Short items (headings or table cells): 1"))
    }

    @Test func systemPromptCarriesContext() {
        let context = TranslationContext(sourceLanguage: "en", targetLanguage: "zh", title: "Paper", summary: "Abstract text",
                                         glossary: [GlossaryEntry(source: "domain generalization", target: "域泛化")])
        let prompt = LLMBatch.systemPrompt(context)
        #expect(prompt.contains("Simplified Chinese") && prompt.contains("Paper") && prompt.contains("domain generalization → 域泛化"))
        #expect(prompt.contains("{v1}"))
    }

    @Test func terms() {
        let terms = LLMBatch.parseTerms(#"{"terms": [{"source": "style mixing", "target": "风格混合"}, {"source": "", "target": "x"}]}"#)
        #expect(terms == [GlossaryEntry(source: "style mixing", target: "风格混合")])
    }

    @Test func placeholdersSurviveMangling() {
        #expect(Placeholders.numbers(in: "使用 { v1 } 和 ｛V2｝ 以及 {v10}") == [1, 2, 10])
        #expect(Placeholders.replace(in: "a {v1} b", { "<x id=\"\($0)\"/>" }) == "a <x id=\"1\"/> b")
        #expect(MicrosoftTranslatorProvider.plain(MicrosoftTranslatorProvider.html("x < {v1} & y")) == "x < {v1} & y")
    }

    @Test func longTextIsCutAtSentences() {
        let text = String(repeating: "This is a sentence about segmentation. ", count: 40)
        let chunks = GoogleWebProvider.chunks(text, limit: 300)
        #expect(chunks.allSatisfy { $0.count <= 300 })
        #expect(chunks.joined(separator: " ").replacingOccurrences(of: " ", with: "") == text.replacingOccurrences(of: " ", with: ""))
        #expect(GoogleWebProvider.chunks("short", limit: 300) == ["short"])
    }

    @Test func batchesRespectLimits() {
        let segments = (0..<10).map { TextSegment(page: 1, block: $0, kind: .paragraph, source: String(repeating: "a", count: 400), formulas: []) }
        let batches = TranslationJob.batches(segments, limits: ProviderLimits(batchCharacters: 1000, batchItems: 30, concurrency: 1, usesContext: true))
        #expect(batches.map(\.count) == [2, 2, 2, 2, 2])
        let single = TranslationJob.batches(segments, limits: ProviderLimits(batchCharacters: 5000, batchItems: 3, concurrency: 1, usesContext: true))
        #expect(single.map(\.count) == [3, 3, 3, 1])
    }

    @Test func glossaryCSV() throws {
        let folder = TemporaryDirectory()
        let file = folder.url.appending(path: "g.csv")
        try "source,target\ndomain generalization, 域泛化\n\"mIoU\",mIoU,zh\nbroken\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(TranslationJob.readGlossary(file) == [GlossaryEntry(source: "domain generalization", target: "域泛化"),
                                                       GlossaryEntry(source: "mIoU", target: "mIoU")])
    }
}
