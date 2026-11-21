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

    /// Language code of the source, e.g. `en`.
    public var langIn: String = "en"
    /// Language code of the target, e.g. `zh` (Simplified Chinese).
    public var langOut: String = "zh"
    public var outputs: Outputs = .both
    public var dualLayout: DualLayout = .sideBySide
    /// Page selection (`1,3,5-7`); nil = all pages.
    public var pages: String?
    /// With `pages`, drop untranslated pages from the output.
    public var onlyIncludeTranslatedPages: Bool = false
    /// Optional glossary CSV (`source,target`).
    public var glossaryFile: URL?
    /// Terms a model finds in a paper go into Folio's glossary, for the papers translated after it.
    public var rememberTerms: Bool = true
    /// Translate table cells in place.
    public var translateTables: Bool = true
    /// Translate the reference list too.
    public var translateReferences: Bool = false
    /// Translate the words inside pictures too (read with OCR, set back over the picture in place).
    public var translateImageText: Bool = false
    /// Parallel requests; nil = the service's own.
    public var concurrency: Int?
    /// Translate again instead of reusing earlier translations of the same text.
    public var ignoreCache: Bool = false
    /// A paper translated again by the same service and model: both kept (told apart by time), or the old one replaced.
    public var duplicates: Duplicates = .keepBoth

    public enum Duplicates: String, Sendable, Hashable, Codable, CaseIterable {
        case keepBoth, replace
    }

    public init(langIn: String = "en", langOut: String = "zh", outputs: Outputs = .both,
                dualLayout: DualLayout = .sideBySide, pages: String? = nil,
                onlyIncludeTranslatedPages: Bool = false, glossaryFile: URL? = nil,
                translateTables: Bool = true, translateReferences: Bool = false,
                concurrency: Int? = nil, ignoreCache: Bool = false) {
        self.langIn = langIn
        self.langOut = langOut
        self.outputs = outputs
        self.dualLayout = dualLayout
        self.pages = pages
        self.onlyIncludeTranslatedPages = onlyIncludeTranslatedPages
        self.glossaryFile = glossaryFile
        self.translateTables = translateTables
        self.translateReferences = translateReferences
        self.concurrency = concurrency
        self.ignoreCache = ignoreCache
    }

    private enum CodingKeys: String, CodingKey {
        case langIn, langOut, outputs, dualLayout, pages, onlyIncludeTranslatedPages, glossaryFile, rememberTerms
        case translateTables, translateReferences, translateImageText, concurrency, ignoreCache, duplicates
    }

    /// Reads settings saved by any version: missing keys keep their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TranslationOptions()
        langIn = try c.decodeIfPresent(String.self, forKey: .langIn) ?? defaults.langIn
        langOut = try c.decodeIfPresent(String.self, forKey: .langOut) ?? defaults.langOut
        outputs = (try? c.decodeIfPresent(Outputs.self, forKey: .outputs)) ?? defaults.outputs
        dualLayout = (try? c.decodeIfPresent(DualLayout.self, forKey: .dualLayout)) ?? defaults.dualLayout
        pages = try c.decodeIfPresent(String.self, forKey: .pages)
        onlyIncludeTranslatedPages = try c.decodeIfPresent(Bool.self, forKey: .onlyIncludeTranslatedPages) ?? false
        glossaryFile = try? c.decodeIfPresent(URL.self, forKey: .glossaryFile)
        rememberTerms = (try? c.decodeIfPresent(Bool.self, forKey: .rememberTerms)) ?? true
        translateTables = try c.decodeIfPresent(Bool.self, forKey: .translateTables) ?? true
        translateReferences = try c.decodeIfPresent(Bool.self, forKey: .translateReferences) ?? false
        translateImageText = try c.decodeIfPresent(Bool.self, forKey: .translateImageText) ?? false
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency)
        ignoreCache = try c.decodeIfPresent(Bool.self, forKey: .ignoreCache) ?? false
        duplicates = (try? c.decodeIfPresent(Duplicates.self, forKey: .duplicates)) ?? .keepBoth
    }

    /// Common target languages offered in settings (code, display name).
    public static let commonLanguages: [(code: String, name: String)] = [
        ("en", String(localized: "英语", bundle: .module)), ("zh", String(localized: "简体中文", bundle: .module)), ("zh-TW", String(localized: "繁体中文", bundle: .module)), ("ja", String(localized: "日语", bundle: .module)), ("ko", String(localized: "韩语", bundle: .module)),
        ("fr", String(localized: "法语", bundle: .module)), ("de", String(localized: "德语", bundle: .module)), ("es", String(localized: "西班牙语", bundle: .module)), ("it", String(localized: "意大利语", bundle: .module)), ("pt", String(localized: "葡萄牙语", bundle: .module)),
        ("ru", String(localized: "俄语", bundle: .module)), ("ar", String(localized: "阿拉伯语", bundle: .module)),
    ]

    /// Page numbers (1-based) selected by `pages` within a document of `count` pages; all pages when unset.
    public func pageNumbers(count: Int) -> [Int] {
        PageSelection(pages).pages(count: count)
    }
}

