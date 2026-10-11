import Foundation
import Testing
@testable import FolioTranslate

@Suite struct CatalogTests {
    /// `pdf2zh_next --help` of version 2.9.0.
    static let help: String = {
        let url = Bundle.module.url(forResource: "Fixtures/pdf2zh_next-2.9.0-help", withExtension: "txt")!
        return try! String(contentsOf: url, encoding: .utf8)
    }()

    /// Every `--option` mentioned in the help text.
    static let helpOptions: Set<String> = {
        Set(help.matches(of: /(?:^|[\s\[,(])(--[a-z][a-z0-9-]*)/.anchorsMatchLineEndings()).map { String($0.output.1) })
    }()

    static let expectedSwitches = ["--siliconflowfree", "--openai", "--aliyundashscope", "--google", "--bing", "--deepl",
                                   "--deepseek", "--ollama", "--xinference", "--azureopenai", "--modelscope", "--zhipu",
                                   "--siliconflow", "--tencentmechinetranslation", "--gemini", "--azure", "--anythingllm",
                                   "--dify", "--grok", "--groq", "--qwenmt", "--openaicompatible", "--claudecode",
                                   "--clitranslator"]

    @Test func everyPDF2ZHServiceIsInTheCatalog() {
        let switches = Set(TranslationServiceCatalog.all.map(\.cliSwitch))
        for expected in Self.expectedSwitches {
            #expect(switches.contains(expected), "missing \(expected)")
        }
        // 24 pdf2zh_next services + Apple (through --clitranslator).
        #expect(TranslationServiceCatalog.all.count == 25)
    }

    @Test func everySwitchAndFieldExistsInHelp() {
        #expect(Self.helpOptions.count > 150)
        for service in TranslationServiceCatalog.all {
            #expect(Self.helpOptions.contains(service.cliSwitch), "\(service.id): \(service.cliSwitch) not in --help")
            for field in service.fields {
                #expect(Self.helpOptions.contains(field.option), "\(service.id): \(field.option) not in --help")
            }
        }
    }

    @Test func helpServiceSwitchesAreAllCovered() {
        // "Use X for translation" lines list the service switches.
        let lines = Self.help.split(separator: "\n").map(String.init)
        var helpSwitches: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("--"), !trimmed.hasPrefix("--term-") else { continue }
            let rest = trimmed.split(separator: " ", omittingEmptySubsequences: true).dropFirst().joined(separator: " ")
            let description = rest.isEmpty && index + 1 < lines.count ? lines[index + 1].trimmingCharacters(in: .whitespaces) : rest
            if description.hasPrefix("Use "), description.hasSuffix(" for translation") {
                helpSwitches.append(String(trimmed.split(separator: " ")[0]))
            }
        }
        #expect(Set(helpSwitches) == Set(Self.expectedSwitches))
    }

    @Test func identifiersAndOptionsAreUnique() {
        let ids = TranslationServiceCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for service in TranslationServiceCatalog.all {
            let options = service.fields.map(\.option)
            #expect(Set(options).count == options.count, "\(service.id) has duplicate fields")
        }
    }

    @Test func freeServicesNeedNoSecrets() {
        let free = TranslationServiceCatalog.all.filter(\.isFree).map(\.id)
        #expect(free.contains("siliconflowfree") && free.contains("google") && free.contains("bing") && free.contains("apple"))
        for service in TranslationServiceCatalog.all where service.isFree {
            #expect(service.secretFields.isEmpty, "\(service.id)")
        }
        for service in TranslationServiceCatalog.all where !service.isFree && service.id != "claudecode" && service.id != "clitranslator" {
            #expect(!service.requiredFields.isEmpty, "\(service.id) should require something")
        }
    }

    @Test func displayNames() {
        #expect(TranslationServiceCatalog.service(id: "siliconflowfree")?.displayName == "SiliconFlow 免费")
        #expect(TranslationServiceCatalog.service(id: "google")?.displayName == "Google（免费）")
        #expect(TranslationServiceCatalog.service(id: "bing")?.displayName == "Bing（免费）")
        #expect(TranslationServiceCatalog.service(id: "ollama")?.displayName == "Ollama（本地）")
        #expect(TranslationServiceCatalog.service(id: "openaicompatible")?.displayName == "OpenAI 兼容接口")
        #expect(TranslationServiceCatalog.service(id: "apple")?.displayName == "Apple 系统翻译（离线）")
        #expect(TranslationServiceCatalog.service(id: "nope") == nil)
    }

    @Test func secretFieldsMapToPDF2ZHEnvironmentVariables() {
        let openai = TranslationServiceCatalog.service(id: "openai")!
        #expect(openai.secretFields.map(\.environmentName) == ["PDF2ZH_OPENAI_API_KEY"])
        let tencent = TranslationServiceCatalog.service(id: "tencentmechinetranslation")!
        #expect(tencent.secretFields.map(\.environmentName) == ["PDF2ZH_TENCENTCLOUD_SECRET_ID", "PDF2ZH_TENCENTCLOUD_SECRET_KEY"])
        #expect(TranslationServiceCatalog.service(id: "deepl")!.secretFields.first?.environmentName == "PDF2ZH_DEEPL_AUTH_KEY")
    }

    @Test func generalOptionsUsedByTheBuilderExistInHelp() throws {
        let request = TranslationRequest(
            input: URL(fileURLWithPath: "/tmp/a.pdf"), outputDirectory: URL(fileURLWithPath: "/tmp/out"), serviceID: "bing",
            options: TranslationOptions(outputs: .dual, dualLayout: .alternatingPages, pages: "1-3", onlyIncludeTranslatedPages: true,
                                        glossaryFile: URL(fileURLWithPath: "/tmp/g.csv"), translateTableText: true,
                                        enhanceCompatibility: true, qps: 2, ignoreCache: true))
        let line = try TranslationArgumentBuilder.build(request)
        for option in line.arguments where option.hasPrefix("--") {
            #expect(Self.helpOptions.contains(option), "\(option) not in --help")
        }
    }
}
