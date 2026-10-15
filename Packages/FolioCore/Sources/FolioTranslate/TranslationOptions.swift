import Foundation

/// General translation options (TRANS-03 "通用选项").
public struct TranslationOptions: Sendable, Hashable, Codable {
    public enum Outputs: String, Sendable, Hashable, Codable, CaseIterable {
        /// 纯译文
        case mono
        /// 双语对照
        case dual
        /// 两者
        case both
    }

    public enum DualLayout: String, Sendable, Hashable, Codable, CaseIterable {
        /// 左右对照（原文页与译文页并排在同一页）
        case sideBySide
        /// 上下交替页（原文页、译文页交替）
        case alternatingPages
    }

    /// pdf2zh_next language code of the source, e.g. `en`.
    public var langIn: String = "en"
    /// pdf2zh_next language code of the target, e.g. `zh` (Simplified Chinese).
    public var langOut: String = "zh"
    public var outputs: Outputs = .both
    public var dualLayout: DualLayout = .sideBySide
    /// Page selection in pdf2zh syntax (`1,3,5-7`); nil = all pages.
    public var pages: String?
    /// With `pages`, drop untranslated pages from the output.
    public var onlyIncludeTranslatedPages: Bool = false
    /// Optional glossary CSV (`source,target[,tgt_lng]`).
    public var glossaryFile: URL?
    public var translateTableText: Bool = false
    public var enhanceCompatibility: Bool = false
    /// Requests per second; nil = pdf2zh_next default (4).
    public var qps: Int?
    /// Ignore pdf2zh_next's translation cache.
    public var ignoreCache: Bool = false
    /// Additional raw arguments, appended last (for diagnostics).
    public var extraArguments: [String] = []

    public init(langIn: String = "en", langOut: String = "zh", outputs: Outputs = .both,
                dualLayout: DualLayout = .sideBySide, pages: String? = nil,
                onlyIncludeTranslatedPages: Bool = false, glossaryFile: URL? = nil,
                translateTableText: Bool = false, enhanceCompatibility: Bool = false,
                qps: Int? = nil, ignoreCache: Bool = false, extraArguments: [String] = []) {
        self.langIn = langIn
        self.langOut = langOut
        self.outputs = outputs
        self.dualLayout = dualLayout
        self.pages = pages
        self.onlyIncludeTranslatedPages = onlyIncludeTranslatedPages
        self.glossaryFile = glossaryFile
        self.translateTableText = translateTableText
        self.enhanceCompatibility = enhanceCompatibility
        self.qps = qps
        self.ignoreCache = ignoreCache
        self.extraArguments = extraArguments
    }

    /// Common target languages offered in settings (pdf2zh code, display name).
    public static let commonLanguages: [(code: String, name: String)] = [
        ("en", "英语"), ("zh", "简体中文"), ("zh-TW", "繁体中文"), ("ja", "日语"), ("ko", "韩语"),
        ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"), ("it", "意大利语"), ("pt", "葡萄牙语"),
        ("ru", "俄语"), ("ar", "阿拉伯语"),
    ]
}

/// Everything needed to translate one PDF.
public struct TranslationRequest: Sendable, Hashable {
    public var input: URL
    /// Directory receiving the translated PDFs (created if needed).
    public var outputDirectory: URL
    public var serviceID: String
    /// Non-secret field values keyed by CLI option (`--openai-model` → `gpt-4o`).
    /// Toggle fields use "true" / "false".
    public var fieldValues: [String: String]
    /// Secret field values keyed by CLI option, normally read from `SecretStore`.
    public var secrets: [String: String]
    public var options: TranslationOptions

    public init(input: URL, outputDirectory: URL, serviceID: String, fieldValues: [String: String] = [:],
                secrets: [String: String] = [:], options: TranslationOptions = .init()) {
        self.input = input
        self.outputDirectory = outputDirectory
        self.serviceID = serviceID
        self.fieldValues = fieldValues
        self.secrets = secrets
        self.options = options
    }
}

public enum TranslationConfigurationError: Error, LocalizedError, Sendable, Equatable {
    case unknownService(String)
    case missingField(service: String, field: String)
    case appleTranslatorUnavailable