/// A page range as people type it: "1-3,5", "4-" (to the end), and the same with full-width digits, Chinese
/// punctuation and other dashes ("１－３，５", "1~3、5", "第3页"); empty or "全部" for every page.
public enum PageSelection: Sendable, Equatable {
    case all
    /// Inclusive ranges as typed; an open end is 1 or `Int.max`.
    case ranges([ClosedRange<Int>])
    /// Not page numbers: nothing can be selected by it.
    case unreadable

    public init(_ text: String?) {
        // Full-width digits and punctuation (１２，－～；) as their ASCII forms.
        var s = (text ?? "").precomposedStringWithCompatibilityMapping.lowercased()
        for dash in ["–", "—", "−", "‐", "‑", "‒", "―", "~", "〜", "至", "到"] { s = s.replacingOccurrences(of: dash, with: "-") }
        for comma in ["、", ";"] { s = s.replacingOccurrences(of: comma, with: ",") }
        for word in ["第", "页", "頁"] { s = s.replacingOccurrences(of: word, with: "") }
        s = s.replacingOccurrences(of: #"\s*-\s*"#, with: "-", options: .regularExpression)
        let parts = s.split { $0 == "," || $0.isWhitespace }.map(String.init)
        if parts.isEmpty || parts.count == 1 && ["全部", "所有", "全文", "all"].contains(parts[0]) {
            self = .all
            return
        }
        var ranges: [ClosedRange<Int>] = []
        for part in parts {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            func number(_ text: String, open: Int) -> Int? { text.isEmpty ? open : Int(text).flatMap { $0 >= 1 ? $0 : nil } }
            switch bounds.count {
            case 1:
                guard let n = number(bounds[0], open: 0), n >= 1 else { self = .unreadable; return }
                ranges.append(n...n)
            case 2:
                guard bounds[0].count + bounds[1].count > 0, let lo = number(bounds[0], open: 1), let hi = number(bounds[1], open: .max) else {
                    self = .unreadable
                    return
                }
                ranges.append(min(lo, hi)...max(lo, hi))
            default:
                self = .unreadable
                return
            }
        }
        self = .ranges(ranges)
    }

    /// The pages (1-based) selected in a document of `count` pages.
    public func pages(count: Int) -> [Int] {
        switch self {
        case .all:
            return Array(1...max(count, 1))
        case .ranges(let ranges):
            var result: Set<Int> = []
            for range in ranges where range.lowerBound <= count { result.formUnion(range.lowerBound...min(range.upperBound, count)) }
            return result.sorted()
        case .unreadable:
            return []
        }
    }

    /// What is wrong with a page range typed by the user, in words for them; nil when it can be used.
    public static func problem(with text: String?) -> String? {
        guard PageSelection(text) == .unreadable else { return nil }
        return unreadableMessage((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func unreadableMessage(_ typed: String) -> String {
        String(localized: "无法识别页码范围「\(typed)」。请填写如 1-3,5 的页码，或留空以翻译全部页。", bundle: .module)
    }
}

/// Everything needed to translate one PDF.
public struct TranslationRequest: Sendable, Hashable {
    public var input: URL
    /// Directory receiving the translated PDFs (created if needed).
    public var outputDirectory: URL
    public var serviceID: String
    /// Non-secret field values keyed by field option (`--openai-model` → `gpt-5`).
    public var fieldValues: [String: String]
    /// Secret field values keyed by option, normally read from `SecretStore`.
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
