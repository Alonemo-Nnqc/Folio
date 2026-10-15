import Foundation
import Testing
@testable import FolioTranslate

@Suite struct ArgumentBuilderTests {
    let input = URL(fileURLWithPath: "/tmp/in dir/paper.pdf")
    let output = URL(fileURLWithPath: "/tmp/out")

    func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @Test func defaults() throws {
        let line = try TranslationArgumentBuilder.build(TranslationRequest(input: input, outputDirectory: output, serviceID: "siliconflowfree"))
        let args = line.arguments
        #expect(args.first == "--siliconflowfree")
        #expect(value(after: "--lang-in", in: args) == "en")
        #expect(value(after: "--lang-out", in: args) == "zh")
        #expect(value(after: "--output", in: args) == "/tmp/out")
        #expect(value(after: "--watermark-output-mode", in: args) == "no_watermark")
        #expect(!args.contains("--no-mono") && !args.contains("--no-dual"))
        #expect(!args.contains("--use-alternating-pages-dual"))
        #expect(!args.contains("--pages") && !args.contains("--qps") && !args.contains("--glossaries"))
        #expect(!args.contains("--translate-table-text") && !args.contains("--enhance-compatibility"))
        #expect(args.last == "/tmp/in dir/paper.pdf")
        #expect(line.environment.isEmpty)
    }

    @Test func outputsAndLayout() throws {
        var options = TranslationOptions(outputs: .mono, dualLayout: .alternatingPages)
        var args = try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "bing", options: options)).arguments
        #expect(args.contains("--no-dual") && !args.contains("--no-mono"))
        #expect(!args.contains("--use-alternating-pages-dual"), "layout is irrelevant without dual output")

        options.outputs = .dual
        args = try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "bing", options: options)).arguments
        #expect(args.contains("--no-mono") && !args.contains("--no-dual"))
        #expect(args.contains("--use-alternating-pages-dual"))

        options.outputs = .both
        options.dualLayout = .sideBySide
        args = try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "bing", options: options)).arguments
        #expect(!args.contains("--no-mono") && !args.contains("--no-dual") && !args.contains("--use-alternating-pages-dual"))
    }

    @Test func generalOptions() throws {
        let options = TranslationOptions(langIn: "ja", langOut: "zh-TW", pages: " 1, 3-5 ", onlyIncludeTranslatedPages: true,
                                         glossaryFile: URL(fileURLWithPath: "/tmp/terms.csv"), translateTableText: true,
                                         enhanceCompatibility: true, qps: 8, ignoreCache: true)
        let args = try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "google", options: options)).arguments
        #expect(value(after: "--lang-in", in: args) == "ja")
        #expect(value(after: "--lang-out", in: args) == "zh-TW")
        #expect(value(after: "--pages", in: args) == "1,3-5")
        #expect(args.contains("--only-include-translated-page"))
        #expect(value(after: "--glossaries", in: args) == "/tmp/terms.csv")
        #expect(args.contains("--translate-table-text"))
        #expect(args.contains("--enhance-compatibility"))
        #expect(value(after: "--qps", in: args) == "8")
        #expect(args.contains("--ignore-cache"))
    }

    @Test func zeroQPSAndEmptyPagesAreOmitted() throws {
        let options = TranslationOptions(pages: "  ", onlyIncludeTranslatedPages: true, qps: 0)
        let args = try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "google", options: options)).arguments
        #expect(!args.contains("--pages") && !args.contains("--only-include-translated-page") && !args.contains("--qps"))
    }

    @Test func secretsGoToEnvironmentNotArguments() throws {
        let request = TranslationRequest(input: input, outputDirectory: output, serviceID: "openai",
                                         fieldValues: ["--openai-model": "gpt-4.1", "--openai-base-url": " https://proxy.example/v1 ",
                                                       "--openai-enable-json-mode": "true", "--openai-send-temprature": "false"],
                                         secrets: ["--openai-api-key": "sk-secret-123"])
        let line = try TranslationArgumentBuilder.build(request)
        #expect(line.arguments.first == "--openai")
        #expect(!line.arguments.contains { $0.contains("sk-secret") })
        #expect(!line.arguments.contains("--openai-api-key"))
        #expect(line.environment == ["PDF2ZH_OPENAI_API_KEY": "sk-secret-123"])
        #expect(value(after: "--openai-model", in: line.arguments) == "gpt-4.1")
        #expect(value(after: "--openai-base-url", in: line.arguments) == "https://proxy.example/v1")
        #expect(line.arguments.contains("--openai-enable-json-mode"))
        #expect(!line.arguments.contains("--openai-send-temprature"))
    }

    @Test func missingRequiredFieldsThrow() {
        #expect(throws: TranslationConfigurationError.missingField(service: "OpenAI", field: "API Key")) {
            try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "openai"))
        }
        #expect(throws: TranslationConfigurationError.missingField(service: "OpenAI-compatible API", field: "Base URL")) {
            try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "openaicompatible",
                                                       secrets: ["--openai-compatible-api-key": "k"]))
        }
        #expect(throws: TranslationConfigurationError.unknownService("nope")) {
            try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "nope"))
        }
        // Required fields with a pdf2zh default may stay empty.
        #expect(throws: Never.self) {
            try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "ollama"))
            try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "claudecode"))
        }
    }

    @Test func appleServiceUsesCLITranslator() throws {
        #expect(throws: TranslationConfigurationError.appleTranslatorUnavailable) {
            try TranslationArgumentBuilder.build(.init(input: input, outputDirectory: output, serviceID: "apple"))
        }
        let options = TranslationOptions(langIn: "en", langOut: "zh")
        let line = try TranslationArgumentBuilder.build(
            .init(input: input, outputDirectory: output, serviceID: "apple", options: options),
            appleTranslatorCommand: ["/Applications/Folio.app/Contents/MacOS/Folio", "--apple-translate"])
        #expect(line.arguments.first == "--clitranslator")
        #expect(value(after: "--clitranslator-command", in: line.arguments)
                == "/Applications/Folio.app/Contents/MacOS/Folio --apple-translate --from en --to zh")

        let spaced = try TranslationArgumentBuilder.build(
            .init(input: input, outputDirectory: output, serviceID: "apple", options: options),
            appleTranslatorCommand: ["/Users/me/Library/Application Support/Folio/folio-apple-translate"])
        #expect(value(after: "--clitranslator-command", in: spaced.arguments)
                == "'/Users/me/Library/Application Support/Folio/folio-apple-translate' --from en --to zh")
    }

    @Test func shellQuoting() {
        #expect(TranslationArgumentBuilder.shellQuote("plain-arg_1.0") == "plain-arg_1.0")
        #expect(TranslationArgumentBuilder.shellQuote("a b") == "'a b'")
        #expect(TranslationArgumentBuilder.shellQuote("it's") == #"'it'"'"'s'"#)
        #expect(TranslationArgumentBuilder.shellQuote("") == "''")
    }
}