    public var errorDescription: String? {
        switch self {
        case .unknownService(let id): "未知的翻译服务：\(id)"
        case .missingField(let service, let field): "\(service) 需要填写“\(field)”，请在设置的“翻译”页补充。"
        case .appleTranslatorUnavailable: "找不到 Apple 系统翻译组件（folio-apple-translate）。"
        }
    }
}

/// Command line for one translation: arguments for pdf2zh_next (after the
/// driver's `translate` subcommand) plus extra environment (secrets).
public struct TranslationCommandLine: Sendable, Hashable {
    public var arguments: [String]
    /// `PDF2ZH_*` variables carrying secret values.
    public var environment: [String: String]
}

public enum TranslationArgumentBuilder {
    /// Builds pdf2zh_next arguments for `request`.
    ///
    /// - Parameter appleTranslatorCommand: command line of the Apple translation
    ///   helper (executable + leading arguments), required for the Apple service.
    public static func build(_ request: TranslationRequest, appleTranslatorCommand: [String]? = nil) throws -> TranslationCommandLine {
        guard let service = TranslationServiceCatalog.service(id: request.serviceID) else {
            throw TranslationConfigurationError.unknownService(request.serviceID)
        }
        let options = request.options
        var args: [String] = [service.cliSwitch]
        var env: [String: String] = [:]

        if service.id == TranslationServiceCatalog.appleServiceID {
            guard let command = appleTranslatorCommand, !command.isEmpty else {
                throw TranslationConfigurationError.appleTranslatorUnavailable
            }
            let full = command + ["--from", options.langIn, "--to", options.langOut]
            args += ["--clitranslator-command", full.map(shellQuote).joined(separator: " ")]
            args += ["--clitranslator-timeout", "120"]
        }

        // Reasoning effort is stored as one choice; expand it into the options and "send" switches.
        let fieldValues = ReasoningEffort.apply(serviceID: service.id, to: request.fieldValues)
        for field in service.fields {
            let raw = field.isSecret ? request.secrets[field.option] : fieldValues[field.option]
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            switch field.kind {
            case .toggle:
                if value == "true" || value == "1" { args.append(field.option) }
            case .secret:
                if value.isEmpty {
                    if field.isRequired { throw TranslationConfigurationError.missingField(service: service.displayName, field: field.title) }
                } else {
                    env[field.environmentName] = value
                }
            default:
                if value.isEmpty {
                    if field.isRequired && field.defaultValue == nil {
                        throw TranslationConfigurationError.missingField(service: service.displayName, field: field.title)
                    }
                } else {
                    // A bare host means its /v1, as when listing models (OpenAIBaseURL).
                    args += [field.option, OpenAIBaseURL.options.contains(field.option) ? OpenAIBaseURL.normalized(value) : value]
                }
            }
        }

        args += ["--lang-in", options.langIn, "--lang-out", options.langOut]
        args += ["--output", request.outputDirectory.path]
        args += ["--watermark-output-mode", "no_watermark"]
        switch options.outputs {
        case .mono: args.append("--no-dual")
        case .dual: args.append("--no-mono")
        case .both: break
        }
        if options.outputs != .mono, options.dualLayout == .alternatingPages {
            args.append("--use-alternating-pages-dual")
        }
        if let pages = options.pages?.replacingOccurrences(of: " ", with: ""), !pages.isEmpty {
            args += ["--pages", pages]
            if options.onlyIncludeTranslatedPages { args.append("--only-include-translated-page") }
        }
        if let glossary = options.glossaryFile { args += ["--glossaries", glossary.path] }
        if options.translateTableText { args.append("--translate-table-text") }
        if options.enhanceCompatibility { args.append("--enhance-compatibility") }
        if let qps = options.qps, qps > 0 { args += ["--qps", String(qps)] }
        if options.ignoreCache { args.append("--ignore-cache") }
        args += ["--report-interval", "0.5"]
        args += options.extraArguments
        args.append(request.input.path)
        return TranslationCommandLine(arguments: args, environment: env)
    }

    /// POSIX shell quoting compatible with Python's `shlex.split`.
    static func shellQuote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_-+=:,./")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
